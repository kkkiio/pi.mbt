///|
/// Loop-level ports of pi's `finishTurn` `{ action: "end" }` cases
/// (`packages/agent/test/agent-loop.test.ts` and `packages/agent/test/agent.test.ts`).

///|
/// A scripted stand-in for a provider: each `generate` call replays the next
/// queued terminal message, advancing the cursor. Only `Start` is emitted.
struct EndHookLLM {
  responses : Array[@agent_loop.AssistantMessage]
  mut cursor : Int32
}

///|
fn EndHookLLM::new(
  responses : Array[@agent_loop.AssistantMessage],
) -> EndHookLLM {
  { responses, cursor: 0, }
}

///|
impl @agent_loop.LLM for EndHookLLM with fn generate(
  self : EndHookLLM,
  _ctx : @agent_loop.Context,
  sink~ : async (@agent_loop.GenerationEvent) -> Unit,
) -> @agent_loop.AssistantMessage {
  let message = self.responses[self.cursor]
  self.cursor += 1
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
    ToolExecutionUpdate(_, _, _) => "tool_execution_update"
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
  let steer_polls : Array[Int32] = []
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
    finish_turn_hook=(_, tool_results) => {
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
    finish_turn_hook=(transcript, tool_results) => {
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

///|
async test "finish turn hook receives completed tool results" {
  let llm = EndHookLLM::new([
    end_hook_assistant(
      [end_hook_tool_call("noop", {}, id="tool-1")],
      stop_reason=ToolUse,
    ),
  ])
  let observed : Array[Int32] = []
  @agent_loop.run_agent_loop(
    llm,
    "",
    [],
    end_hook_no_tools(),
    [end_hook_user("run")],
    tool_executor=(_, _) => end_hook_tool_result(),
    finish_turn_hook=(_, results) => {
      observed.push(results.length())
      Some(End)
    },
  )
  json_inspect(observed, content=[1])
}

///|

///|
async test "cancelling generation seals the partial and skips the finish hook" {
  let llm = EndHookLLM::new([
    end_hook_assistant([end_hook_text("cut short")], stop_reason=Pending),
  ])
  let messages : Array[@agent_loop.AgentMessage] = []
  let events : Array[@agent_loop.AgentEvent] = []
  let mut hooked = false
  @async.with_task_group() <| group => {
    let active : Ref[@async.Task[Unit?]?] = Ref(None)
    let task = group.spawn(() => {
      @async.handle_cancellation(() => {
        @agent_loop.run_agent_loop(
          llm,
          "",
          messages,
          [],
          [end_hook_user("run")],
          tool_executor=(_, _) => end_hook_tool_result(),
          finish_turn_hook=(_, _) => {
            hooked = true
            Some(End)
          },
          event_sink=event => {
            events.push(event)
            if event is MessageStart(Assistant(_)) {
              active.val.unwrap().cancel()
            }
          },
        )
      })
    })
    active.val = Some(task)
    assert_true(task.wait() is None)
  }
  assert_false(hooked)
  assert_eq(llm.cursor, 1)
  json_inspect(events.map(end_hook_event_name), content=[
    "agent_start", "turn_start", "message_start", "message_end", "message_start",
    "message_end", "turn_end", "agent_end",
  ])
  guard messages.last() is Some(Assistant(message)) else {
    fail("missing assistant")
  }
  assert_true(message.stop_reason is Aborted)
  guard message.content is [Text(text, ..)] else { fail("missing text") }
  assert_eq(text, "cut short")
}

///|
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
  let steer_calls : Array[Int32] = []
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
    finish_turn_hook=(_, _) => Some(@agent_loop.AgentTurnDecision::End),
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

///|
async test "cancelling before startup journals the accepted input and an aborted turn" {
  let llm = EndHookLLM::new([])
  let messages : Array[@agent_loop.AgentMessage] = []
  let events : Array[@agent_loop.AgentEvent] = []
  @async.with_task_group() <| group => {
    let task = group.spawn(() => {
      @async.handle_cancellation(() => {
        @agent_loop.run_agent_loop(
          llm,
          "",
          messages,
          [],
          [end_hook_user("hi")],
          tool_executor=(_, _) => end_hook_tool_result(),
          event_sink=event => events.push(event),
        )
      })
    })
    task.cancel()
    assert_true(task.wait() is None)
  }
  assert_eq(llm.cursor, 0)
  json_inspect(messages.map(end_hook_message_role), content=[
    "user", "assistant",
  ])
  json_inspect(events.map(end_hook_event_name), content=[
    "agent_start", "turn_start", "message_start", "message_end", "message_start",
    "message_end", "turn_end", "agent_end",
  ])
  guard messages.last() is Some(Assistant(message)) else {
    fail("missing assistant")
  }
  assert_true(message.stop_reason is Aborted)
}

///|
fn end_hook_user_message(text : String) -> @agent_loop.AgentMessage {
  @agent_loop.AgentMessage::User(end_hook_user(text))
}

///|
fn end_hook_assistant_message(
  content : Array[@agent_loop.AssistantMessageContent],
  stop_reason~ : @agent_loop.StopReason,
) -> @agent_loop.AgentMessage {
  @agent_loop.AgentMessage::Assistant(end_hook_assistant(content, stop_reason~))
}

///|
fn end_hook_tool_result_message(
  tool_call_id : String,
  tool_name : String,
) -> @agent_loop.AgentMessage {
  @agent_loop.AgentMessage::ToolResult({
    tool_call_id,
    tool_name,
    content: [@agent_loop.InputMessageContent::Text("done")],
    details: None,
    usage: None,
    is_error: false,
    timestamp: 1786903823973,
  })
}

///|
async test "continue runs a turn from a tool result tail" {
  let llm = EndHookLLM::new([
    end_hook_assistant(
      [end_hook_text("done")],
      stop_reason=@agent_loop.StopReason::Stop,
    ),
  ])
  let messages : Array[@agent_loop.AgentMessage] = [
    end_hook_user_message("run"),
    end_hook_assistant_message(
      [end_hook_tool_call("noop", {}, id="tool-1")],
      stop_reason=@agent_loop.StopReason::ToolUse,
    ),
    end_hook_tool_result_message("tool-1", "noop"),
  ]
  let events : Array[@agent_loop.AgentEvent] = []
  @agent_loop.run_agent_loop_continue(
    llm,
    "",
    messages,
    end_hook_no_tools(),
    tool_executor=(_, _) => end_hook_tool_result(),
    event_sink=event => events.push(event),
  )
  json_inspect(messages.map(end_hook_message_role), content=[
    "user", "assistant", "toolResult", "assistant",
  ])
  json_inspect(events.map(end_hook_event_name), content=[
    "agent_start", "turn_start", "message_start", "message_end", "turn_end", "agent_end",
  ])
}

///|
async fn end_hook_continue_error(
  messages : Array[@agent_loop.AgentMessage],
) -> String {
  let llm = EndHookLLM::new([])
  try {
    @agent_loop.run_agent_loop_continue(
      llm,
      "",
      messages,
      end_hook_no_tools(),
      tool_executor=(_, _) => end_hook_tool_result(),
    )
    ""
  } catch {
    err => err.to_string()
  }
}

///|
async test "continue rejects an empty transcript" {
  let error = end_hook_continue_error([])
  assert_true(error.contains("no messages in context"))
}

///|
async test "continue rejects an assistant tail" {
  let messages : Array[@agent_loop.AgentMessage] = [
    end_hook_user_message("hi"),
    end_hook_assistant_message(
      [end_hook_text("done")],
      stop_reason=@agent_loop.StopReason::Stop,
    ),
  ]
  let error = end_hook_continue_error(messages)
  assert_true(error.contains("Cannot continue from message role: assistant"))
}

///|
/// pi `emitToolExecutionUpdate`:执行中的 partial result 以
/// `tool_execution_update` 透出,排在 start 之后、end 之前;callback 在
/// settle 之后被忽略(pi #5573,迟到的回调不得发出 stale 事件)。
async test "tool execution updates stream between start and end" {
  let llm = EndHookLLM::new([
    end_hook_assistant(
      [end_hook_tool_call("probe", { "k": "v" }, id="tool-1")],
      stop_reason=@agent_loop.StopReason::ToolUse,
    ),
    end_hook_assistant(
      [end_hook_text("final")],
      stop_reason=@agent_loop.StopReason::Stop,
    ),
  ])
  let messages : Array[@agent_loop.AgentMessage] = []
  let events : Array[@agent_loop.AgentEvent] = []
  let mut settled_sink : @agent_loop.ToolExecUpdateCallback? = None
  let _ = @agent_loop.run_agent_loop(
    llm,
    "",
    messages,
    end_hook_no_tools(),
    [end_hook_user("run")],
    tool_executor=(_, update) => {
      settled_sink = Some(update)
      update([@agent_loop.InputMessageContent::Text("half")], {
        "pct": Json::number(50),
      })
      update([@agent_loop.InputMessageContent::Text("full")], {
        "pct": Json::number(100),
      })
      end_hook_tool_result()
    },
    event_sink=event => events.push(event),
  )
  guard settled_sink is Some(update) else { fail("executor saw no sink") }
  update([@agent_loop.InputMessageContent::Text("stale")], {})
  json_inspect(events.map(end_hook_event_name), content=[
    "agent_start", "turn_start", "message_start", "message_end", "message_start",
    "message_end", "tool_execution_start", "tool_execution_update", "tool_execution_update",
    "tool_execution_end", "turn_end", "turn_start", "message_start", "message_end",
    "turn_end", "agent_end",
  ])
  let updates : Array[Json] = []
  for event in events {
    match event {
      @agent_loop.AgentEvent::ToolExecutionUpdate(call, content, details) =>
        updates.push({
          "toolCallId": Json(call.id),
          "toolName": Json(call.name),
          "args": call.arguments,
          "partialResult": {
            "content": [
              for c in content => c.to_json()
            ],
            "details": details,
          },
        })
      _ => ()
    }
  }
  json_inspect(updates, content=[
    {
      "toolCallId": "tool-1",
      "toolName": "probe",
      "args": { "k": "v" },
      "partialResult": {
        "content": [{ "type": "text", "text": "half" }],
        "details": { "pct": 50 },
      },
    },
    {
      "toolCallId": "tool-1",
      "toolName": "probe",
      "args": { "k": "v" },
      "partialResult": {
        "content": [{ "type": "text", "text": "full" }],
        "details": { "pct": 100 },
      },
    },
  ])
}
