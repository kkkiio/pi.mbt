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
  cwd : String
  mut seq : Int
  mut leaf_id : String?
  /// 构造时已存在的条目数(已落盘)。flush 只写这个下标之后的条目。
  start_index : Int
  /// 是否已经开始落盘。`false` 时新条目只在内存里。
  mut flushed : Bool
  now : () -> UInt64
}

///|
/// Create a JSONL session journal that writes to the given `writer`.
///
/// Nothing is written — and, when `writer` is a `LazyFile`, no file is even
/// created — until the session has an assistant message, mirroring pi's
/// `_persist`: a session that never got a reply leaves no trace on disk.
/// The header is written at that first flush, so a resumed session passes
/// `fresh=false` and appends straight to the entries already on file.
///
/// The caller is responsible for any parent directories, filename choice, and
/// closing `writer` when done.
pub fn[W] JsonlSessionJournal::JsonlSessionJournal(
  writer : W,
  entries? : Array[@agent_session.SessionEntry] = [],
  rand? : @random.Rand = @random.Rand::new(),
  cwd? : String = @env.current_dir().unwrap_or(""),
  now? : () -> UInt64 = @env.now,
  lane? : String = "main",
  fresh? : Bool = true,
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
  {
    writer,
    entries,
    ids,
    rand,
    lane,
    cwd,
    seq,
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
/// Append entries, flushing lazily like pi's `_persist`: until the buffer holds
/// an assistant message nothing reaches the writer —— 配合惰性打开的 writer,
/// 文件也不会被创建。第一轮没跑完的会话因此不会在磁盘上留下痕迹。
/// 首次 flush 写出 header + 全部缓冲条目,之后的条目随即追加。
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
    if self.flushed {
      self.writer.write(entry_mutation_json(entry, self.lane).stringify())
      self.writer.write("\n")
    } else if self.has_assistant() {
      let header : Json = {
        "kind": "header",
        "version": 4,
        "id": make_id(self.rand, self.ids),
        "createdAt": Json::number((self.now)().to_double()),
        "cwd": self.cwd,
      }
      self.writer.write(header.stringify())
      self.writer.write("\n")
      // 只写本次新增的;构造时传入的条目已经在盘上了。
      for i in self.start_index..<self.entries.length() {
        self.writer.write(
          entry_mutation_json(self.entries[i], self.lane).stringify(),
        )
        self.writer.write("\n")
      }
      // 在批次内也要立刻置位,否则同一批的下一条会再 flush 一次。
      self.flushed = true
    }
  }
  stored
}

///|
/// 本次新增的条目里是否已经有 assistant 消息(pi 用它决定何时创建文件)。
/// 只在未 flush 时调用,那时新条目最多几条用户消息,扫描成本可忽略。
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
pub fn fetch_entries(
  path : String,
) -> Array[@agent_session.SessionEntry] raise Failure {
  let content = read_text_file(path) catch {
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
