///|
/// Scripted responses replay in order and drain one per `generate`; text is
/// streamed as `chunk_size` deltas between `TextStart` and `TextEnd`.
async test "faux replays scripted responses in order and streams events" {
  let llm = @faux.FauxLLM::FauxLLM(chunk_size=4)
  llm.set_responses([
    @faux.faux_message([@faux.faux_text("hello world")]),
    @faux.faux_message(
      [@faux.faux_tool_call("bash", { "command": "ls" }, id="call-x")],
      stop_reason=@agent_loop.StopReason::ToolUse,
    ),
  ])
  assert_eq(llm.pending_responses(), 2)
  let events : Array[String] = []
  let first = llm.generate(
    { system_prompt: "", messages: [], tools: [], },
    sink=event => {
      events.push(
        match event {
          Start(..) => "start"
          TextStart(..) => "text_start"
          TextDelta(..) => "text_delta"
          TextEnd(..) => "text_end"
          _ => "other"
        },
      )
    },
    abort=@agent_loop.AbortSignal::never(),
  )
  assert_true(first.stop_reason is @agent_loop.StopReason::Stop)
  // "hello world" (11 chars) split into 4-char chunks → 3 deltas.
  assert_eq(events, [
    "start", "text_start", "text_delta", "text_delta", "text_delta", "text_end",
  ])
  assert_eq(llm.pending_responses(), 1)
  match first.content {
    [@agent_loop.AssistantMessageContent::Text(text, ..)] =>
      assert_eq(text, "hello world")
    _ => fail("expected a single text block")
  }
  let second = llm.generate(
    { system_prompt: "", messages: [], tools: [], },
    sink=fn(_) { () },
    abort=@agent_loop.AbortSignal::never(),
  )
  assert_true(second.stop_reason is @agent_loop.StopReason::ToolUse)
  assert_eq(llm.pending_responses(), 0)
}

///|
/// Exhausting the script is a test bug, not a silent empty turn.
async test "faux fails when the script is exhausted" {
  let llm = @faux.FauxLLM::FauxLLM()
  let error_text = try {
    ignore(
      llm.generate(
        { system_prompt: "", messages: [], tools: [], },
        sink=fn(_) { () },
        abort=@agent_loop.AbortSignal::never(),
      ),
    )
    fail("expected generate to fail on an empty script")
  } catch {
    err => err.to_string()
  }
  assert_true(error_text.contains("no scripted response"))
}

///|
/// An abort that lands mid-stream returns the partial as an `Aborted` message
/// instead of unwinding (the contract the agent loop relies on).
async test "faux returns the partial and Aborted when the signal fires mid-stream" {
  let llm = @faux.FauxLLM::FauxLLM(chunk_size=4)
  llm.set_responses([@faux.faux_message([@faux.faux_text("hello world")])])
  let controller = @agent_loop.AbortController::new()
  let emits = Ref(0)
  let message = llm.generate(
    { system_prompt: "", messages: [], tools: [], },
    sink=fn(_) {
      emits.val += 1
      // Abort right after the first text delta (emit 3: start, text_start,
      // text_delta).
      if emits.val == 3 {
        controller.abort()
      }
    },
    abort=controller.signal(),
  )
  assert_true(message.stop_reason is @agent_loop.StopReason::Aborted)
  assert_eq(message.error_message, Some("Interrupted"))
  match message.content {
    [@agent_loop.AssistantMessageContent::Text(text, ..)] => {
      assert_true(text.length() > 0)
      assert_true(text.length() < 11)
      assert_true("hello world".has_prefix(text))
    }
    _ => fail("expected a partial text block")
  }
}
