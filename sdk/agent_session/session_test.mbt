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
) -> @agent_loop.AssistantMessage {
  ignore(self)
  ignore(sink)
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
    is_retryable_error_message("DeepSeek API error 503: service unavailable"),
  )
  assert_true(
    is_retryable_error_message(
      "The model is currently overloaded, please try again",
    ),
  )
  assert_true(is_retryable_error_message("429 Too Many Requests"))
  assert_true(is_retryable_error_message("internal server error"))
  // Rate limiting (any separator, case-insensitive).
  assert_true(is_retryable_error_message("rate limit exceeded"))
  assert_true(is_retryable_error_message("rate-limit exceeded"))
  assert_true(is_retryable_error_message("RATELIMIT exceeded"))
  // Transport failures.
  assert_true(is_retryable_error_message("reset before headers"))
  assert_true(is_retryable_error_message("Socket hang up"))
  assert_true(is_retryable_error_message("ENOTFOUND api.deepseek.com"))
  assert_true(is_retryable_error_message("stream ended before message_stop"))
  assert_true(is_retryable_error_message("please retry your request"))
  assert_true(is_retryable_error_message("timed out waiting for the stream"))
}

///|
async test "is_retryable_error_message rejects non-retryable and limit errors" {
  // Client errors and protocol failures are not transient.
  assert_false(
    is_retryable_error_message("DeepSeek API error 404: model not found"),
  )
  assert_false(
    is_retryable_error_message("DeepSeek API error 401: invalid api key"),
  )
  assert_false(is_retryable_error_message("Malformed Responses SSE event"))
  assert_false(
    is_retryable_error_message("Responses stream ended before a terminal event"),
  )
  // Quota/billing exhaustion is never retried (pi's blacklist).
  assert_false(
    is_retryable_error_message(
      "You exceeded your current quota, please check your plan and billing details",
    ),
  )
  assert_false(is_retryable_error_message("insufficient_quota"))
  assert_false(is_retryable_error_message("monthly usage limit reached"))
  assert_false(is_retryable_error_message("out of budget"))
  // Unrelated text.
  assert_false(is_retryable_error_message("some unrelated error text"))
}

///|
async test "session hydration drops Error assistant messages from the journal" {
  let journal = @agent_session.InMemorySessionJournal()
  ignore(
    journal.append([
      {
        id: "u1",
        content: Message(
          User([@agent_loop.InputMessageContent::Text("hi")]),
          terminate=false,
        ),
      },
      {
        id: "e1",
        content: Message(
          Assistant(error_message("DeepSeek API error 503: overloaded")),
          terminate=false,
        ),
      },
      { id: "ok1", content: Message(Assistant(ok_message()), terminate=false) },
    ]),
  )
  // The constructor hydrates `message_buffer` from the journal: superseded
  // Error turns are dropped (the journal keeps them), everything else is kept
  // in order, so a resumed session never replays a failure into the prompt.
  let llm = StubLLM::{  }
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
