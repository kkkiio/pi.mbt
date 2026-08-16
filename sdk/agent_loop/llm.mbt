///|
/// The LLM interface. `generate` runs one model turn to completion,
/// delivering streaming deltas through `sink` as they arrive and returning the
/// final `AssistantMessage` as the terminal outcome. Providers run their
/// response stream inline in the calling task (no background task), following
/// the callback/sink model.
pub(open) trait LLM {
  async fn generate(
    Self,
    Context,
    sink~ : async (GenerationEvent) -> Unit,
  ) -> AssistantMessage
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
  Hosted(HostedTool)
  Function(FunctionTool)
}

///|
pub(all) enum HostedTool {
  WebSearch
} derive(Debug)

///|
pub(all) struct FunctionTool {
  name : String
  description : String
  parameters : Json
  constrained_sampling : ConstrainedSampling
}

///|
pub(all) enum ConstrainedSampling {
  JsonSchema(strict~ : Bool)
  Grammar(
    format~ : GrammarFormat,
    definition~ : String,
    input_property~ : String
  )
}

///|
pub(all) enum GrammarFormat {
  Lark
  Regex
}

///|
pub(all) enum InputMessageContent {
  Text(String)
  Image(Bytes)
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

///|
/// Event protocol for `generate`'s sink: the phases of one generation call.
/// The terminal outcome is not an event — `generate` returns the final
/// `AssistantMessage`, whose `stop_reason` and `error_message` describe how
/// the turn ended.
pub(all) enum GenerationEvent {
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
  /// Set when `stop_reason` is `Aborted` or `Error`: the failure description.
  error_message : String?
  usage : Usage?
} derive(Debug)

///|
pub(all) enum AssistantMessageContent {
  Text(String, signature~ : Json)
  Thinking(String, signature~ : Json)
  ToolCall(ToolCall, signature~ : Json)
  HostedToolCall(HostedTool, signature~ : Json)
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

///|
pub impl Show for StopReason with fn to_string(self : StopReason) -> String {
  match self {
    Stop => "stop"
    Length => "length"
    ToolUse => "tool_use"
    Aborted => "aborted"
    Error => "error"
  }
}
