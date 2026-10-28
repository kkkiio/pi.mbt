///|
struct DiscoveryLLM {
  seen : Array[Array[String]]
  responses : Array[@agent_loop.AssistantMessage]
}

///|
impl @agent_loop.LLM for DiscoveryLLM with fn generate(self, ctx, sink~, abort~) {
  ignore(abort)
  let index = self.seen.length()
  self.seen.push(ctx.tools.to_owned().map(t => t.name))
  let message = self.responses[index]
  sink(@agent_loop.Start(partial=message))
  message
}

///|
fn search_message(query : String) -> @agent_loop.AssistantMessage {
  @faux.faux_message(
    [@faux.faux_tool_call("tool_search", { "query": query, "limit": 1 })],
    stop_reason=@agent_loop.ToolUse,
  )
}

///|
async test "tool_search declares and executes a match on the next model request" {
  let registry = @tools.ToolRegistry()
  registry.register_tool(
    fake_tool("mcp__github__read_issue"),
    exposure=@tools.Deferred,
  )
  registry.register_tool(fake_tool("unrelated"))
  let llm = DiscoveryLLM::{
    seen: [],
    responses: [
      search_message("read_issue"),
      @faux.faux_message(
        [@faux.faux_tool_call("mcp__github__read_issue", {}, id="read")],
        stop_reason=@agent_loop.ToolUse,
      ),
      ok_message(),
    ],
  }
  let journal = @agent_session.InMemorySessionJournal()
  let session = @agent_session.AgentSession(
    llm,
    tool_registry=registry,
    journal~,
    active_tools=["tool_search"],
  )
  session.prompt([user_message("read the issue")])
  assert_eq(llm.seen, [
    ["tool_search"],
    ["tool_search", "mcp__github__read_issue"],
    ["tool_search", "mcp__github__read_issue"],
  ])
  assert_eq(session.active_tool_names(), [
    "tool_search", "mcp__github__read_issue",
  ])
  let results = session
    .messages()
    .filter_map(m => {
      match m {
        ToolResult(r) => Some(r)
        _ => None
      }
    })
  assert_eq(results.length(), 2)
  assert_false(results[0].is_error)
  assert_false(results[1].is_error)
  json_inspect(results[0].details.unwrap(), content={
    "loaded": ["mcp__github__read_issue"],
  })
  let entries = journal.get_entries()
  assert_true(entries[3].content is Custom(custom_type="pi.tools", ..))
  assert_true(entries[4].content is Message(ToolResult(_)))
  let resumed = @agent_session.AgentSession(
    StubLLM::{ },
    tool_registry=registry,
    journal~,
    active_tools=[],
  )
  assert_eq(resumed.active_tool_names(), session.active_tool_names())
}

///|
async test "search does not reload active or model-only tools and sees late registrations" {
  let registry = @tools.ToolRegistry()
  registry.register_tool(fake_tool("issue_active"))
  registry.register_tool(
    fake_tool("issue_model_only"),
    exposure=@tools.ModelOnly,
  )
  let journal = @agent_session.InMemorySessionJournal()
  let session = @agent_session.AgentSession(
    StubLLM::{ },
    tool_registry=registry,
    journal~,
    active_tools=["issue_active", "tool_search"],
  )
  let search = @agent_session.new_tool_search_tool_definition(session)
  let none = (search.execute)("s1", { "query": "issue" }, (_, _) => ())
  assert_true(none.content is [@agent_loop.Text("No matching tools found.")])
  json_inspect(none.details, content={ "loaded": [] })
  assert_true(journal.get_entries().is_empty())
  registry.register_tool(fake_tool("issue_late"), exposure=@tools.Codemode)
  let loaded = (search.execute)("s2", { "query": "issue" }, (_, _) => ())
  json_inspect(loaded.details, content={ "loaded": ["issue_late"] })
  assert_eq(session.active_tool_names(), [
    "issue_active", "tool_search", "issue_late",
  ])
  ignore((search.execute)("s3", { "query": "issue" }, (_, _) => ()))
  assert_eq(journal.get_entries().length(), 1)
}

///|
async test "invalid search arguments never change tools or journal" {
  let registry = @tools.ToolRegistry()
  registry.register_tool(fake_tool("issue"))
  let journal = @agent_session.InMemorySessionJournal()
  let session = @agent_session.AgentSession(
    StubLLM::{ },
    tool_registry=registry,
    journal~,
    active_tools=["tool_search"],
  )
  let search = @agent_session.new_tool_search_tool_definition(session)
  let invalid : Array[Json] = [
    {},
    { "query": "  " },
    { "query": 1 },
    { "query": "issue", "limit": 0 },
    { "query": "issue", "limit": -1 },
    { "query": "issue", "limit": 1.5 },
    { "query": "issue", "limit": "2" },
    { "query": "issue", "limit": null },
    { "query": "issue", "limit": 2147483648 },
  ]
  for arguments in invalid {
    let rejected = try {
      ignore((search.execute)("s", arguments, (_, _) => ()))
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
  assert_eq(session.active_tool_names(), ["tool_search"])
  assert_true(journal.get_entries().is_empty())
}

///|
async test "shared registries keep each session's discovery state independent" {
  let registry = @tools.ToolRegistry()
  registry.register_tool(fake_tool("issue"))
  let first = @agent_session.AgentSession(
    StubLLM::{ },
    tool_registry=registry,
    active_tools=["tool_search"],
  )
  let second = @agent_session.AgentSession(
    StubLLM::{ },
    tool_registry=registry,
    active_tools=["tool_search"],
  )
  ignore(
    (@agent_session.new_tool_search_tool_definition(first).execute)(
      "s",
      { "query": "issue" },
      (_, _) => (),
    ),
  )
  assert_eq(first.active_tool_names(), ["tool_search", "issue"])
  assert_eq(second.active_tool_names(), ["tool_search"])
}

///|
async test "tool replacements are journaled, deduplicated, validated and restored including empty" {
  let registry = @tools.ToolRegistry()
  registry.register_tool(fake_tool("read"))
  let journal = @agent_session.InMemorySessionJournal()
  let session = @agent_session.AgentSession(
    StubLLM::{ },
    tool_registry=registry,
    journal~,
    active_tools=["tool_search"],
  )
  session.set_active_tools(["read", "read"])
  session.set_active_tools(["read"])
  assert_eq(journal.get_entries().length(), 1)
  assert_eq(session.active_tool_names(), ["read"])
  let rejected = try {
    session.set_active_tools(["read", "missing"])
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  assert_eq(journal.get_entries().length(), 1)
  assert_eq(session.active_tool_names(), ["read"])
  session.set_active_tools([])
  assert_eq(journal.get_entries().length(), 2)
  let resumed = @agent_session.AgentSession(
    StubLLM::{ },
    tool_registry=registry,
    journal~,
    active_tools=["read"],
  )
  assert_true(resumed.active_tool_names().is_empty())
  assert_true(resumed.messages().is_empty())
}

///|
struct RejectingToolJournal {}

///|
impl @agent_session.SessionJournal for RejectingToolJournal with fn generate_id(
  _,
) {
  "change"
}

///|
impl @agent_session.SessionJournal for RejectingToolJournal with fn get_entries(
  _,
) {
  []
}

///|
impl @agent_session.SessionJournal for RejectingToolJournal with fn append(_, _) {
  fail("journal unavailable")
}

///|
async test "failed tool-change persistence leaves the active set unchanged" {
  let registry = @tools.ToolRegistry()
  registry.register_tool(fake_tool("read"))
  let session = @agent_session.AgentSession(
    StubLLM::{ },
    tool_registry=registry,
    journal=RejectingToolJournal::{ },
    active_tools=["tool_search"],
  )
  let rejected = try {
    session.set_active_tools(["read"])
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  assert_eq(session.active_tool_names(), ["tool_search"])
}

///|
async test "tool state predating compaction survives hydration" {
  let registry = @tools.ToolRegistry()
  registry.register_tool(fake_tool("read"))
  let journal = @agent_session.InMemorySessionJournal()
  ignore(
    journal.append([
      {
        id: "tools",
        content: Custom(
          custom_type="pi.tools",
          data=Some({ "activeTools": ["read"] }),
        ),
      },
      { id: "user", content: Message(User(user_message("kept"))), },
      {
        id: "compact",
        content: Compaction(
          summary="summary",
          first_kept_entry_id="user",
          tokens_before=100,
          details=None,
          usage=None,
        ),
      },
    ]),
  )
  let resumed = @agent_session.AgentSession(
    StubLLM::{ },
    tool_registry=registry,
    journal~,
    active_tools=["tool_search"],
  )
  assert_eq(resumed.active_tool_names(), ["read"])
  assert_eq(resumed.messages().length(), 2)
}

///|
async test "the initial tool set survives hydration without any search or tool changes" {
  let initial_sets : Array[Array[String]] = [[], ["tool_search"]]
  for initial in initial_sets {
    let journal = @agent_session.InMemorySessionJournal()
    let llm = @faux.FauxLLM()
    llm.set_responses([ok_message()])
    let session = @agent_session.AgentSession(
      llm,
      journal~,
      active_tools=initial,
    )
    session.prompt([user_message("hello")])
    let fallback = if initial.is_empty() { ["tool_search"] } else { [] }
    let resumed = @agent_session.AgentSession(
      StubLLM::{ },
      journal~,
      active_tools=fallback,
    )
    assert_eq(resumed.active_tool_names(), initial)
    assert_eq(resumed.messages().length(), 2)
    assert_eq(journal.get_entries().length(), 3)
  }
}
