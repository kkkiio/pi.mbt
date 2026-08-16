///|
/// A JSON Lines session journal that implements `SessionJournal`.
///
/// The file format is a single session header line followed by one JSON object
/// per persisted `SessionEntry`. This matches the on-disk shape used by
/// `pi` session journals: a header plus a stream of append-only records.

///|
pub struct JsonlSessionJournal {
  path : String
  mut file : @fs.File?
  ids : Set[String]
  rand : @random.Rand
}

///|
/// Create a new JSONL session journal at `path`. The file is truncated if it
/// already exists. A session header line is written immediately.
pub async fn JsonlSessionJournal::new(path~ : String) -> JsonlSessionJournal {
  let file = @fs.create(path, allow_existing=true)
  let journal = { path, file: Some(file), ids: Set([]), rand: @random.Rand::new() }
  journal.write_header()
  journal
}

///|
/// Close the underlying file. Subsequent `persist` calls become no-ops for the
/// file.
pub fn JsonlSessionJournal::close(self : JsonlSessionJournal) -> Unit {
  if self.file is Some(file) {
    file.close()
    self.file = None
  }
}

///|
async fn JsonlSessionJournal::write_header(self : JsonlSessionJournal) -> Unit {
  guard self.file is Some(file) else { return }
  let header : Json = {
    "type": "session",
    "version": 1,
    "id": self.make_id(),
    "createdAt": @env.now().to_string(),
    "cwd": @env.current_dir().unwrap_or(""),
  }
  file.write(header.stringify())
  file.write("\n")
}

///|
fn JsonlSessionJournal::make_id(self : JsonlSessionJournal) -> String {
  for _ in 0..<100 {
    let id = self.rand.uint64().to_string()[:8].to_owned()
    if !self.ids.contains(id) {
      return id
    }
  }
  self.rand.uint64().to_string()[:8].to_owned()
}

///|
fn entry_to_json(entry : @agent_session.SessionEntry) -> Json {
  {
    "id": entry.id,
    "timestamp": entry.timestamp.to_string(),
    "content": session_entry_content_to_json(entry.content),
  }
}

///|
fn session_entry_content_to_json(
  content : @agent_session.SessionEntryContent,
) -> Json {
  match content {
    Message(message) => {
      "type": "message",
      "message": agent_message_to_json(message),
    }
    ModelChanage(provider~, model_id~) => {
      "type": "model_change",
      "provider": provider,
      "model_id": model_id,
    }
    Compaction => { "type": "compaction" }
    CustomMessage => { "type": "custom_message" }
  }
}

///|
fn agent_message_to_json(message : @agent_loop.AgentMessage) -> Json {
  match message {
    User(contents) => {
      let cs : Array[Json] = []
      for content in contents {
        cs.push(input_content_to_json(content))
      }
      { "role": "user", "content": cs }
    }
    Assistant(contents) => {
      let cs : Array[Json] = []
      for content in contents {
        cs.push(assistant_content_to_json(content))
      }
      { "role": "assistant", "content": cs }
    }
    ToolResult(result) => {
      let cs : Array[Json] = []
      for content in result.content {
        cs.push(input_content_to_json(content))
      }
      {
        "role": "tool",
        "tool_call_id": result.tool_call_id,
        "name": result.tool_name,
        "content": cs,
      }
    }
  }
}

///|
fn input_content_to_json(content : @agent_loop.InputMessageContent) -> Json {
  match content {
    Text(text) => { "type": "text", "text": text }
    Image(bytes) => { "type": "image", "length": bytes.length() }
  }
}

///|
fn assistant_content_to_json(
  content : @agent_loop.AssistantMessageContent,
) -> Json {
  match content {
    Text(text, signature~) => {
      "type": "text",
      "text": text,
      "signature": signature,
    }
    Thinking(text, signature~) => {
      "type": "thinking",
      "thinking": text,
      "signature": signature,
    }
    ToolCall(tool_call, signature~) => {
      "type": "tool_call",
      "id": tool_call.id,
      "name": tool_call.name,
      "arguments": tool_call.arguments,
      "signature": signature,
    }
    HostedToolCall(tool, signature~) => {
      "type": "hosted_tool_call",
      "tool": hosted_tool_to_json(tool),
      "signature": signature,
    }
  }
}

///|
fn hosted_tool_to_json(tool : @agent_loop.HostedTool) -> Json {
  match tool {
    WebSearch => "web_search"
  }
}

///|
pub impl @agent_session.SessionJournal for JsonlSessionJournal with fn persist(
  self : JsonlSessionJournal,
  entries,
) {
  guard self.file is Some(file) else { return }
  for entry in entries {
    self.ids.add(entry.id)
    file.write(entry_to_json(entry).stringify())
    file.write("\n")
  }
}

///|
pub impl @agent_session.SessionJournal for JsonlSessionJournal with fn fetch_entries(
  self : JsonlSessionJournal,
) {
  let content = @fs.read_file(self.path).text()
  let lines = content.split("\n").to_array().filter(fn(line) {
    line.length() > 0
  })
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
pub impl @agent_session.SessionJournal for JsonlSessionJournal with fn generate_id(
  self : JsonlSessionJournal,
) -> String {
  self.make_id()
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
  let timestamp = try {
    @string.parse_uint64(s)
  } catch {
    _ => return None
  }
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
  fields : Map[String, Json]
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
        @agent_session.SessionEntryContent::ModelChanage(
          provider~,
          model_id~,
        ),
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
fn parse_input_content(
  json : Json
) -> @agent_loop.InputMessageContent? {
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
fn parse_assistant_content(
  json : Json
) -> @agent_loop.AssistantMessageContent? {
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
