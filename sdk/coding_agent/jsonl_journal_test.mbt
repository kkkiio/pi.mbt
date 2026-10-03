///|
/// A test-only `@io.Writer` that accumulates bytes in a `@buffer.Buffer`.
/// Used instead of a real file so tests can snapshot the written JSONL.
struct BufferWriter {
  buf : @buffer.Buffer
}

///|
pub fn BufferWriter::BufferWriter() -> BufferWriter {
  { buf: @buffer.Buffer::Buffer(), }
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
/// Appending keeps the preloaded entry and writes one JSONL line per entry;
/// the serialized entries (`json_inspect` below) are the on-disk contract.
async test "persists various entries in memory and as JSONL" {
  let writer = BufferWriter::BufferWriter()
  let preloaded : @agent_session.SessionEntry = {
    id: "e0",
    parent_id: None,
    timestamp: 100,
    content: @agent_session.SessionEntryContent::Compaction(
      summary="earlier context",
      first_kept_entry_id="e0",
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
      details: None,
      usage: None,
      is_error: false,
      timestamp: 1786903823973,
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
      content: @agent_session.SessionEntryContent::Message(user_message),
    },
    {
      id: "e3",
      content: @agent_session.SessionEntryContent::Message(assistant_message),
    },
    {
      id: "e4",
      content: @agent_session.SessionEntryContent::Message(tool_result),
    },
  ])

  // The journal assigns parentId/timestamp at append time.
  json_inspect(stored, content=[
    {
      "id": "e1",
      "parentId": "e0",
      "timestamp": "2026-08-16T18:10:23.973Z",
      "type": "model_change",
      "provider": "deepseek",
      "modelId": "v4",
    },
    {
      "id": "e2",
      "parentId": "e1",
      "timestamp": "2026-08-16T18:10:23.973Z",
      "type": "message",
      "message": {
        "role": "user",
        "content": [{ "type": "text", "text": "hello" }],
        "timestamp": 1786903823973,
      },
    },
    {
      "id": "e3",
      "parentId": "e2",
      "timestamp": "2026-08-16T18:10:23.973Z",
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
        "usage": {
          "input": 0,
          "output": 0,
          "cacheRead": 0,
          "cacheWrite": 0,
          "totalTokens": 0,
          "cost": {
            "input": 0,
            "output": 0,
            "cacheRead": 0,
            "cacheWrite": 0,
            "total": 0,
          },
        },
        "timestamp": 1786903823973,
      },
    },
    {
      "id": "e4",
      "parentId": "e3",
      "timestamp": "2026-08-16T18:10:23.973Z",
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
  let temp_dir = @coding_agent.create_temp_dir("pim-jsonl-roundtrip-")
  let path = "\{temp_dir}/journal.jsonl"
  let file = @coding_agent.create_file(path, allow_existing=true)
  file.write(writer_text(writer))
  file.close()
  let fetched = @coding_agent.fetch_entries(path)
  // Round-trip: entries written to disk parse back into the same values.
  json_inspect(fetched, content=[
    {
      "id": "e1",
      "parentId": "e0",
      "timestamp": "2026-08-16T18:10:23.973Z",
      "type": "model_change",
      "provider": "deepseek",
      "modelId": "v4",
    },
    {
      "id": "e2",
      "parentId": "e1",
      "timestamp": "2026-08-16T18:10:23.973Z",
      "type": "message",
      "message": {
        "role": "user",
        "content": [{ "type": "text", "text": "hello" }],
        "timestamp": 1786903823973,
      },
    },
    {
      "id": "e3",
      "parentId": "e2",
      "timestamp": "2026-08-16T18:10:23.973Z",
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
        "usage": {
          "input": 0,
          "output": 0,
          "cacheRead": 0,
          "cacheWrite": 0,
          "totalTokens": 0,
          "cost": {
            "input": 0,
            "output": 0,
            "cacheRead": 0,
            "cacheWrite": 0,
            "total": 0,
          },
        },
        "timestamp": 1786903823973,
      },
    },
    {
      "id": "e4",
      "parentId": "e3",
      "timestamp": "2026-08-16T18:10:23.973Z",
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

  @coding_agent.remove_file(path)
  @coding_agent.remove_dir(temp_dir)

  // The writer received the pi v3 header plus one line per entry.
  inspect(
    writer_text(writer),
    content=(
      #|{"type":"session","version":3,"id":"13219109","timestamp":"2026-08-16T18:10:23.973Z","cwd":"/workspaces/pi.mbt"}
      #|{"id":"e1","parentId":"e0","timestamp":"2026-08-16T18:10:23.973Z","type":"model_change","provider":"deepseek","modelId":"v4"}
      #|{"id":"e2","parentId":"e1","timestamp":"2026-08-16T18:10:23.973Z","type":"message","message":{"role":"user","content":[{"type":"text","text":"hello"}],"timestamp":1786903823973}}
      #|{"id":"e3","parentId":"e2","timestamp":"2026-08-16T18:10:23.973Z","type":"message","message":{"role":"assistant","content":[{"type":"text","text":"hi","textSignature":"{\"type\":\"message\",\"id\":\"msg_1\"}"}],"api":"openai-responses","provider":"deepseek","model":"deepseek-v4-flash","stopReason":"stop","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"timestamp":1786903823973}}
      #|{"id":"e4","parentId":"e3","timestamp":"2026-08-16T18:10:23.973Z","type":"message","message":{"role":"toolResult","toolCallId":"call_1","toolName":"bash","content":[{"type":"text","text":"ok"}],"isError":false,"timestamp":1786903823973}}
      #|
    ),
  )
}

///|
/// A crash can leave a half-written final line behind. Reading the journal drops
/// that fragment *and* repairs the file, so resuming appends on a fresh line —
/// glued to the fragment every later entry would be unreadable.
async test "resuming over a torn tail repairs the file before appending" {
  let temp_dir = @coding_agent.create_temp_dir("pim-jsonl-torn-tail-")
  let path = "\{temp_dir}/journal.jsonl"
  @coding_agent.write_bytes_file(
    path, b"{\"type\":\"session\",\"version\":3,\"id\":\"hdr\",\"timestamp\":\"1970-01-01T00:00:00.001Z\",\"cwd\":\"/tmp\"}\n{\"id\":\"kept\",\"parentId\":null,\"timestamp\":\"1970-01-01T00:00:00.007Z\",\"type\":\"custom\",\"customType\":\"kept\"}\n{\"id\":\"torn\",\"paren",
  )
  let entries = @coding_agent.fetch_entries(path)
  inspect(entries.length(), content="1")
  inspect(
    @utf8.decode_lossy(@coding_agent.read_bytes_file(path)),
    content=(
      #|{"type":"session","version":3,"id":"hdr","timestamp":"1970-01-01T00:00:00.001Z","cwd":"/tmp"}
      #|{"id":"kept","parentId":null,"timestamp":"1970-01-01T00:00:00.007Z","type":"custom","customType":"kept"}
      #|
    ),
  )
  let file = @coding_agent.open_append_file(path)
  let journal = @coding_agent.JsonlSessionJournal::JsonlSessionJournal(
    file,
    rand=@random.Rand::chacha8(),
    cwd="/tmp",
    now=() => 8,
    fresh=false,
  )
  let _stored = journal.append([
    {
      id: "disk2",
      content: @agent_session.SessionEntryContent::Custom(
        custom_type="appended",
        data=None,
      ),
    },
  ])
  file.close()
  let resumed = @coding_agent.fetch_entries(path)
  inspect(resumed.length(), content="2")
  @coding_agent.remove_file(path)
  @coding_agent.remove_dir(temp_dir)
}

///|
/// A journal can hold an abandoned branch (pi writes one when a session is
/// continued from an older entry). Resuming follows the active `parentId` chain
/// from the last entry, so the abandoned branch neither hydrates the model nor
/// becomes the parent of the next append.
async test "resuming follows the active parentId chain" {
  let temp_dir = @coding_agent.create_temp_dir("pim-jsonl-branch-")
  let path = "\{temp_dir}/journal.jsonl"
  @coding_agent.write_bytes_file(
    path, b"{\"type\":\"session\",\"version\":3,\"id\":\"hdr\",\"timestamp\":\"1970-01-01T00:00:00.000Z\",\"cwd\":\"/tmp\"}\n{\"id\":\"a1\",\"parentId\":null,\"timestamp\":\"1970-01-01T00:00:00.001Z\",\"type\":\"custom\",\"customType\":\"root\"}\n{\"id\":\"b1\",\"parentId\":\"a1\",\"timestamp\":\"1970-01-01T00:00:00.002Z\",\"type\":\"custom\",\"customType\":\"abandoned\"}\n{\"id\":\"c1\",\"parentId\":\"a1\",\"timestamp\":\"1970-01-01T00:00:00.003Z\",\"type\":\"custom\",\"customType\":\"active\"}\n",
  )
  json_inspect(
    @coding_agent.fetch_active_entries(path).map(entry => entry.id),
    content=["a1", "c1"],
  )
  @coding_agent.remove_file(path)
  @coding_agent.remove_dir(temp_dir)
}

///|
/// An unsupported header fails rather than being treated as an empty session.
async test "journal reader rejects a non-pi header without changing it" {
  let dir = @coding_agent.create_temp_dir("pim-journal-header-")
  let path = "\{dir}/journal.jsonl"
  let original = b"{\"kind\":\"header\",\"version\":4,\"id\":\"hdr\",\"createdAt\":1,\"cwd\":\"/tmp\"}\n"
  @coding_agent.write_bytes_file(path, original)
  let failed = try {
    ignore(@coding_agent.fetch_entries(path))
    false
  } catch {
    _ => true
  }
  assert_true(failed)
  assert_eq(@coding_agent.read_bytes_file(path), original)
  @coding_agent.remove_file(path)
  @coding_agent.remove_dir(dir)
}

///|
/// Resuming appends to the file that is already there: the header is not
/// written twice, and `fetch_entries` reads back what the append stored.
async test "appending to an existing journal keeps its header" {
  let temp_dir = @coding_agent.create_temp_dir(
    "pim-jsonl-session-journal-test-",
  )
  let path = "\{temp_dir}/journal.jsonl"
  // 续写已有会话:header 已经在文件里了。
  @coding_agent.write_bytes_file(
    path, b"{\"type\":\"session\",\"version\":3,\"id\":\"hdr\",\"timestamp\":\"1970-01-01T00:00:00.001Z\",\"cwd\":\"/tmp\"}\n",
  )
  let file = @coding_agent.open_append_file(path)
  let journal = @coding_agent.JsonlSessionJournal::JsonlSessionJournal(
    file,
    rand=@random.Rand::chacha8(),
    cwd="/tmp",
    now=() => 7,
    fresh=false,
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
    "parentId": null,
    "timestamp": "1970-01-01T00:00:00.007Z",
    "type": "custom",
    "customType": "note",
  })
  @coding_agent.remove_file(path)
  @coding_agent.remove_dir(temp_dir)
}

///|
/// Until the session has an assistant message nothing reaches the writer, so a
/// first turn that never completed leaves no bytes — and, with a lazily opened
/// file, no file — behind.
async test "a journal stays in memory until the first assistant message" {
  let writer = BufferWriter::BufferWriter()
  let journal = @coding_agent.JsonlSessionJournal::JsonlSessionJournal(
    writer,
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
  ignore(
    journal.append([
      {
        id: "u1",
        content: @agent_session.SessionEntryContent::Message(user_message),
      },
    ]),
  )
  inspect(writer_text(writer), content="")
  ignore(
    journal.append([
      {
        id: "a1",
        content: @agent_session.SessionEntryContent::Message(assistant_message),
      },
    ]),
  )
  // 第一条 assistant 到了:header 与已缓冲的条目一次性写出。
  inspect(
    writer_text(writer),
    content=(
      #|{"type":"session","version":3,"id":"13219109","timestamp":"2026-08-16T18:10:23.973Z","cwd":"/workspaces/pi.mbt"}
      #|{"id":"u1","parentId":null,"timestamp":"2026-08-16T18:10:23.973Z","type":"message","message":{"role":"user","content":[{"type":"text","text":"hello"}],"timestamp":1786903823973}}
      #|{"id":"a1","parentId":"u1","timestamp":"2026-08-16T18:10:23.973Z","type":"message","message":{"role":"assistant","content":[{"type":"text","text":"hi","textSignature":"{\"type\":\"message\",\"id\":\"msg_1\"}"}],"api":"openai-responses","provider":"deepseek","model":"deepseek-v4-flash","stopReason":"stop","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"timestamp":1786903823973}}
      #|
    ),
  )
}

///|
/// Opaque signatures must not acquire quotes or disappear just because their
/// string happens to be valid JSON; absent signatures stay absent.
test "pi signatures and optional message fields round trip" {
  let entry_json : Json = {
    "type": "message",
    "id": "assistant",
    "parentId": null,
    "timestamp": "2024-03-01T00:00:00.000Z",
    "message": {
      "role": "assistant",
      "api": "openai-responses",
      "provider": "deepseek",
      "model": "deepseek-v4-flash",
      "stopReason": "stop",
      "timestamp": 1,
      "content": [
        { "type": "text", "text": "plain" },
        { "type": "text", "text": "legacy", "textSignature": "msg_123" },
        { "type": "thinking", "thinking": "opaque", "thinkingSignature": "123" },
        {
          "type": "thinking",
          "thinking": "empty object",
          "thinkingSignature": "{}",
        },
        {
          "type": "toolCall",
          "id": "call",
          "name": "bash",
          "arguments": {},
          "thoughtSignature": "opaque+/=",
        },
        {
          "type": "text",
          "text": "structured",
          "textSignature": "{\"type\":\"message\",\"id\":\"msg_456\"}",
        },
      ],
      "usage": {
        "input": 4,
        "output": 2,
        "cacheRead": 1,
        "cacheWrite": 0,
        "totalTokens": 7,
        "cost": {
          "input": 0,
          "output": 0,
          "cacheRead": 0,
          "cacheWrite": 0,
          "total": 0,
        },
      },
    },
  }
  let entry : @agent_session.SessionEntry = @json.from_json(entry_json)
  assert_eq(entry.to_json(), entry_json)
}
