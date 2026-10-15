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
    /// 本次运行的中断令牌(只读),对应 pi 传给 stream function 的 `signal`。
    abort~ : AbortSignal,
  ) -> AssistantMessage
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
/// Providers must emit `Start` before any other event; consumers drop
/// mid-stream events that arrive earlier (pi's `if (partialMessage)` guard).
pub(all) enum GenerationEvent {
  Start(partial~ : AssistantMessage)
  TextStart(content_index~ : Int32, partial~ : AssistantMessage)
  TextDelta(
    content_index~ : Int32,
    delta~ : String,
    partial~ : AssistantMessage
  )
  TextEnd(
    content_index~ : Int32,
    content~ : String,
    partial~ : AssistantMessage
  )
  ThinkingStart(content_index~ : Int32, partial~ : AssistantMessage)
  ThinkingDelta(
    content_index~ : Int32,
    delta~ : String,
    partial~ : AssistantMessage
  )
  ThinkingEnd(
    content_index~ : Int32,
    content~ : String,
    partial~ : AssistantMessage
  )
  ToolCallStart(content_index~ : Int32, partial~ : AssistantMessage)
  ToolCallDelta(
    content_index~ : Int32,
    delta~ : String,
    partial~ : AssistantMessage
  )
  ToolCallEnd(
    content_index~ : Int32,
    tool_call~ : ToolCall,
    partial~ : AssistantMessage
  )
} derive(Debug)

///|
pub extend GenerationEvent with Debug::{to_repr}

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
pub extend StopReason with Debug::{to_repr}

///|
pub(all) struct Usage {
  input : Int32
  output : Int32
  cache_read : Int32
  cache_write : Int32
  /// Subset of `cache_write` written with 1h retention. Only Anthropic reports this split.
  cache_write_1h : Int32?
  /// Reasoning/thinking tokens, when the provider reports them. This is a subset of
  /// `output`: `output` already includes these tokens. Set to a number (possibly 0) by providers that expose a reasoning breakdown; left undefined by providers that don't.
  reasoning : Int32?
  total_tokens : Int32
  cost : UsageCost
} derive(Debug)

///|
pub extend Usage with Debug::{to_repr}

///|
pub impl ToJson for Usage with fn to_json(self : Usage) -> Json {
  let obj : Map[String, Json] = {
    "input": Json(self.input),
    "output": Json(self.output),
    "cacheRead": Json(self.cache_read),
    "cacheWrite": Json(self.cache_write),
    "totalTokens": Json(self.total_tokens),
    "cost": self.cost.to_json(),
  }
  if self.cache_write_1h is Some(n) {
    obj["cacheWrite1h"] = Json(n)
  }
  if self.reasoning is Some(n) {
    obj["reasoning"] = Json(n)
  }
  Json::object(obj)
}

///|
pub extend Usage with ToJson::{to_json}

///|
pub(all) struct UsageCost {
  input : Float
  output : Float
  cache_read : Float
  cache_write : Float
  total : Float
} derive(Debug)

///|
pub extend UsageCost with Debug::{to_repr}

///|
pub impl ToJson for UsageCost with fn to_json(self : UsageCost) -> Json {
  Json::object({
    "input": Json(self.input),
    "output": Json(self.output),
    "cacheRead": Json(self.cache_read),
    "cacheWrite": Json(self.cache_write),
    "total": Json(self.total),
  })
}

///|
pub extend UsageCost with ToJson::{to_json}

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
pub extend StopReason with Show::{to_string, output}

///|
/// Serialized values match pi's `StopReason` strings.
pub impl ToJson for StopReason with fn to_json(self : StopReason) -> Json {
  match self {
    Pending => Json("pending")
    Stop => Json("stop")
    Length => Json("length")
    ToolUse => Json("toolUse")
    Aborted => Json("aborted")
    Error => Json("error")
  }
}

///|
pub extend StopReason with ToJson::{to_json}
