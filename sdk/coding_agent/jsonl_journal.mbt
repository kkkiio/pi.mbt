///|
/// JSON Lines session journal implementing `SessionJournal` (v3 format).
pub struct JsonlSessionJournal[W] {
  writer : W
  entries : Array[@agent_session.SessionEntry]
  ids : Set[String]
  rand : @random.Rand
  cwd : String
  header_id : String
  created_at : UInt64
  mut leaf_id : String?
  /// Number of pre-existing persisted entries at construction; only entries from `start_index` onward are flushed.
  start_index : Int32
  /// Whether the initial flush has occurred.
  mut flushed : Bool
  now : () -> UInt64
}

///|
/// Creates a JSONL session journal backed by `writer`.
/// When `fresh` is `true`, nothing is written to `writer` until the first assistant message is appended.
pub fn[W] JsonlSessionJournal::JsonlSessionJournal(
  writer : W,
  entries~ : Array[@agent_session.SessionEntry] = [],
  rand~ : @random.Rand = @random.Rand(),
  cwd~ : String = @env.current_dir().unwrap_or(""),
  now~ : () -> UInt64 = @env.now,
  fresh~ : Bool = true,
) -> JsonlSessionJournal[W] {
  let ids = Set([])
  let mut leaf_id : String? = None
  for entry in entries {
    ids.add(entry.id)
    leaf_id = Some(entry.id)
  }
  {
    writer,
    entries,
    ids,
    header_id: make_id(rand, ids),
    created_at: now(),
    rand,
    cwd,
    leaf_id,
    start_index: entries.length(),
    flushed: !fresh,
    now,
  }
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
pub extend JsonlSessionJournal with @agent_session.SessionJournal::{
  get_entries,
  append,
  generate_id,
}

///|
/// Appends `provisioned` entries and lazily flushes the session header and buffered entries once an assistant message is present.
pub impl[W : @io.Writer] @agent_session.SessionJournal for JsonlSessionJournal[
  W,
] with fn append(self, provisioned) {
  let stored = []
  for p in provisioned {
    let entry : @agent_session.SessionEntry = {
      id: p.id,
      parent_id: self.leaf_id,
      timestamp: (self.now)(),
      content: p.content,
    }
    self.leaf_id = Some(p.id)
    self.ids.add(p.id)
    self.entries.push(entry)
    stored.push(entry)
    if self.flushed {
      self.writer.write(entry.to_json().stringify())
      self.writer.write("\n")
    } else if self.has_assistant() {
      let header : Json = {
        "type": "session",
        "version": 3,
        "id": self.header_id,
        "timestamp": @agent_session.format_journal_timestamp(self.created_at),
        "cwd": self.cwd,
      }
      self.writer.write(header.stringify())
      self.writer.write("\n")
      for i in self.start_index..<self.entries.length() {
        self.writer.write(self.entries[i].to_json().stringify())
        self.writer.write("\n")
      }
      self.flushed = true
    }
  }
  stored
}

///|
fn[W] JsonlSessionJournal::has_assistant(self : JsonlSessionJournal[W]) -> Bool {
  for i in self.start_index..<self.entries.length() {
    match self.entries[i].content {
      Message(Assistant(_)) => return true
      _ => ()
    }
  }
  false
}

///|
fn active_path(
  entries : Array[@agent_session.SessionEntry],
) -> Array[@agent_session.SessionEntry] raise Failure {
  if entries.length() == 0 {
    return entries
  }
  let by_id : Map[String, @agent_session.SessionEntry] = Map([])
  for entry in entries {
    by_id[entry.id] = entry
  }
  let path : Array[@agent_session.SessionEntry] = []
  let mut current : @agent_session.SessionEntry? = Some(
    entries[entries.length() - 1],
  )
  while current is Some(entry) {
    guard path.length() <= entries.length() else {
      fail("session journal has a parentId cycle")
    }
    path.push(entry)
    current = match entry.parent_id {
      Some(id) => by_id.get(id)
      None => None
    }
  }
  path.rev()
}

///|
/// Reads the journal at `path` and returns the active `parentId` chain ending at the last entry.
pub fn fetch_active_entries(
  path : String,
) -> Array[@agent_session.SessionEntry] raise Failure {
  active_path(fetch_entries(path))
}

///|
fn split_complete_lines(content : String) -> (String, Bool) {
  if content.length() == 0 || content.has_suffix("\n") {
    (content, false)
  } else {
    let lines = content.split("\n").to_array()
    (lines[0:lines.length() - 1].join("\n") + "\n", true)
  }
}

///|
/// Reads all entries from the journal at `path`, repairing any torn final line before returning.
/// Raises `Failure` if the file cannot be read, has an invalid header, or contains malformed JSON entries.
pub fn fetch_entries(
  path : String,
) -> Array[@agent_session.SessionEntry] raise Failure {
  let content = read_text_file(path) catch {
    err => fail("failed to read session journal at \{path}: \{err}")
  }
  let (content, torn) = split_complete_lines(content)
  if torn {
    write_file_atomically(path, @utf8.encode(content)) catch {
      err => fail("failed to repair session journal at \{path}: \{err}")
    }
  }
  let has_trailing_newline = content.has_suffix("\n")
  let lines = content
    .split("\n")
    .to_array()
    .filter(fn(line) { line.length() > 0 })
  let entries = []
  if lines.length() == 0 {
    return entries
  }
  let header = Some(@json.parse(lines[0])) catch { _ => None }
  guard header
    is Some(
      {
        "type": "session",
        "version": Number(version, ..),
        "id": String(_),
        "timestamp": String(_),
        "cwd": String(_),
        ..
      }
    ) &&
    version == 3 else {
    fail("session journal at \{path} has an invalid or unsupported header")
  }
  for i = 1; i < lines.length(); i = i + 1 {
    let last = i == lines.length() - 1 && !has_trailing_newline
    let json = Some(@json.parse(lines[i])) catch { _ => None }
    match json {
      None =>
        if last {
          continue
        } else {
          fail("session journal has invalid JSON at line \{i + 1}")
        }
      Some(json) => {
        let entry = @json.from_json(json) catch {
          err =>
            fail("session journal has invalid entry at line \{i + 1}: \{err}")
        }
        entries.push(entry)
      }
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
