///|
async test "cancellation gives each listener a native cancellation boundary after journal commit" {
  let llm = @faux.FauxLLM(chunk_size=2)
  llm.set_responses([@faux.faux_message([@faux.faux_text("partial answer")])])
  let journal = @agent_session.InMemorySessionJournal()
  let session = @agent_session.AgentSession(llm, journal~)
  let delivered : Array[String] = []
  session.subscribe(event => {
    match event {
      Loop(MessageUpdate(TextDelta(..))) => session.abort()
      Loop(MessageEnd(Assistant(message))) if message.stop_reason is Aborted => {
        assert_true(@async.is_being_cancelled())
        guard journal.get_entries().last()
          is Some({ content: Message(Assistant(stored)), .. }) else {
          fail("missing committed assistant")
        }
        assert_true(stored.stop_reason is Aborted)
        delivered.push("first entered")
        defer delivered.push("first released")
        @async.sleep(1000)
        delivered.push("first completed")
      }
      _ => ()
    }
  })
  session.subscribe(event => {
    if event is Loop(MessageEnd(Assistant({ stop_reason: Aborted, .. }))) {
      assert_true(@async.is_being_cancelled())
      delivered.push("second entered")
      @async.protect_from_cancel(() => {
        @async.sleep(0)
        delivered.push("second completed")
      })
    }
  })
  session.subscribe(event => {
    match event {
      Loop(MessageEnd(Assistant(message))) if message.stop_reason is Aborted => {
        assert_true(@async.is_being_cancelled())
        delivered.push("third entered")
      }
      Loop(AgentEnd(_)) => {
        assert_true(@async.is_being_cancelled())
        delivered.push("agent ended")
      }
      _ => ()
    }
  })
  @async.with_timeout(1000, () => session.prompt([user_message("run")]))
  json_inspect(delivered, content=[
    "first entered", "first released", "second entered", "second completed", "third entered",
    "agent ended",
  ])
}

///|
async test "normal listeners retain ordered asynchronous delivery" {
  let llm = @faux.FauxLLM()
  llm.set_responses([ok_message()])
  let session = @agent_session.AgentSession(llm)
  let delivered : Array[String] = []
  session.subscribe(event => {
    if event is Loop(MessageEnd(User(_))) {
      assert_false(@async.is_being_cancelled())
      delivered.push("first entered")
      @async.sleep(0)
      delivered.push("first completed")
    }
  })
  session.subscribe(event => {
    if event is Loop(MessageEnd(User(_))) {
      assert_false(@async.is_being_cancelled())
      delivered.push("second entered")
    }
  })
  session.prompt([user_message("run")])
  json_inspect(delivered, content=[
    "first entered", "first completed", "second entered",
  ])
}

///|
async test "tool cancellation reaches listeners even when the assistant completed with tool use" {
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
  let delivered : Array[String] = []
  session.subscribe(event => {
    match event {
      Loop(ToolExecutionStart(_)) => session.abort()
      Loop(ToolExecutionEnd(_)) => {
        assert_true(@async.is_being_cancelled())
        delivered.push("first tool result")
        @async.sleep(1000)
      }
      _ => ()
    }
  })
  session.subscribe(event => {
    match event {
      Loop(ToolExecutionEnd(result)) => {
        assert_true(@async.is_being_cancelled())
        assert_true(result.is_error)
        delivered.push("second tool result")
      }
      Loop(TurnEnd(message, _)) => {
        assert_true(@async.is_being_cancelled())
        assert_true(message.stop_reason is ToolUse)
        delivered.push("turn ended")
      }
      Loop(AgentEnd(_)) => {
        assert_true(@async.is_being_cancelled())
        delivered.push("agent ended")
      }
      _ => ()
    }
  })
  @async.with_timeout(1000, () => session.prompt([user_message("run")]))
  json_inspect(delivered, content=[
    "first tool result", "second tool result", "turn ended", "agent ended",
  ])
}

///|
async test "retry cancellation attempts each listener with native cancellation" {
  let llm = @faux.FauxLLM()
  llm.set_responses([error_message("429 rate limit"), ok_message()])
  let session = @agent_session.AgentSession(
    llm,
    retry_settings=fast_retry_settings(),
  )
  let delivered : Array[String] = []
  session.subscribe(event => {
    match event {
      AutoRetryStart(..) => session.abort()
      AutoRetryEnd(success~, ..) => {
        assert_false(success)
        assert_true(@async.is_being_cancelled())
        delivered.push("first retry end")
        @async.sleep(1000)
      }
      _ => ()
    }
  })
  session.subscribe(event => {
    if event is AutoRetryEnd(success~, ..) {
      assert_false(success)
      assert_true(@async.is_being_cancelled())
      delivered.push("second retry end")
    }
  })
  @async.with_timeout(1000, () => session.prompt([user_message("run")]))
  assert_eq(llm.pending_responses(), 1)
  json_inspect(delivered, content=["first retry end", "second retry end"])
}

///|
async test "an ordinary error from a cancelled listener terminates remaining delivery" {
  let llm = @faux.FauxLLM(chunk_size=2)
  llm.set_responses([@faux.faux_message([@faux.faux_text("partial answer")])])
  let journal = @agent_session.InMemorySessionJournal()
  let session = @agent_session.AgentSession(llm, journal~)
  let mut reached = false
  session.subscribe(event => {
    match event {
      Loop(MessageUpdate(TextDelta(..))) => session.abort()
      Loop(MessageEnd(Assistant(message))) if message.stop_reason is Aborted => {
        assert_true(@async.is_being_cancelled())
        raise SessionExtensionFailure
      }
      _ => ()
    }
  })
  session.subscribe(event => {
    if event is Loop(MessageEnd(Assistant(_))) {
      reached = true
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
  assert_false(reached)
  assert_eq(journal.get_entries().length(), 2)
}
