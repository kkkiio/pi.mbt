///|
pub(open) trait LLM {
  fn generate(Self, Context) -> &AssistantMessageEventStream
}

///|
pub(all) struct Context {
  system_prompt : String
  messages : ArrayView[AgentMessage]
  tools : ArrayView[ToolDefinition]
}

///|
pub(all) enum AgentMessage {
  User(ArrayView[InputMessageContent])
  Assistant(ArrayView[AssistantMessageContent])
  // System(Array[InputMessageContent])
  ToolResult(ToolResultMessage)
}

///|
pub(all) enum ToolDefinition {
  WebSearch
  Function(FunctionTool)
  Custom(FunctionTool)
}

///|
pub(all) struct FunctionTool {
  name : String
  description : String
  parameters : Json
  strict : Bool
}

///|
pub(all) struct CustomTool {
  name : String
  description : String
  parameters : Json
  strict : Bool
}

///|
pub(all) enum InputMessageContent {
  Text(String)
  Image(Bytes)
}

///|
pub struct ToolResultMessage {
  tool_call_id : String
  tool_name : String
  content : Array[InputMessageContent]
  is_error : Bool
  timestamp : Int
  /// Whether the tool wants to exit the agent loop, like yielding control back to the user or system. For example, a ui tool may want to exit the loop and wait for user input before continuing.
  terminate : Bool
}

///|
pub(open) trait AssistantMessageEventStream {
  async fn next(Self) -> AssistantMessageEvent
  fn close(Self) -> Unit
}

///|
/// Event protocol for AssistantMessageEventStream.
/// 
/// Streams should emit `start` before partial updates, then terminate with either:
/// - `done` carrying the final successful AssistantMessage, or
/// - `error` carrying the final AssistantMessage with stopReason "error" or "aborted"
///   and errorMessage.
pub(all) enum AssistantMessageEvent {
  Start
  TextStart(Int, PartialAssistantMessage)
  TextDelta(Int, String, PartialAssistantMessage)
  TextEnd(Int, String, PartialAssistantMessage)
  ThinkingStart(Int, PartialAssistantMessage)
  ThinkingDelta(Int, String, PartialAssistantMessage)
  ThinkingEnd(Int, String, PartialAssistantMessage)
  ToolCallStart(Int, PartialAssistantMessage)
  ToolCallDelta(Int, String, PartialAssistantMessage)
  ToolCallEnd(Int, ToolCall, PartialAssistantMessage)
  Done(OkStopReason, AssistantMessage)
  Error(ErrorStopReason, AssistantMessage)
} derive(Debug)

///|
pub(all) enum OkStopReason {
  Stop
  /// The model stopped because it reached the maximum number of tokens allowed.
  Length
  ToolUse
} derive(Debug)

///|
pub(all) enum ErrorStopReason {
  /// The model was aborted by the user or system.
  Aborted
  Error
} derive(Debug)

///|
pub(all) enum StopReason {
  Stop
  /// The model stopped because it reached the maximum number of tokens allowed.
  Length
  ToolUse
  /// The model was aborted by the user or system.
  Aborted
  Error
} derive(Debug)

///|
pub(all) struct PartialAssistantMessage {
  content : ArrayView[AssistantMessageContent]
} derive(Debug)

///|
pub(all) struct AssistantMessage {
  content : Array[AssistantMessageContent]
  stop_reason : StopReason
  usage : Usage?
} derive(Debug)

///|
pub(all) enum AssistantMessageContent {
  Text(String, signature~ : Json)
  Thinking(String, signature~ : Json)
  ToolCall(ToolCall, signature~ : Json)
  BuiltinToolCall(String, signature~ : Json)
} derive(Debug)

///|
pub(all) struct ToolCall {
  id : String
  name : String
  arguments : Json
} derive(Debug)

///|
pub(all) struct Usage {
  input : Int
  output : Int
  cache_read : Int
  cache_write : Int
  /// Subset of `cache_write` written with 1h retention. Only Anthropic reports this split.
  cache_write_1h : Int?
  /// Reasoning/thinking tokens, when the provider reports them. This is a subset of
  /// `output`: `output` already includes these tokens. Set to a number (possibly 0) by providers that expose a reasoning breakdown; left undefined by providers that don't.
  reasoning : Int?
  total_tokens : Int
  cost : UsageCost
} derive(Debug)

///|
pub(all) struct UsageCost {
  input : Float
  output : Float
  cache_read : Float
  cache_write : Float
  total : Float
} derive(Debug)
