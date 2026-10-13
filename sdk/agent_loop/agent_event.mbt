///|
/// Lifecycle events emitted by agent loop, ordered by nesting:
/// agent → turn → message → tool execution.
///
/// Streaming events carry the provider's `GenerationEvent`: the delta together
/// with an in-flight `AssistantMessage` snapshot whose `stop_reason` is
/// `Pending` and `usage` is `None`; metadata is only trustworthy from
/// `MessageEnd` onwards.
/// The owning session also emits terminal events when the loop raises.
pub(all) enum AgentEvent {
  AgentStart
  TurnStart
  MessageStart(AgentMessage)
  MessageUpdate(GenerationEvent)
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
  User(UserMessage)
  Assistant(AssistantMessage)
  ToolResult(ToolResultMessage)
}

///|
/// JSON shapes mirror pi's message format so that `--mode json` wire output
/// and persisted journal entries stay isomorphic with pi.
pub impl ToJson for AgentMessage with fn to_json(self : AgentMessage) -> Json {
  match self {
    User(message) => ToJson::to_json(message)
    Assistant(message) => ToJson::to_json(message)
    ToolResult(result) => {
      let obj : Map[String, Json] = {
        "role": "toolResult".to_json(),
        "toolCallId": result.tool_call_id.to_json(),
        "toolName": result.tool_name.to_json(),
        "content": result.content.to_json(),
        "isError": result.is_error.to_json(),
        "timestamp": Json::number(result.timestamp.to_double()),
      }
      if result.details is Some(details) {
        obj["details"] = details
      }
      if result.usage is Some(usage) {
        obj["usage"] = usage.to_json()
      }
      Json::object(obj)
    }
  }
}

///|
pub extend AgentMessage with ToJson::{to_json}

///|
pub(all) enum InputMessageContent {
  Text(String)
  Image(Bytes)
}

///|
/// A user message in the conversation. Mirrors pi's `UserMessage`: `content`
/// plus a Unix-epoch-milliseconds `timestamp`.
pub(all) struct UserMessage {
  content : Array[InputMessageContent]
  timestamp : UInt64
}

///|
/// JSON shape mirrors pi's `UserMessage` (`role` / `content` / `timestamp`).
pub impl ToJson for UserMessage with fn to_json(self : UserMessage) -> Json {
  {
    "role": "user",
    "content": self.content,
    "timestamp": Json::number(self.timestamp.to_double()),
  }
}

///|
pub extend UserMessage with ToJson::{to_json}

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
pub extend InputMessageContent with ToJson::{to_json}

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
pub extend AssistantMessage with Debug::{to_repr}

///|
/// Zeroed usage for an in-flight message: streaming snapshots carry `None`
/// until the provider reports usage, and every JSON shape containing usage
/// substitutes pi's all-zero object instead of dropping the field.
///
/// Shared with the event projection, which puts usage on the wire's
/// `message_update` because the snapshot itself is stripped there.
pub fn usage_json(usage : Usage?) -> Json {
  match usage {
    Some(usage) => usage.to_json()
    None =>
      {
        "input": 0,
        "output": 0,
        "cacheRead": 0,
        "cacheWrite": 0,
        "totalTokens": 0,
        "cost": {
          "input": 0,
          "output": 0,
          "cacheRead": 0,
          "cacheWrite": 0,
          "total": 0,
        },
      }
  }
}

///|
pub impl ToJson for AssistantMessage with fn to_json(self : AssistantMessage) -> Json {
  let obj : Map[String, Json] = {
    "role": "assistant".to_json(),
    "content": self.content.to_json(),
    "api": self.api.to_json(),
    "provider": self.provider.to_json(),
    "model": self.model.to_json(),
    "stopReason": self.stop_reason.to_json(),
    "usage": usage_json(self.usage),
    "timestamp": Json::number(self.timestamp.to_double()),
  }
  if self.error_message is Some(message) {
    obj["errorMessage"] = message.to_json()
  }
  Json::object(obj)
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
pub extend AssistantMessageContent with Debug::{to_repr}

///|
/// The `ToolCall` JSON object shared by assistant content and the wire's
/// `toolcall_end` event; pi carries the discriminant in `type`.
fn tool_call_fields(tool_call : ToolCall) -> Map[String, Json] {
  {
    "type": "toolCall".to_json(),
    "id": tool_call.id.to_json(),
    "name": tool_call.name.to_json(),
    "arguments": tool_call.arguments,
  }
}

///|
/// Provider signatures are opaque strings or serialized JSON. Empty objects
/// represent an absent signature in the current provider APIs.
pub impl ToJson for AssistantMessageContent with fn to_json(
  self : AssistantMessageContent,
) -> Json {
  let (obj, key, signature) : (Map[String, Json], String, Json) = match self {
    Text(text, signature~) =>
      (
        { "type": "text".to_json(), "text": text.to_json() },
        "textSignature",
        signature,
      )
    Thinking(text, signature~) =>
      (
        { "type": "thinking".to_json(), "thinking": text.to_json() },
        "thinkingSignature",
        signature,
      )
    ToolCall(tool_call, signature~) =>
      (tool_call_fields(tool_call), "thoughtSignature", signature)
    HostedToolCall(tool, signature~) =>
      (
        { "type": "hostedToolCall".to_json(), "tool": tool.to_json() },
        "signature",
        signature,
      )
  }
  match signature {
    Null => ()
    Object(fields) if fields.is_empty() => ()
    String(_) => obj[key] = signature
    _ => obj[key] = signature.stringify().to_json()
  }
  Json::object(obj)
}

///|
pub extend AssistantMessageContent with ToJson::{to_json}

///|
pub extend HostedTool with ToJson::{to_json}

///|
pub(all) struct ToolCall {
  id : String
  name : String
  arguments : Json
} derive(Debug)

///|
pub extend ToolCall with Debug::{to_repr}

///|
/// pi's `ToolCall` JSON: the discriminant lives in `type`. The `toolcall_end`
/// wire projection depends on this being the constant-size substitute for the
/// snapshot it strips.
pub impl ToJson for ToolCall with fn to_json(self : ToolCall) -> Json {
  Json::object(tool_call_fields(self))
}

///|
pub extend ToolCall with ToJson::{to_json}

///|
pub(all) enum HostedTool {
  WebSearch
} derive(Debug)

///|
pub extend HostedTool with Debug::{to_repr}

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
  details : Json?
  usage : Usage?
  is_error : Bool
  timestamp : UInt64
}
