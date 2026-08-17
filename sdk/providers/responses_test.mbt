///|
async test "openai streaming example" {
  let response =
    #| event: response.created
    #| data: {"type":"response.created","response":{"id":"resp_67c9fdcecf488190bdd9a0409de3a1ec07b8b0ad4e5eb654","object":"response","created_at":1741290958,"status":"in_progress","error":null,"incomplete_details":null,"instructions":"You are a helpful assistant.","max_output_tokens":null,"model":"gpt-5.4","output":[],"parallel_tool_calls":true,"previous_response_id":null,"reasoning":{"effort":null,"summary":null},"store":true,"temperature":1.0,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[],"top_p":1.0,"truncation":"disabled","usage":null,"user":null,"metadata":{}}}
    #| 
    #| event: response.in_progress
    #| data: {"type":"response.in_progress","response":{"id":"resp_67c9fdcecf488190bdd9a0409de3a1ec07b8b0ad4e5eb654","object":"response","created_at":1741290958,"status":"in_progress","error":null,"incomplete_details":null,"instructions":"You are a helpful assistant.","max_output_tokens":null,"model":"gpt-5.4","output":[],"parallel_tool_calls":true,"previous_response_id":null,"reasoning":{"effort":null,"summary":null},"store":true,"temperature":1.0,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[],"top_p":1.0,"truncation":"disabled","usage":null,"user":null,"metadata":{}}}
    #| 
    #| event: response.output_item.added
    #| data: {"type":"response.output_item.added","output_index":0,"item":{"id":"msg_67c9fdcf37fc8190ba82116e33fb28c507b8b0ad4e5eb654","type":"message","status":"in_progress","role":"assistant","content":[]}}
    #| 
    #| event: response.content_part.added
    #| data: {"type":"response.content_part.added","item_id":"msg_67c9fdcf37fc8190ba82116e33fb28c507b8b0ad4e5eb654","output_index":0,"content_index":0,"part":{"type":"output_text","text":"","annotations":[]}}
    #| 
    #| event: response.output_text.delta
    #| data: {"type":"response.output_text.delta","item_id":"msg_67c9fdcf37fc8190ba82116e33fb28c507b8b0ad4e5eb654","output_index":0,"content_index":0,"delta":"Hi"}
    #| 
    #| event: response.output_text.done
    #| data: {"type":"response.output_text.done","item_id":"msg_67c9fdcf37fc8190ba82116e33fb28c507b8b0ad4e5eb654","output_index":0,"content_index":0,"text":"Hi there! How can I assist you today?"}
    #| 
    #| event: response.content_part.done
    #| data: {"type":"response.content_part.done","item_id":"msg_67c9fdcf37fc8190ba82116e33fb28c507b8b0ad4e5eb654","output_index":0,"content_index":0,"part":{"type":"output_text","text":"Hi there! How can I assist you today?","annotations":[]}}
    #| 
    #| event: response.output_item.done
    #| data: {"type":"response.output_item.done","output_index":0,"item":{"id":"msg_67c9fdcf37fc8190ba82116e33fb28c507b8b0ad4e5eb654","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Hi there! How can I assist you today?","annotations":[]}]}}
    #| 
    #| event: response.completed
    #| data: {"type":"response.completed","response":{"id":"resp_67c9fdcecf488190bdd9a0409de3a1ec07b8b0ad4e5eb654","object":"response","created_at":1741290958,"status":"completed","error":null,"incomplete_details":null,"instructions":"You are a helpful assistant.","max_output_tokens":null,"model":"gpt-5.4","output":[{"id":"msg_67c9fdcf37fc8190ba82116e33fb28c507b8b0ad4e5eb654","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Hi there! How can I assist you today?","annotations":[]}]}],"parallel_tool_calls":true,"previous_response_id":null,"reasoning":{"effort":null,"summary":null},"store":true,"temperature":1.0,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[],"top_p":1.0,"truncation":"disabled","usage":{"input_tokens":37,"output_tokens":11,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":48},"user":null,"metadata":{}}}

  let messages = []
  let final_message = read_responses_sse_stream(
    @io.MemoryReader::MemoryReader() <| w => { w.write(response) },
    sink=event => messages.push(event),
    api="openai-responses",
    provider="deepseek",
    model="deepseek-v4-flash",
    now=() => 1741290958000,
  )
  debug_inspect(
    messages,
    content=(
      #|[
      #|  Start(
      #|    {
      #|      content: [
      #|        Text(
      #|          "Hi there! How can I assist you today?",
      #|          signature=Object(
      #|            {
      #|              "type": String("message"),
      #|              "id": String("msg_67c9fdcf37fc8190ba82116e33fb28c507b8b0ad4e5eb654"),
      #|            },
      #|          ),
      #|        ),
      #|      ],
      #|      api: "openai-responses",
      #|      provider: "deepseek",
      #|      model: "deepseek-v4-flash",
      #|      stop_reason: Pending,
      #|      error_message: None,
      #|      usage: None,
      #|      timestamp: 1741290958000,
      #|    },
      #|  ),
      #|  TextStart(
      #|    0,
      #|    {
      #|      content: [
      #|        Text(
      #|          "Hi there! How can I assist you today?",
      #|          signature=Object(
      #|            {
      #|              "type": String("message"),
      #|              "id": String("msg_67c9fdcf37fc8190ba82116e33fb28c507b8b0ad4e5eb654"),
      #|            },
      #|          ),
      #|        ),
      #|      ],
      #|      api: "openai-responses",
      #|      provider: "deepseek",
      #|      model: "deepseek-v4-flash",
      #|      stop_reason: Pending,
      #|      error_message: None,
      #|      usage: None,
      #|      timestamp: 1741290958000,
      #|    },
      #|  ),
      #|  TextDelta(
      #|    0,
      #|    "Hi",
      #|    {
      #|      content: [
      #|        Text(
      #|          "Hi there! How can I assist you today?",
      #|          signature=Object(
      #|            {
      #|              "type": String("message"),
      #|              "id": String("msg_67c9fdcf37fc8190ba82116e33fb28c507b8b0ad4e5eb654"),
      #|            },
      #|          ),
      #|        ),
      #|      ],
      #|      api: "openai-responses",
      #|      provider: "deepseek",
      #|      model: "deepseek-v4-flash",
      #|      stop_reason: Pending,
      #|      error_message: None,
      #|      usage: None,
      #|      timestamp: 1741290958000,
      #|    },
      #|  ),
      #|  TextEnd(
      #|    0,
      #|    "Hi there! How can I assist you today?",
      #|    {
      #|      content: [
      #|        Text(
      #|          "Hi there! How can I assist you today?",
      #|          signature=Object(
      #|            {
      #|              "type": String("message"),
      #|              "id": String("msg_67c9fdcf37fc8190ba82116e33fb28c507b8b0ad4e5eb654"),
      #|            },
      #|          ),
      #|        ),
      #|      ],
      #|      api: "openai-responses",
      #|      provider: "deepseek",
      #|      model: "deepseek-v4-flash",
      #|      stop_reason: Pending,
      #|      error_message: None,
      #|      usage: None,
      #|      timestamp: 1741290958000,
      #|    },
      #|  ),
      #|]
    ),
  )
  debug_inspect(
    final_message,
    content=(
      #|{
      #|  content: [
      #|    Text(
      #|      "Hi there! How can I assist you today?",
      #|      signature=Object(
      #|        {
      #|          "type": String("message"),
      #|          "id": String("msg_67c9fdcf37fc8190ba82116e33fb28c507b8b0ad4e5eb654"),
      #|        },
      #|      ),
      #|    ),
      #|  ],
      #|  api: "openai-responses",
      #|  provider: "deepseek",
      #|  model: "deepseek-v4-flash",
      #|  stop_reason: Stop,
      #|  error_message: None,
      #|  usage: Some(
      #|    {
      #|      input: 37,
      #|      output: 11,
      #|      cache_read: 0,
      #|      cache_write: 0,
      #|      cache_write_1h: None,
      #|      reasoning: Some(0),
      #|      total_tokens: 48,
      #|      cost: { input: 0, output: 0, cache_read: 0, cache_write: 0, total: 0 },
      #|    },
      #|  ),
      #|  timestamp: 1741290958000,
      #|}
    ),
  )
}

///|
async test "retry_transient retries transient failures with fresh attempts" {
  // Attempt 1: TCP reset mid-stream (OSError). Attempt 2: SSE idle timeout.
  // Attempt 3: success. Each retry must be a fresh invocation; the successful
  // attempt alone produces the result.
  let mut calls = 0
  let result = retry_transient(
    max_attempts=3,
    base_backoff_ms=0,
    is_transient=is_transient_provider_error,
    attempt=() => {
      calls = calls + 1
      match calls {
        1 => raise @os_error.OSError(104, context="read")
        2 => fail("Responses stream idle for 120000ms")
        _ => "ok"
      }
    },
  )
  debug_inspect(result, content="\"ok\"")
  debug_inspect(calls, content="3")
}

///|
async test "retry_transient does not retry non-transient failures" {
  let mut calls = 0
  let outcome = try {
    retry_transient(
      max_attempts=3,
      base_backoff_ms=0,
      is_transient=is_transient_provider_error,
      attempt=() => {
        calls = calls + 1
        fail("Malformed Responses SSE event")
      },
    )
    "no error"
  } catch {
    err => "\{err}"
  }
  debug_inspect(calls, content="1")
  debug_inspect(
    outcome.contains("Malformed Responses SSE event"),
    content="true",
  )
}

///|
async test "retry_transient propagates the last error after exhausting attempts" {
  let mut calls = 0
  let outcome = try {
    retry_transient(
      max_attempts=3,
      base_backoff_ms=0,
      is_transient=is_transient_provider_error,
      attempt=() => {
        calls = calls + 1
        raise @os_error.OSError(104, context="read")
      },
    )
    "no error"
  } catch {
    err => "\{err}"
  }
  debug_inspect(calls, content="3")
  debug_inspect(outcome.has_prefix("OSError("), content="true")
}

///|
async test "is_transient_provider_error classifies transient conditions only" {
  // Connection reset (OSError) and the SSE idle timeout are transient.
  debug_inspect(classify_oserror(), content="true")
  debug_inspect(classify_idle_timeout(), content="true")
  // HTTP 429/5xx are transient (the provider signals them with a `[retryable]`
  // marker in the error message).
  debug_inspect(classify_retryable_http(), content="true")
  // 4xx and unrelated protocol failures are not.
  debug_inspect(classify_fatal_http(), content="false")
  debug_inspect(classify_malformed_sse(), content="false")
}

///|
fn classify_oserror() -> Bool {
  try {
    raise @os_error.OSError(104, context="read")
  } catch {
    err => is_transient_provider_error(err)
  }
}

///|
fn classify_idle_timeout() -> Bool {
  fail("Responses stream idle for 120000ms") catch {
    err => is_transient_provider_error(err)
  }
}

///|
fn classify_retryable_http() -> Bool {
  // `RetryableHttpError` renders as "DeepSeek API error {code}: {detail}
  // [retryable]"; exercising the classifier on the rendered message keeps the
  // test black-box while covering the 429/5xx predicate.
  fail("DeepSeek API error 429: rate limited [retryable]") catch {
    err => is_transient_provider_error(err)
  }
}

///|
fn classify_fatal_http() -> Bool {
  fail("DeepSeek API error 404: model not found") catch {
    err => is_transient_provider_error(err)
  }
}

///|
fn classify_malformed_sse() -> Bool {
  fail("Malformed Responses SSE event") catch {
    err => is_transient_provider_error(err)
  }
}
