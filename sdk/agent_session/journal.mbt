///|
using @agent_loop {type AgentMessage}

///|
pub trait SessionJournal {
  async fn persist(Self, ArrayView[SessionEntry]) -> Unit
  async fn fetch_entries(Self) -> ArrayView[SessionEntry]
  fn generate_id(Self) -> String
}

///|
pub(all) struct SessionEntry {
  id : String
  /// persist time
  timestamp : UInt64
  content : SessionEntryContent
}

///|
pub enum SessionEntryContent {
  Message(AgentMessage)
  ModelChanage(provider~ : String, model_id~ : String)
  Compaction
  CustomMessage
}

///|
struct InMemorySessionJournal {
  journal : Array[SessionEntry]
  ids : Set[String]
  rand : @random.Rand
}

///|
pub fn InMemorySessionJournal::InMemorySessionJournal() -> InMemorySessionJournal {
  InMemorySessionJournal::{ journal: [], ids: Set([]), rand: @random.Rand::new() }
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
pub impl SessionJournal for InMemorySessionJournal with fn fetch_entries(self) {
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
