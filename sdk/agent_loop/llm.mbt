///|
/// The LLM interface. `generate` runs one model turn to completion,
/// delivering streaming deltas through `sink` as they arrive and returning the
/// final `AssistantMessage` as the terminal outcome. Providers run their
/// response stream inline in the calling task (no background task), following
/// the callback/sink model.
pub(open) trait LLM {
  async fn generate(Self, Context, sink~ : async (GenerationEvent) -> Unit) -> AssistantMessage
}

///|
pub(all) struct Context {
  system_prompt : String
  messages : ArrayView[AgentMessage]
  tools : ArrayView[ToolDefinition]
}

///|
pub(all) enum ToolDefinition {
  Hosted(HostedTool)
  Function(FunctionTool)
}

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
/// Event protocol for `generate`'s sink: the phases of one generation call.
/// The terminal outcome is not an event — `generate` returns the final
/// `AssistantMessage`, whose `stop_reason` and `error_message` describe how
/// the turn ended.
///
/// `Start` carries the in-flight `AssistantMessage` created by the provider
/// when the stream begins: `api`/`provider`/`model`/`timestamp` are already
/// known, `stop_reason` is `Pending`, and `content` grows as deltas arrive.
pub(all) enum GenerationEvent {
  Start(partial~ : AssistantMessage)
  TextStart(content_index~ : Int, partial~ : AssistantMessage)
  TextDelta(content_index~ : Int, delta~ : String, partial~ : AssistantMessage)
  TextEnd(content_index~ : Int, content~ : String, partial~ : AssistantMessage)
  ThinkingStart(content_index~ : Int, partial~ : AssistantMessage)
  ThinkingDelta(
    content_index~ : Int,
    delta~ : String,
    partial~ : AssistantMessage
  )
  ThinkingEnd(
    content_index~ : Int,
    content~ : String,
    partial~ : AssistantMessage
  )
  ToolCallStart(content_index~ : Int, partial~ : AssistantMessage)
  ToolCallDelta(
    content_index~ : Int,
    delta~ : String,
    partial~ : AssistantMessage
  )
  ToolCallEnd(
    content_index~ : Int,
    tool_call~ : ToolCall,
    partial~ : AssistantMessage
  )
} derive(Debug)

///|
pub(all) enum StopReason {
  /// Streaming is still in progress; replaced by a terminal reason when the
  /// turn ends. Must never appear in persisted journal entries.
  Pending
  Stop
  /// The model stopped because it reached the maximum number of tokens allowed.
  Length
  ToolUse
  /// The model was aborted by the user or system.
  Aborted
  Error
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
pub impl ToJson for Usage with fn to_json(self : Usage) -> Json {
  {
    "input": self.input,
    "output": self.output,
    "cacheRead": self.cache_read,
    "cacheWrite": self.cache_write,
    "cacheWrite1h": match self.cache_write_1h {
      Some(n) => n.to_json()
      None => null
    },
    "reasoning": match self.reasoning {
      Some(n) => n.to_json()
      None => null
    },
    "totalTokens": self.total_tokens,
    "cost": self.cost,
  }
}

///|
pub(all) struct UsageCost {
  input : Float
  output : Float
  cache_read : Float
  cache_write : Float
  total : Float
} derive(Debug)

///|
pub impl ToJson for UsageCost with fn to_json(self : UsageCost) -> Json {
  Json::object({
    "input": self.input.to_json(),
    "output": self.output.to_json(),
    "cacheRead": self.cache_read.to_json(),
    "cacheWrite": self.cache_write.to_json(),
    "total": self.total.to_json(),
  })
}

///|
pub impl Show for StopReason with fn to_string(self : StopReason) -> String {
  match self {
    Pending => "pending"
    Stop => "stop"
    Length => "length"
    ToolUse => "toolUse"
    Aborted => "aborted"
    Error => "error"
  }
}

///|
/// Serialized values match pi's `StopReason` strings.
pub impl ToJson for StopReason with fn to_json(self : StopReason) -> Json {
  match self {
    Pending => "pending".to_json()
    Stop => "stop".to_json()
    Length => "length".to_json()
    ToolUse => "toolUse".to_json()
    Aborted => "aborted".to_json()
    Error => "error".to_json()
  }
}
