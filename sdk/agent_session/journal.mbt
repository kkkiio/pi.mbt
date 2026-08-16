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
