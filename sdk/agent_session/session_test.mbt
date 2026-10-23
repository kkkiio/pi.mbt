///|
/// A stub LLM for hydration tests: never called, but `AgentSession` requires
/// a `&LLM` at construction. Defined here instead of borrowing the real
/// DeepSeek provider, which would drag a native-only dependency into this
/// otherwise target-agnostic package.
struct StubLLM {}

///|
impl @agent_loop.LLM for StubLLM with fn generate(
  self : StubLLM,
  _ctx : @agent_loop.Context,
  sink~ : async (@agent_loop.GenerationEvent) -> Unit,
  abort~ : @agent_loop.AbortSignal,
) -> @agent_loop.AssistantMessage {
  ignore(self)
  ignore(sink)
  ignore(abort)
  fail("StubLLM must not be called in hydration tests")
}

///|
/// A terminal Error `AssistantMessage` for journal hydration tests.
fn error_message(text : String) -> @agent_loop.AssistantMessage {
  {
    content: [],
    api: "openai-responses",
    provider: "deepseek",
    model: "deepseek-v4-flash",
    stop_reason: @agent_loop.StopReason::Error,
    error_message: Some(text),
    usage: None,
    timestamp: 1741290958000,
  }
}

///|
/// A completed `AssistantMessage` for journal hydration tests.
fn ok_message() -> @agent_loop.AssistantMessage {
  {
    content: [
      @agent_loop.AssistantMessageContent::Text("final answer", signature={
        "type": "message",
        "id": "msg-ok",
      }),
    ],
    api: "openai-responses",
    provider: "deepseek",
    model: "deepseek-v4-flash",
    stop_reason: @agent_loop.StopReason::Stop,
    error_message: None,
    usage: None,
    timestamp: 1741290958000,
  }
}

///|
/// A user message with the fixed timestamp the journal snapshots pin.
fn user_message(
  text : String,
  timestamp~ : UInt64 = 1786903823973,
) -> @agent_loop.UserMessage {
  { content: [@agent_loop.InputMessageContent::Text(text)], timestamp, }
}

///|
/// Transient provider failures — HTTP 5xx, overload, 429 / rate limits, and
/// reset-before-headers transport errors — are retried.
async test "is_retryable_error_message matches pi's retryable patterns" {
  // HTTP 5xx and provider load.
  assert_true(
    @agent_session.is_retryable_error_message(
      "DeepSeek API error 503: service unavailable",
    ),
  )
  assert_true(
    @agent_session.is_retryable_error_message(
      "The model is currently overloaded, please try again",
    ),
  )
  assert_true(
    @agent_session.is_retryable_error_message("429 Too Many Requests"),
  )
  assert_true(
    @agent_session.is_retryable_error_message("internal server error"),
  )
  // Rate limiting (any separator, case-insensitive).
  assert_true(@agent_session.is_retryable_error_message("rate limit exceeded"))
  assert_true(@agent_session.is_retryable_error_message("rate-limit exceeded"))
  assert_true(@agent_session.is_retryable_error_message("RATELIMIT exceeded"))
  // Transport failures.
  assert_true(@agent_session.is_retryable_error_message("reset before headers"))
  assert_true(@agent_session.is_retryable_error_message("Socket hang up"))
  assert_true(
    @agent_session.is_retryable_error_message("ENOTFOUND api.deepseek.com"),
  )
  assert_true(
    @agent_session.is_retryable_error_message(
      "stream ended before message_stop",
    ),
  )
  assert_true(
    @agent_session.is_retryable_error_message("please retry your request"),
  )
  assert_true(
    @agent_session.is_retryable_error_message(
      "timed out waiting for the stream",
    ),
  )
  // Our own SSE idle-stall message (providers/responses.mbt) must stay
  // worded so it matches here — otherwise mid-stream stalls never auto-retry.
  assert_true(
    @agent_session.is_retryable_error_message(
      "Responses stream timed out (idle for 120000ms)",
    ),
  )
  // MoonBit async runtime error names (surface via Debug/Show text).
  assert_true(@agent_session.is_retryable_error_message("ReaderClosed"))
  assert_true(@agent_session.is_retryable_error_message("PipeClosed"))
  assert_true(@agent_session.is_retryable_error_message("ConnectionClosed"))
  assert_true(@agent_session.is_retryable_error_message("TimeoutError"))
  assert_true(
    @agent_session.is_retryable_error_message(
      "ResolveHostnameError: api.deepseek.com",
    ),
  )
}

///|
/// Client errors (404/401), protocol failures, and context-limit errors are
/// not transient and must not be retried.
async test "is_retryable_error_message rejects non-retryable and limit errors" {
  // Client errors and protocol failures are not transient.
  assert_false(
    @agent_session.is_retryable_error_message(
      "DeepSeek API error 404: model not found",
    ),
  )
  assert_false(
    @agent_session.is_retryable_error_message(
      "DeepSeek API error 401: invalid api key",
    ),
  )
  assert_false(
    @agent_session.is_retryable_error_message("Malformed Responses SSE event"),
  )
  assert_false(
    @agent_session.is_retryable_error_message(
      "Responses stream ended before a terminal event",
    ),
  )
  // Quota/billing exhaustion is never retried (pi's blacklist).
  assert_false(
    @agent_session.is_retryable_error_message(
      "You exceeded your current quota, please check your plan and billing details",
    ),
  )
  assert_false(@agent_session.is_retryable_error_message("insufficient_quota"))
  assert_false(
    @agent_session.is_retryable_error_message("monthly usage limit reached"),
  )
  assert_false(@agent_session.is_retryable_error_message("out of budget"))
  // Unrelated text.
  assert_false(
    @agent_session.is_retryable_error_message("some unrelated error text"),
  )
}

///|
/// `role: text` 一行一条上下文消息,方便快照出投影后的模型上下文。
fn context_lines(messages : Array[@agent_loop.AgentMessage]) -> String {
  messages
  .map(message => {
    match message {
      @agent_loop.AgentMessage::User(user) =>
        "user: \{input_text(user.content)}"
      @agent_loop.AgentMessage::Assistant(assistant) => {
        let parts = assistant.content.map(block => {
          match block {
            @agent_loop.AssistantMessageContent::Text(text, ..) => text
            _ => "<non-text>"
          }
        })
        "assistant: \{parts.join(" ")}"
      }
      @agent_loop.AgentMessage::ToolResult(result) =>
        "toolResult: \{input_text(result.content)}"
    }
  })
  .join("\n")
}

///|
fn input_text(content : Array[@agent_loop.InputMessageContent]) -> String {
  content
  .map(block => {
    match block {
      @agent_loop.InputMessageContent::Text(text) => text
      _ => "<non-text>"
    }
  })
  .join(" ")
}

///|
/// 恢复带压缩记录的 journal:模型上下文是"总结(user 消息)+ 保留尾部",压缩前的
/// 历史已被替换(pi 的 `buildContextEntries`)。否则被摘要掉的历史会重新进上下文,
/// 而压缩记录被丢掉。
async test "hydrating a compacted journal projects the summary and kept tail" {
  let journal = @agent_session.InMemorySessionJournal()
  ignore(
    journal.append([
      { id: "u1", content: Message(User(user_message("compacted away"))), },
      { id: "a1", content: Message(Assistant(ok_message())), },
      { id: "kept", content: Message(User(user_message("kept turn"))), },
      {
        id: "c1",
        content: Compaction(
          summary="the earlier exchange was a greeting",
          first_kept_entry_id="kept",
          tokens_before=4096,
          details=None,
          usage=None,
        ),
      },
      { id: "u2", content: Message(User(user_message("after"))), },
    ]),
  )
  let session = @agent_session.AgentSession(StubLLM::{ }, journal~)
  inspect(
    context_lines(session.messages().to_owned()),
    content=(
      #|user: The conversation history before this point was compacted into the following summary:
      #|
      #|<summary>
      #|the earlier exchange was a greeting
      #|</summary>
      #|user: kept turn
      #|user: after
    ),
  )
}

///|
/// Only the latest summary contributes context, even if an older compaction's
/// ID lies within the retained range. The boundary may also retain no history.
async test "latest compaction omits older summaries within the kept range" {
  for first_kept_entry_id in ["kept", "c2"] {
    let journal = @agent_session.InMemorySessionJournal(now=() => 7)
    ignore(
      journal.append([
        { id: "old", content: Message(User(user_message("summarized"))), },
        { id: "kept", content: Message(User(user_message("kept turn"))), },
        {
          id: "c1",
          content: Compaction(
            summary="old summary",
            first_kept_entry_id="kept",
            tokens_before=100,
            details=None,
            usage=None,
          ),
        },
        { id: "between", content: Message(User(user_message("between"))), },
        {
          id: "c2",
          content: Compaction(
            summary="latest summary",
            first_kept_entry_id~,
            tokens_before=200,
            details=None,
            usage=None,
          ),
        },
        { id: "after", content: Message(User(user_message("after"))), },
      ]),
    )
    let session = @agent_session.AgentSession(StubLLM::{ }, journal~)
    let expected_tail = if first_kept_entry_id == "kept" {
      "\nuser: kept turn\nuser: between"
    } else {
      ""
    }
    assert_eq(
      context_lines(session.messages().to_owned()),
      "user: The conversation history before this point was compacted into the following summary:\n\n<summary>\nlatest summary\n</summary>" +
      expected_tail +
      "\nuser: after",
    )
  }
}

///|
/// Replaying a journal keeps every entry, including a superseded `Error` turn:
/// the journal is a record of what happened, and a resumed buffer that reads
/// like the journal is what makes `session.messages` usable as history.
/// Keeping a failure out of the prompt is the request build's job
/// (`transform_messages` drops `Error` / `Aborted`), so live and resumed
/// contexts agree without hydration filtering anything.
async test "session hydration keeps Error assistant messages like every other entry" {
  let journal = @agent_session.InMemorySessionJournal()
  ignore(
    journal.append([
      {
        id: "u1",
        content: Message(
          User({
            content: [@agent_loop.InputMessageContent::Text("hi")],
            timestamp: 1786903823973,
          }),
        ),
      },
      {
        id: "e1",
        content: Message(
          Assistant(error_message("DeepSeek API error 503: overloaded")),
        ),
      },
      { id: "ok1", content: Message(Assistant(ok_message())), },
    ]),
  )
  // The constructor hydrates the agent transcript from the journal verbatim.
  let llm = StubLLM::{ }
  let session = @agent_session.AgentSession(llm, journal~)
  assert_eq(session.messages().length(), 3)
  let user_count = session
    .messages()
    .filter(m => m is @agent_loop.AgentMessage::User(_))
    .length()
  assert_eq(user_count, 1)
  match session.messages()[1] {
    @agent_loop.AgentMessage::Assistant(message) =>
      assert_true(message.stop_reason is @agent_loop.StopReason::Error)
    _ => fail("expected the superseded Error turn to survive hydration")
  }
  let text = match session.messages()[2] {
    @agent_loop.AgentMessage::Assistant(m) =>
      match m.content {
        [@agent_loop.AssistantMessageContent::Text(text, ..)] => text
        _ => ""
      }
    _ => ""
  }
  assert_eq(text, "final answer")
}

///|
/// A scripted LLM that answers immediately with a fixed message.
struct ScriptedLLM {}

///|
impl @agent_loop.LLM for ScriptedLLM with fn generate(
  self : ScriptedLLM,
  _ctx : @agent_loop.Context,
  sink~ : async (@agent_loop.GenerationEvent) -> Unit,
  abort~ : @agent_loop.AbortSignal,
) -> @agent_loop.AssistantMessage {
  ignore(self)
  ignore(abort)
  let msg = ok_message()
  sink(@agent_loop.GenerationEvent::Start(partial=msg))
  msg
}

///|
/// pi pins this contract in agent-session-retry-events.test.ts.
async test "session prompt emits pi's event order" {
  let events : Array[String] = []
  let session = @agent_session.AgentSession(ScriptedLLM::{ })
  session.subscribe(event => {
    guard event is Loop(e) else { return }
    events.push(
      match e {
        AgentStart => "agent_start"
        TurnStart => "turn_start"
        MessageStart(User(_)) => "message_start:user"
        MessageEnd(User(_)) => "message_end:user"
        MessageStart(Assistant(_)) => "message_start:assistant"
        MessageEnd(Assistant(_)) => "message_end:assistant"
        TurnEnd(_) => "turn_end"
        AgentEnd(_) => "agent_end"
        _ => "other"
      },
    )
  })
  session.prompt([user_message("hi")])
  assert_eq(events, [
    "agent_start", "turn_start", "message_start:user", "message_end:user", "message_start:assistant",
    "message_end:assistant", "turn_end", "agent_end",
  ])
}

///|
/// A misbehaving LLM that violates the `GenerationEvent` protocol: streams a
/// delta without emitting `Start` first.
struct NoStartLLM {}

///|
impl @agent_loop.LLM for NoStartLLM with fn generate(
  self : NoStartLLM,
  _ctx : @agent_loop.Context,
  sink~ : async (@agent_loop.GenerationEvent) -> Unit,
  abort~ : @agent_loop.AbortSignal,
) -> @agent_loop.AssistantMessage {
  ignore(self)
  ignore(abort)
  let msg = ok_message()
  sink(
    @agent_loop.GenerationEvent::TextDelta(
      content_index=0,
      delta="final answer",
      partial=msg,
    ),
  )
  msg
}

///|
/// pi drops mid-stream events that arrive before `start` (agent-loop.ts's
/// `if (partialMessage)` guard); the terminal message still lands via
/// `generate`'s return value, so the event order is identical to a conforming
/// provider.
async test "mid-stream events before Start are dropped" {
  let events : Array[String] = []
  let session = @agent_session.AgentSession(NoStartLLM::{ })
  session.subscribe(event => {
    guard event is Loop(e) else { return }
    events.push(
      match e {
        AgentStart => "agent_start"
        TurnStart => "turn_start"
        MessageStart(User(_)) => "message_start:user"
        MessageEnd(User(_)) => "message_end:user"
        MessageStart(Assistant(_)) => "message_start:assistant"
        MessageUpdate(_) => "message_update"
        MessageEnd(Assistant(_)) => "message_end:assistant"
        TurnEnd(_) => "turn_end"
        AgentEnd(_) => "agent_end"
        _ => "other"
      },
    )
  })
  session.prompt([user_message("hi")])
  assert_eq(events, [
    "agent_start", "turn_start", "message_start:user", "message_end:user", "message_start:assistant",
    "message_end:assistant", "turn_end", "agent_end",
  ])
}

///|
/// A stub LLM that streams nothing and waits until it is interrupted, then
/// reports `stop_reason: Aborted` with the text received so far — the shape
/// pi's providers produce when `AbortSignal` fires mid-stream.
struct InterruptibleLLM {}

///|
impl @agent_loop.LLM for InterruptibleLLM with fn generate(
  self : InterruptibleLLM,
  _ctx : @agent_loop.Context,
  sink~ : async (@agent_loop.GenerationEvent) -> Unit,
  abort~ : @agent_loop.AbortSignal,
) -> @agent_loop.AssistantMessage {
  ignore(self)
  ignore(abort)
  let partial : @agent_loop.AssistantMessage = {
    content: [
      @agent_loop.AssistantMessageContent::Text("half", signature={
        "type": "text",
      }),
    ],
    api: "openai-responses",
    provider: "deepseek",
    model: "deepseek-v4-flash",
    stop_reason: @agent_loop.StopReason::Pending,
    error_message: None,
    usage: None,
    timestamp: 1741290958000,
  }
  sink(@agent_loop.GenerationEvent::Start(partial~))
  for ;; {
    if abort.is_aborted() {
      return {
        content: partial.content,
        api: "openai-responses",
        provider: "deepseek",
        model: "deepseek-v4-flash",
        stop_reason: @agent_loop.StopReason::Aborted,
        error_message: Some("Interrupted"),
        usage: None,
        timestamp: 1741290958000,
      }
    }
    @async.sleep(5)
  }
}

///|
/// Interrupt mid-run: the partial answer is kept, the turn ends as `Aborted`,
/// and the aborted message is journaled (pi: `stopReason: "aborted"`).
async test "session interrupt ends the turn as aborted and journals it" {
  let journal = @agent_session.InMemorySessionJournal()
  let session = @agent_session.AgentSession(InterruptibleLLM::{ }, journal~)
  @async.with_task_group() <| group => {
    group.spawn_bg(async fn() {
      @async.sleep(20)
      session.abort()
    })
    session.prompt([user_message("hi")])
  }
  let messages = journal
    .get_entries()
    .filter_map(entry => {
      match entry.content {
        Message(m) => Some(m)
        _ => None
      }
    })
  let last = messages[messages.length() - 1]
  guard last is @agent_loop.AgentMessage::Assistant(message) else {
    fail("expected the last journaled message to be the assistant turn")
  }
  assert_true(message.stop_reason is @agent_loop.StopReason::Aborted)
  assert_eq(message.error_message, Some("Interrupted"))
  let text = match message.content {
    [@agent_loop.AssistantMessageContent::Text(text, ..)] => text
    _ => fail("expected the partial text block to survive the interrupt")
  }
  assert_eq(text, "half")
}

///|
/// A minimal callable tool definition: only the name matters here.
fn fake_tool(name : String) -> @tools.ToolDefinition {
  {
    name,
    label: name,
    prompt_guidelines: [],
    description: "\{name} tool",
    parameters: { "type": "object", "properties": {} },
    constrained_sampling: @agent_loop.ConstrainedSampling::JsonSchema(
      strict=true,
    ),
    execute: fake_tool_execute,
  }
}

///|
/// Returns an empty successful result; the stub LLM never calls it.
async fn fake_tool_execute(
  _id : String,
  _args : Json,
  _on_update : @agent_loop.ToolExecUpdateCallback,
) -> @agent_loop.ToolResult {
  @async.sleep(0)
  { content: [], is_error: false, details: {}, usage: None, }
}

///|
/// Records the tool names the model was offered on each generation call.
struct ToolCapturingLLM {
  seen : Array[String]
}

///|
impl @agent_loop.LLM for ToolCapturingLLM with fn generate(
  self : ToolCapturingLLM,
  ctx : @agent_loop.Context,
  sink~ : async (@agent_loop.GenerationEvent) -> Unit,
  abort~ : @agent_loop.AbortSignal,
) -> @agent_loop.AssistantMessage {
  ignore(abort)
  self.seen.clear()
  for tool in ctx.tools {
    self.seen.push(tool.name)
  }
  let message = ok_message()
  sink(@agent_loop.GenerationEvent::Start(partial=message))
  message
}

///|
/// Which tools the model sees is the session's decision, not the registry's:
/// registering a tool does not expose it, and the session can change the
/// active set later.
async test "session offers only its active tools to the model" {
  let registry = @tools.ToolRegistry()
  registry.register_tool(fake_tool("bash"))
  registry.register_tool(fake_tool("read"))
  registry.register_tool(fake_tool("grep"))
  let seen : Array[String] = []
  let session = @agent_session.AgentSession(
    ToolCapturingLLM::{ seen, },
    tool_registry=registry,
    active_tools=["read"],
  )
  session.prompt([user_message("hi")])
  assert_eq(seen, ["read"])
  assert_eq(session.active_tool_names(), ["read"])
  session.set_active_tools(["bash", "grep"])
  assert_eq(session.active_tool_names(), ["bash", "grep"])
  session.prompt([user_message("hi", timestamp=1786903823974)])
  assert_eq(seen, ["bash", "grep"])
}

///|
/// Activating a name that was never registered is a configuration error and
/// must fail loudly at prompt time instead of silently exposing fewer tools.
async test "activating an unregistered tool fails at prompt time" {
  let registry = @tools.ToolRegistry()
  registry.register_tool(fake_tool("bash"))
  let session = @agent_session.AgentSession(
    StubLLM::{ },
    tool_registry=registry,
    active_tools=["bash", "grep"],
  )
  let error_text = try {
    session.prompt([user_message("hi")])
    ""
  } catch {
    err => err.to_string()
  }
  assert_true(error_text.contains("unknown tool: grep"))
}

///|
/// 已中断的信号上等待立即返回(不挂起),且重复 `abort` 仍然幂等。
async test "wait_abort returns immediately when already aborted" {
  let controller = @agent_loop.AbortController::new()
  let signal = controller.signal()
  assert_false(signal.is_aborted())
  controller.abort()
  assert_true(signal.is_aborted())
  signal.wait_abort()
  controller.abort()
  assert_true(signal.is_aborted())
}

///|
/// 广播唤醒全部等待者。
async test "wait_abort wakes every waiter on abort" {
  let controller = @agent_loop.AbortController::new()
  let signal = controller.signal()
  let woken : Array[String] = []
  @async.with_task_group() <| group => {
    for name in ["a", "b"] {
      group.spawn_bg() <| () => {
        signal.wait_abort()
        woken.push(name)
      }
    }
    @async.sleep(50)
    assert_eq(woken, [])
    controller.abort()
  }
  assert_eq(woken, ["a", "b"])
}

///|
/// 等待被取消(超时)时不消费这次中断,也不留在等待队列里。
async test "a cancelled wait_abort does not consume the abort signal" {
  let controller = @agent_loop.AbortController::new()
  let signal = controller.signal()
  let log : Array[String] = []
  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      @async.with_timeout(50, () => signal.wait_abort()) catch {
        _ => log.push("cancelled")
      }
    }
    group.spawn_bg() <| () => {
      @async.sleep(80)
      signal.wait_abort()
      log.push("woken")
    }
    @async.sleep(150)
    controller.abort()
  }
  assert_eq(log, ["cancelled", "woken"])
}

///|
async fn blocking_execute(
  _id : String,
  _args : Json,
  _on_update : @agent_loop.ToolExecUpdateCallback,
) -> @agent_loop.ToolResult {
  @async.sleep(3000)
  { content: [], details: {}, is_error: false, usage: None, }
}

///|
/// A tool that blocks until cancelled, recording cleanup via `defer`; plus a
/// `marker` tool that must never run once the batch has been aborted.
fn abort_batch_tools(log : Array[String]) -> @tools.ToolRegistry {
  let registry = @tools.ToolRegistry()
  registry.register_tool({
    name: "slow",
    label: "slow",
    prompt_guidelines: [],
    description: "blocks until cancelled",
    parameters: { "type": "object", "properties": {} },
    constrained_sampling: @agent_loop.ConstrainedSampling::JsonSchema(
      strict=true,
    ),
    execute: (_, _, on_update) => {
      defer log.push("cleanup")
      blocking_execute("slow", {}, on_update)
    },
  })
  registry.register_tool({
    name: "marker",
    label: "marker",
    prompt_guidelines: [],
    description: "must not run after abort",
    parameters: { "type": "object", "properties": {} },
    constrained_sampling: @agent_loop.ConstrainedSampling::JsonSchema(
      strict=true,
    ),
    execute: (_, _, on_update) => {
      log.push("marker")
      blocking_execute("marker", {}, on_update)
    },
  })
  registry
}

///|
/// Interrupt while a tool is running: cancellation reaches the tool coroutine
/// (its `defer` cleanup runs), the running call is recorded as an aborted
/// result, and the rest of the batch is not executed.
async test "interrupt during a running tool cancels it and records aborted results" {
  let log : Array[String] = []
  let registry = abort_batch_tools(log)
  let journal = @agent_session.InMemorySessionJournal()
  // The model asks for `slow` then `marker`, so the abort is observable on both
  // the running call and the not-yet-started one.
  let llm = @faux.FauxLLM::FauxLLM()
  llm.set_responses([
    @faux.faux_message(
      [
        @faux.faux_tool_call("slow", {}, id="call-slow"),
        @faux.faux_tool_call("marker", {}, id="call-marker"),
      ],
      stop_reason=@agent_loop.StopReason::ToolUse,
    ),
  ])
  let session = @agent_session.AgentSession(
    llm,
    journal~,
    tool_registry=registry,
    active_tools=["slow", "marker"],
  )
  @async.with_task_group() <| group => {
    group.spawn_bg(async fn() {
      @async.sleep(20)
      session.abort()
    })
    session.prompt([user_message("go")])
  }
  // 运行中的工具被取消,`defer` 清理已执行;批内后续调用不执行。
  assert_eq(log, ["cleanup"])
  let results = journal
    .get_entries()
    .filter_map(entry => {
      match entry.content {
        Message(@agent_loop.AgentMessage::ToolResult(result)) => Some(result)
        _ => None
      }
    })
  assert_eq(results.length(), 2)
  for result in results {
    assert_true(result.is_error)
    let text = match result.content {
      [@agent_loop.InputMessageContent::Text(text)] => text
      _ => fail("expected an aborted text result")
    }
    assert_eq(text, "Operation aborted")
  }
}

///|
async fn probe_execute(
  _id : String,
  _args : Json,
  _on_update : @agent_loop.ToolExecUpdateCallback,
) -> @agent_loop.ToolResult {
  @async.sleep(0)
  {
    content: [@agent_loop.InputMessageContent::Text("probe-ok")],
    details: {},
    is_error: false,
    usage: None,
  }
}

///|
/// A tool that finishes on its own and records that it ran.
fn probe_tools(log : Array[String]) -> @tools.ToolRegistry {
  let registry = @tools.ToolRegistry()
  registry.register_tool({
    name: "probe",
    label: "probe",
    prompt_guidelines: [],
    description: "completes immediately",
    parameters: { "type": "object", "properties": {} },
    constrained_sampling: @agent_loop.ConstrainedSampling::JsonSchema(
      strict=true,
    ),
    execute: (id, args, on_update) => {
      log.push("probe")
      probe_execute(id, args, on_update)
    },
  })
  registry
}

///|
/// 每个事件一行 JSON(与 `--mode json` 同一个投影),过滤掉流式增量。
///
/// 投影可能 raise(snapshot 不合约的 `toolcall_start`),而闭包类型没有 raise,
/// 所以这里用循环把 raise 留在函数体里。
fn event_lines(
  events : Array[@agent_session.AgentSessionEvent],
) -> String raise {
  let out = StringBuilder()
  for event in events {
    guard !(event is Loop(MessageUpdate(_))) else { continue }
    if !out.is_empty() {
      out.write_string("\n")
    }
    out.write_string(@agent_session.to_pi_json(event).stringify())
  }
  out.to_string()
}

///|
/// pi's own trick for retry tests — it runs them with
/// `settingsManager.applyOverrides({ retry: { enabled: true, maxRetries,
/// baseDelayMs: 1, maxAgentDelayMs } })`. Keeping the real mechanism but making
/// every backoff window 1ms means these tests never wait out the defaults'
/// 2s/4s, and their timeouts and margins stop being racy. Only the delay is
/// overridden, so `maxAttempts` in the snapshots still reports pi's default.
/// The defaults themselves are pinned by "retry settings mirror pi's resolved
/// defaults and backoff".
fn fast_retry_settings() -> @agent_session.RetrySettings {
  { ..@agent_session.RetrySettings::default(), base_delay_ms: 1, }
}

///|
/// `RetrySettings::default()` mirrors pi's `SETTINGS_DEFAULTS.retry` agent half
/// (`enabled`, `maxRetries`, `baseDelayMs`, `maxAgentDelayMs`), and `delay_ms`
/// is pi's `retryDelayMs`: `baseDelayMs * 2^(attempt-1)` capped per attempt.
async test "retry settings mirror pi's resolved defaults and backoff" {
  let settings = @agent_session.RetrySettings::default()
  assert_true(settings.enabled)
  assert_eq(settings.max_retries, 3)
  assert_eq(settings.base_delay_ms, 2000)
  assert_eq(settings.max_agent_delay_ms, 60_000)
  // The cap only binds from attempt 6 on: 2000 * 2^5 = 64000 > 60000.
  json_inspect(Array::makei(7, i => settings.delay_ms(i + 1)), content=[
    2000, 4000, 8000, 16000, 32000, 60000, 60000,
  ])
}

///|
/// `max_agent_delay_ms` is a per-attempt ceiling. Unlike the sibling provider
/// setting `retry.provider.maxRetryDelayMs`, `0` means "cap every delay at 0"
/// (immediate retries) rather than "no limit".
async test "retry delay honours the cap and saturates on a huge attempt" {
  let capped = @agent_session.RetrySettings::{
    enabled: true,
    max_retries: 3,
    base_delay_ms: 2000,
    max_agent_delay_ms: 5000,
  }
  json_inspect(Array::makei(4, i => capped.delay_ms(i + 1)), content=[
    2000, 4000, 5000, 5000,
  ])
  let no_backoff = @agent_session.RetrySettings::{
    enabled: true,
    max_retries: 3,
    base_delay_ms: 1000,
    max_agent_delay_ms: 0,
  }
  json_inspect(Array::makei(3, i => no_backoff.delay_ms(i + 1)), content=[
    0, 0, 0,
  ])
  // A base already above the cap is clamped on the first attempt.
  let base_over_cap = @agent_session.RetrySettings::{
    enabled: true,
    max_retries: 3,
    base_delay_ms: 9000,
    max_agent_delay_ms: 5000,
  }
  assert_eq(base_over_cap.delay_ms(1), 5000)
  // Doubling saturates at the cap instead of shifting left: `1 << attempt`
  // would wrap negative for a large attempt count and then slip past the
  // `> max` clamp. pi guards `baseDelayMs * 2^(attempt-1)` the same way with
  // `Number.isSafeInteger`.
  assert_eq(capped.delay_ms(1_000_000), 5000)
  assert_eq(base_over_cap.delay_ms(64), 5000)
}

///|
/// Observe the actual next model request, not the session's private buffer.
struct ContextCapturingLLM {
  inner : @faux.FauxLLM
  contexts : Array[Array[@agent_loop.AgentMessage]]
}

///|
impl @agent_loop.LLM for ContextCapturingLLM with fn generate(
  self : ContextCapturingLLM,
  ctx : @agent_loop.Context,
  sink~ : async (@agent_loop.GenerationEvent) -> Unit,
  abort~ : @agent_loop.AbortSignal,
) -> @agent_loop.AssistantMessage {
  self.contexts.push(ctx.messages.to_owned())
  self.inner.generate(ctx, sink~, abort~)
}

///|
/// pi's handleRunFailure closes a listener failure with an error/aborted turn.
/// The next prompt keeps the journaled user, but not the interrupted partial.
async test "listener failures close the run and preserve the next model context" {
  for phase in ["start", "update", "turn_end", "aborted_update"] {
    let inner = @faux.FauxLLM::FauxLLM(chunk_size=3)
    inner.set_responses([
      @faux.faux_message([@faux.faux_text("discarded response")]),
      @faux.faux_message([@faux.faux_text("next answer")]),
    ])
    let llm = ContextCapturingLLM::{ inner, contexts: [], }
    let journal = @agent_session.InMemorySessionJournal()
    let session = @agent_session.AgentSession(llm, journal~)
    let mut failed = false
    let recovery_events : Array[String] = []
    session.subscribe(event => {
      let should_fail = match event {
        Loop(MessageStart(Assistant(_))) => phase == "start"
        Loop(MessageUpdate(TextDelta(..))) =>
          phase == "update" || phase == "aborted_update"
        Loop(TurnEnd(_, _)) => phase == "turn_end"
        _ => false
      }
      if !failed && should_fail {
        failed = true
        if phase == "aborted_update" {
          session.abort()
        }
        @async.sleep(0)
        fail("listener exploded")
      }
      if failed {
        match event {
          Loop(MessageStart(Assistant(_))) => recovery_events.push("start")
          Loop(MessageEnd(Assistant(_))) => recovery_events.push("end")
          Loop(TurnEnd(_, _)) => recovery_events.push("turn_end")
          Loop(AgentEnd(_)) => recovery_events.push("agent_end")
          _ => ()
        }
      }
    })
    session.prompt([user_message("first request")])
    assert_eq(recovery_events, ["start", "end", "turn_end", "agent_end"])
    let entries = journal.get_entries()
    let expected_count = if phase == "turn_end" { 3 } else { 2 }
    assert_eq(entries.length(), expected_count)
    guard entries[expected_count - 1].content is Message(Assistant(failure)) else {
      fail("expected terminal assistant failure")
    }
    assert_true(
      failure.error_message.unwrap_or("").contains("listener exploded"),
    )
    assert_eq(failure.api, "faux")
    assert_eq(failure.provider, "faux")
    assert_eq(failure.model, "faux-1")
    assert_eq(context_lines([Assistant(failure)]), "assistant: ")
    if phase == "aborted_update" {
      assert_true(failure.stop_reason is Aborted)
    } else {
      assert_true(failure.stop_reason is Error)
    }
    session.prompt([user_message("second request")])
    assert_eq(
      context_lines(llm.contexts[1]),
      if phase == "turn_end" {
        "user: first request\nassistant: discarded response\nassistant: \nuser: second request"
      } else {
        "user: first request\nassistant: \nuser: second request"
      },
    )
  }
}

///|
/// Like pi, an exception while delivering the synthetic failure still escapes.
/// Cleanup must leave the same session reusable with exactly its saved history.
async test "a listener that also rejects recovery leaves the session reusable" {
  for reject_end in [false, true] {
    let inner = @faux.FauxLLM::FauxLLM()
    inner.set_responses([
      @faux.faux_message([@faux.faux_text("unfinished")]),
      @faux.faux_message([@faux.faux_text("next answer")]),
    ])
    let llm = ContextCapturingLLM::{ inner, contexts: [], }
    let journal = @agent_session.InMemorySessionJournal()
    let session = @agent_session.AgentSession(llm, journal~)
    let mut reject = true
    session.subscribe(event => {
      guard reject else { return }
      match event {
        Loop(MessageUpdate(TextDelta(..))) => fail("initial listener failure")
        Loop(MessageStart(Assistant(m))) if m.stop_reason is Error &&
          !reject_end => fail("recovery listener failure")
        Loop(MessageEnd(Assistant(m))) if m.stop_reason is Error && reject_end =>
          fail("recovery listener failure")
        _ => ()
      }
    })
    let error = try {
      session.prompt([user_message("first request")])
      ""
    } catch {
      err => err.to_string()
    }
    assert_true(error.contains("recovery listener failure"))
    assert_eq(journal.get_entries().length(), if reject_end { 2 } else { 1 })
    reject = false
    session.prompt([user_message("second request")])
    assert_eq(
      context_lines(llm.contexts[1]),
      if reject_end {
        "user: first request\nassistant: \nuser: second request"
      } else {
        "user: first request\nuser: second request"
      },
    )
  }
}

///|
/// A listener that throws after the turn already succeeded escapes the loop;
/// the session still closes the run with a synthetic Error turn, but that
/// failure is local — provider errors always arrive through the normal
/// MessageEnd path — so a retryable-looking error text must not start
/// auto-retry. Before the fix this emitted auto_retry_start, journaled a
/// context_edit, waited out a backoff, and only then failed the continue.
async test "a failure that escapes the run does not auto-retry" {
  let llm = @faux.FauxLLM::FauxLLM()
  llm.set_responses([@faux.faux_message([@faux.faux_text("completed answer")])])
  let journal = @agent_session.InMemorySessionJournal()
  let session = @agent_session.AgentSession(
    llm,
    journal~,
    retry_settings=fast_retry_settings(),
  )
  let retry_events : Array[@agent_session.AgentSessionEvent] = []
  let mut failed = false
  session.subscribe(event => {
    match event {
      AutoRetryStart(..) | AutoRetryEnd(..) => retry_events.push(event)
      Loop(TurnEnd(_, _)) if !failed => {
        failed = true
        fail("socket hang up")
      }
      _ => ()
    }
  })
  session.prompt([user_message("go")])
  assert_eq(retry_events.length(), 0)
  assert_eq(llm.pending_responses(), 0)
  // [user, assistant(completed), assistant(synthetic error)]: the failure is
  // journaled like pi's handleRunFailure, with no context_edit and no second
  // provider call.
  let entries = journal.get_entries()
  assert_eq(entries.length(), 3)
  guard entries[1].content is Message(Assistant(completed)) else {
    fail("expected the completed assistant turn")
  }
  assert_true(completed.stop_reason is @agent_loop.StopReason::Stop)
  guard entries[2].content is Message(Assistant(failure)) else {
    fail("expected terminal assistant failure")
  }
  assert_true(failure.error_message.unwrap_or("").contains("socket hang up"))
}

///|
/// `enabled: false` suppresses retries entirely: the first retryable failure
/// ends the run with no `auto_retry_start` and no second provider call.
async test "retry settings can disable auto-retry" {
  let llm = @faux.FauxLLM::FauxLLM()
  llm.set_responses([error_message("429 rate limit"), ok_message()])
  let session = @agent_session.AgentSession(llm, retry_settings={
    enabled: false,
    max_retries: 3,
    base_delay_ms: 2000,
    max_agent_delay_ms: 60_000,
  })
  let retry_events : Array[@agent_session.AgentSessionEvent] = []
  session.subscribe(event => {
    match event {
      AutoRetryStart(..) | AutoRetryEnd(..) => retry_events.push(event)
      _ => ()
    }
  })
  session.prompt([user_message("go")])
  // The retryable failure was not retried, so the scripted success is unused.
  assert_eq(llm.pending_responses(), 1)
  assert_eq(retry_events.length(), 0)
}

///|
/// 同一次 prompt 内发生两次"错误 → 恢复":每次恢复都结束当前重试窗口并归零,
/// 所以第二次失败又从 `attempt=1` 开始(pi 在 `message_end` 上重置的契约)。
async test "auto-retry window resets after each successful response" {
  let tool_runs : Array[String] = []
  let registry = probe_tools(tool_runs)
  let llm = @faux.FauxLLM::FauxLLM()
  llm.set_responses([
    @faux.faux_message(
      [],
      stop_reason=@agent_loop.StopReason::Error,
      error_message=Some("overloaded_error"),
    ),
    @faux.faux_message(
      [@faux.faux_tool_call("probe", {}, id="call-probe")],
      stop_reason=@agent_loop.StopReason::ToolUse,
    ),
    @faux.faux_message(
      [],
      stop_reason=@agent_loop.StopReason::Error,
      error_message=Some("rate limit exceeded"),
    ),
    @faux.faux_message([@faux.faux_text("done")]),
  ])
  let session = @agent_session.AgentSession(
    llm,
    tool_registry=registry,
    active_tools=["probe"],
    retry_settings=fast_retry_settings(),
  )
  let events : Array[@agent_session.AgentSessionEvent] = []
  session.subscribe(event => events.push(event))
  session.prompt([user_message("go")])
  assert_eq(tool_runs, ["probe"])
  assert_eq(llm.pending_responses(), 0)
  inspect(
    event_lines(events),
    content=(
      #|{"type":"agent_start"}
      #|{"type":"turn_start"}
      #|{"type":"message_start","message":{"role":"user","content":[{"type":"text","text":"go"}],"timestamp":1786903823973}}
      #|{"type":"message_end","message":{"role":"user","content":[{"type":"text","text":"go"}],"timestamp":1786903823973}}
      #|{"type":"message_start","message":{"role":"assistant","content":[],"api":"faux","provider":"faux","model":"faux-1","stopReason":"pending","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"timestamp":0}}
      #|{"type":"message_end","message":{"role":"assistant","content":[],"api":"faux","provider":"faux","model":"faux-1","stopReason":"error","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"timestamp":0,"errorMessage":"overloaded_error"}}
      #|{"type":"turn_end","message":{"role":"assistant","content":[],"api":"faux","provider":"faux","model":"faux-1","stopReason":"error","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"timestamp":0,"errorMessage":"overloaded_error"},"toolCalls":[]}
      #|{"type":"agent_end"}
      #|{"type":"auto_retry_start","attempt":1,"maxAttempts":3,"delayMs":1,"errorMessage":"overloaded_error"}
      #|{"type":"agent_start"}
      #|{"type":"turn_start"}
      #|{"type":"message_start","message":{"role":"assistant","content":[],"api":"faux","provider":"faux","model":"faux-1","stopReason":"pending","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"timestamp":0}}
      #|{"type":"message_end","message":{"role":"assistant","content":[{"type":"toolCall","id":"call-probe","name":"probe","arguments":{}}],"api":"faux","provider":"faux","model":"faux-1","stopReason":"toolUse","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"timestamp":0}}
      #|{"type":"auto_retry_end","success":true,"attempt":1,"finalError":null}
      #|{"type":"tool_execution_start","toolName":"probe","args":{}}
      #|{"type":"tool_execution_end","toolName":"probe","content":[{"type":"text","text":"probe-ok"}],"isError":false}
      #|{"type":"turn_end","message":{"role":"assistant","content":[{"type":"toolCall","id":"call-probe","name":"probe","arguments":{}}],"api":"faux","provider":"faux","model":"faux-1","stopReason":"toolUse","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"timestamp":0},"toolCalls":["probe"]}
      #|{"type":"turn_start"}
      #|{"type":"message_start","message":{"role":"assistant","content":[],"api":"faux","provider":"faux","model":"faux-1","stopReason":"pending","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"timestamp":0}}
      #|{"type":"message_end","message":{"role":"assistant","content":[],"api":"faux","provider":"faux","model":"faux-1","stopReason":"error","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"timestamp":0,"errorMessage":"rate limit exceeded"}}
      #|{"type":"turn_end","message":{"role":"assistant","content":[],"api":"faux","provider":"faux","model":"faux-1","stopReason":"error","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"timestamp":0,"errorMessage":"rate limit exceeded"},"toolCalls":[]}
      #|{"type":"agent_end"}
      #|{"type":"auto_retry_start","attempt":1,"maxAttempts":3,"delayMs":1,"errorMessage":"rate limit exceeded"}
      #|{"type":"agent_start"}
      #|{"type":"turn_start"}
      #|{"type":"message_start","message":{"role":"assistant","content":[],"api":"faux","provider":"faux","model":"faux-1","stopReason":"pending","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"timestamp":0}}
      #|{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"api":"faux","provider":"faux","model":"faux-1","stopReason":"stop","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"timestamp":0}}
      #|{"type":"auto_retry_end","success":true,"attempt":1,"finalError":null}
      #|{"type":"turn_end","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"api":"faux","provider":"faux","model":"faux-1","stopReason":"stop","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"timestamp":0},"toolCalls":[]}
      #|{"type":"agent_end"}
    ),
  )
}

///|
/// The normal path: a tool that completes without any interrupt must let
/// `prompt` return and must be journaled as a real result.
///
/// Regression guard — the agent loop races each tool against an abort watcher
/// inside a task group, and `with_task_group` waits for every child unless
/// `no_wait=true`. Without it the group waited forever on a watcher that only
/// returns on abort, so *every* tool call hung after the tool itself finished.
/// The interrupt test above cannot catch that: it aborts, which unblocks the
/// watcher.
async test "a completing tool call returns and records its result" {
  let log : Array[String] = []
  let registry = probe_tools(log)
  let journal = @agent_session.InMemorySessionJournal()
  let llm = @faux.FauxLLM::FauxLLM()
  llm.set_responses([
    @faux.faux_message(
      [@faux.faux_tool_call("probe", {}, id="call-probe")],
      stop_reason=@agent_loop.StopReason::ToolUse,
    ),
    @faux.faux_message([@faux.faux_text("done")]),
  ])
  let session = @agent_session.AgentSession(
    llm,
    journal~,
    tool_registry=registry,
    active_tools=["probe"],
  )
  // No interrupt is ever delivered here. If the group starts waiting on the
  // abort watcher again, the timeout below reports `false` instead of hanging
  // the whole suite.
  let finished = @async.with_task_group() <| group => {
    group.spawn_bg(no_wait=true) <| async fn() {
      @async.sleep(2000)
      group.return_immediately(false)
    }
    session.prompt([user_message("go")])
    true
  }
  assert_true(finished)
  assert_eq(log, ["probe"])
  let results = journal
    .get_entries()
    .filter_map(entry => {
      match entry.content {
        Message(@agent_loop.AgentMessage::ToolResult(result)) => Some(result)
        _ => None
      }
    })
  assert_eq(results.length(), 1)
  assert_false(results[0].is_error)
  let text = match results[0].content {
    [@agent_loop.InputMessageContent::Text(text)] => text
    _ => fail("expected the probe tool's text result")
  }
  assert_eq(text, "probe-ok")
}

///|
/// The finish-turn hook is reachable from a session and its `End` decision
/// stops the run: the tool batch would otherwise drive a second provider call,
/// so the scripted follow-up response must stay unconsumed.
async test "finish turn hook on a session ends the run after the tool batch" {
  let log : Array[String] = []
  let registry = probe_tools(log)
  let journal = @agent_session.InMemorySessionJournal()
  let llm = @faux.FauxLLM::FauxLLM()
  llm.set_responses([
    @faux.faux_message(
      [@faux.faux_tool_call("probe", {}, id="call-probe")],
      stop_reason=@agent_loop.StopReason::ToolUse,
    ),
    @faux.faux_message([@faux.faux_text("should not run")]),
  ])
  let hook_calls : Array[Int32] = []
  let session = @agent_session.AgentSession(
    llm,
    journal~,
    tool_registry=registry,
    active_tools=["probe"],
    finish_turn_hook=(_, tool_results, _) => {
      hook_calls.push(tool_results.length())
      Some(@agent_loop.AgentTurnDecision::End)
    },
  )
  let events : Array[@agent_session.AgentSessionEvent] = []
  session.subscribe(event => events.push(event))
  session.prompt([user_message("go")])
  assert_eq(log, ["probe"])
  // One provider call: the hook ran after the tool result and stopped the run.
  assert_eq(llm.pending_responses(), 1)
  assert_eq(hook_calls, [1])
  assert_eq(events.filter(event => event is Loop(TurnEnd(_, _))).length(), 1)
  assert_eq(events.filter(event => event is Loop(AgentEnd(_))).length(), 1)
  json_inspect(journal_roles(journal), content=[
    "user", "assistant", "toolResult",
  ])
}

///|
/// Message roles in journal order, for the finish-turn tests below.
fn journal_roles(journal : &@agent_session.SessionJournal) -> Array[String] {
  journal
  .get_entries()
  .filter_map(entry => {
    match entry.content {
      Message(User(_)) => Some("user")
      Message(Assistant(_)) => Some("assistant")
      Message(ToolResult(_)) => Some("toolResult")
      _ => None
    }
  })
}

///|
/// `set_finish_turn_hook` replaces the hook after construction, and a wrapper
/// can read the current one first — the shape pi relies on when a higher layer
/// layers its own policy over the app's.
async test "a session can replace and wrap its finish turn hook" {
  let log : Array[String] = []
  let registry = probe_tools(log)
  let llm = @faux.FauxLLM::FauxLLM()
  llm.set_responses([
    @faux.faux_message(
      [@faux.faux_tool_call("probe", {}, id="call-probe")],
      stop_reason=@agent_loop.StopReason::ToolUse,
    ),
    @faux.faux_message([@faux.faux_text("should not run")]),
  ])
  let calls : Array[String] = []
  let session = @agent_session.AgentSession(
    llm,
    tool_registry=registry,
    active_tools=["probe"],
    finish_turn_hook=(_, _, _) => {
      calls.push("inner")
      None
    },
  )
  let inner = session.agent.finish_turn_hook
  session.set_finish_turn_hook((messages, tool_results, abort) => {
    calls.push("outer")
    // Delegate to the hook this one replaced, then decide.
    ignore(inner(messages, tool_results, abort))
    Some(@agent_loop.AgentTurnDecision::End)
  })
  session.prompt([user_message("go")])
  assert_eq(llm.pending_responses(), 1)
  assert_eq(calls, ["outer", "inner"])
}

///|
/// Interrupt inside each backoff window, not from its start event. The deadline
/// begins at interrupt, so the second attempt's initial backoff wait is allowed.
///
/// This is the one retry test that cannot use the 1ms `fast_retry_settings`:
/// it has to deliver the abort while a backoff sleep is still pending, which
/// needs a window wide enough to survive the 20ms poll below.
async test "interrupt cancels retry backoff without starting another attempt" {
  for attempt in [1, 2] {
    let llm = @faux.FauxLLM::FauxLLM()
    let responses = Array::makei(attempt, _ => error_message("429 rate limit"))
    responses.push(ok_message())
    llm.set_responses(responses)
    let journal = @agent_session.InMemorySessionJournal()
    let retry_settings = { ..fast_retry_settings(), base_delay_ms: 200, }
    let session = @agent_session.AgentSession(llm, journal~, retry_settings~)
    let started = @async.Semaphore::Semaphore(1, initial_value=0)
    let ends : Array[(Int32, Bool, String?)] = []
    session.subscribe(event => {
      match event {
        AutoRetryStart(attempt=number, ..) if number == attempt =>
          started.release()
        AutoRetryEnd(attempt~, success~, final_error~) =>
          ends.push((attempt, success, final_error))
        _ => ()
      }
    })
    let finished = @async.with_task_group() <| group => {
      group.spawn_bg(no_wait=true) <| async fn() {
        started.acquire()
        @async.sleep(20)
        session.abort()
        @async.sleep(200)
        group.return_immediately(false)
      }
      session.prompt([user_message("first")])
      true
    }
    assert_true(finished)
    assert_eq(ends, [(attempt, false, Some("Retry cancelled"))])
    assert_eq(llm.pending_responses(), 1)
    // Raw history keeps the completed failures; cancellation adds no fake turn.
    // Each attempted retry also records the `context_edit` that omits its failed
    // turn, so `attempt` runs contribute `attempt` edits on top of the user
    // message and the failed assistants.
    assert_eq(journal.get_entries().length(), 2 * attempt + 1)
    session.prompt([user_message("next")])
    assert_eq(llm.pending_responses(), 0)
    assert_eq(journal.get_entries().length(), 2 * attempt + 3)
    assert_eq(ends.length(), 1)
  }
}

///|
/// A retry that reaches generation but is interrupted must not report success.
async test "interrupt during a retried generation reports a cancelled retry" {
  let llm = @faux.FauxLLM::FauxLLM(chunk_delay_ms=20)
  llm.set_responses([error_message("429 rate limit"), ok_message()])
  let session = @agent_session.AgentSession(
    llm,
    retry_settings=fast_retry_settings(),
  )
  let mut starts = 0
  let ends : Array[(Int32, Bool, String?)] = []
  session.subscribe(event => {
    match event {
      Loop(MessageStart(Assistant(_))) => {
        starts += 1
        if starts == 2 {
          session.abort()
        }
      }
      AutoRetryEnd(attempt~, success~, final_error~) =>
        ends.push((attempt, success, final_error))
      _ => ()
    }
  })
  @async.with_timeout(2000, () => session.prompt([user_message("go")]))
  assert_eq(starts, 2)
  assert_eq(ends, [(1, false, Some("Retry cancelled"))])
}

///|
/// Without an interrupt the winning timer cancels its watcher and retries once.
async test "a completed retry reports success and releases its abort watcher" {
  let llm = @faux.FauxLLM::FauxLLM()
  llm.set_responses([error_message("429 rate limit"), ok_message()])
  let session = @agent_session.AgentSession(
    llm,
    retry_settings=fast_retry_settings(),
  )
  let ends : Array[(Int32, Bool, String?)] = []
  session.subscribe(event => {
    if event is AutoRetryEnd(attempt~, success~, final_error~) {
      ends.push((attempt, success, final_error))
    }
  })
  @async.with_timeout(2000, () => session.prompt([user_message("go")]))
  assert_eq(llm.pending_responses(), 0)
  assert_eq(ends, [(1, true, None)])
}

///|
/// A `context_edit` removes its target from the model projection and nothing
/// else: the journal keeps the entry, and the entry itself is unchanged.
async test "a context edit omits its target from the projection only" {
  let journal = @agent_session.InMemorySessionJournal()
  ignore(
    journal.append([
      { id: "u1", content: Message(User(user_message("request"))), },
      { id: "a1", content: Message(Assistant(ok_message())), },
      { id: "x1", content: ContextEdit(target_id="a1"), },
    ]),
  )
  let session = @agent_session.AgentSession(StubLLM::{ }, journal~)
  inspect(
    session.messages().to_owned() |> context_lines,
    content="user: request",
  )
  assert_eq(journal.get_entries().length(), 3)
  match journal.get_entries()[1].content {
    Message(Assistant(message)) =>
      assert_true(message.stop_reason is @agent_loop.StopReason::Stop)
    _ => fail("expected the edited target to stay in the journal")
  }
}

///|
/// Reloading a session projects the same context the live session has, so the
/// buffer is a function of the journal rather than of what this process did.
async test "a reloaded session projects the same context as the live one" {
  let llm = @faux.FauxLLM::FauxLLM()
  llm.set_responses([
    @faux.faux_message(
      [],
      stop_reason=@agent_loop.StopReason::Error,
      error_message=Some("429 rate limit"),
    ),
    @faux.faux_message([@faux.faux_text("done")]),
  ])
  let journal = @agent_session.InMemorySessionJournal()
  let session = @agent_session.AgentSession(llm, journal~)
  session.prompt([user_message("go")])
  let live = context_lines(session.messages().to_owned())
  inspect(live, content="user: go\nassistant: done")
  let reloaded = @agent_session.AgentSession(StubLLM::{ }, journal~)
  assert_eq(context_lines(reloaded.messages().to_owned()), live)
  // The failed turn stays in the record: user, error turn, its edit, the retry.
  assert_eq(journal.get_entries().length(), 4)
}
