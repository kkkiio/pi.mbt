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
    seq: 1,
    parent_id: None,
    timestamp: 100,
    content: @agent_session.SessionEntryContent::Compaction(
      summary="earlier context",
      retained_tail=[],
      tokens_before=42,
      details=None,
      usage=None,
    ),
  }
  let journal = @coding_agent.JsonlSessionJournal::JsonlSessionJournal(
    writer,
    entries=[preloaded],
    rand=@random.Rand::chacha8(),
    cwd="/workspaces/pi.mbt",
    now=() => 1786903823973,
  )

  let user_message : @agent_loop.AgentMessage = @agent_loop.AgentMessage::User({
    content: [@agent_loop.InputMessageContent::Text("hello")],
    timestamp: 1786903823973,
  })
  let assistant_message : @agent_loop.AgentMessage = @agent_loop.AgentMessage::Assistant({
      content: [
        @agent_loop.AssistantMessageContent::Text("hi", signature={
          "type": "message",
          "id": "msg_1",
        }),
      ],
      api: "openai-responses",
      provider: "deepseek",
      model: "deepseek-v4-flash",
      stop_reason: @agent_loop.StopReason::Stop,
      error_message: None,
      usage: None,
      timestamp: 1786903823973,
    },
  )
  let tool_result : @agent_loop.AgentMessage = @agent_loop.AgentMessage::ToolResult({
      tool_call_id: "call_1",
      tool_name: "bash",
      content: [@agent_loop.InputMessageContent::Text("ok")],
      is_error: false,
      timestamp: 1786903823973,
      terminate: false,
    },
  )
  let stored = journal.append([
    {
      id: "e1",
      content: @agent_session.SessionEntryContent::ModelChange(
        provider="deepseek",
        model_id="v4",
      ),
    },
    {
      id: "e2",
      content: @agent_session.SessionEntryContent::Message(
        user_message,
        terminate=false,
      ),
    },
    {
      id: "e3",
      content: @agent_session.SessionEntryContent::Message(
        assistant_message,
        terminate=false,
      ),
    },
    {
      id: "e4",
      content: @agent_session.SessionEntryContent::Message(
        tool_result,
        terminate=false,
      ),
    },
  ])

  // The journal assigns seq/parentId/timestamp at append time.
  json_inspect(stored, content=[
    {
      "id": "e1",
      "seq": 2,
      "parentId": "e0",
      "timestamp": 1786903823973,
      "type": "model_change",
      "provider": "deepseek",
      "modelId": "v4",
    },
    {
      "id": "e2",
      "seq": 3,
      "parentId": "e1",
      "timestamp": 1786903823973,
      "type": "message",
      "message": {
        "role": "user",
        "content": [{ "type": "text", "text": "hello" }],
        "timestamp": 1786903823973,
      },
    },
    {
      "id": "e3",
      "seq": 4,
      "parentId": "e2",
      "timestamp": 1786903823973,
      "type": "message",
      "message": {
        "role": "assistant",
        "content": [
          {
            "type": "text",
            "text": "hi",
            "textSignature": "{\"type\":\"message\",\"id\":\"msg_1\"}",
          },
        ],
        "api": "openai-responses",
        "provider": "deepseek",
        "model": "deepseek-v4-flash",
        "stopReason": "stop",
        "errorMessage": null,
        "usage": null,
        "timestamp": 1786903823973,
      },
    },
    {
      "id": "e4",
      "seq": 5,
      "parentId": "e3",
      "timestamp": 1786903823973,
      "type": "message",
      "message": {
        "role": "toolResult",
        "toolCallId": "call_1",
        "toolName": "bash",
        "content": [{ "type": "text", "text": "ok" }],
        "isError": false,
        "timestamp": 1786903823973,
      },
    },
  ])

  // In-memory entries include the preloaded one plus the four appended ones.
  inspect(journal.get_entries().length(), content="5")

  // Round-trip: entries written to disk parse back into the same values.
  let temp_dir = @fs.tmpdir(prefix="pim-jsonl-roundtrip-")
  let path = "\{temp_dir}/journal.jsonl"
  let file = @fs.create(path, allow_existing=true)
  file.write(writer_text(writer))
  file.close()
  let fetched = @coding_agent.fetch_entries(path)
  json_inspect(fetched, content=[
    {
      "id": "e1",
      "seq": 2,
      "parentId": "e0",
      "timestamp": 1786903823973,
      "type": "model_change",
      "provider": "deepseek",
      "modelId": "v4",
    },
    {
      "id": "e2",
      "seq": 3,
      "parentId": "e1",
      "timestamp": 1786903823973,
      "type": "message",
      "message": {
        "role": "user",
        "content": [{ "type": "text", "text": "hello" }],
        "timestamp": 1786903823973,
      },
    },
    {
      "id": "e3",
      "seq": 4,
      "parentId": "e2",
      "timestamp": 1786903823973,
      "type": "message",
      "message": {
        "role": "assistant",
        "content": [
          {
            "type": "text",
            "text": "hi",
            "textSignature": "{\"type\":\"message\",\"id\":\"msg_1\"}",
          },
        ],
        "api": "openai-responses",
        "provider": "deepseek",
        "model": "deepseek-v4-flash",
        "stopReason": "stop",
        "errorMessage": null,
        "usage": null,
        "timestamp": 1786903823973,
      },
    },
    {
      "id": "e4",
      "seq": 5,
      "parentId": "e3",
      "timestamp": 1786903823973,
      "type": "message",
      "message": {
        "role": "toolResult",
        "toolCallId": "call_1",
        "toolName": "bash",
        "content": [{ "type": "text", "text": "ok" }],
        "isError": false,
        "timestamp": 1786903823973,
      },
    },
  ])
  @fs.remove(path)
  @fs.rmdir(temp_dir)

  // The writer received the pi v4 header plus one mutation line per entry.
  inspect(
    writer_text(writer),
    content=(
      #|{"kind":"header","version":4,"id":"13219109","createdAt":1786903823973,"cwd":"/workspaces/pi.mbt"}
      #|{"kind":"entry","lane":"main","id":"e1","seq":2,"parentId":"e0","timestamp":1786903823973,"type":"model_change","provider":"deepseek","modelId":"v4"}
      #|{"kind":"entry","lane":"main","id":"e2","seq":3,"parentId":"e1","timestamp":1786903823973,"type":"message","message":{"role":"user","content":[{"type":"text","text":"hello"}],"timestamp":1786903823973}}
      #|{"kind":"entry","lane":"main","id":"e3","seq":4,"parentId":"e2","timestamp":1786903823973,"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"hi","textSignature":"{\"type\":\"message\",\"id\":\"msg_1\"}"}],"api":"openai-responses","provider":"deepseek","model":"deepseek-v4-flash","stopReason":"stop","errorMessage":null,"usage":null,"timestamp":1786903823973}}
      #|{"kind":"entry","lane":"main","id":"e4","seq":5,"parentId":"e3","timestamp":1786903823973,"type":"message","message":{"role":"toolResult","toolCallId":"call_1","toolName":"bash","content":[{"type":"text","text":"ok"}],"isError":false,"timestamp":1786903823973}}
      #|
    ),
  )
}

///|
async test "fetch_entries reads persisted entries from disk" {
  let temp_dir = @fs.tmpdir(prefix="pim-jsonl-session-journal-test-")
  let path = "\{temp_dir}/journal.jsonl"
  let file = @fs.create(path, allow_existing=true)
  let journal = @coding_agent.JsonlSessionJournal::JsonlSessionJournal(
    file,
    rand=@random.Rand::chacha8(),
    cwd="/tmp",
    now=() => 7,
  )
  let _stored = journal.append([
    {
      id: "disk1",
      content: @agent_session.SessionEntryContent::Custom(
        custom_type="note",
        data=None,
      ),
    },
  ])
  file.close()

  let entries = @coding_agent.fetch_entries(path)
  inspect(entries.length(), content="1")
  json_inspect(entries[0], content={
    "id": "disk1",
    "seq": 1,
    "parentId": null,
    "timestamp": 7,
    "type": "custom",
    "customType": "note",
  })
  @fs.remove(path)
  @fs.rmdir(temp_dir)
}
