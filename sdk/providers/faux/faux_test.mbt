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
  let first = llm.generate({ system_prompt: "", messages: [], tools: [], }, sink=event => {
    events.push(
      match event {
        Start(..) => "start"
        TextStart(..) => "text_start"
        TextDelta(..) => "text_delta"
        TextEnd(..) => "text_end"
        _ => "other"
      },
    )
  })
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
  let second = llm.generate({ system_prompt: "", messages: [], tools: [], }, sink=fn(
    _,
  ) {
    ()
  })
  assert_true(second.stop_reason is @agent_loop.StopReason::ToolUse)
  assert_eq(llm.pending_responses(), 0)
}

///|
/// Exhausting the script is a test bug, not a silent empty turn.
async test "faux fails when the script is exhausted" {
  let llm = @faux.FauxLLM::FauxLLM()
  let error_text = try {
    ignore(
      llm.generate({ system_prompt: "", messages: [], tools: [], }, sink=fn(_) {
        ()
      }),
    )
    fail("expected generate to fail on an empty script")
  } catch {
    err => err.to_string()
  }
  assert_true(error_text.contains("no scripted response"))
}

///|
async test "faux cancellation leaves the latest streamed partial with the caller" {
  let llm = @faux.FauxLLM(chunk_size=4)
  llm.set_responses([@faux.faux_message([@faux.faux_text("hello world")])])
  let partial : Ref[@agent_loop.AssistantMessage?] = Ref(None)
  @async.with_task_group() <| group => {
    let active : Ref[@async.Task[@agent_loop.AssistantMessage?]?] = Ref(None)
    let task = group.spawn(() => {
      @async.handle_cancellation(() => {
        llm.generate({ system_prompt: "", messages: [], tools: [], }, sink=event => {
          if event is TextDelta(partial=message, ..) {
            partial.val = Some(message)
            active.val.unwrap().cancel()
          }
        })
      })
    })
    active.val = Some(task)
    assert_true(task.wait() is None)
  }
  guard partial.val is Some(message) else { fail("missing partial") }
  guard message.content is [Text(text, ..)] else { fail("missing text") }
  assert_eq(text, "hell")
}
