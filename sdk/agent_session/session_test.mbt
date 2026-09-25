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
  session.prompt([
    @agent_loop.UserMessage::{
      content: [@agent_loop.InputMessageContent::Text("hi")],
      timestamp: 1786903823973,
    },
  ])
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
  session.prompt([
    @agent_loop.UserMessage::{
      content: [@agent_loop.InputMessageContent::Text("hi")],
      timestamp: 1786903823973,
    },
  ])
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
      session.interrupt()
    })
    session.prompt([
      @agent_loop.UserMessage::{
        content: [@agent_loop.InputMessageContent::Text("hi")],
        timestamp: 1786903823973,
      },
    ])
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
  session.prompt([
    @agent_loop.UserMessage::{
      content: [@agent_loop.InputMessageContent::Text("hi")],
      timestamp: 1786903823973,
    },
  ])
  assert_eq(seen, ["read"])
  assert_eq(session.active_tool_names(), ["read"])
  session.set_active_tools(["bash", @agent_session.WEB_SEARCH_TOOL_NAME])
  assert_eq(session.active_tool_names(), [
    "bash",
    @agent_session.WEB_SEARCH_TOOL_NAME,
  ])
  session.prompt([
    @agent_loop.UserMessage::{
      content: [@agent_loop.InputMessageContent::Text("hi")],
      timestamp: 1786903823974,
    },
  ])
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
    session.prompt([
      @agent_loop.UserMessage::{
        content: [@agent_loop.InputMessageContent::Text("hi")],
        timestamp: 1786903823973,
      },
    ])
    ""
  } catch {
    err => err.to_string()
  }
  assert_true(error_text.contains("unknown tool: web_search"))
}
