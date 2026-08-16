///|
using @agent_loop {type AgentMessage}

///|
pub(open) trait SessionJournal {
  fn generate_id(Self) -> String
  async fn persist(Self, ArrayView[SessionEntry]) -> Unit
  fn get_entries(Self) -> ArrayView[SessionEntry]
}

///|
pub(all) struct SessionEntry {
  id : String
  /// persist time
  timestamp : UInt64
  content : SessionEntryContent
}

///|
pub(all) enum SessionEntryContent {
  Message(AgentMessage)
  ModelChanage(provider~ : String, model_id~ : String)
  Compaction
  CustomMessage
}

///|
pub impl ToJson for SessionEntry with fn to_json(self) -> Json {
  {
    "id": self.id,
    "timestamp": self.timestamp.to_string(),
    "content": session_entry_content_to_json(self.content),
  }
}

///|
pub impl FromJson for SessionEntry with fn from_json(json, path) {
  match json {
    {
      "id": String(id),
      "timestamp": String(ts),
      "content": Object(content_fields),
      ..
    } => {
      let timestamp = @string.parse_uint64(ts) catch {
        _ => decode_error(path, "SessionEntry::from_json: invalid timestamp")
      }
      {
        id,
        timestamp,
        content: parse_session_entry_content(
          content_fields,
          path.add_key("content"),
        ),
      }
    }
    _ => decode_error(path, "SessionEntry::from_json: invalid shape")
  }
}

///|
fn[T] decode_error(path : @json.JsonPath, msg : String) -> T raise @json.JsonDecodeError {
  raise @json.JsonDecodeError((path, msg))
}

///|
fn session_entry_content_to_json(content : SessionEntryContent) -> Json {
  match content {
    Message(message) =>
      { "type": "message", "message": agent_message_to_json(message) }
    ModelChanage(provider~, model_id~) =>
      { "type": "model_change", "provider": provider, "model_id": model_id }
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
    Text(text, signature~) =>
      { "type": "text", "text": text, "signature": signature }
    Thinking(text, signature~) =>
      { "type": "thinking", "thinking": text, "signature": signature }
    ToolCall(tool_call, signature~) =>
      {
        "type": "tool_call",
        "id": tool_call.id,
        "name": tool_call.name,
        "arguments": tool_call.arguments,
        "signature": signature,
      }
    HostedToolCall(tool, signature~) =>
      {
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
fn parse_session_entry_content(
  fields : Map[String, Json],
  path : @json.JsonPath,
) -> SessionEntryContent raise @json.JsonDecodeError {
  match fields {
    { "type": "message", "message": message_json, .. } =>
      Message(parse_agent_message(message_json, path.add_key("message")))
    { "type": "model_change", "provider": String(provider), "model_id": String(model_id), .. } =>
      ModelChanage(provider~, model_id~)
    { "type": "compaction", .. } => Compaction
    { "type": "custom_message", .. } => CustomMessage
    _ => decode_error(path, "unknown content type")
  }
}

///|
fn parse_agent_message(json : Json, path : @json.JsonPath) -> @agent_loop.AgentMessage raise @json.JsonDecodeError {
  match json {
    { "role": "user", "content": Array(items), .. } => {
      let contents = []
      for i, item in items {
        contents.push(
          parse_input_content(item, path.add_key("content").add_index(i)),
        )
      }
      User(contents)
    }
    { "role": "assistant", "content": Array(items), .. } => {
      let contents = []
      for i, item in items {
        contents.push(
          parse_assistant_content(
            item,
            path.add_key("content").add_index(i),
          ),
        )
      }
      Assistant(contents)
    }
    {
      "role": "tool",
      "tool_call_id": String(tool_call_id),
      "name": String(tool_name),
      "content": Array(items),
      ..
    } => {
      let content = []
      for i, item in items {
        content.push(
          parse_input_content(item, path.add_key("content").add_index(i)),
        )
      }
      ToolResult(
        {
          tool_call_id,
          tool_name,
          content,
          is_error: false,
          timestamp: 0,
          terminate: false,
        },
      )
    }
    _ => decode_error(path, "AgentMessage: invalid shape")
  }
}

///|
fn parse_input_content(json : Json, path : @json.JsonPath) -> @agent_loop.InputMessageContent raise @json.JsonDecodeError {
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
  let signature = match json {
    { "signature": sig, .. } => sig
    _ => Json::empty_object()
  }
  match json {
    { "type": "text", "text": String(text), .. } => Text(text, signature~)
    { "type": "thinking", "thinking": String(text), .. } =>
      Thinking(text, signature~)
    { "type": "tool_call", "id": String(id), "name": String(name), .. } => {
      let arguments = match json {
        { "arguments": args, .. } => args
        _ => Json::empty_object()
      }
      ToolCall({ id, name, arguments }, signature~)
    }
    { "type": "hosted_tool_call", .. } =>
      HostedToolCall(@agent_loop.HostedTool::WebSearch, signature~)
    _ => decode_error(path, "AssistantMessageContent: invalid shape")
  }
}

///|
struct InMemorySessionJournal {
  journal : Array[SessionEntry]
  ids : Set[String]
  rand : @random.Rand
}

///|
pub fn InMemorySessionJournal::InMemorySessionJournal() -> InMemorySessionJournal {
  InMemorySessionJournal::{
    journal: [],
    ids: Set([]),
    rand: @random.Rand::new(),
  }
}

///|
pub impl SessionJournal for InMemorySessionJournal with fn persist(
  self,
  entries,
) {
  self.journal.append(entries)
  for e in entries {
    self.ids.add(e.id)
  }
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
