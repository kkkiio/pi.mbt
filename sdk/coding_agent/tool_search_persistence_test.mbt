///|
async test "loaded tools survive an on-disk resume and a copied branch journal" {
  let dir = @coding_agent.create_temp_dir("pim-tool-search-")
  let path = "\{dir}/original.jsonl"
  let fork_path = "\{dir}/fork.jsonl"
  defer @coding_agent.remove_dir(dir)
  defer (if @coding_agent.path_exists(path) { @coding_agent.remove_file(path) })
  defer (if @coding_agent.path_exists(fork_path) {
    @coding_agent.remove_file(fork_path)
  })
  let llm = @faux.FauxLLM()
  llm.set_responses([
    @faux.faux_message(
      [@faux.faux_tool_call("tool_search", { "query": "bash" })],
      stop_reason=@agent_loop.ToolUse,
    ),
    @faux.faux_message([@faux.faux_text("ready")]),
  ])
  let file = @coding_agent.open_lazy_file(path)
  let journal = @coding_agent.JsonlSessionJournal(file)
  let session = @coding_agent.new_coding_session(llm, cwd=dir, journal~, active_tools=[
    "tool_search",
  ])
  session.prompt([user_message("find bash")])
  file.close()
  assert_eq(session.active_tool_names(), ["tool_search", "bash"])
  let entries = @coding_agent.fetch_active_entries(path)
  let changes = entries.filter(e => {
    e.content is Custom(custom_type="pi.tools", ..)
  })
  assert_eq(changes.length(), 2)
  @coding_agent.write_bytes_file(fork_path, @coding_agent.read_bytes_file(path))
  let resumed_file = @coding_agent.open_lazy_file(path, append=true)
  let resumed_journal = @coding_agent.JsonlSessionJournal(
    resumed_file,
    entries=entries.copy(),
    fresh=false,
  )
  let resumed = @coding_agent.new_coding_session(
    llm,
    cwd=dir,
    journal=resumed_journal,
  )
  assert_eq(resumed.active_tool_names(), ["tool_search", "bash"])
  resumed.set_active_tools([])
  resumed_file.close()
  let empty_file = @coding_agent.open_lazy_file(path, append=true)
  let empty_journal = @coding_agent.JsonlSessionJournal(
    empty_file,
    entries=@coding_agent.fetch_active_entries(path),
    fresh=false,
  )
  assert_true(
    @coding_agent.new_coding_session(llm, cwd=dir, journal=empty_journal)
    .active_tool_names()
    .is_empty(),
  )
  empty_file.close()
  // A fork made before the later deactivation keeps the tools loaded there.
  let fork_file = @coding_agent.open_lazy_file(fork_path, append=true)
  let fork_journal = @coding_agent.JsonlSessionJournal(
    fork_file,
    entries=entries.copy(),
    fresh=false,
  )
  let fork = @coding_agent.new_coding_session(
    llm,
    cwd=dir,
    journal=fork_journal,
  )
  assert_eq(fork.active_tool_names(), ["tool_search", "bash"])
  llm.set_responses([@faux.faux_message([@faux.faux_text("fork reply")])])
  fork.prompt([user_message("continue")])
  fork_file.close()
  let fork_entries = @coding_agent.fetch_active_entries(fork_path)
  assert_eq(
    fork_entries
    .filter(e => e.content is Custom(custom_type="pi.tools", ..))
    .length(),
    2,
  )
}

///|
async test "abandoned tool changes do not affect a resumed branch" {
  let dir = @coding_agent.create_temp_dir("pim-tool-branch-")
  let path = "\{dir}/journal.jsonl"
  defer @coding_agent.remove_dir(dir)
  defer @coding_agent.remove_file(path)
  let entries : Array[@agent_session.SessionEntry] = [
    {
      id: "root",
      parent_id: None,
      timestamp: 0,
      content: Custom(
        custom_type="pi.tools",
        data=Some({ "activeTools": ["tool_search"] }),
      ),
    },
    {
      id: "abandoned",
      parent_id: Some("root"),
      timestamp: 1,
      content: Custom(
        custom_type="pi.tools",
        data=Some({ "activeTools": ["tool_search", "bash"] }),
      ),
    },
    {
      id: "selected",
      parent_id: Some("root"),
      timestamp: 2,
      content: Custom(custom_type="branch", data=None),
    },
  ]
  let header : Json = {
    "type": "session",
    "version": 3,
    "id": "fork",
    "timestamp": "1970-01-01T00:00:00.000Z",
    "cwd": dir,
  }
  @coding_agent.write_bytes_file(
    path,
    @utf8.encode(
      header.stringify() +
      "\n" +
      entries.map(e => e.to_json().stringify()).join("\n") +
      "\n",
    ),
  )
  let file = @coding_agent.open_lazy_file(path, append=true)
  let journal = @coding_agent.JsonlSessionJournal(
    file,
    entries=@coding_agent.fetch_active_entries(path),
    fresh=false,
  )
  let session = @coding_agent.new_coding_session(
    @faux.FauxLLM(),
    cwd=dir,
    journal~,
  )
  assert_eq(session.active_tool_names(), ["tool_search"])
  file.close()
}
