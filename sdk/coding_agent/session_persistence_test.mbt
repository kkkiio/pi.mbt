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
  let roles = @coding_agent
    .fetch_entries(path)
    .map(entry => {
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
  let headers = @coding_agent
    .read_text_file(path)
    .split("\n")
    .to_array()
    .filter(line => line.to_owned().contains("\"kind\":\"header\""))
    .length()
  assert_eq(headers, 1)
  @coding_agent.remove_file(path)
  @coding_agent.remove_dir(dir)
}
