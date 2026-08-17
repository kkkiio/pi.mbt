///|
/// A JSON Lines session journal that implements `SessionJournal`.
///
/// The on-disk format matches pi's v4 session journal: a `kind: "header"`
/// line followed by one `kind: "entry"` mutation line per persisted
/// `SessionEntry`. Entry payloads are flattened and carry storage-assigned
/// `seq`/`parentId`/`timestamp`, so journals written by pim can be read by
/// pi tooling and vice versa.

///|
pub struct JsonlSessionJournal[W] {
  writer : W
  entries : Array[@agent_session.SessionEntry]
  ids : Set[String]
  rand : @random.Rand
  lane : String
  mut seq : Int
  mut leaf_id : String?
  now : () -> UInt64
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
  now? : () -> UInt64 = @env.now,
  lane? : String = "main",
) -> JsonlSessionJournal[W] {
  let ids = Set([])
  let mut seq = 0
  let mut leaf_id : String? = None
  for entry in entries {
    ids.add(entry.id)
    if entry.seq > seq {
      seq = entry.seq
    }
    leaf_id = Some(entry.id)
  }
  let header : Json = {
    "kind": "header",
    "version": 4,
    "id": make_id(rand, ids),
    "createdAt": Json::number(now().to_double()),
    "cwd": cwd,
  }
  writer.write(header.stringify())
  writer.write("\n")
  { writer, entries, ids, rand, lane, seq, leaf_id, now }
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
] with fn append(self, provisioned) {
  let stored = []
  for p in provisioned {
    self.seq += 1
    let entry : @agent_session.SessionEntry = {
      id: p.id,
      seq: self.seq,
      parent_id: self.leaf_id,
      timestamp: (self.now)(),
      content: p.content,
    }
    self.leaf_id = Some(p.id)
    self.ids.add(p.id)
    self.entries.push(entry)
    stored.push(entry)
    self.writer.write(entry_mutation_json(entry, self.lane).stringify())
    self.writer.write("\n")
  }
  stored
}

///|
fn entry_mutation_json(
  entry : @agent_session.SessionEntry,
  lane : String,
) -> Json {
  guard entry.to_json() is Object(fields) else {
    abort("SessionEntry::to_json must produce an object")
  }
  // kind/lane first, matching pi's key order so journals diff cleanly.
  let obj : Map[String, Json] = Map([])
  obj["kind"] = "entry".to_json()
  obj["lane"] = lane.to_json()
  for key, value in fields {
    obj[key] = value
  }
  Json::object(obj)
}

///|
pub async fn fetch_entries(
  path : String,
) -> Array[@agent_session.SessionEntry] raise Failure {
  let content = @fs.read_file(path).text() catch {
    err => fail("failed to read session journal at \{path}: \{err}")
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
  guard header is Some({ "kind": "header", "version": Number(version, ..), .. }) &&
    version == 4 else {
    fail("session journal at \{path} has an invalid or unsupported header")
  }
  for i = 1; i < lines.length(); i = i + 1 {
    let last = i == lines.length() - 1 && !has_trailing_newline
    let json = Some(@json.parse(lines[i])) catch { _ => None }
    match json {
      None =>
        if last {
          // tolerate a torn final line (crash mid-append)
          continue
        } else {
          fail("session journal has invalid JSON at line \{i + 1}")
        }
      Some(json) => {
        // Skip non-entry mutations (record/lane/fact) so journals written by
        // pi remain readable here.
        if json is { "kind": String(kind), .. } && kind != "entry" {
          continue
        }
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
