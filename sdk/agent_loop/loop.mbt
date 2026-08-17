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
  // TODO: support follow-up channel
  event_sink? : async (AgentEvent) -> Unit = fn(_) { () },
) -> LoopStopReason {
  event_sink(AgentEvent::AgentStart)
  let mut pending_prompts = prompts
  if steer_channel() is ([_, ..] as steer_messages) {
    pending_prompts += steer_messages
  }
  let reason : LoopStopReason = for ;; {
    event_sink(AgentEvent::TurnStart)
    for prompt in pending_prompts {
      messages.push(AgentMessage::User(prompt.content))
      event_sink(AgentEvent::MessageStart(AgentMessage::User(prompt.content)))
    }
    pending_prompts = []
    let mut message_started = false
    let assistant_message = llm.generate(
      { system_prompt, messages, tools },
      sink=event => {
        match event {
          Start(m) => {
            message_started = true
            let msg = AgentMessage::Assistant(m)
            messages.push(msg)
            event_sink(AgentEvent::MessageStart(msg))
          }
          TextStart(_, m)
          | TextDelta(_, _, m)
          | TextEnd(_, _, m)
          | ThinkingStart(_, m)
          | ThinkingDelta(_, _, m)
          | ThinkingEnd(_, _, m)
          | ToolCallStart(_, m)
          | ToolCallDelta(_, _, m)
          | ToolCallEnd(_, _, m) => {
            let msg = AgentMessage::Assistant(m)
            if message_started {
              messages[messages.length() - 1] = msg
            } else {
              message_started = true
              messages.push(msg)
              event_sink(AgentEvent::MessageStart(msg))
            }
            event_sink(AgentEvent::MessageUpdate(msg))
          }
        }
      },
    )
    let final_msg = AgentMessage::Assistant(assistant_message)
    if message_started {
      messages[messages.length() - 1] = final_msg
    } else {
      messages.push(final_msg)
      event_sink(AgentEvent::MessageStart(final_msg))
    }
    event_sink(AgentEvent::MessageEnd(final_msg))

    let tool_results = []
    match assistant_message.stop_reason {
      Pending => fail("generate returned a message with pending stop_reason")
      Aborted | Error => ()
      _ =>
        for content in assistant_message.content {
          guard content is AssistantMessageContent::ToolCall(tool_call, ..) else {
            continue
          }
          event_sink(AgentEvent::ToolExecutionStart(tool_call))
          let call_timestamp = @env.now()
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
    match assistant_message.stop_reason {
      Pending => fail("generate returned a message with pending stop_reason")
      Aborted => break Aborted
      Error => break Error
      _ => ()
    }
    if tool_results.any(r => !r.terminate) {
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
