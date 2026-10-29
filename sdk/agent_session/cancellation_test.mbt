///|
async test "startup cancellation preserves ownership until the accepted prompt settles" {
  let llm = @faux.FauxLLM()
  llm.set_responses([ok_message()])
  let journal = @agent_session.InMemorySessionJournal()
  let session = @agent_session.AgentSession(llm, journal~)
  let mut rejected = false
  @async.with_task_group() <| group => {
    group.spawn_bg(() => session.prompt([user_message("accepted")]))
    group.spawn_bg(() => {
      session.abort()
      session.abort()
      rejected = try {
        session.prompt([user_message("overlapping")])
        false
      } catch {
        err => err.to_string().contains("already processing")
      }
    })
  }
  assert_true(rejected)
  assert_eq(llm.pending_responses(), 1)
  guard journal.get_entries().last()
    is Some({ content: Message(Assistant(message)), .. }) else {
    fail("missing cancellation result")
  }
  assert_true(message.stop_reason is Aborted)
  session.abort()
  session.prompt([user_message("next")])
  assert_eq(llm.pending_responses(), 0)
}

///|
async test "cancellation at lifecycle boundaries attempts each terminal event once" {
  for
    phase in [
      "agent_start", "turn_start", "user_start", "user_end", "assistant_start", "update",
      "assistant_end", "tool_start", "tool_end", "turn_end", "agent_end",
    ] {
    let llm = @faux.FauxLLM(chunk_size=2)
    llm.set_responses([
      @faux.faux_message(
        [
          @faux.faux_text("partial answer"),
          @faux.faux_tool_call("probe", {}, id="probe-1"),
        ],
        stop_reason=ToolUse,
      ),
      ok_message(),
    ])
    let journal = @agent_session.InMemorySessionJournal()
    let executions : Array[String] = []
    let session = @agent_session.AgentSession(
      llm,
      journal~,
      tool_registry=probe_tools(executions),
      active_tools=["probe"],
    )
    let seen : Array[String] = []
    let mut cancelled = false
    session.subscribe(event => {
      let name = match event {
        Loop(AgentStart) => "agent_start"
        Loop(TurnStart) => "turn_start"
        Loop(MessageStart(User(_))) => "user_start"
        Loop(MessageEnd(User(_))) => "user_end"
        Loop(MessageStart(Assistant(_))) => "assistant_start"
        Loop(MessageUpdate(TextDelta(..))) => "update"
        Loop(MessageEnd(Assistant(_))) => "assistant_end"
        Loop(ToolExecutionStart(_)) => "tool_start"
        Loop(ToolExecutionEnd(_)) => "tool_end"
        Loop(TurnEnd(_, _)) => "turn_end"
        Loop(AgentEnd(_)) => "agent_end"
        _ => "other"
      }
      seen.push(name)
      if name == phase && !cancelled {
        cancelled = true
        session.abort()
      }
    })
    session.prompt([user_message("run")])
    assert_true(cancelled)
    assert_eq(seen.filter(name => name == "agent_end").length(), 1)
    assert_eq(seen.filter(name => name == "user_start").length(), 1)
    assert_eq(seen.filter(name => name == "user_end").length(), 1)
    assert_eq(
      seen.filter(name => name == "tool_start").length(),
      seen.filter(name => name == "tool_end").length(),
    )
    for entry in journal.get_entries() {
      if entry.content is Message(Assistant(message)) {
        assert_false(message.stop_reason is Pending)
      }
    }
    if phase == "tool_start" {
      assert_true(executions.is_empty())
    }
    if phase == "tool_end" {
      assert_eq(executions.length(), 1)
      guard journal.get_entries().last()
        is Some({ content: Message(ToolResult(result)), .. }) else {
        fail("missing completed result")
      }
      assert_false(result.is_error)
    }
  }
}

///|
async test "a tool result survives cancellation while its last update is being delivered" {
  let registry = @tools.ToolRegistry()
  registry.register_tool({
    name: "probe",
    label: "probe",
    description: "returns a result and a progress update",
    prompt_guidelines: [],
    parameters: { "type": "object", "properties": {} },
    constrained_sampling: @agent_loop.JsonSchema(strict=true),
    execute: (_, _, update) => {
      update([Text("progress")], {})
      {
        content: [Text("completed")],
        details: {},
        is_error: false,
        usage: None,
      }
    },
  })
  let llm = @faux.FauxLLM()
  llm.set_responses([
    @faux.faux_message(
      [@faux.faux_tool_call("probe", {}, id="probe-1")],
      stop_reason=ToolUse,
    ),
  ])
  let journal = @agent_session.InMemorySessionJournal()
  let session = @agent_session.AgentSession(
    llm,
    journal~,
    tool_registry=registry,
    active_tools=["probe"],
  )
  let mut updating = false
  let mut update_closed = false
  let mut result_count = 0
  session.subscribe(event => {
    match event {
      Loop(ToolExecutionUpdate(_, _, _)) => {
        updating = true
        defer {
          update_closed = true
        }
        @async.sleep(1000)
      }
      Loop(ToolExecutionEnd(result)) => {
        assert_true(update_closed)
        assert_false(result.is_error)
        result_count += 1
      }
      _ => ()
    }
  })
  @async.with_timeout(1000, () => {
    @async.with_task_group(group => {
      group.spawn_bg(() => session.prompt([user_message("run")]))
      while !updating {
        @async.pause()
      }
      session.abort()
    })
  })
  assert_eq(result_count, 1)
  guard journal.get_entries().last()
    is Some({ content: Message(ToolResult(result)), .. }) else {
    fail("missing tool result")
  }
  guard result.content is [Text(text)] else { fail("missing tool output") }
  assert_eq(text, "completed")
}

///|
async test "cancelling a result listener preserves one journal entry and can skip later listeners" {
  let llm = @faux.FauxLLM()
  llm.set_responses([
    @faux.faux_message(
      [@faux.faux_tool_call("probe", {}, id="probe-1")],
      stop_reason=ToolUse,
    ),
  ])
  let journal = @agent_session.InMemorySessionJournal()
  let session = @agent_session.AgentSession(
    llm,
    journal~,
    tool_registry=probe_tools([]),
    active_tools=["probe"],
  )
  let mut listening = false
  let mut later_results = 0
  let mut ended = false
  session.subscribe(event => {
    if event is Loop(ToolExecutionEnd(_)) {
      listening = true
      @async.sleep(1000)
    }
  })
  session.subscribe(event => {
    match event {
      Loop(ToolExecutionEnd(_)) => later_results += 1
      Loop(AgentEnd(_)) => ended = true
      _ => ()
    }
  })
  @async.with_timeout(1000, () => {
    @async.with_task_group(group => {
      group.spawn_bg(() => session.prompt([user_message("run")]))
      while !listening {
        @async.pause()
      }
      session.abort()
    })
  })
  assert_true(ended)
  assert_eq(later_results, 0)
  let results = journal
    .get_entries()
    .filter_map(entry => {
      match entry.content {
        Message(ToolResult(result)) => Some(result)
        _ => None
      }
    })
  assert_eq(results.length(), 1)
  assert_false(results[0].is_error)
}

///|
struct PausingJournal {
  inner : @agent_session.InMemorySessionJournal
  mut appending : Bool
  mut appended : Bool
  reject : Bool
}

///|
impl @agent_session.SessionJournal for PausingJournal with fn generate_id(self) {
  self.inner.generate_id()
}

///|
impl @agent_session.SessionJournal for PausingJournal with fn get_entries(self) {
  self.inner.get_entries()
}

///|
impl @agent_session.SessionJournal for PausingJournal with fn append(
  self,
  entries,
) {
  let terminal = entries.any(entry => entry.content is Message(Assistant(_)))
  if terminal {
    self.appending = true
    @async.sleep(20)
    if self.reject {
      raise SessionExtensionFailure
    }
  }
  let stored = self.inner.append(entries)
  if terminal {
    self.appended = true
  }
  stored
}

///|
async test "cancelling during a journal append waits for its commit" {
  let journal = PausingJournal::{
    inner: @agent_session.InMemorySessionJournal(),
    appending: false,
    appended: false,
    reject: false,
  }
  let llm = @faux.FauxLLM()
  llm.set_responses([ok_message()])
  let session = @agent_session.AgentSession(llm, journal~)
  @async.with_timeout(1000, () => {
    @async.with_task_group(group => {
      group.spawn_bg(() => session.prompt([user_message("run")]))
      while !journal.appending {
        @async.pause()
      }
      session.abort()
      assert_false(journal.appended)
    })
  })
  assert_true(journal.appended)
  assert_eq(journal.inner.get_entries().length(), 2)
  guard journal.inner.get_entries()[1].content is Message(Assistant(message)) else {
    fail("missing committed assistant")
  }
  assert_true(message.stop_reason is Stop)
}

///|
async test "cancellation cleanup waits for async listeners and ignores repeated abort requests" {
  let llm = @faux.FauxLLM(chunk_size=2)
  llm.set_responses([@faux.faux_message([@faux.faux_text("partial answer")])])
  let session = @agent_session.AgentSession(llm)
  let mut delivered = false
  let mut ended = false
  session.subscribe(event => {
    match event {
      Loop(MessageUpdate(TextDelta(..))) => session.abort()
      Loop(MessageEnd(Assistant(message))) if message.stop_reason is Aborted => {
        assert_true(@async.is_being_cancelled())
        @async.protect_from_cancel(() => {
          @async.sleep(5)
          session.abort()
          @async.sleep(5)
          delivered = true
        })
      }
      Loop(AgentEnd(_)) => {
        assert_true(delivered)
        ended = true
      }
      _ => ()
    }
  })
  session.prompt([user_message("run")])
  assert_true(ended)
}

///|
async test "errors raised during cancellation cleanup propagate and stop dispatch" {
  let llm = @faux.FauxLLM(chunk_size=2)
  llm.set_responses([@faux.faux_message([@faux.faux_text("partial answer")])])
  let session = @agent_session.AgentSession(llm)
  let mut ended = false
  session.subscribe(event => {
    match event {
      Loop(MessageUpdate(TextDelta(..))) => session.abort()
      Loop(MessageEnd(Assistant(message))) if message.stop_reason is Aborted =>
        @async.protect_from_cancel(() => {
          @async.sleep(0)
          raise SessionExtensionFailure
        })
      Loop(AgentEnd(_)) => ended = true
      _ => ()
    }
  })
  let caught = try {
    session.prompt([user_message("run")])
    false
  } catch {
    SessionExtensionFailure => true
    err => raise err
  }
  assert_true(caught)
  assert_false(ended)
}

///|
async test "an extension error wins over its synchronous abort request" {
  let llm = @faux.FauxLLM()
  llm.set_responses([ok_message()])
  let journal = @agent_session.InMemorySessionJournal()
  let session = @agent_session.AgentSession(llm, journal~)
  session.subscribe(event => {
    if event is Loop(MessageStart(Assistant(_))) {
      session.abort()
      raise SessionExtensionFailure
    }
  })
  let caught = try {
    session.prompt([user_message("run")])
    false
  } catch {
    SessionExtensionFailure => true
    err => raise err
  }
  assert_true(caught)
  assert_eq(journal.get_entries().length(), 1)
}

///|
async test "cancelling an executing finish hook preserves the completed assistant" {
  let llm = @faux.FauxLLM()
  llm.set_responses([ok_message()])
  let journal = @agent_session.InMemorySessionJournal()
  let mut entered = false
  let mut cleaned = false
  let session = @agent_session.AgentSession(llm, journal~, finish_turn_hook=(
    _,
    _,
  ) => {
    entered = true
    defer {
      cleaned = true
    }
    @async.sleep(1000)
    None
  })
  @async.with_timeout(1000, () => {
    @async.with_task_group(group => {
      group.spawn_bg(() => session.prompt([user_message("run")]))
      while !entered {
        @async.pause()
      }
      session.abort()
    })
  })
  assert_true(cleaned)
  guard journal.get_entries().last()
    is Some({ content: Message(Assistant(message)), .. }) else {
    fail("missing assistant")
  }
  assert_true(message.stop_reason is Stop)
}

///|
async test "external cancellation of prompt propagates after releasing session ownership" {
  let llm = @faux.FauxLLM(chunk_size=2)
  llm.set_responses([
    @faux.faux_message([@faux.faux_text("partial answer")]),
    ok_message(),
  ])
  let session = @agent_session.AgentSession(llm)
  let mut entered = false
  let mut block = true
  session.subscribe(event => {
    if block && event is Loop(MessageUpdate(TextDelta(..))) {
      entered = true
      @async.sleep(1000)
    }
  })
  @async.with_timeout(1000, () => {
    @async.with_task_group(group => {
      let task = group.spawn(() => {
        @async.handle_cancellation(() => session.prompt([user_message("run")]))
      })
      while !entered {
        @async.pause()
      }
      task.cancel()
      assert_true(task.wait() is None)
    })
  })
  block = false
  session.prompt([user_message("next")])
}

///|
async test "a retry end waiting behind a cancelled listener is delivered once" {
  let llm = @faux.FauxLLM()
  llm.set_responses([error_message("429 rate limit"), ok_message()])
  let session = @agent_session.AgentSession(
    llm,
    retry_settings=fast_retry_settings(),
  )
  let retry_ends : Array[Bool] = []
  session.subscribe(event => {
    match event {
      Loop(MessageEnd(Assistant(message))) if message.stop_reason is Stop => {
        session.abort()
        @async.sleep(0)
      }
      AutoRetryEnd(success~, ..) => {
        assert_true(@async.is_being_cancelled())
        retry_ends.push(success)
      }
      _ => ()
    }
  })
  session.prompt([user_message("run")])
  json_inspect(retry_ends, content=[true])
}

///|
async test "cancelling while accepting multiple prompts retains every accepted input" {
  let llm = @faux.FauxLLM()
  llm.set_responses([ok_message()])
  let journal = @agent_session.InMemorySessionJournal()
  let session = @agent_session.AgentSession(llm, journal~)
  let mut cancelled = false
  session.subscribe(event => {
    if !cancelled && event is Loop(MessageStart(User(_))) {
      cancelled = true
      session.abort()
    }
  })
  session.prompt([user_message("first"), user_message("second")])
  let messages = journal
    .get_entries()
    .filter_map(entry => {
      match entry.content {
        Message(message) => Some(message)
        _ => None
      }
    })
  inspect(
    context_lines(messages),
    content=(
      #|user: first
      #|user: second
      #|assistant: 
    ),
  )
  assert_eq(llm.pending_responses(), 1)
  guard messages.last() is Some(Assistant(message)) else {
    fail("missing assistant")
  }
  assert_true(message.stop_reason is Aborted)
}

///|
async test "finish hook errors propagate with the already committed assistant" {
  let llm = @faux.FauxLLM()
  llm.set_responses([ok_message(), ok_message()])
  let journal = @agent_session.InMemorySessionJournal()
  let session = @agent_session.AgentSession(
    llm,
    journal~,
    retry_settings=fast_retry_settings(),
    finish_turn_hook=(_, _) => raise SessionExtensionFailure,
  )
  let caught = try {
    session.prompt([user_message("run")])
    false
  } catch {
    SessionExtensionFailure => true
    err => raise err
  }
  assert_true(caught)
  assert_eq(journal.get_entries().length(), 2)
  assert_eq(llm.pending_responses(), 1)
  session.set_finish_turn_hook((_, _) => None)
  session.prompt([user_message("next")])
}

///|
async test "a tool update listener error cancels and cleans the running tool" {
  let mut cleaned = false
  let registry = @tools.ToolRegistry()
  registry.register_tool({
    name: "probe",
    label: "probe",
    description: "streams until cancelled",
    prompt_guidelines: [],
    parameters: { "type": "object", "properties": {} },
    constrained_sampling: @agent_loop.JsonSchema(strict=true),
    execute: (_, _, update) => {
      defer {
        cleaned = true
      }
      update([Text("progress")], {})
      @async.sleep(1000)
      { content: [], details: {}, is_error: false, usage: None, }
    },
  })
  let llm = @faux.FauxLLM()
  llm.set_responses([
    @faux.faux_message(
      [@faux.faux_tool_call("probe", {}, id="probe-1")],
      stop_reason=ToolUse,
    ),
  ])
  let session = @agent_session.AgentSession(llm, tool_registry=registry, active_tools=[
    "probe",
  ])
  session.subscribe(event => {
    if event is Loop(ToolExecutionUpdate(_, _, _)) {
      raise SessionExtensionFailure
    }
  })
  let caught = try {
    session.prompt([user_message("run")])
    false
  } catch {
    SessionExtensionFailure => true
    err => raise err
  }
  assert_true(caught)
  assert_true(cleaned)
}

///|
struct BeforeStartLLM {
  entered : Ref[Bool]
}

///|
impl @agent_loop.LLM for BeforeStartLLM with fn generate(self, _context, sink~) {
  ignore(sink)
  self.entered.val = true
  @async.sleep(1000)
  ok_message()
}

///|
async test "cancelling a provider before its first event creates an empty aborted assistant" {
  let entered = Ref(false)
  let llm = BeforeStartLLM::{ entered, }
  let journal = @agent_session.InMemorySessionJournal()
  let session = @agent_session.AgentSession(llm, journal~)
  @async.with_timeout(1000, () => {
    @async.with_task_group(group => {
      group.spawn_bg(() => session.prompt([user_message("run")]))
      while !entered.val {
        @async.pause()
      }
      session.abort()
    })
  })
  assert_eq(journal.get_entries().length(), 2)
  guard journal.get_entries()[1].content is Message(Assistant(message)) else {
    fail("missing assistant")
  }
  assert_true(message.stop_reason is Aborted)
  assert_true(message.content.is_empty())
}

///|
async test "journal errors escape without retrying the provider" {
  let journal = PausingJournal::{
    inner: @agent_session.InMemorySessionJournal(),
    appending: false,
    appended: false,
    reject: true,
  }
  let llm = @faux.FauxLLM()
  llm.set_responses([ok_message(), ok_message()])
  let session = @agent_session.AgentSession(
    llm,
    journal~,
    retry_settings=fast_retry_settings(),
  )
  let caught = try {
    session.prompt([user_message("run")])
    false
  } catch {
    SessionExtensionFailure => true
    err => raise err
  }
  assert_true(caught)
  assert_eq(llm.pending_responses(), 1)
  assert_eq(journal.inner.get_entries().length(), 1)
}
