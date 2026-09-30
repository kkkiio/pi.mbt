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
  timestamp? : UInt64 = 1786903823973,
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
      {
        id: "c1",
        content: Compaction(
          summary="the earlier exchange was a greeting",
          retained_tail=[User(user_message("kept turn"))],
          tokens_before=4096,
          details=None,
          usage=None,
        ),
      },
      { id: "u2", content: Message(User(user_message("after"))), },
    ]),
  )
  let session = @agent_session.AgentSession(
    StubLLM::{ },
    system_prompt="",
    journal~,
  )
  inspect(
    context_lines(session.message_buffer),
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
/// Replaying a journal skips `Error` assistant messages and keeps every other
/// entry, so a failed request never re-enters the context.
async test "session hydration drops Error assistant messages from the journal" {
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
  // The constructor hydrates `message_buffer` from the journal: superseded
  // Error turns are dropped (the journal keeps them), everything else is kept
  // in order, so a resumed session never replays a failure into the prompt.
  let llm = StubLLM::{ }
  let session = @agent_session.AgentSession(llm, system_prompt="", journal~)
  assert_eq(session.message_buffer.length(), 2)
  let user_count = session.message_buffer
    .filter(m => m is @agent_loop.AgentMessage::User(_))
    .length()
  assert_eq(user_count, 1)
  let text = match session.message_buffer[1] {
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
  let session = @agent_session.AgentSession(ScriptedLLM::{ }, system_prompt="")
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
  let session = @agent_session.AgentSession(NoStartLLM::{ }, system_prompt="")
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
  let session = @agent_session.AgentSession(
    InterruptibleLLM::{ },
    system_prompt="",
    journal~,
  )
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
    callable_definition: Some({
      description: "\{name} tool",
      parameters: { "type": "object", "properties": {} },
      constrained_sampling: @agent_loop.ConstrainedSampling::JsonSchema(
        strict=true,
      ),
      execute: fake_tool_execute,
    }),
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
  { content: [], is_error: false, terminate: false, details: {}, usage: None, }
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
    self.seen.push(
      match tool {
        @agent_loop.Function(definition) => definition.name
        @agent_loop.Hosted(WebSearch) => @agent_session.WEB_SEARCH_TOOL_NAME
      },
    )
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
  registry.register_tool(@agent_session.web_search_tool)
  let seen : Array[String] = []
  let session = @agent_session.AgentSession(
    ToolCapturingLLM::{ seen, },
    system_prompt="",
    tool_registry=registry,
    active_tools=["read"],
  )
  session.prompt([user_message("hi")])
  assert_eq(seen, ["read"])
  assert_eq(session.active_tool_names(), ["read"])
  session.set_active_tools(["bash", @agent_session.WEB_SEARCH_TOOL_NAME])
  assert_eq(session.active_tool_names(), [
    "bash",
    @agent_session.WEB_SEARCH_TOOL_NAME,
  ])
  session.prompt([user_message("hi", timestamp=1786903823974)])
  assert_eq(seen, ["bash", @agent_session.WEB_SEARCH_TOOL_NAME])
}

///|
/// Activating a name that was never registered is a configuration error and
/// must fail loudly at prompt time instead of silently exposing fewer tools.
async test "activating an unregistered tool fails at prompt time" {
  let registry = @tools.ToolRegistry()
  registry.register_tool(fake_tool("bash"))
  let session = @agent_session.AgentSession(
    StubLLM::{ },
    system_prompt="",
    tool_registry=registry,
    active_tools=["bash", "web_search"],
  )
  let error_text = try {
    session.prompt([user_message("hi")])
    ""
  } catch {
    err => err.to_string()
  }
  assert_true(error_text.contains("unknown tool: web_search"))
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
  { content: [], details: {}, is_error: false, terminate: false, usage: None, }
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
    callable_definition: Some({
      description: "blocks until cancelled",
      parameters: { "type": "object", "properties": {} },
      constrained_sampling: @agent_loop.ConstrainedSampling::JsonSchema(
        strict=true,
      ),
      execute: (_, _, on_update) => {
        defer log.push("cleanup")
        blocking_execute("slow", {}, on_update)
      },
    }),
  })
  registry.register_tool({
    name: "marker",
    label: "marker",
    prompt_guidelines: [],
    callable_definition: Some({
      description: "must not run after abort",
      parameters: { "type": "object", "properties": {} },
      constrained_sampling: @agent_loop.ConstrainedSampling::JsonSchema(
        strict=true,
      ),
      execute: (_, _, on_update) => {
        log.push("marker")
        blocking_execute("marker", {}, on_update)
      },
    }),
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
    system_prompt="",
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
    terminate: false,
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
    callable_definition: Some({
      description: "completes immediately",
      parameters: { "type": "object", "properties": {} },
      constrained_sampling: @agent_loop.ConstrainedSampling::JsonSchema(
        strict=true,
      ),
      execute: (id, args, on_update) => {
        log.push("probe")
        probe_execute(id, args, on_update)
      },
    }),
  })
  registry
}

///|
/// 每个事件一行 JSON(与 `--mode json` 同一个 `ToJson`),过滤掉流式增量。
fn event_lines(events : Array[@agent_session.AgentSessionEvent]) -> String {
  events
  .filter(event => !(event is Loop(MessageUpdate(_))))
  .map(event => event.to_json().stringify())
  .join("\n")
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
    system_prompt="",
    tool_registry=registry,
    active_tools=["probe"],
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
      #|{"type":"message_start","message":{"role":"assistant","content":[],"api":"faux","provider":"faux","model":"faux-1","stopReason":"pending","errorMessage":null,"usage":null,"timestamp":0}}
      #|{"type":"message_end","message":{"role":"assistant","content":[],"api":"faux","provider":"faux","model":"faux-1","stopReason":"error","errorMessage":"overloaded_error","usage":null,"timestamp":0}}
      #|{"type":"turn_end","message":{"role":"assistant","content":[],"api":"faux","provider":"faux","model":"faux-1","stopReason":"error","errorMessage":"overloaded_error","usage":null,"timestamp":0},"toolCalls":[]}
      #|{"type":"agent_end"}
      #|{"type":"auto_retry_start","attempt":1,"maxAttempts":2,"delayMs":500,"errorMessage":"overloaded_error"}
      #|{"type":"agent_start"}
      #|{"type":"turn_start"}
      #|{"type":"message_start","message":{"role":"assistant","content":[],"api":"faux","provider":"faux","model":"faux-1","stopReason":"pending","errorMessage":null,"usage":null,"timestamp":0}}
      #|{"type":"message_end","message":{"role":"assistant","content":[{"type":"toolCall","id":"call-probe","name":"probe","arguments":{},"thoughtSignature":"{}"}],"api":"faux","provider":"faux","model":"faux-1","stopReason":"toolUse","errorMessage":null,"usage":null,"timestamp":0}}
      #|{"type":"auto_retry_end","success":true,"attempt":1,"finalError":null}
      #|{"type":"tool_execution_start","toolName":"probe","args":{}}
      #|{"type":"tool_execution_end","toolName":"probe","content":[{"type":"text","text":"probe-ok"}],"isError":false}
      #|{"type":"turn_end","message":{"role":"assistant","content":[{"type":"toolCall","id":"call-probe","name":"probe","arguments":{},"thoughtSignature":"{}"}],"api":"faux","provider":"faux","model":"faux-1","stopReason":"toolUse","errorMessage":null,"usage":null,"timestamp":0},"toolCalls":["probe"]}
      #|{"type":"turn_start"}
      #|{"type":"message_start","message":{"role":"assistant","content":[],"api":"faux","provider":"faux","model":"faux-1","stopReason":"pending","errorMessage":null,"usage":null,"timestamp":0}}
      #|{"type":"message_end","message":{"role":"assistant","content":[],"api":"faux","provider":"faux","model":"faux-1","stopReason":"error","errorMessage":"rate limit exceeded","usage":null,"timestamp":0}}
      #|{"type":"turn_end","message":{"role":"assistant","content":[],"api":"faux","provider":"faux","model":"faux-1","stopReason":"error","errorMessage":"rate limit exceeded","usage":null,"timestamp":0},"toolCalls":[]}
      #|{"type":"agent_end"}
      #|{"type":"auto_retry_start","attempt":1,"maxAttempts":2,"delayMs":500,"errorMessage":"rate limit exceeded"}
      #|{"type":"agent_start"}
      #|{"type":"turn_start"}
      #|{"type":"message_start","message":{"role":"assistant","content":[],"api":"faux","provider":"faux","model":"faux-1","stopReason":"pending","errorMessage":null,"usage":null,"timestamp":0}}
      #|{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"done","textSignature":"{}"}],"api":"faux","provider":"faux","model":"faux-1","stopReason":"stop","errorMessage":null,"usage":null,"timestamp":0}}
      #|{"type":"auto_retry_end","success":true,"attempt":1,"finalError":null}
      #|{"type":"turn_end","message":{"role":"assistant","content":[{"type":"text","text":"done","textSignature":"{}"}],"api":"faux","provider":"faux","model":"faux-1","stopReason":"stop","errorMessage":null,"usage":null,"timestamp":0},"toolCalls":[]}
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
    system_prompt="",
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
/// Interrupt inside each backoff window, not from its start event. The deadline
/// begins at interrupt, so the second attempt's initial 500ms wait is allowed.
async test "interrupt cancels retry backoff without starting another attempt" {
  for attempt in [1, 2] {
    let llm = @faux.FauxLLM::FauxLLM()
    let responses = Array::makei(attempt, _ => error_message("429 rate limit"))
    responses.push(ok_message())
    llm.set_responses(responses)
    let journal = @agent_session.InMemorySessionJournal()
    let session = @agent_session.AgentSession(llm, system_prompt="", journal~)
    let started = @async.Semaphore::Semaphore(1, initial_value=0)
    let ends : Array[(Int, Bool, String?)] = []
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
    assert_eq(journal.get_entries().length(), attempt + 1)
    session.prompt([user_message("next")])
    assert_eq(llm.pending_responses(), 0)
    assert_eq(journal.get_entries().length(), attempt + 3)
    assert_eq(ends.length(), 1)
  }
}

///|
/// A retry that reaches generation but is interrupted must not report success.
async test "interrupt during a retried generation reports a cancelled retry" {
  let llm = @faux.FauxLLM::FauxLLM(chunk_delay_ms=20)
  llm.set_responses([error_message("429 rate limit"), ok_message()])
  let session = @agent_session.AgentSession(llm, system_prompt="")
  let mut starts = 0
  let ends : Array[(Int, Bool, String?)] = []
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
  let session = @agent_session.AgentSession(llm, system_prompt="")
  let ends : Array[(Int, Bool, String?)] = []
  session.subscribe(event => {
    if event is AutoRetryEnd(attempt~, success~, final_error~) {
      ends.push((attempt, success, final_error))
    }
  })
  @async.with_timeout(2000, () => session.prompt([user_message("go")]))
  assert_eq(llm.pending_responses(), 0)
  assert_eq(ends, [(1, true, None)])
}
