///|
/// A JSON Lines session journal that implements `SessionJournal`.
///
/// The file format is a single session header line followed by one JSON object
/// per persisted `SessionEntry`. This matches the on-disk shape used by
/// `pi` session journals: a header plus a stream of append-only records.

///|
pub struct JsonlSessionJournal[W] {
  writer : W
  entries : Array[@agent_session.SessionEntry]
  ids : Set[String]
  rand : @random.Rand
}

///|
/// Create a new JSONL session journal that writes to the given `writer`.
/// A session header line is written immediately. The caller is responsible for
/// any parent directories, filename choice, and closing `writer` when done.
pub async fn[W : @io.Writer] JsonlSessionJournal::JsonlSessionJournal(
  writer : W,
  entries? : Array[@agent_session.SessionEntry] = [],
  rand? : @random.Rand = @random.Rand::new(),
  cwd? : String = @env.current_dir().unwrap_or(""),
  now? : UInt64 = @env.now(),
) -> JsonlSessionJournal[W] {
  let ids = Set([])
  writer.write(
    (
      {
        "type": "session",
        "version": 1,
        "id": make_id(rand, ids),
        "createdAt": now,
        "cwd": cwd,
      } : Json).stringify(),
  )
  writer.write("\n")
  { writer, entries, ids, rand }
}

///|
fn make_id(rand : @random.Rand, ids : Set[String]) -> String {
  for _ in 0..<100 {
    let id = rand.uint64().to_string()[:8].to_owned()
    if !ids.contains(id) {
      return id
    }
  }
  rand.uint64().to_string()[:8].to_owned()
}

///|
pub impl[W : @io.Writer] @agent_session.SessionJournal for JsonlSessionJournal[
  W,
] with fn persist(self, entries) {
  for entry in entries {
    self.ids.add(entry.id)
    self.entries.push(entry)
    self.writer.write(ToJson::to_json(entry).stringify())
    self.writer.write("\n")
  }
}

///|
pub async fn fetch_entries(path : String) -> Array[@agent_session.SessionEntry] {
  let content = @fs.read_file(path).text()
  let lines = content
    .split("\n")
    .to_array()
    .filter(fn(line) { line.length() > 0 })
  let entries = []
  for i = 1; i < lines.length(); i = i + 1 {
    let json = @json.parse(lines[i])
    guard json is Json::Object(fields) else { continue }
    if parse_entry(fields) is Some(entry) {
      entries.push(entry)
    }
  }
  entries
}

///|
pub impl[W : @io.Writer] @agent_session.SessionJournal for JsonlSessionJournal[
  W,
] with fn get_entries(self : JsonlSessionJournal[W]) {
  self.entries
}

///|
pub impl[W : @io.Writer] @agent_session.SessionJournal for JsonlSessionJournal[
  W,
] with fn generate_id(self) -> String {
  make_id(self.rand, self.ids)
}

///|
fn parse_entry(fields : Map[String, Json]) -> @agent_session.SessionEntry? {
  let id = match fields.get("id") {
    Some(Json::String(id)) => id
    _ => return None
  }
  let s = match fields.get("timestamp") {
    Some(Json::String(s)) => s
    _ => return None
  }
  let timestamp = @string.parse_uint64(s) catch { _ => return None }
  let content = match fields.get("content") {
    Some(Json::Object(content_fields)) => content_fields
    _ => return None
  }
  let content = match parse_session_entry_content(content) {
    Some(c) => c
    None => return None
  }
  Some({ id, timestamp, content })
}

///|
fn parse_session_entry_content(
  fields : Map[String, Json],
) -> @agent_session.SessionEntryContent? {
  match fields.get("type") {
    Some(Json::String("message")) =>
      match fields.get("message") {
        Some(json) =>
          match parse_agent_message(json) {
            Some(message) =>
              Some(@agent_session.SessionEntryContent::Message(message))
            None => None
          }
        None => None
      }
    Some(Json::String("model_change")) => {
      let provider = match fields.get("provider") {
        Some(Json::String(s)) => s
        _ => return None
      }
      let model_id = match fields.get("model_id") {
        Some(Json::String(s)) => s
        _ => return None
      }
      Some(
        @agent_session.SessionEntryContent::ModelChanage(provider~, model_id~),
      )
    }
    Some(Json::String("compaction")) =>
      Some(@agent_session.SessionEntryContent::Compaction)
    Some(Json::String("custom_message")) =>
      Some(@agent_session.SessionEntryContent::CustomMessage)
    _ => None
  }
}

///|
fn parse_agent_message(json : Json) -> @agent_loop.AgentMessage? {
  guard json is Json::Object(fields) else { return None }
  match fields.get("role") {
    Some(Json::String("user")) =>
      match fields.get("content") {
        Some(Json::Array(items)) => {
          let contents = []
          for item in items {
            if parse_input_content(item) is Some(content) {
              contents.push(content)
            }
          }
          Some(@agent_loop.AgentMessage::User(contents))
        }
        _ => None
      }
    Some(Json::String("assistant")) =>
      match fields.get("content") {
        Some(Json::Array(items)) => {
          let contents = []
          for item in items {
            if parse_assistant_content(item) is Some(content) {
              contents.push(content)
            }
          }
          Some(@agent_loop.AgentMessage::Assistant(contents))
        }
        _ => None
      }
    Some(Json::String("tool")) => {
      let tool_call_id = match fields.get("tool_call_id") {
        Some(Json::String(s)) => s
        _ => return None
      }
      let tool_name = match fields.get("name") {
        Some(Json::String(s)) => s
        _ => return None
      }
      let content = match fields.get("content") {
        Some(Json::Array(items)) => {
          let cs = []
          for item in items {
            if parse_input_content(item) is Some(c) {
              cs.push(c)
            }
          }
          cs
        }
        _ => return None
      }
      Some(
        @agent_loop.AgentMessage::ToolResult({
          tool_call_id,
          tool_name,
          content,
          is_error: false,
          timestamp: 0,
          terminate: false,
        }),
      )
    }
    _ => None
  }
}

///|
fn parse_input_content(json : Json) -> @agent_loop.InputMessageContent? {
  guard json is Json::Object(fields) else { return None }
  match fields.get("type") {
    Some(Json::String("text")) =>
      match fields.get("text") {
        Some(Json::String(text)) =>
          Some(@agent_loop.InputMessageContent::Text(text))
        _ => None
      }
    _ => None
  }
}

///|
fn parse_assistant_content(json : Json) -> @agent_loop.AssistantMessageContent? {
  guard json is Json::Object(fields) else { return None }
  let signature = match fields.get("signature") {
    Some(value) => value
    None => Json::empty_object()
  }
  match fields.get("type") {
    Some(Json::String("text")) =>
      match fields.get("text") {
        Some(Json::String(text)) =>
          Some(@agent_loop.AssistantMessageContent::Text(text, signature~))
        _ => None
      }
    Some(Json::String("thinking")) =>
      match fields.get("thinking") {
        Some(Json::String(text)) =>
          Some(@agent_loop.AssistantMessageContent::Thinking(text, signature~))
        _ => None
      }
    Some(Json::String("tool_call")) => {
      let id = match fields.get("id") {
        Some(Json::String(s)) => s
        _ => return None
      }
      let name = match fields.get("name") {
        Some(Json::String(s)) => s
        _ => return None
      }
      let arguments = match fields.get("arguments") {
        Some(value) => value
        None => Json::empty_object()
      }
      Some(
        @agent_loop.AssistantMessageContent::ToolCall(
          { id, name, arguments },
          signature~,
        ),
      )
    }
    Some(Json::String("hosted_tool_call")) =>
      Some(
        @agent_loop.AssistantMessageContent::HostedToolCall(
          @agent_loop.HostedTool::WebSearch,
          signature~,
        ),
      )
    _ => None
  }
}
