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
pub async fn fetch_entries(path : String) -> Array[@agent_session.SessionEntry] raise Failure {
  let content = try {
    @fs.read_file(path).text()
  } catch {
    err => fail("failed to read session journal at \{path}: \{err}")
  }
  let lines = content
    .split("\n")
    .to_array()
    .filter(fn(line) { line.length() > 0 })
  let entries = []
  for i = 1; i < lines.length(); i = i + 1 {
    let last = i == lines.length() - 1
    let json = try {
      Some(@json.parse(lines[i]))
    } catch {
      _ => None
    }
    match json {
      None =>
        if last {
          // tolerate a torn final line (crash mid-append)
          continue
        } else {
          fail("session journal has invalid JSON at line \{i + 1}")
        }
      Some(json) => {
        let entry = try {
          @json.from_json(json)
        } catch {
          err => fail("session journal has invalid entry at line \{i + 1}: \{err}")
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
