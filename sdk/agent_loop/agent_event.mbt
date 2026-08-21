///|
/// Lifecycle events emitted by agent loop, ordered by nesting:
/// agent → turn → message → tool execution.
///
/// Streaming events carry in-flight `AssistantMessage` snapshots whose
/// `stop_reason` is `Pending` and `usage` is `None`; metadata is only
/// trustworthy from `MessageEnd` onwards.
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
/// A message in the agent conversation. Appears in the loop's `messages`
/// buffer, in `AgentEvent` payloads, and in persisted journal entries.
pub(all) enum AgentMessage {
  User(ArrayView[InputMessageContent])
  Assistant(AssistantMessage)
  ToolResult(ToolResultMessage)
}

///|
/// JSON shapes mirror pi's message format so that `--mode json` wire output
/// and persisted journal entries stay isomorphic with pi.
pub impl ToJson for AgentMessage with fn to_json(self : AgentMessage) -> Json {
  match self {
    User(contents) => { "role": "user", "content": contents }
    Assistant(message) => ToJson::to_json(message)
    ToolResult(result) =>
      {
        "role": "toolResult",
        "toolCallId": result.tool_call_id,
        "toolName": result.tool_name,
        "content": result.content,
        "isError": result.is_error,
        "timestamp": Json::number(result.timestamp.to_double()),
      }
  }
}

///|
pub(all) enum InputMessageContent {
  Text(String)
  Image(Bytes)
}

///|
pub impl ToJson for InputMessageContent with fn to_json(
  self : InputMessageContent,
) -> Json {
  match self {
    Text(text) =>
      Json::object({ "type": "text".to_json(), "text": text.to_json() })
    Image(bytes) =>
      Json::object({
        "type": "image".to_json(),
        "length": bytes.length().to_json(),
      })
  }
}

///|
pub(all) struct AssistantMessage {
  content : Array[AssistantMessageContent]
  api : String
  provider : String
  model : String
  stop_reason : StopReason
  /// Set when `stop_reason` is `Aborted` or `Error`: the failure description.
  error_message : String?
  usage : Usage?
  /// Unix timestamp in milliseconds, set when the message is created.
  timestamp : UInt64
} derive(Debug)

///|
pub impl ToJson for AssistantMessage with fn to_json(self : AssistantMessage) -> Json {
  {
    "role": "assistant",
    "content": self.content,
    "api": self.api,
    "provider": self.provider,
    "model": self.model,
    "stopReason": self.stop_reason,
    "errorMessage": match self.error_message {
      Some(message) => message.to_json()
      None => null
    },
    "usage": match self.usage {
      Some(usage) => usage.to_json()
      None => null
    },
    "timestamp": Json::number(self.timestamp.to_double()),
  }
}

///|
pub extend AssistantMessage with ToJson::{to_json}

///|
pub(all) enum AssistantMessageContent {
  Text(String, signature~ : Json)
  Thinking(String, signature~ : Json)
  ToolCall(ToolCall, signature~ : Json)
  HostedToolCall(HostedTool, signature~ : Json)
} derive(Debug)

///|
/// Signatures serialize as stringified JSON, matching pi's `textSignature` /
/// `thinkingSignature` / `thoughtSignature` string fields.
pub impl ToJson for AssistantMessageContent with fn to_json(
  self : AssistantMessageContent,
) -> Json {
  match self {
    Text(text, signature~) =>
      Json::object({
        "type": "text".to_json(),
        "text": text.to_json(),
        "textSignature": signature.stringify().to_json(),
      })
    Thinking(text, signature~) =>
      Json::object({
        "type": "thinking".to_json(),
        "thinking": text.to_json(),
        "thinkingSignature": signature.stringify().to_json(),
      })
    ToolCall(tool_call, signature~) =>
      Json::object({
        "type": "toolCall".to_json(),
        "id": tool_call.id.to_json(),
        "name": tool_call.name.to_json(),
        "arguments": tool_call.arguments,
        "thoughtSignature": signature.stringify().to_json(),
      })
    HostedToolCall(tool, signature~) =>
      Json::object({
        "type": "hostedToolCall".to_json(),
        "tool": tool.to_json(),
        "signature": signature.stringify().to_json(),
      })
  }
}

///|
pub(all) struct ToolCall {
  id : String
  name : String
  arguments : Json
} derive(Debug)

///|
pub(all) enum HostedTool {
  WebSearch
} derive(Debug)

///|
pub impl ToJson for HostedTool with fn to_json(self : HostedTool) -> Json {
  match self {
    WebSearch => "web_search".to_json()
  }
}

///|
pub(all) struct ToolResultMessage {
  tool_call_id : String
  tool_name : String
  content : Array[InputMessageContent]
  is_error : Bool
  timestamp : UInt64
  /// Whether the tool wants to exit the agent loop, like yielding control back to the user or system. For example, a ui tool may want to exit the loop and wait for user input before continuing.
  terminate : Bool
}
