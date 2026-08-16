///|
async test "JsonlSessionJournal writes a session header line" {
  let temp_dir = @fs.tmpdir(prefix="pim-jsonl-session-journal-test-")
  let path = "\{temp_dir}/journal.jsonl"
  let journal = @coding_agent.JsonlSessionJournal::new(path~)
  journal.close()
  let content = @fs.read_file(path).text()
  let lines = content.split("\n").to_array().filter(fn(line) {
    line.length() > 0
  })
  inspect(lines.length(), content="1")
  let header = @json.parse(lines[0])
  guard header is Json::Object(fields) else { fail("header should be object") }
  guard fields.get("type") is Some(Json::String("session")) else {
    fail("header type should be session")
  }
  guard fields.get("version") is Some(Json::Number(1, ..)) else {
    fail("header version should be 1")
  }
  guard fields.get("id") is Some(Json::String(_)) else { fail("header id should be string") }
  guard fields.get("cwd") is Some(Json::String(_)) else { fail("header cwd should be string") }
  @fs.remove(path)
  @fs.rmdir(temp_dir)
}

///|
async test "JsonlSessionJournal round-trips model change entries" {
  let temp_dir = @fs.tmpdir(prefix="pim-jsonl-session-journal-test-")
  let path = "\{temp_dir}/journal.jsonl"
  let journal = @coding_agent.JsonlSessionJournal::new(path~)
  let entry : @agent_session.SessionEntry = {
    id: journal.generate_id(),
    timestamp: 42,
    content: @agent_session.SessionEntryContent::ModelChanage(
      provider="deepseek",
      model_id="deepseek-v4-flash",
    ),
  }
  journal.persist([entry])
  journal.close()
  let entries = journal.fetch_entries()
  inspect(entries.length(), content="1")
  guard entries[0].content is ModelChanage(provider="deepseek", model_id="deepseek-v4-flash") else {
    fail("expected model change entry")
  }
  @fs.remove(path)
  @fs.rmdir(temp_dir)
}

///|
async test "JsonlSessionJournal round-trips user message entries" {
  let temp_dir = @fs.tmpdir(prefix="pim-jsonl-session-journal-test-")
  let path = "\{temp_dir}/journal.jsonl"
  let journal = @coding_agent.JsonlSessionJournal::new(path~)
  let user_message : @agent_loop.AgentMessage = @agent_loop.AgentMessage::User(
    [@agent_loop.InputMessageContent::Text("hello")],
  )
  let entry : @agent_session.SessionEntry = {
    id: journal.generate_id(),
    timestamp: 42,
    content: @agent_session.SessionEntryContent::Message(user_message),
  }
  journal.persist([entry])
  journal.close()
  let entries = journal.fetch_entries()
  inspect(entries.length(), content="1")
  guard entries[0].content is Message(@agent_loop.AgentMessage::User(contents)) else {
    fail("expected user message entry")
  }
  inspect(contents.length(), content="1")
  guard contents[0] is @agent_loop.InputMessageContent::Text("hello") else {
    fail("expected text content")
  }
  @fs.remove(path)
  @fs.rmdir(temp_dir)
}

///|
async test "JsonlSessionJournal becomes no-op after close" {
  let temp_dir = @fs.tmpdir(prefix="pim-jsonl-session-journal-test-")
  let path = "\{temp_dir}/journal.jsonl"
  let journal = @coding_agent.JsonlSessionJournal::new(path~)
  journal.close()
  // After close the file should only contain the header.
  let before = @fs.read_file(path).text()
  journal.close()
  let after = @fs.read_file(path).text()
  inspect(after, content=before)
  @fs.remove(path)
  @fs.rmdir(temp_dir)
}
