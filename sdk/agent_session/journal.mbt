///|
using @agent_loop {type AgentMessage}

///|
pub(open) trait SessionJournal {
  fn generate_id(Self) -> String
  /// Append caller-provisioned entries. The journal assigns the
  /// storage-owned fields (`seq`, `parent_id`, `timestamp`), persists the
  /// entries, and returns them in stored form.
  async fn append(Self, ArrayView[NewSessionEntry]) -> Array[SessionEntry]
  fn get_entries(Self) -> ArrayView[SessionEntry]
}

///|
/// A stored journal entry. The JSON shape mirrors pi's v4 session entries:
/// flattened fields, storage-assigned `seq`/`parentId`/`timestamp`, and a
/// `type` discriminant alongside the variant payload.
pub(all) struct SessionEntry {
  id : String
  /// Storage-assigned sequence number, monotonically increasing per journal.
  seq : Int
  /// The lane leaf at append time; `None` for the first entry.
  parent_id : String?
  /// Storage-assigned persist time, Unix milliseconds.
  timestamp : UInt64
  content : SessionEntryContent
}

///|
/// Caller-provisioned entry: everything except the storage-assigned fields
/// (`seq`, `parent_id`, `timestamp`).
pub(all) struct NewSessionEntry {
  id : String
  content : SessionEntryContent
}

///|
pub(all) enum SessionEntryContent {
  Message(AgentMessage, terminate~ : Bool)
  ModelChange(provider~ : String, model_id~ : String)
  Compaction(
    summary~ : String,
    retained_tail~ : Array[AgentMessage],
    tokens_before~ : Int,
    details~ : Json?,
    usage~ : @agent_loop.Usage?
  )
  Custom(custom_type~ : String, data~ : Json?)
}

///|
pub impl ToJson for SessionEntry with fn to_json(self) -> Json {
  let obj : Map[String, Json] = Map([])
  obj["id"] = self.id.to_json()
  obj["seq"] = self.seq.to_json()
  obj["parentId"] = match self.parent_id {
    Some(id) => id.to_json()
    None => Json::null()
  }
  // pi stores timestamps as JSON numbers; UInt64's own ToJson emits a
  // string, so convert explicitly. Millisecond timestamps fit safely in a
  // JSON double.
  obj["timestamp"] = Json::number(self.timestamp.to_double())
  match self.content {
    Message(message, terminate~) => {
      obj["type"] = "message".to_json()
      obj["message"] = message.to_json()
      if terminate {
        obj["terminate"] = Json::boolean(true)
      }
    }
    ModelChange(provider~, model_id~) => {
      obj["type"] = "model_change".to_json()
      obj["provider"] = provider.to_json()
      obj["modelId"] = model_id.to_json()
    }
    Compaction(summary~, retained_tail~, tokens_before~, details~, usage~) => {
      obj["type"] = "compaction".to_json()
      obj["summary"] = summary.to_json()
      obj["retainedTail"] = retained_tail.to_json()
      obj["tokensBefore"] = tokens_before.to_json()
      if details is Some(details) {
        obj["details"] = details
      }
      if usage is Some(usage) {
        obj["usage"] = usage.to_json()
      }
    }
    Custom(custom_type~, data~) => {
      obj["type"] = "custom".to_json()
      obj["customType"] = custom_type.to_json()
      if data is Some(data) {
        obj["data"] = data
      }
    }
  }
  Json::object(obj)
}

///|
pub impl FromJson for SessionEntry with fn from_json(json, path) {
  guard json is Object(fields) else {
    decode_error(path, "SessionEntry::from_json: expected object")
  }
  guard fields.get("id") is Some(String(id)) else {
    decode_error(path, "SessionEntry::from_json: invalid id")
  }
  guard fields.get("seq") is Some(Number(seq, ..)) else {
    decode_error(path, "SessionEntry::from_json: invalid seq")
  }
  let parent_id = match fields.get("parentId") {
    Some(String(id)) => Some(id)
    _ => None
  }
  let timestamp = parse_timestamp(fields.get("timestamp"), path)
  guard fields.get("type") is Some(String(entry_type)) else {
    decode_error(path, "SessionEntry::from_json: missing type")
  }
  let content_path = path.add_key("type")
  let content : SessionEntryContent = match entry_type {
    "message" => {
      guard fields.get("message") is Some(message_json) else {
        decode_error(content_path, "message entry is missing message")
      }
      Message(
        parse_agent_message(message_json, path.add_key("message")),
        terminate=fields.get("terminate") is Some(True),
      )
    }
    "model_change" => {
      guard fields.get("provider") is Some(String(provider)) else {
        decode_error(content_path, "model_change entry is missing provider")
      }
      guard fields.get("modelId") is Some(String(model_id)) else {
        decode_error(content_path, "model_change entry is missing modelId")
      }
      ModelChange(provider~, model_id~)
    }
    "compaction" => {
      guard fields.get("summary") is Some(String(summary)) else {
        decode_error(content_path, "compaction entry is missing summary")
      }
      guard fields.get("retainedTail") is Some(Array(tail)) else {
        decode_error(content_path, "compaction entry is missing retainedTail")
      }
      let retained_tail = []
      for i, item in tail {
        retained_tail.push(
          parse_agent_message(item, path.add_key("retainedTail").add_index(i)),
        )
      }
      guard fields.get("tokensBefore") is Some(Number(tokens_before, ..)) else {
        decode_error(content_path, "compaction entry is missing tokensBefore")
      }
      let usage = match fields.get("usage") {
        Some(usage_json) if usage_json is Object(_) =>
          Some(parse_usage(usage_json, path.add_key("usage")))
        _ => None
      }
      Compaction(
        summary~,
        retained_tail~,
        tokens_before=tokens_before.to_int(),
        details=fields.get("details"),
        usage~,
      )
    }
    "custom" => {
      guard fields.get("customType") is Some(String(custom_type)) else {
        decode_error(content_path, "custom entry is missing customType")
      }
      Custom(custom_type~, data=fields.get("data"))
    }
    _ => decode_error(content_path, "unknown entry type \{entry_type}")
  }
  { id, seq: seq.to_int(), parent_id, timestamp, content }
}

///|
fn[T] decode_error(
  path : @json.JsonPath,
  msg : String,
) -> T raise @json.JsonDecodeError {
  raise @json.JsonDecodeError((path, msg))
}

///|
/// pi stores timestamps as JSON numbers (Unix ms).
fn parse_timestamp(
  json : Json?,
  path : @json.JsonPath,
) -> UInt64 raise @json.JsonDecodeError {
  match json {
    Some(Number(n, ..)) if n >= 0.0 => n.to_int64().reinterpret_as_uint64()
    _ => decode_error(path, "invalid timestamp")
  }
}

///|
fn parse_agent_message(
  json : Json,
  path : @json.JsonPath,
) -> AgentMessage raise @json.JsonDecodeError {
  guard json is Object(fields) else {
    decode_error(path, "AgentMessage: expected object")
  }
  guard fields.get("role") is Some(String(role)) else {
    decode_error(path, "AgentMessage: missing role")
  }
  match role {
    "user" => {
      guard fields.get("content") is Some(Array(items)) else {
        decode_error(path, "User message: missing content")
      }
      let contents = []
      for i, item in items {
        contents.push(
          parse_input_content(item, path.add_key("content").add_index(i)),
        )
      }
      User(contents)
    }
    "assistant" => {
      guard fields.get("content") is Some(Array(items)) else {
        decode_error(path, "Assistant message: missing content")
      }
      let contents = []
      for i, item in items {
        contents.push(
          parse_assistant_content(item, path.add_key("content").add_index(i)),
        )
      }
      guard fields.get("api") is Some(String(api)) else {
        decode_error(path, "Assistant message: missing api")
      }
      guard fields.get("provider") is Some(String(provider)) else {
        decode_error(path, "Assistant message: missing provider")
      }
      guard fields.get("model") is Some(String(model)) else {
        decode_error(path, "Assistant message: missing model")
      }
      guard fields.get("stopReason") is Some(String(stop_reason)) else {
        decode_error(path, "Assistant message: missing stopReason")
      }
      let stop_reason : @agent_loop.StopReason = match stop_reason {
        "pending" => Pending
        "stop" => Stop
        "length" => Length
        "toolUse" => ToolUse
        "aborted" => Aborted
        "error" => Error
        _ => decode_error(path, "unknown stopReason \{stop_reason}")
      }
      let error_message = match fields.get("errorMessage") {
        Some(String(message)) => Some(message)
        _ => None
      }
      let usage = match fields.get("usage") {
        Some(usage_json) if usage_json is Object(_) =>
          Some(parse_usage(usage_json, path.add_key("usage")))
        _ => None
      }
      let timestamp = parse_timestamp(
        fields.get("timestamp"),
        path.add_key("timestamp"),
      )
      Assistant({
        content: contents,
        api,
        provider,
        model,
        stop_reason,
        error_message,
        usage,
        timestamp,
      })
    }
    "toolResult" => {
      guard fields.get("toolCallId") is Some(String(tool_call_id)) else {
        decode_error(path, "ToolResult: missing toolCallId")
      }
      guard fields.get("toolName") is Some(String(tool_name)) else {
        decode_error(path, "ToolResult: missing toolName")
      }
      guard fields.get("content") is Some(Array(items)) else {
        decode_error(path, "ToolResult: missing content")
      }
      let content = []
      for i, item in items {
        content.push(
          parse_input_content(item, path.add_key("content").add_index(i)),
        )
      }
      let timestamp = parse_timestamp(
        fields.get("timestamp"),
        path.add_key("timestamp"),
      )
      ToolResult({
        tool_call_id,
        tool_name,
        content,
        is_error: fields.get("isError") is Some(True),
        timestamp,
        terminate: fields.get("terminate") is Some(True),
      })
    }
    _ => decode_error(path, "AgentMessage: unknown role \{role}")
  }
}

///|
fn parse_input_content(
  json : Json,
  path : @json.JsonPath,
) -> @agent_loop.InputMessageContent raise @json.JsonDecodeError {
  match json {
    { "type": "text", "text": String(text), .. } => Text(text)
    _ => decode_error(path, "InputMessageContent: invalid shape")
  }
}

///|
fn parse_assistant_content(
  json : Json,
  path : @json.JsonPath,
) -> @agent_loop.AssistantMessageContent raise @json.JsonDecodeError {
  guard json is Object(fields) else {
    decode_error(path, "AssistantMessageContent: expected object")
  }
  guard fields.get("type") is Some(String(content_type)) else {
    decode_error(path, "AssistantMessageContent: missing type")
  }
  match content_type {
    "text" => {
      guard fields.get("text") is Some(String(text)) else {
        decode_error(path, "Text content: missing text")
      }
      Text(text, signature=parse_signature(fields.get("textSignature")))
    }
    "thinking" => {
      guard fields.get("thinking") is Some(String(text)) else {
        decode_error(path, "Thinking content: missing thinking")
      }
      Thinking(text, signature=parse_signature(fields.get("thinkingSignature")))
    }
    "toolCall" => {
      guard fields.get("id") is Some(String(id)) else {
        decode_error(path, "ToolCall content: missing id")
      }
      guard fields.get("name") is Some(String(name)) else {
        decode_error(path, "ToolCall content: missing name")
      }
      let arguments = fields.get("arguments").unwrap_or(Json::empty_object())
      ToolCall(
        { id, name, arguments },
        signature=parse_signature(fields.get("thoughtSignature")),
      )
    }
    "hostedToolCall" =>
      HostedToolCall(
        @agent_loop.HostedTool::WebSearch,
        signature=parse_signature(fields.get("signature")),
      )
    _ =>
      decode_error(
        path,
        "AssistantMessageContent: unknown type \{content_type}",
      )
  }
}

///|
/// Signatures are stored as strings in pi's format (legacy id strings or
/// stringified JSON). Parse stringified JSON back; keep unparseable strings
/// as plain JSON strings so the round trip stays lossless.
fn parse_signature(json : Json?) -> Json {
  match json {
    Some(String(s)) => @json.parse(s) catch { _ => Json::string(s) }
    Some(other) => other
    None => Json::empty_object()
  }
}

///|
fn parse_usage(
  json : Json,
  path : @json.JsonPath,
) -> @agent_loop.Usage raise @json.JsonDecodeError {
  guard json is Object(fields) else {
    decode_error(path, "Usage: expected object")
  }
  guard fields.get("input") is Some(Number(input, ..)) else {
    decode_error(path, "Usage: missing input")
  }
  guard fields.get("output") is Some(Number(output, ..)) else {
    decode_error(path, "Usage: missing output")
  }
  guard fields.get("cacheRead") is Some(Number(cache_read, ..)) else {
    decode_error(path, "Usage: missing cacheRead")
  }
  guard fields.get("cacheWrite") is Some(Number(cache_write, ..)) else {
    decode_error(path, "Usage: missing cacheWrite")
  }
  guard fields.get("totalTokens") is Some(Number(total_tokens, ..)) else {
    decode_error(path, "Usage: missing totalTokens")
  }
  let cache_write_1h = match fields.get("cacheWrite1h") {
    Some(Number(n, ..)) => Some(n.to_int())
    _ => None
  }
  let reasoning = match fields.get("reasoning") {
    Some(Number(n, ..)) => Some(n.to_int())
    _ => None
  }
  guard fields.get("cost") is Some(Object(cost)) else {
    decode_error(path, "Usage: missing cost")
  }
  let cost_input = parse_cost_field(cost, "input", path)
  let cost_output = parse_cost_field(cost, "output", path)
  let cost_cache_read = parse_cost_field(cost, "cacheRead", path)
  let cost_cache_write = parse_cost_field(cost, "cacheWrite", path)
  let cost_total = parse_cost_field(cost, "total", path)
  {
    input: input.to_int(),
    output: output.to_int(),
    cache_read: cache_read.to_int(),
    cache_write: cache_write.to_int(),
    cache_write_1h,
    reasoning,
    total_tokens: total_tokens.to_int(),
    cost: {
      input: cost_input,
      output: cost_output,
      cache_read: cost_cache_read,
      cache_write: cost_cache_write,
      total: cost_total,
    },
  }
}

///|
fn parse_cost_field(
  cost : Map[String, Json],
  key : String,
  path : @json.JsonPath,
) -> Float raise @json.JsonDecodeError {
  match cost.get(key) {
    Some(Number(n, ..)) => Float::from_double(n)
    _ => decode_error(path.add_key(key), "Usage cost: missing \{key}")
  }
}

///|
struct InMemorySessionJournal {
  journal : Array[SessionEntry]
  ids : Set[String]
  rand : @random.Rand
  mut seq : Int
  mut leaf_id : String?
  now : () -> UInt64
}

///|
pub fn InMemorySessionJournal::InMemorySessionJournal(
  now? : () -> UInt64 = @env.now,
) -> InMemorySessionJournal {
  InMemorySessionJournal::{
    journal: [],
    ids: Set([]),
    rand: @random.Rand::new(),
    seq: 0,
    leaf_id: None,
    now,
  }
}

///|
pub impl SessionJournal for InMemorySessionJournal with fn append(
  self,
  provisioned,
) {
  let stored = []
  for p in provisioned {
    self.seq += 1
    let entry : SessionEntry = {
      id: p.id,
      seq: self.seq,
      parent_id: self.leaf_id,
      timestamp: (self.now)(),
      content: p.content,
    }
    self.leaf_id = Some(p.id)
    self.ids.add(p.id)
    self.journal.push(entry)
    stored.push(entry)
  }
  stored
}

///|
pub impl SessionJournal for InMemorySessionJournal with fn get_entries(self) {
  self.journal
}

///|
pub impl SessionJournal for InMemorySessionJournal with fn generate_id(self) {
  for _ in 0..<100 {
    let id = self.rand.uint64().to_string()[:8].to_owned()
    if !self.ids.contains(id) {
      return id
    }
  }
  self.rand.uint64().to_string()[:8].to_owned()
}
