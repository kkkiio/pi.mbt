///|
using @agent_loop {type AgentMessage}

///|
pub(open) trait SessionJournal {
  fn generate_id(Self) -> String
  /// Append caller-provisioned entries. The journal assigns the
  /// storage-owned fields (`parent_id`, `timestamp`), persists the
  /// entries, and returns them in stored form.
  async fn append(Self, ArrayView[NewSessionEntry]) -> Array[SessionEntry]
  fn get_entries(Self) -> ArrayView[SessionEntry]
}

///|
/// A stored pi v3 session entry. Entry timestamps serialize as UTC ISO
/// strings; timestamps inside messages remain Unix milliseconds.
pub(all) struct SessionEntry {
  id : String
  /// The branch leaf at append time; `None` for the first entry.
  parent_id : String?
  /// Storage-assigned persist time, Unix milliseconds.
  timestamp : UInt64
  content : SessionEntryContent
}

///|
/// Caller-provisioned entry: everything except the storage-assigned fields
/// (`parent_id`, `timestamp`).
pub(all) struct NewSessionEntry {
  id : String
  content : SessionEntryContent
}

///|
pub(all) enum SessionEntryContent {
  Message(AgentMessage)
  ModelChange(provider~ : String, model_id~ : String)
  Compaction(
    summary~ : String,
    first_kept_entry_id~ : String,
    tokens_before~ : Int,
    details~ : Json?,
    usage~ : @agent_loop.Usage?
  )
  Custom(custom_type~ : String, data~ : Json?)
  /// pi metadata entries not used by the current agent (for example thinking levels).
  Metadata(Json)
}

///|
pub impl ToJson for SessionEntry with fn to_json(self) -> Json {
  let obj : Map[String, Json] = Map([])
  obj["id"] = self.id.to_json()
  obj["parentId"] = match self.parent_id {
    Some(id) => id.to_json()
    None => Json::null()
  }
  obj["timestamp"] = format_journal_timestamp(self.timestamp).to_json()
  match self.content {
    Message(message) => {
      obj["type"] = "message".to_json()
      obj["message"] = message.to_json()
    }
    ModelChange(provider~, model_id~) => {
      obj["type"] = "model_change".to_json()
      obj["provider"] = provider.to_json()
      obj["modelId"] = model_id.to_json()
    }
    Compaction(summary~, first_kept_entry_id~, tokens_before~, details~, usage~) => {
      obj["type"] = "compaction".to_json()
      obj["summary"] = summary.to_json()
      obj["firstKeptEntryId"] = first_kept_entry_id.to_json()
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
    Metadata(Object(fields)) =>
      for key, value in fields {
        if key != "id" && key != "parentId" && key != "timestamp" {
          obj[key] = value
        }
      }
    Metadata(_) => abort("session metadata must be an object")
  }
  Json::object(obj)
}

///|
pub extend SessionEntry with ToJson::{to_json}

///|
pub impl FromJson for SessionEntry with fn from_json(json, path) {
  guard json is Object(fields) else {
    decode_error(path, "SessionEntry::from_json: expected object")
  }
  guard fields.get("id") is Some(String(id)) else {
    decode_error(path, "SessionEntry::from_json: invalid id")
  }
  let parent_id = match fields.get("parentId") {
    Some(String(id)) => Some(id)
    _ => None
  }
  let timestamp = parse_journal_timestamp(
    fields.get("timestamp"),
    path.add_key("timestamp"),
  )
  guard fields.get("type") is Some(String(entry_type)) else {
    decode_error(path, "SessionEntry::from_json: missing type")
  }
  let content_path = path.add_key("type")
  let content : SessionEntryContent = match entry_type {
    "message" => {
      guard fields.get("message") is Some(message_json) else {
        decode_error(content_path, "message entry is missing message")
      }
      Message(parse_agent_message(message_json, path.add_key("message")))
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
      guard fields.get("firstKeptEntryId") is Some(String(first_kept_entry_id)) else {
        decode_error(
          content_path, "compaction entry is missing firstKeptEntryId",
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
        first_kept_entry_id~,
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
    "thinking_level_change" | "session_info" | "label" | "usage" =>
      Metadata(json)
    _ =>
      decode_error(content_path, "unsupported session entry type \{entry_type}")
  }
  { id, parent_id, timestamp, content, }
}

///|
pub extend SessionEntry with @json.FromJson::{from_json}

///|
/// Shared by the session header and entries, matching Date.toISOString().
pub fn format_journal_timestamp(timestamp : UInt64) -> String {
  let millis = timestamp.reinterpret_as_int64()
  let date = @time.PlainDateTime::from_unix_second(
    millis / 1000,
    (millis % 1000).to_int() * 1_000_000,
    @time.utc_offset,
  ) catch {
    error => abort(error.to_string())
  }
  let pad = (value : Int, width : Int) => {
    let text = value.to_string()
    "0".repeat(width - text.length()) + text
  }
  "\{pad(date.year(), 4)}-\{pad(date.month(), 2)}-\{pad(date.day(), 2)}T\{pad(date.hour(), 2)}:\{pad(date.minute(), 2)}:\{pad(date.second(), 2)}.\{pad(date.nanosecond() / 1_000_000, 3)}Z"
}

///|
fn parse_journal_timestamp(
  json : Json?,
  path : @json.JsonPath,
) -> UInt64 raise @json.JsonDecodeError {
  guard json is Some(String(text)) && text.length() == 24 else {
    decode_error(path, "invalid ISO timestamp")
  }
  guard text.strip_suffix("Z") is Some(date_text) else {
    decode_error(path, "invalid ISO timestamp")
  }
  let date : @time.PlainDateTime = @string.FromStr::from_str(date_text) catch {
    _ => decode_error(path, "invalid ISO timestamp")
  }
  let millis = date.to_unix_second() * 1000 +
    (date.nanosecond() / 1_000_000).to_int64()
  guard millis >= 0 else { decode_error(path, "invalid ISO timestamp") }
  millis.reinterpret_as_uint64()
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
      let contents = match fields.get("content") {
        Some(String(text)) => [@agent_loop.InputMessageContent::Text(text)]
        Some(Array(items)) =>
          items.mapi((i, item) => {
            parse_input_content(item, path.add_key("content").add_index(i))
          })
        _ => decode_error(path, "User message: missing content")
      }
      let timestamp = parse_timestamp(
        fields.get("timestamp"),
        path.add_key("timestamp"),
      )
      User({ content: contents, timestamp, })
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
        details: fields.get("details"),
        usage: match fields.get("usage") {
          Some(usage_json) if usage_json is Object(_) =>
            Some(parse_usage(usage_json, path.add_key("usage")))
          _ => None
        },
        is_error: fields.get("isError") is Some(True),
        timestamp,
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
        { id, name, arguments, },
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
/// Restore structured provider replay data while keeping opaque strings
/// (including strings that happen to parse as JSON primitives) verbatim.
fn parse_signature(json : Json?) -> Json {
  match json {
    Some(String(text)) => {
      let parsed = Some(@json.parse(text)) catch { _ => None }
      match parsed {
        Some(Object(fields)) if !fields.is_empty() => Json::object(fields)
        _ => Json::string(text)
      }
    }
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
    leaf_id: None,
    now,
  }
}

///|
pub extend InMemorySessionJournal with SessionJournal::{
  get_entries,
  append,
  generate_id,
}

///|
pub impl SessionJournal for InMemorySessionJournal with fn append(
  self,
  provisioned,
) {
  let stored = []
  for p in provisioned {
    let entry : SessionEntry = {
      id: p.id,
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
