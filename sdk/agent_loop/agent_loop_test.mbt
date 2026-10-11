///|
/// Loop-level ports of pi's `finishTurn` `{ action: "end" }` cases
/// (`packages/agent/test/agent-loop.test.ts` and `packages/agent/test/agent.test.ts`).
///
/// pi.mbt has no `Agent` class, so the two Agent-level cases are expressed
/// against `run_agent_loop` directly: the `finish_turn_hook` argument replaces
/// `AgentOptions.finishTurn`, and the steering channel replaces the two queues.
/// pi's follow-up queue has no pi.mbt counterpart yet (see the TODO in
/// `run_agent_loop`), so the follow-up half of "queues stay untouched" is not
/// covered here.

///|
/// A scripted stand-in for a provider: each `generate` call replays the next
/// queued terminal message and advances the cursor. Only `Start` is emitted,
/// because the loop's sink uses it to mark the message as started and these
/// tests do not assert streamed deltas.
struct EndHookLLM {
  responses : Array[@agent_loop.AssistantMessage]
  /// When set, `generate` fires this controller before returning the scripted
  /// message — standing in for a user abort that lands while the provider is
  /// still streaming, which the provider then closes out with an Aborted
  /// message.
  abort_before_return : @agent_loop.AbortController?
  mut cursor : Int
}

///|
fn EndHookLLM::new(
  responses : Array[@agent_loop.AssistantMessage],
  abort_before_return? : @agent_loop.AbortController? = None,
) -> EndHookLLM {
  { responses, abort_before_return, cursor: 0, }
}

///|
impl @agent_loop.LLM for EndHookLLM with fn generate(
  self : EndHookLLM,
  _ctx : @agent_loop.Context,
  sink~ : async (@agent_loop.GenerationEvent) -> Unit,
  abort~ : @agent_loop.AbortSignal,
) -> @agent_loop.AssistantMessage {
  ignore(abort)
  let message = self.responses[self.cursor]
  self.cursor += 1
  match self.abort_before_return {
    Some(controller) => controller.abort()
    None => ()
  }
  sink(@agent_loop.GenerationEvent::Start(partial=message))
  message
}

///|
fn end_hook_no_tools() -> ArrayView[@agent_loop.ToolDefinition] {
  []
}

///|
fn end_hook_no_steering() -> ArrayView[@agent_loop.UserMessage] {
  []
}

///|
fn end_hook_user(text : String) -> @agent_loop.UserMessage {
  {
    content: [@agent_loop.InputMessageContent::Text(text)],
    timestamp: 1786903823973,
  }
}

///|
fn end_hook_assistant(
  content : Array[@agent_loop.AssistantMessageContent],
  stop_reason~ : @agent_loop.StopReason,
) -> @agent_loop.AssistantMessage {
  {
    content,
    api: "faux",
    provider: "faux",
    model: "faux-1",
    stop_reason,
    error_message: None,
    usage: None,
    timestamp: 1786903823973,
  }
}

///|
fn end_hook_text(text : String) -> @agent_loop.AssistantMessageContent {
  @agent_loop.AssistantMessageContent::Text(text, signature={})
}

///|
fn end_hook_tool_call(
  name : String,
  arguments : Json,
  id~ : String,
) -> @agent_loop.AssistantMessageContent {
  @agent_loop.AssistantMessageContent::ToolCall({ id, name, arguments, }, signature={})
}

///|
fn end_hook_tool_result() -> @agent_loop.ToolResult {
  {
    content: [@agent_loop.InputMessageContent::Text("done")],
    details: {},
    is_error: false,
    usage: None,
  }
}

///|
fn end_hook_event_name(event : @agent_loop.AgentEvent) -> String {
  match event {
    AgentStart => "agent_start"
    TurnStart => "turn_start"
    MessageStart(_) => "message_start"
    MessageUpdate(_) => "message_update"
    MessageEnd(_) => "message_end"
    ToolExecutionStart(_) => "tool_execution_start"
    ToolExecutionEnd(_) => "tool_execution_end"
    TurnEnd(_, _) => "turn_end"
    AgentEnd(_) => "agent_end"
  }
}

///|
fn end_hook_message_role(message : @agent_loop.AgentMessage) -> String {
  match message {
    User(_) => "user"
    Assistant(_) => "assistant"
    ToolResult(_) => "toolResult"
  }
}

///|
/// pi `agent-loop.test.ts` "action:end skips queue polling and next-turn
/// preparation": the tool batch would normally drive another provider request,
/// but `end` returns a Stop without polling steering again.
async test "finish turn end: stops the run and skips the next steering poll" {
  let llm = EndHookLLM::new([
    end_hook_assistant(
      [end_hook_tool_call("noop", {}, id="tool-1")],
      stop_reason=@agent_loop.StopReason::ToolUse,
    ),
    end_hook_assistant(
      [end_hook_text("should not run")],
      stop_reason=@agent_loop.StopReason::Stop,
    ),
  ])
  let messages : Array[@agent_loop.AgentMessage] = []
  let ordering : Array[String] = []
  let events : Array[@agent_loop.AgentEvent] = []
  let steer_polls : Array[Int] = []
  let _ = @agent_loop.run_agent_loop(
    llm,
    "",
    messages,
    end_hook_no_tools(),
    [end_hook_user("run")],
    tool_executor=(call, _) => {
      ordering.push("execute:\{call.name}")
      end_hook_tool_result()
    },
    steer_channel=() => {
      steer_polls.push(1)
      end_hook_no_steering()
    },
    finish_turn_hook=(_, tool_results, _) => {
      ordering.push("finish_turn:\{tool_results.length()}")
      Some(@agent_loop.AgentTurnDecision::End)
    },
    event_sink=event => events.push(event),
  )
  // One provider call: `end` cancelled the pending tool follow-up.
  assert_eq(llm.cursor, 1)
  // Steering is polled once before the loop and never again.
  assert_eq(steer_polls.length(), 1)
  json_inspect(ordering, content=["execute:noop", "finish_turn:1"])
  // pi wraps tool results in `message_start`/`message_end`; pi.mbt reports them
  // only through `tool_execution_end`, so the sequence carries one pair less.
  json_inspect(events.map(end_hook_event_name), content=[
    "agent_start", "turn_start", "message_start", "message_end", "message_start",
    "message_end", "tool_execution_start", "tool_execution_end", "turn_end", "agent_end",
  ])
  json_inspect(messages.map(end_hook_message_role), content=[
    "user", "assistant", "toolResult",
  ])
}

///|
/// pi `agent-loop.test.ts` "action:end receives finalized turn context and
/// stops before queue polling": the tool really ran, and the hook observes the
/// transcript with the tool result already appended.
async test "finish turn end: hook sees the transcript with tool results appended" {
  let llm = EndHookLLM::new([
    end_hook_assistant(
      [end_hook_tool_call("echo", { "value": "hello" }, id="tool-1")],
      stop_reason=@agent_loop.StopReason::ToolUse,
    ),
    end_hook_assistant(
      [end_hook_text("should not run")],
      stop_reason=@agent_loop.StopReason::Stop,
    ),
  ])
  let messages : Array[@agent_loop.AgentMessage] = []
  let executed : Array[Json] = []
  let hook_tool_call_ids : Array[String] = []
  let hook_roles : Array[String] = []
  let events : Array[@agent_loop.AgentEvent] = []
  let _ = @agent_loop.run_agent_loop(
    llm,
    "",
    messages,
    end_hook_no_tools(),
    [end_hook_user("echo something")],
    tool_executor=(call, _) => {
      executed.push(call.arguments)
      end_hook_tool_result()
    },
    finish_turn_hook=(transcript, tool_results, _) => {
      for i = 0; i < tool_results.length(); i = i + 1 {
        hook_tool_call_ids.push(tool_results[i].tool_call_id)
      }
      for i = 0; i < transcript.length(); i = i + 1 {
        hook_roles.push(end_hook_message_role(transcript[i]))
      }
      Some(@agent_loop.AgentTurnDecision::End)
    },
    event_sink=event => events.push(event),
  )
  assert_eq(llm.cursor, 1)
  json_inspect(executed, content=[{ "value": "hello" }])
  json_inspect(hook_tool_call_ids, content=["tool-1"])
  // pi's transcript is `["system", "user", "assistant", "toolResult"]`; pi.mbt
  // carries the system prompt out of band, so there is no system message.
  json_inspect(hook_roles, content=["user", "assistant", "toolResult"])
  json_inspect(events.map(end_hook_event_name), content=[
    "agent_start", "turn_start", "message_start", "message_end", "message_start",
    "message_end", "tool_execution_start", "tool_execution_end", "turn_end", "agent_end",
  ])
  json_inspect(messages.map(end_hook_message_role), content=[
    "user", "assistant", "toolResult",
  ])
}

///|
/// A hook that is awaited can be long-running (pi's README forwards the signal
/// into `await shouldStop(turn, signal)`), so it needs to see whether the run is
/// being cancelled. On a normal turn the signal is still live and `end` is a
/// deliberate stop.
async test "finish turn end: hook receives a live signal on a normal turn" {
  let llm = EndHookLLM::new([
    end_hook_assistant(
      [end_hook_tool_call("noop", {}, id="tool-1")],
      stop_reason=@agent_loop.StopReason::ToolUse,
    ),
  ])
  let messages : Array[@agent_loop.AgentMessage] = []
  let controller = @agent_loop.AbortController::new()
  let observed : Array[Bool] = []
  let _ = @agent_loop.run_agent_loop(
    llm,
    "",
    messages,
    end_hook_no_tools(),
    [end_hook_user("run")],
    tool_executor=(_, _) => end_hook_tool_result(),
    steer_channel=end_hook_no_steering,
    abort=controller.signal(),
    finish_turn_hook=(_, _, signal) => {
      observed.push(signal.is_aborted())
      Some(@agent_loop.AgentTurnDecision::End)
    },
  )
  json_inspect(observed, content=[false])
}

///|
/// An abort that lands while the provider is streaming: the hook still runs and
/// observes the aborted signal, but its `end` decision is discarded — aborted
/// responses are hard exits, and `LoopStopReason::Aborted` outranks the hook.
///
/// pi has no case for this: its only signal test is an `instanceof` smoke check.
async test "finish turn end: hook sees an aborted signal, hard exit wins" {
  let controller = @agent_loop.AbortController::new()
  let llm = EndHookLLM::new(
    [
      end_hook_assistant(
        [end_hook_text("cut short")],
        stop_reason=@agent_loop.StopReason::Aborted,
      ),
    ],
    abort_before_return=Some(controller),
  )
  let messages : Array[@agent_loop.AgentMessage] = []
  let observed : Array[Bool] = []
  let events : Array[@agent_loop.AgentEvent] = []
  let _ = @agent_loop.run_agent_loop(
    llm,
    "",
    messages,
    end_hook_no_tools(),
    [end_hook_user("run")],
    tool_executor=(_, _) => end_hook_tool_result(),
    steer_channel=end_hook_no_steering,
    abort=controller.signal(),
    finish_turn_hook=(_, tool_results, signal) => {
      observed.push(signal.is_aborted())
      // An aborted response has no tool results, so the hook cannot act on them.
      observed.push(tool_results.length() > 0)
      Some(@agent_loop.AgentTurnDecision::End)
    },
    event_sink=event => events.push(event),
  )
  json_inspect(observed, content=[true, false])
  assert_eq(llm.cursor, 1)
  json_inspect(events.map(end_hook_event_name), content=[
    "agent_start", "turn_start", "message_start", "message_end", "message_start",
    "message_end", "turn_end", "agent_end",
  ])
  json_inspect(messages.map(end_hook_message_role), content=[
    "user", "assistant",
  ])
}

///|
/// pi `agent.test.ts` "keeps queues when finishTurn ends the run": a steering
/// message queued during the turn stays queued because `end` skips the
/// post-turn poll. The turn itself carries no tool call, matching pi's case.
async test "finish turn end: leaves queued steering unconsumed" {
  let llm = EndHookLLM::new([
    end_hook_assistant(
      [end_hook_text("done")],
      stop_reason=@agent_loop.StopReason::Stop,
    ),
  ])
  let messages : Array[@agent_loop.AgentMessage] = []
  let events : Array[@agent_loop.AgentEvent] = []
  let queued : Array[@agent_loop.UserMessage] = [end_hook_user("steering")]
  let steer_calls : Array[Int] = []
  let _ = @agent_loop.run_agent_loop(
    llm,
    "",
    messages,
    end_hook_no_tools(),
    [end_hook_user("start")],
    tool_executor=(_, _) => end_hook_tool_result(),
    steer_channel=() => {
      steer_calls.push(1)
      if steer_calls.length() == 1 {
        end_hook_no_steering()
      } else {
        queued
      }
    },
    finish_turn_hook=(_, _, _) => Some(@agent_loop.AgentTurnDecision::End),
    event_sink=event => events.push(event),
  )
  // Polled once before the loop; the post-turn poll never happened.
  assert_eq(steer_calls.length(), 1)
  json_inspect(messages.map(end_hook_message_role), content=[
    "user", "assistant",
  ])
  json_inspect(events.map(end_hook_event_name), content=[
    "agent_start", "turn_start", "message_start", "message_end", "message_start",
    "message_end", "turn_end", "agent_end",
  ])
}

///|
/// A cancellation that predates the run is closed out by the provider, not by
/// the loop: `generate` sees the live signal and returns an `Aborted` message
/// without starting a request. The loop therefore never inspects the signal
/// (pi's `runLoop` only threads it through). The turn stays balanced, the
/// prompt is recorded rather than dropped, and the aborted message is part of
/// what the run returns — dropping it is `transform_messages`' job, at request
/// build time.
async test "pre-aborted run completes a balanced turn instead of dropping it" {
  let llm = EndHookLLM::new([
    end_hook_assistant([], stop_reason=@agent_loop.StopReason::Aborted),
  ])
  let messages : Array[@agent_loop.AgentMessage] = []
  let events : Array[@agent_loop.AgentEvent] = []
  let controller = @agent_loop.AbortController::new()
  controller.abort()
  let added = @agent_loop.run_agent_loop(
    llm,
    "",
    messages,
    end_hook_no_tools(),
    [end_hook_user("hi")],
    tool_executor=(_, _) => end_hook_tool_result(),
    steer_channel=end_hook_no_steering,
    abort=controller.signal(),
    event_sink=event => events.push(event),
  )
  json_inspect(messages.map(end_hook_message_role), content=[
    "user", "assistant",
  ])
  json_inspect(added.map(end_hook_message_role), content=["user", "assistant"])
  json_inspect(events.map(end_hook_event_name), content=[
    "agent_start", "turn_start", "message_start", "message_end", "message_start",
    "message_end", "turn_end", "agent_end",
  ])
  match messages.last() {
    Some(Assistant(message)) => assert_true(message.stop_reason is Aborted)
    _ => fail("expected a trailing assistant message")
  }
}
