///|
priv suberror ListenerError {
  ListenerError(Error)
}

///|
/// Runs model turns and tools, delivering ordered events through `event_sink`.
/// Provider errors become Error messages; extension errors propagate unchanged.
/// Cancellation seals the current turn and delivers remaining terminal events.
pub async fn run_agent_loop(
  llm : &LLM,
  system_prompt : String,
  messages : Array[AgentMessage],
  tools : ArrayView[ToolDefinition],
  prompts : ArrayView[UserMessage],
  tool_executor~ : async (ToolCall, ToolExecUpdateCallback) -> ToolResult,
  steer_channel~ : () -> ArrayView[UserMessage] = fn() { [] },
  event_sink~ : EventSink = (_, _) => (),
  finish_turn_hook~ : FinishTurnHook = (_, _) => None,
) -> Unit {
  let context = EventContext::{ is_cancelling: false, }
  let mut pending_prompts = prompts
  if steer_channel() is ([_, ..] as steer_messages) {
    pending_prompts += steer_messages
  }
  let mut agent_started = false
  for ;; {
    let mut failure : Error? = None
    let mut turn_started = false
    let mut input_index = 0
    let mut input_started = false
    let mut assistant : AssistantMessage? = None
    let mut assistant_slot : Int32? = None
    let mut assistant_started = false
    let mut assistant_finalized = false
    let mut assistant_ended = false
    let mut tool_calls : Array[ToolCall] = []
    let tool_results : Array[ToolResultMessage] = []
    let mut tool_index = 0
    let mut tool_started = false
    let mut ready_result : ToolResultMessage? = None
    let mut turn_ended = false
    let mut agent_ended = false
    errdefer (if failure is None && @async.is_being_cancelled() {
      @async.protect_from_cancel(() => {
        let context = EventContext::{ is_cancelling: true, }
        if !turn_started {
          turn_started = true
          event_sink(TurnStart, context)
        }
        while input_index < pending_prompts.length() {
          let msg = AgentMessage::User(pending_prompts[input_index])
          if !input_started {
            messages.push(msg)
            input_started = true
            event_sink(MessageStart(msg), context)
          }
          input_index += 1
          input_started = false
          event_sink(MessageEnd(msg), context)
        }
        let message = if assistant_finalized {
          assistant.unwrap()
        } else {
          let partial = assistant.unwrap_or(AssistantMessage::{
            content: [],
            api: "",
            provider: "",
            model: "",
            stop_reason: Pending,
            error_message: None,
            usage: None,
            timestamp: @env.now(),
          })
          let aborted = {
            ..partial,
            stop_reason: Aborted,
            error_message: Some("Interrupted"),
          }
          assistant = Some(aborted)
          assistant_finalized = true
          match assistant_slot {
            Some(index) => messages[index] = Assistant(aborted)
            None => {
              assistant_slot = Some(messages.length())
              messages.push(Assistant(aborted))
            }
          }
          aborted
        }
        if !assistant_started {
          assistant_started = true
          event_sink(MessageStart(Assistant(message)), context)
        }
        if !assistant_ended {
          assistant_ended = true
          event_sink(MessageEnd(Assistant(message)), context)
        }
        while tool_index < tool_calls.length() {
          let call = tool_calls[tool_index]
          if !tool_started {
            tool_started = true
            event_sink(ToolExecutionStart(call), context)
          }
          let result = ready_result.unwrap_or(ToolResultMessage::{
            tool_call_id: call.id,
            tool_name: call.name,
            content: [InputMessageContent::Text("Operation aborted")],
            details: None,
            usage: None,
            is_error: true,
            timestamp: @env.now(),
          })
          tool_results.push(result)
          messages.push(ToolResult(result))
          tool_index += 1
          tool_started = false
          ready_result = None
          event_sink(ToolExecutionEnd(result), context)
        }
        if !turn_ended {
          turn_ended = true
          event_sink(TurnEnd(message, tool_results), context)
        }
        if !agent_ended {
          agent_ended = true
          event_sink(AgentEnd(messages), context)
        }
      })
    })
    let outcome : Result[Unit, Error] = try {
      if !agent_started {
        agent_started = true
        event_sink(AgentStart, context)
        @async.pause()
      }
      turn_started = true
      event_sink(TurnStart, context)
      @async.pause()
      while input_index < pending_prompts.length() {
        let msg = AgentMessage::User(pending_prompts[input_index])
        messages.push(msg)
        input_started = true
        event_sink(MessageStart(msg), context)
        @async.pause()
        input_index += 1
        input_started = false
        event_sink(MessageEnd(msg), context)
        @async.pause()
      }
      let message = llm.generate({ system_prompt, messages, tools, }, sink=event => {
        match event {
          Start(partial~) => {
            assistant = Some(partial)
            assistant_slot = Some(messages.length())
            messages.push(Assistant(partial))
            assistant_started = true
            event_sink(MessageStart(Assistant(partial)), context) catch {
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
            if assistant_slot is Some(index) {
              assistant = Some(partial)
              messages[index] = Assistant(partial)
              event_sink(MessageUpdate(event), context) catch {
                err => raise ListenerError(err)
              }
            }
        }
        @async.pause()
      }) catch {
        ListenerError(err) => raise err
        err => {
          let text = err.to_string()
          let error_message = match text.rev_split_once(" FAILED: ") {
            Some((_, message)) =>
              message.strip_suffix(")").unwrap_or(message).to_owned()
            None => text
          }
          let partial = assistant.unwrap_or(AssistantMessage::{
            content: [],
            api: "",
            provider: "",
            model: "",
            stop_reason: Pending,
            error_message: None,
            usage: None,
            timestamp: @env.now(),
          })
          {
            ..partial,
            content: [],
            stop_reason: Error,
            error_message: Some(error_message),
            usage: None,
          }
        }
      }
      guard !(message.stop_reason is Pending) else {
        fail("generate returned a message with pending stop_reason")
      }
      assistant = Some(message)
      assistant_finalized = true
      match assistant_slot {
        Some(index) => messages[index] = Assistant(message)
        None => {
          assistant_slot = Some(messages.length())
          messages.push(Assistant(message))
        }
      }
      let hard_exit = message.stop_reason is Aborted ||
        message.stop_reason is Error
      if !hard_exit {
        tool_calls = message.content.filter_map(content => {
          match content {
            AssistantMessageContent::ToolCall(call, ..) => Some(call)
            _ => None
          }
        })
      }
      if !assistant_started {
        assistant_started = true
        event_sink(MessageStart(Assistant(message)), context)
        @async.pause()
      }
      assistant_ended = true
      event_sink(MessageEnd(Assistant(message)), context)
      @async.pause()
      while tool_index < tool_calls.length() {
        let call = tool_calls[tool_index]
        tool_started = true
        event_sink(ToolExecutionStart(call), context)
        @async.pause()
        let timestamp = @env.now()
        if message.stop_reason is Length {
          ready_result = Some(ToolResultMessage::{
            tool_call_id: call.id,
            tool_name: call.name,
            content: [],
            details: None,
            usage: None,
            is_error: true,
            timestamp,
          })
        } else {
          let updates = @aqueue.Queue(kind=@aqueue.Unbounded)
          defer updates.close()
          let update_sink = fn(content, details) {
            ignore(updates.try_put((content, details)) catch { _ => false })
          }
          @async.with_task_group() <| group => {
            group.spawn_bg() <| () => {
              for ;; {
                let (content, details) = updates.get() catch { _ => break }
                event_sink(ToolExecutionUpdate(call, content, details), context)
                @async.pause()
              }
            }
            let result = tool_executor(call, update_sink) catch {
              err =>
                ToolResult::{
                  content: [InputMessageContent::Text(err.to_string())],
                  details: {},
                  is_error: true,
                  usage: None,
                }
            }
            ready_result = Some(ToolResultMessage::{
              tool_call_id: call.id,
              tool_name: call.name,
              content: result.content,
              details: Some(result.details),
              usage: result.usage,
              is_error: result.is_error,
              timestamp,
            })
            updates.close()
          }
        }
        let result = ready_result.unwrap()
        tool_results.push(result)
        messages.push(ToolResult(result))
        tool_index += 1
        tool_started = false
        ready_result = None
        event_sink(ToolExecutionEnd(result), context)
        @async.pause()
      }
      @async.pause()
      let decision = finish_turn_hook(messages, tool_results)
      @async.pause()
      turn_ended = true
      event_sink(TurnEnd(message, tool_results), context)
      @async.pause()
      if !hard_exit && !(decision is Some(End)) {
        pending_prompts = steer_channel()
        if tool_results.length() > 0 || pending_prompts.length() > 0 {
          continue
        }
      }
      agent_ended = true
      event_sink(AgentEnd(messages), context)
      @async.pause()
      return
    } catch {
      err => Err(err)
    }
    match outcome {
      Ok(_) => ()
      Err(err) => {
        failure = Some(err)
        raise err
      }
    }
  }
}

///|
/// Continues a transcript ending in a user message or tool result.
/// Empty transcripts and assistant tails raise an error before execution.
pub async fn run_agent_loop_continue(
  llm : &LLM,
  system_prompt : String,
  messages : Array[AgentMessage],
  tools : ArrayView[ToolDefinition],
  tool_executor~ : async (ToolCall, ToolExecUpdateCallback) -> ToolResult,
  steer_channel~ : () -> ArrayView[UserMessage] = fn() { [] },
  event_sink~ : EventSink = (_, _) => (),
  finish_turn_hook~ : FinishTurnHook = (_, _) => None,
) -> Unit {
  guard messages.length() > 0 else {
    fail("Cannot continue: no messages in context")
  }
  match messages[messages.length() - 1] {
    Assistant(_) => fail("Cannot continue from message role: assistant")
    _ => ()
  }
  run_agent_loop(
    llm,
    system_prompt,
    messages,
    tools,
    [],
    tool_executor~,
    steer_channel~,
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
) -> AgentTurnDecision?

///|
pub(all) enum AgentTurnDecision {
  End
}
