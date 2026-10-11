///|
/// Runs the agent loop, which generates messages from the LLM and executes tools as needed.
pub async fn run_agent_loop(
  llm : &LLM,
  system_prompt : String,
  messages : Array[AgentMessage],
  tools : ArrayView[ToolDefinition],
  prompts : ArrayView[UserMessage],
  tool_executor~ : async (ToolCall, ToolExecUpdateCallback) -> ToolResult,
  steer_channel? : () -> ArrayView[UserMessage] = fn() { [] },
  abort? : AbortSignal = AbortSignal::never(),
  // TODO: support follow-up channel
  event_sink? : async (AgentEvent) -> Unit = _ => (),
  finish_turn_hook? : FinishTurnHook = (_, _, _) => None,
) -> LoopStopReason {
  event_sink(AgentEvent::AgentStart)
  let mut pending_prompts = prompts
  if steer_channel() is ([_, ..] as steer_messages) {
    pending_prompts += steer_messages
  }
  let reason : LoopStopReason = for ;; {
    // 上一回合被中断:不再开新回合(此时 provider 已产出 Aborted 消息)。
    if abort.is_aborted() {
      break Aborted
    }
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
            event_sink(AgentEvent::MessageStart(msg))
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
              let msg = AgentMessage::Assistant(partial)
              messages[messages.length() - 1] = msg
              event_sink(AgentEvent::MessageUpdate(msg))
            }
        }
      },
      abort~,
    ) catch {
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
    let early_stop_reason = match assistant_message.stop_reason {
      Pending => fail("generate returned a message with pending stop_reason")
      Aborted => Some(LoopStopReason::Aborted)
      Error => Some(LoopStopReason::Error)
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
        None
      }
    }
    let finish_turn_decision = finish_turn_hook(messages, tool_results, abort)
    event_sink(AgentEvent::TurnEnd(assistant_message, tool_results))
    if early_stop_reason is Some(r) {
      break r
    }
    match finish_turn_decision {
      Some(End) => break Stop
      None => ()
    }
    if tool_results.length() > 0 {
      continue
    }
    pending_prompts = steer_channel()
    if pending_prompts.length() > 0 {
      continue
    }
    break Stop
  }
  event_sink(AgentEvent::AgentEnd(messages))
  reason
}

///|
pub enum LoopStopReason {
  Stop
  /// The model was aborted by the user or system.
  Aborted
  Error
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
