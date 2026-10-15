///|
/// Marks an error raised by an event listener (the `event_sink` chain) so the
/// generation catch passes it to the owning run's lifecycle handler rather
/// than treating it as a provider response. Never escapes `run_agent_loop`.
priv suberror ListenerError {
  ListenerError(Error)
}

///|
/// Runs the agent loop, which generates messages from the LLM and executes tools as needed.
///
/// Provider failures become a terminal `AssistantMessage` with `stop_reason` `Error`
/// or `Aborted`. Errors raised by `event_sink` (an event listener) are re-raised to
/// the caller, where `AgentSession` closes the run like pi's `handleRunFailure`.
pub async fn run_agent_loop(
  llm : &LLM,
  system_prompt : String,
  messages : Array[AgentMessage],
  tools : ArrayView[ToolDefinition],
  prompts : ArrayView[UserMessage],
  tool_executor~ : async (ToolCall, ToolExecUpdateCallback) -> ToolResult,
  steer_channel~ : () -> ArrayView[UserMessage] = fn() { [] },
  abort~ : AbortSignal = AbortSignal::never(),
  // TODO: support follow-up channel
  event_sink~ : async (AgentEvent) -> Unit = _ => (),
  finish_turn_hook~ : FinishTurnHook = (_, _, _) => None,
) -> Unit {
  event_sink(AgentEvent::AgentStart)
  let mut pending_prompts = prompts
  if steer_channel() is ([_, ..] as steer_messages) {
    pending_prompts += steer_messages
  }
  for ;; {
    event_sink(AgentEvent::TurnStart)
    for prompt in pending_prompts {
      let msg = AgentMessage::User(prompt)
      messages.push(msg)
      // Complete messages get start+end back to back, like pi.
      event_sink(AgentEvent::MessageStart(msg))
      event_sink(AgentEvent::MessageEnd(msg))
    }
    pending_prompts = []
    let mut message_started = false
    let assistant_message = llm.generate(
      { system_prompt, messages, tools, },
      sink=event => {
        match event {
          Start(partial~) => {
            message_started = true
            let msg = AgentMessage::Assistant(partial)
            messages.push(msg)
            event_sink(AgentEvent::MessageStart(msg)) catch {
              err => raise ListenerError(err)
            }
          }
          TextStart(partial~, ..)
          | TextDelta(partial~, ..)
          | TextEnd(partial~, ..)
          | ThinkingStart(partial~, ..)
          | ThinkingDelta(partial~, ..)
          | ThinkingEnd(partial~, ..)
          | ToolCallStart(partial~, ..)
          | ToolCallDelta(partial~, ..)
          | ToolCallEnd(partial~, ..) =>
            // 在 Start 之前到达的中间事件违反流契约,直接丢弃;终态消息由 generate 的返回值兜底。
            if message_started {
              messages[messages.length() - 1] = AgentMessage::Assistant(partial)
              // 事件同时带增量和快照:订阅方要么按 delta 追加,要么用 partial 重建。
              event_sink(AgentEvent::MessageUpdate(event)) catch {
                err => raise ListenerError(err)
              }
            }
        }
      },
      abort~,
    ) catch {
      // Listener failures belong to the run lifecycle, not provider generation.
      ListenerError(err) => raise err
      err => {
        let error_message = {
          let text = err.to_string()
          match text.rev_split_once(" FAILED: ") {
            Some((_, message)) =>
              match message.strip_suffix(")") {
                Some(rest) => rest.to_owned()
                None => message.to_owned()
              }
            None => text
          }
        }
        let fallback = AssistantMessage::{
          content: [],
          api: "",
          provider: "",
          model: "",
          stop_reason: Error,
          error_message: Some(error_message),
          usage: None,
          timestamp: @env.now(),
        }
        if message_started && messages.length() > 0 {
          match messages[messages.length() - 1] {
            Assistant(m) =>
              AssistantMessage::{
                content: [],
                api: m.api,
                provider: m.provider,
                model: m.model,
                stop_reason: Error,
                error_message: Some(error_message),
                usage: None,
                timestamp: m.timestamp,
              }
            _ => fallback
          }
        } else {
          fallback
        }
      }
    }
    let final_msg = AgentMessage::Assistant(assistant_message)
    if message_started {
      messages[messages.length() - 1] = final_msg
    } else {
      messages.push(final_msg)
      event_sink(AgentEvent::MessageStart(final_msg))
    }
    event_sink(AgentEvent::MessageEnd(final_msg))

    let tool_results = []
    let hard_exit = match assistant_message.stop_reason {
      Pending => fail("generate returned a message with pending stop_reason")
      Aborted => true
      Error => true
      (Length with model_error = true)
      | (Stop | ToolUse with model_error = false) => {
        for content in assistant_message.content {
          guard content is AssistantMessageContent::ToolCall(tool_call, ..) else {
            continue
          }
          event_sink(AgentEvent::ToolExecutionStart(tool_call))
          let call_timestamp = @env.now()
          let tool_result = if abort.is_aborted() {
            // pi: 未执行的工具补一个 "Operation aborted" 结果,保证每个调用都有结果。
            ToolResultMessage::{
              tool_call_id: tool_call.id,
              tool_name: tool_call.name,
              content: [InputMessageContent::Text("Operation aborted")],
              details: None,
              usage: None,
              is_error: true,
              timestamp: call_timestamp,
            }
          } else if model_error {
            ToolResultMessage::{
              tool_call_id: tool_call.id,
              tool_name: tool_call.name,
              content: [],
              details: None,
              usage: None,
              is_error: true,
              timestamp: call_timestamp,
            }
          } else {
            let update_sink = (_, _) => () // TODO: support progress update
            // 子协程里跑工具,watcher 盯中断:置位即结束 group 并取消工具协程。
            let raced = @async.with_task_group() <| group => {
              group.spawn_bg(no_wait=true) <| async fn() {
                abort.wait_abort()
                group.return_immediately(None)
              }
              Some(
                tool_executor(tool_call, update_sink) catch {
                  err =>
                    {
                      content: [InputMessageContent::Text(err.to_string())],
                      details: {},
                      is_error: true,
                      usage: None,
                    }
                },
              )
            }
            match raced {
              // 运行中被中断:与未执行的调用一致,补一条 aborted 结果。
              None =>
                ToolResultMessage::{
                  tool_call_id: tool_call.id,
                  tool_name: tool_call.name,
                  content: [InputMessageContent::Text("Operation aborted")],
                  details: None,
                  usage: None,
                  is_error: true,
                  timestamp: call_timestamp,
                }
              Some(result) =>
                ToolResultMessage::{
                  tool_call_id: tool_call.id,
                  tool_name: tool_call.name,
                  content: result.content,
                  details: Some(result.details),
                  usage: result.usage,
                  is_error: result.is_error,
                  timestamp: call_timestamp,
                }
            }
          }
          event_sink(AgentEvent::ToolExecutionEnd(tool_result))
          tool_results.push(tool_result)
          messages.push(AgentMessage::ToolResult(tool_result))
        }
        false
      }
    }
    let finish_turn_decision = finish_turn_hook(messages, tool_results, abort)
    event_sink(AgentEvent::TurnEnd(assistant_message, tool_results))
    if hard_exit {
      break
    }
    match finish_turn_decision {
      Some(End) => break
      None => ()
    }
    if tool_results.length() > 0 {
      continue
    }
    pending_prompts = steer_channel()
    if pending_prompts.length() > 0 {
      continue
    }
    break
  }
  event_sink(AgentEvent::AgentEnd(messages))
}

///|
/// Continue the loop from the current transcript, appending no prompt.
///
/// The transcript must end with something the model can answer: a user message
/// or a tool result. pi's `runAgentLoopContinue` rejects the other cases, and
/// this mirrors it.
pub async fn run_agent_loop_continue(
  llm : &LLM,
  system_prompt : String,
  messages : Array[AgentMessage],
  tools : ArrayView[ToolDefinition],
  tool_executor~ : async (ToolCall, ToolExecUpdateCallback) -> ToolResult,
  steer_channel~ : () -> ArrayView[UserMessage] = fn() { [] },
  abort~ : AbortSignal = AbortSignal::never(),
  event_sink~ : async (AgentEvent) -> Unit = _ => (),
  finish_turn_hook~ : FinishTurnHook = (_, _, _) => None,
) -> Unit {
  guard messages.length() > 0 else {
    fail("Cannot continue: no messages in context")
  }
  match messages[messages.length() - 1] {
    Assistant(_) => fail("Cannot continue from message role: assistant")
    _ => ()
  }
  let no_prompts : Array[UserMessage] = []
  run_agent_loop(
    llm,
    system_prompt,
    messages,
    tools,
    no_prompts,
    tool_executor~,
    steer_channel~,
    abort~,
    event_sink~,
    finish_turn_hook~,
  )
}

///|
pub(all) struct ToolResult {
  content : Array[InputMessageContent]
  details : ToolResultDetail
  is_error : Bool
  /// Usage if the tool use LLM internally.
  usage : Usage?
}

///|
/// Metadata helps display the result in a more user-friendly way. Includes:
/// - "Smart" actions that tools have automatically taken to protect the system or user. For example, read tool may have truncated the text or downsampled the image to avoid sending too much data.
pub type ToolResultDetail = Json

///|
pub impl ToJson for ToolResult with fn to_json(self : ToolResult) -> Json {
  {
    "content": self.content,
    "details": self.details,
    "isError": self.is_error,
    "usage": match self.usage {
      Some(usage) => usage.to_json()
      None => null
    },
  }
}

///|
pub extend ToolResult with ToJson::{to_json}

///|
pub type ToolExecUpdateCallback = (Array[InputMessageContent], ToolResultDetail) -> Unit

///|
/// Called after a completed assistant turn and all of its tool-result messages, but before `turn_end`.
/// Error and aborted responses remain hard exits.
pub type FinishTurnHook = async (
  ArrayView[AgentMessage],
  ArrayView[ToolResultMessage],
  AbortSignal,
) -> AgentTurnDecision?

///|
pub(all) enum AgentTurnDecision {
  End
}
