///|
/// Runs the agent loop, which generates messages from the LLM and executes tools as needed.
pub async fn run_agent_loop(
  llm : &LLM,
  system_prompt : String,
  messages : Array[AgentMessage],
  tools : ArrayView[ToolDefinition],
  prompts : ArrayView[UserMessage],
  tool_executor~ : async (ToolCall, ToolExecUpdateSink) -> ToolResult,
  steer_channel? : () -> ArrayView[UserMessage] = fn() { [] },
  event_sink? : (AgentEvent) -> Unit = fn(_) { () },
  clock~ : () -> Int,
) -> LoopStopReason {
  event_sink(AgentEvent::AgentStart)
  defer (fn() { event_sink(AgentEvent::AgentEnd(messages)) })()
  let mut pending_stream : &AssistantMessageEventStream? = None
  defer (fn() { if pending_stream is Some(stream) { stream.close() } })()
  let mut pending_prompts = prompts
  if steer_channel() is ([_, ..] as steer_messages) {
    pending_prompts += steer_messages
  }
  for ;; {
    event_sink(AgentEvent::TurnStart)
    for prompt in pending_prompts {
      messages.push(AgentMessage::User(prompt.content))
      event_sink(AgentEvent::MessageStart(AgentMessage::User(prompt.content)))
    }
    pending_prompts = []
    let stream = llm.generate({ system_prompt, messages, tools })
    pending_stream = Some(stream)
    let assistant_message : AssistantMessage = for ;; {
      match stream.next() {
        Start => ()
        TextStart(_, partial)
        | ThinkingStart(_, partial)
        | ToolCallStart(_, partial) =>
          event_sink(
            AgentEvent::MessageStart(AgentMessage::Assistant(partial.content)),
          )
        TextDelta(_, _, partial)
        | ThinkingDelta(_, _, partial)
        | ToolCallDelta(_, _, partial) =>
          event_sink(
            AgentEvent::MessageUpdate(AgentMessage::Assistant(partial.content)),
          )
        TextEnd(_, _, partial)
        | ThinkingEnd(_, _, partial)
        | ToolCallEnd(_, _, partial) =>
          event_sink(
            AgentEvent::MessageEnd(AgentMessage::Assistant(partial.content)),
          )
        Done(reason, message) =>
          break AssistantMessage::{
            content: message.content,
            stop_reason: match reason {
              Stop => Stop
              Length => Length
              ToolUse => ToolUse
            },
            usage: None,
          }
        Error(reason, message) =>
          break AssistantMessage::{
            content: message.content,
            stop_reason: match reason {
              Aborted => Aborted
              Error => Error
            },
            usage: None,
          }
      }
    }
    messages.push(AgentMessage::Assistant(assistant_message.content))

    let tool_results = []
    match assistant_message.stop_reason {
      Aborted | Error => ()
      _ =>
        for content in assistant_message.content {
          guard content is AssistantMessageContent::ToolCall(tool_call, ..) else {
            continue
          }
          event_sink(AgentEvent::ToolExecutionStart(tool_call))
          let call_timestamp = clock()
          let tool_result = if assistant_message.stop_reason is Length {
            ToolResultMessage::{
              tool_call_id: tool_call.id,
              tool_name: tool_call.name,
              content: [],
              is_error: true,
              timestamp: call_timestamp,
              terminate: false,
            }
          } else {
            let update_sink = (_, _) => () // TODO: support progress update
            let result = tool_executor(tool_call, update_sink) catch {
              err => create_error_tool_result(err)
            }
            ToolResultMessage::{
              tool_call_id: tool_call.id,
              tool_name: tool_call.name,
              content: result.content,
              is_error: result.is_error,
              timestamp: call_timestamp,
              terminate: result.terminate,
            }
          }
          event_sink(AgentEvent::ToolExecutionEnd(tool_result))
          tool_results.push(tool_result)
          messages.push(AgentMessage::ToolResult(tool_result))
        }
    }

    event_sink(AgentEvent::TurnEnd(assistant_message, tool_results))
    pending_stream = None
    stream.close()
    match assistant_message.stop_reason {
      Aborted => return Aborted
      Error => return Error
      _ => ()
    }
    if tool_results.any(r => !r.terminate) {
      continue
    }
    pending_prompts = steer_channel()
    if pending_prompts.length() > 0 {
      continue
    }
    return Stop
  }
}

///|
pub enum AgentEvent {
  AgentStart
  TurnStart
  MessageStart(AgentMessage)
  MessageUpdate(AgentMessage)
  MessageEnd(AgentMessage)
  ToolExecutionStart(ToolCall)
  ToolExecutionEnd(ToolResultMessage)
  TurnEnd(AssistantMessage, ArrayView[ToolResultMessage])
  AgentEnd(ArrayView[AgentMessage])
}

///|
pub enum LoopStopReason {
  Stop
  /// The model was aborted by the user or system.
  Aborted
  Error
}

///|
pub(all) struct UserMessage {
  content : Array[InputMessageContent]
}

///|
pub(all) struct ToolResult {
  content : Array[InputMessageContent]
  details : ToolResultDetail
  is_error : Bool
  /// Whether the tool wants to exit the agent loop, like yielding control back to the user or system. For example, a ui tool may want to exit the loop and wait for user input before continuing.
  terminate : Bool
  /// Usage if the tool use LLM internally.
  usage : Usage?
}

///|
/// Metadata helps display the result in a more user-friendly way. Includes:
/// - "Smart" actions that tools have automatically taken to protect the system or user. For example, read tool may have truncated the text or downsampled the image to avoid sending too much data.
pub type ToolResultDetail = Json

///|
pub type ToolExecUpdateSink = (Array[InputMessageContent], ToolResultDetail) -> Unit

///|
fn create_error_tool_result(err : Error) -> ToolResult {
  return {
    content: [InputMessageContent::Text(err.to_string())],
    details: {},
    is_error: true,
    terminate: false,
    usage: None,
  }
}
