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
  debug_inspect(
    is_retryable_error_message("DeepSeek API error 503: service unavailable"),
    content="true",
  )
  debug_inspect(
    is_retryable_error_message(
      "The model is currently overloaded, please try again",
    ),
    content="true",
  )
  debug_inspect(
    is_retryable_error_message("429 Too Many Requests"),
    content="true",
  )
  debug_inspect(
    is_retryable_error_message("internal server error"),
    content="true",
  )
  // Rate limiting (any separator, case-insensitive).
  debug_inspect(
    is_retryable_error_message("rate limit exceeded"),
    content="true",
  )
  debug_inspect(
    is_retryable_error_message("rate-limit exceeded"),
    content="true",
  )
  debug_inspect(
    is_retryable_error_message("RATELIMIT exceeded"),
    content="true",
  )
  // Transport failures.
  debug_inspect(
    is_retryable_error_message("reset before headers"),
    content="true",
  )
  debug_inspect(is_retryable_error_message("Socket hang up"), content="true")
  debug_inspect(
    is_retryable_error_message("ENOTFOUND api.deepseek.com"),
    content="true",
  )
  debug_inspect(
    is_retryable_error_message("stream ended before message_stop"),
    content="true",
  )
  debug_inspect(
    is_retryable_error_message("please retry your request"),
    content="true",
  )
  debug_inspect(
    is_retryable_error_message("timed out waiting for the stream"),
    content="true",
  )
}

///|
async test "is_retryable_error_message rejects non-retryable and limit errors" {
  // Client errors and protocol failures are not transient.
  debug_inspect(
    is_retryable_error_message("DeepSeek API error 404: model not found"),
    content="false",
  )
  debug_inspect(
    is_retryable_error_message("DeepSeek API error 401: invalid api key"),
    content="false",
  )
  debug_inspect(
    is_retryable_error_message("Malformed Responses SSE event"),
    content="false",
  )
  debug_inspect(
    is_retryable_error_message("Responses stream ended before a terminal event"),
    content="false",
  )
  // Quota/billing exhaustion is never retried (pi's blacklist).
  debug_inspect(
    is_retryable_error_message(
      "You exceeded your current quota, please check your plan and billing details",
    ),
    content="false",
  )
  debug_inspect(
    is_retryable_error_message("insufficient_quota"),
    content="false",
  )
  debug_inspect(
    is_retryable_error_message("monthly usage limit reached"),
    content="false",
  )
  debug_inspect(is_retryable_error_message("out of budget"), content="false")
  // Unrelated text.
  debug_inspect(
    is_retryable_error_message("some unrelated error text"),
    content="false",
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
  let llm = @providers.DeepSeekResponsesAPILLM("dummy-key")
  let session = @agent_session.AgentSession(llm, system_prompt="", journal~)
  debug_inspect(session.message_buffer.length(), content="2")
  let user_count = session.message_buffer
    .filter(m => m is @agent_loop.AgentMessage::User(_))
    .length()
  debug_inspect(user_count, content="1")
  let text = match session.message_buffer[1] {
    @agent_loop.AgentMessage::Assistant(m) =>
      match m.content {
        [@agent_loop.AssistantMessageContent::Text(text, ..)] => text
        _ => ""
      }
    _ => ""
  }
  debug_inspect(text, content="\"final answer\"")
}
