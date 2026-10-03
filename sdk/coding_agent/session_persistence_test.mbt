///|
/// A user message with the timestamp these tests pin.
fn user_message(text : String) -> @agent_loop.UserMessage {
  {
    content: [@agent_loop.InputMessageContent::Text(text)],
    timestamp: 1786903823973,
  }
}

///|
/// Records the messages each generation call sees, so a test can assert what a
/// resumed session hydrated into the prompt. (`FauxLLM` ignores the context.)
struct ContextCapturingLLM {
  seen : Array[@agent_loop.AgentMessage]
}

///|
impl @agent_loop.LLM for ContextCapturingLLM with fn generate(
  self : ContextCapturingLLM,
  ctx : @agent_loop.Context,
  sink~ : async (@agent_loop.GenerationEvent) -> Unit,
  abort~ : @agent_loop.AbortSignal,
) -> @agent_loop.AssistantMessage {
  ignore(abort)
  self.seen.clear()
  for message in ctx.messages {
    self.seen.push(message)
  }
  let message = @faux.faux_message([@faux.faux_text("resumed reply")])
  sink(@agent_loop.GenerationEvent::Start(partial=message))
  message
}

///|
/// A real turn — driven by the scripted `faux` provider, so no network call and
/// no credentials — writes exactly one session file, and that file only appears
/// once the turn has produced an assistant message. This is the contract behind
/// "sessions persist by default, but a turn that never completed leaves nothing
/// behind".
async test "a session turn persists exactly one journal file" {
  let dir = @coding_agent.create_temp_dir("pim-session-persist-")
  let path = "\{dir}/s1.jsonl"
  let llm = @faux.FauxLLM::FauxLLM()
  llm.set_responses([@faux.faux_message([@faux.faux_text("hi")])])
  let file = @coding_agent.open_lazy_file(path)
  let journal = @coding_agent.JsonlSessionJournal::JsonlSessionJournal(file)
    as &@agent_session.SessionJournal
  let session = @coding_agent.new_coding_session(llm, cwd=dir, journal~)
  // Nothing has been said yet: the file must not exist.
  assert_false(@coding_agent.path_exists(path))
  session.prompt([user_message("hello")])
  file.close()
  assert_true(@coding_agent.path_exists(path))
  assert_eq(@coding_agent.list_sessions(dir), ["s1"])
  let roles = @coding_agent.fetch_entries(path).map(entry => {
    match entry.content {
      Message(User(_)) => "user"
      Message(Assistant(_)) => "assistant"
      _ => "other"
    }
  })
  assert_eq(roles, ["user", "assistant"])
  @coding_agent.remove_file(path)
  @coding_agent.remove_dir(dir)
}

///|
/// Resuming an existing journal hydrates its messages into the next prompt and
/// keeps a single header — the contract `-c` / `/resume` rely on.
async test "a resumed session hydrates its journal into the next prompt" {
  let dir = @coding_agent.create_temp_dir("pim-session-resume-")
  let path = "\{dir}/s1.jsonl"
  let first = @faux.FauxLLM::FauxLLM()
  first.set_responses([@faux.faux_message([@faux.faux_text("first reply")])])
  let file = @coding_agent.open_lazy_file(path)
  let journal = @coding_agent.JsonlSessionJournal::JsonlSessionJournal(file)
    as &@agent_session.SessionJournal
  let session = @coding_agent.new_coding_session(first, cwd=dir, journal~)
  session.prompt([user_message("hello")])
  file.close()

  // 续写:同一个文件,追加打开、`fresh=false`(不重写 header)。
  let entries = @coding_agent.fetch_entries(path)
  let second = ContextCapturingLLM::{ seen: [], }
  let resumed_file = @coding_agent.open_lazy_file(path, append=true)
  let resumed_journal = @coding_agent.JsonlSessionJournal::JsonlSessionJournal(
      resumed_file,
      entries~,
      fresh=false,
    )
    as &@agent_session.SessionJournal
  let resumed = @coding_agent.new_coding_session(
    second,
    cwd=dir,
    journal=resumed_journal,
  )
  resumed.prompt([user_message("and now?")])
  resumed_file.close()

  // 上一轮的两条消息已经在水合后的上下文里,新提问追加在后面。
  let roles = second.seen.map(message => {
    match message {
      User(_) => "user"
      Assistant(_) => "assistant"
      ToolResult(_) => "tool"
    }
  })
  assert_eq(roles, ["user", "assistant", "user"])
  let headers = @coding_agent.read_text_file(path)
    .split("\n")
    .to_array()
    .filter(line => {
      let json = Some(@json.parse(line.to_owned())) catch { _ => None }
      json is Some({ "type": "session", .. })
    })
    .length()
  assert_eq(headers, 1)
  @coding_agent.remove_file(path)
  @coding_agent.remove_dir(dir)
}

///|
/// Independently authored pi v3 entries exercise string user content,
/// metadata in the parent chain, compaction, and append after a branch.
async test "resuming a pi v3 journal reconstructs compacted branch context" {
  let dir = @coding_agent.create_temp_dir("pim-pi-v3-resume-")
  let path = "\{dir}/s1.jsonl"
  let fixture =
    #|{"type":"session","version":3,"id":"pi-session","timestamp":"2024-02-29T23:59:59.999Z","cwd":"/tmp"}
    #|{"type":"message","id":"root","parentId":null,"timestamp":"2024-02-29T23:59:59.999Z","message":{"role":"user","content":"summarized","timestamp":1}}
    #|{"type":"thinking_level_change","id":"level","parentId":"root","timestamp":"2024-03-01T00:00:00.000Z","thinkingLevel":"high"}
    #|{"type":"message","id":"kept","parentId":"level","timestamp":"2024-03-01T00:00:00.001Z","message":{"role":"user","content":[{"type":"text","text":"kept turn"}],"timestamp":2}}
    #|{"type":"compaction","id":"compact","parentId":"kept","timestamp":"2024-03-01T00:00:00.002Z","summary":"earlier greeting","firstKeptEntryId":"kept","tokensBefore":4096,"details":{"readFiles":["a.mbt"]}}
    #|{"type":"message","id":"abandoned","parentId":"compact","timestamp":"2024-03-01T00:00:00.003Z","message":{"role":"user","content":"abandoned branch","timestamp":3}}
    #|{"type":"message","id":"active","parentId":"compact","timestamp":"2024-03-01T00:00:00.004Z","message":{"role":"user","content":"active branch","timestamp":4}}
    #|
  @coding_agent.write_bytes_file(path, @utf8.encode(fixture))
  let entries = @coding_agent.fetch_active_entries(path)
  assert_eq(entries[0].timestamp, 1709251199999)
  assert_eq(entries[1].timestamp, 1709251200000)
  json_inspect(entries, content=[
    {
      "id": "root",
      "parentId": null,
      "timestamp": "2024-02-29T23:59:59.999Z",
      "type": "message",
      "message": {
        "role": "user",
        "content": [{ "type": "text", "text": "summarized" }],
        "timestamp": 1,
      },
    },
    {
      "id": "level",
      "parentId": "root",
      "timestamp": "2024-03-01T00:00:00.000Z",
      "type": "thinking_level_change",
      "thinkingLevel": "high",
    },
    {
      "id": "kept",
      "parentId": "level",
      "timestamp": "2024-03-01T00:00:00.001Z",
      "type": "message",
      "message": {
        "role": "user",
        "content": [{ "type": "text", "text": "kept turn" }],
        "timestamp": 2,
      },
    },
    {
      "id": "compact",
      "parentId": "kept",
      "timestamp": "2024-03-01T00:00:00.002Z",
      "type": "compaction",
      "summary": "earlier greeting",
      "firstKeptEntryId": "kept",
      "tokensBefore": 4096,
      "details": { "readFiles": ["a.mbt"] },
    },
    {
      "id": "active",
      "parentId": "compact",
      "timestamp": "2024-03-01T00:00:00.004Z",
      "type": "message",
      "message": {
        "role": "user",
        "content": [{ "type": "text", "text": "active branch" }],
        "timestamp": 4,
      },
    },
  ])
  let llm = ContextCapturingLLM::{ seen: [], }
  let file = @coding_agent.open_append_file(path)
  let journal = @coding_agent.JsonlSessionJournal::JsonlSessionJournal(
    file,
    entries~,
    fresh=false,
    now=() => 1709251200005,
  )
  let session = @coding_agent.new_coding_session(llm, cwd=dir, journal~)
  session.prompt([user_message("next turn")])
  file.close()
  let texts = llm.seen.map(message => {
    match message {
      User(user) =>
        user.content
        .map(content => {
          match content {
            Text(text) => text
            _ => "<non-text>"
          }
        })
        .join("")
      _ => "<non-user>"
    }
  })
  json_inspect(texts, content=[
    "The conversation history before this point was compacted into the following summary:\n\n<summary>\nearlier greeting\n</summary>",
    "kept turn", "active branch", "next turn",
  ])
  let all = @coding_agent.fetch_entries(path)
  assert_eq(all.length(), 8)
  assert_eq(all[6].parent_id, Some("active"))
  assert_eq(all[7].parent_id, Some(all[6].id))
  @coding_agent.remove_file(path)
  @coding_agent.remove_dir(dir)
}

///|
/// Tool metadata must survive execution, JSONL serialization, decoding, and
/// hydration into the next generation call.
async test "tool details and usage survive journal resume" {
  let dir = @coding_agent.create_temp_dir("pim-tool-journal-")
  let path = "\{dir}/s1.jsonl"
  let usage : @agent_loop.Usage = {
    input: 11,
    output: 7,
    cache_read: 3,
    cache_write: 2,
    cache_write_1h: Some(1),
    reasoning: Some(0),
    total_tokens: 23,
    cost: { input: 0, output: 0, cache_read: 0, cache_write: 0, total: 0, },
  }
  let details : Json = { "files": ["a.mbt"], "truncated": false }
  let registry = @tools.ToolRegistry()
  registry.register_tool({
    name: "probe",
    label: "probe",
    prompt_guidelines: [],
    callable_definition: Some({
      description: "metadata probe",
      parameters: {},
      constrained_sampling: @agent_loop.ConstrainedSampling::JsonSchema(
        strict=true,
      ),
      execute: (_, _, _) => {
        content: [Text("tool output")],
        details,
        usage: Some(usage),
        is_error: false,
        terminate: true,
      },
    }),
  })
  let llm = @faux.FauxLLM::FauxLLM()
  llm.set_responses([
    @faux.faux_message(
      [@faux.faux_tool_call("probe", {}, id="call-metadata")],
      stop_reason=@agent_loop.StopReason::ToolUse,
    ),
  ])
  let file = @coding_agent.open_lazy_file(path)
  let journal = @coding_agent.JsonlSessionJournal::JsonlSessionJournal(
    file,
    now=() => 1709251200000,
    cwd="/tmp",
  )
  let session = @agent_session.AgentSession(
    llm,
    system_prompt="",
    journal~,
    tool_registry=registry,
    active_tools=["probe"],
  )
  session.prompt([user_message("run probe")])
  file.close()
  let entries = @coding_agent.fetch_active_entries(path)
  let result = match entries[2].content {
    Message(ToolResult(result)) => result
    _ => fail("expected tool result in journal")
  }
  assert_eq(result.details, Some(details))
  assert_eq(result.usage.map(usage => usage.to_json()), Some(usage.to_json()))
  // Tool timestamps are runtime-assigned; snapshot all other message fields.
  json_inspect(
    @agent_loop.AgentMessage::ToolResult({ ..result, timestamp: 9, }),
    content={
      "role": "toolResult",
      "toolCallId": "call-metadata",
      "toolName": "probe",
      "content": [{ "type": "text", "text": "tool output" }],
      "isError": false,
      "timestamp": 9,
      "details": { "files": ["a.mbt"], "truncated": false },
      "usage": {
        "input": 11,
        "output": 7,
        "cacheRead": 3,
        "cacheWrite": 2,
        "totalTokens": 23,
        "cost": {
          "input": 0,
          "output": 0,
          "cacheRead": 0,
          "cacheWrite": 0,
          "total": 0,
        },
        "cacheWrite1h": 1,
        "reasoning": 0,
      },
    },
  )
  let second = ContextCapturingLLM::{ seen: [], }
  let resumed_file = @coding_agent.open_append_file(path)
  let resumed_journal = @coding_agent.JsonlSessionJournal::JsonlSessionJournal(
    resumed_file,
    entries~,
    fresh=false,
  )
  let resumed = @coding_agent.new_coding_session(
    second,
    cwd=dir,
    journal=resumed_journal,
  )
  resumed.prompt([user_message("continue")])
  resumed_file.close()
  guard second.seen[2] is ToolResult(restored) else {
    fail("expected hydrated tool result")
  }
  assert_eq(restored.details, Some(details))
  assert_eq(restored.usage.map(usage => usage.to_json()), Some(usage.to_json()))
  @coding_agent.remove_file(path)
  @coding_agent.remove_dir(dir)
}
