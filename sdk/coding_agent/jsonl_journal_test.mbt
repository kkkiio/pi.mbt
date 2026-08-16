///|
/// A test-only `@io.Writer` that accumulates bytes in a `@buffer.Buffer`.
/// Used instead of a real file so tests can snapshot the written JSONL.
struct BufferWriter {
  buf : @buffer.Buffer
}

///|
pub fn BufferWriter::BufferWriter() -> BufferWriter {
  { buf: @buffer.Buffer::Buffer() }
}

///|
pub impl @io.Writer for BufferWriter with fn write_once(
  self : BufferWriter,
  bytes : Bytes,
  offset~ : Int,
  len~ : Int,
) -> Int {
  self.buf.write_bytes(bytes[offset:offset + len])
  len
}

///|
fn writer_text(writer : BufferWriter) -> String {
  @utf8.decode_lossy(writer.buf.to_bytes())
}

///|
async test "persists various entries in memory and as JSONL" {
  let writer = BufferWriter::BufferWriter()
  let preloaded : @agent_session.SessionEntry = {
    id: "e0",
    timestamp: 0,
    content: @agent_session.SessionEntryContent::Compaction,
  }
  let journal = @coding_agent.JsonlSessionJournal::JsonlSessionJournal(
    writer,
    entries=[preloaded],
    rand=@random.Rand::chacha8(),
    cwd="/workspaces/pi.mbt",
    now=1786903823973,
  )

  let user_message : @agent_loop.AgentMessage = @agent_loop.AgentMessage::User([
    @agent_loop.InputMessageContent::Text("hello"),
  ])
  journal.persist([
    {
      id: "e1",
      timestamp: 1,
      content: @agent_session.SessionEntryContent::ModelChanage(
        provider="deepseek",
        model_id="v4",
      ),
    },
    {
      id: "e2",
      timestamp: 2,
      content: @agent_session.SessionEntryContent::Message(user_message),
    },
  ])

  // In-memory entries include the preloaded one plus the two persisted ones.
  json_inspect(journal.get_entries(), content=[
    { "id": "e0", "timestamp": "0", "content": { "type": "compaction" } },
    {
      "id": "e1",
      "timestamp": "1",
      "content": {
        "type": "model_change",
        "provider": "deepseek",
        "model_id": "v4",
      },
    },
    {
      "id": "e2",
      "timestamp": "2",
      "content": {
        "type": "message",
        "message": {
          "role": "user",
          "content": [{ "type": "text", "text": "hello" }],
        },
      },
    },
  ])

  // The writer received the header plus one line per entry.
  inspect(
    writer_text(writer),
    content=(
      #|{"type":"session","version":1,"id":"13219109","createdAt":"1786903823973","cwd":"/workspaces/pi.mbt"}
      #|{"id":"e1","timestamp":"1","content":{"type":"model_change","provider":"deepseek","model_id":"v4"}}
      #|{"id":"e2","timestamp":"2","content":{"type":"message","message":{"role":"user","content":[{"type":"text","text":"hello"}]}}}
      #|
    ),
  )
}

///|
async test "fetch_entries reads persisted entries from disk" {
  let temp_dir = @fs.tmpdir(prefix="pim-jsonl-session-journal-test-")
  let path = "\{temp_dir}/journal.jsonl"
  let file = @fs.create(path, allow_existing=true)
  let journal = @coding_agent.JsonlSessionJournal::JsonlSessionJournal(file)
  let entry : @agent_session.SessionEntry = {
    id: "disk1",
    timestamp: 7,
    content: @agent_session.SessionEntryContent::Compaction,
  }
  journal.persist([entry])
  file.close()

  let entries = @coding_agent.fetch_entries(path)
  inspect(entries.length(), content="1")
  inspect(entries[0].id, content="disk1")
  @fs.remove(path)
  @fs.rmdir(temp_dir)
}
