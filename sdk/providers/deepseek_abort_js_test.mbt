// Exercise the public LLM API with an offline JS fetch fixture. Restore the
// global transport after every case; no production test seam is needed.

///|
#external
type FetchFixture

///|
// Moon runs async tests concurrently; serialize tests replacing global fetch.
let fetch_gate : @async.Semaphore = @async.Semaphore::Semaphore(1)

///|
extern "js" fn install_fetch(mode : String) -> FetchFixture =
  #| (mode) => {
  #|   const fixture = { original: globalThis.fetch, calls: 0, aborted: false, closed: false, body: null };
  #|   globalThis.fetch = (_url, options) => {
  #|     fixture.calls++;
  #|     fixture.body = new TextDecoder().decode(options.body);
  #|     if (mode === "capture") {
  #|       const message = {
  #|         type: "message", id: "msg_capture", role: "assistant", status: "completed",
  #|         content: [{ type: "output_text", text: "ok", annotations: [] }],
  #|       };
  #|       const events = [
  #|         ["response.created", { response: { status: "in_progress" } }],
  #|         ["response.output_item.added", {
  #|           output_index: 0,
  #|           item: { ...message, content: [], status: "in_progress" },
  #|         }],
  #|         ["response.output_text.delta", { output_index: 0, delta: "ok" }],
  #|         ["response.output_item.done", { output_index: 0, item: message }],
  #|         ["response.completed", { response: {
  #|           status: "completed", output: [message], error: null, incomplete_details: null,
  #|           usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 },
  #|         } }],
  #|       ];
  #|       const sse = events.map(([t, d]) => `event: ${t}\ndata: ${JSON.stringify({ type: t, ...d })}\n\n`).join("");
  #|       return Promise.resolve(new Response(sse, { headers: { "Content-Type": "text/event-stream" } }));
  #|     }
  #|     if (mode === "headers") {
  #|       return new Promise((_resolve, reject) => {
  #|         options.signal.addEventListener("abort", () => {
  #|           fixture.aborted = true;
  #|           reject(new DOMException("Aborted", "AbortError"));
  #|         }, { once: true });
  #|       });
  #|     }
  #|     if (mode === "backoff") return Promise.resolve(new Response("retry", { status: 429 }));
  #|     const body = new ReadableStream({
  #|       start(controller) {
  #|         if (mode === "stream") {
  #|           const events = [
  #|             ["response.created", {}],
  #|             ["response.output_item.added", {
  #|               output_index: 0, item: { id: "msg_1", type: "message", status: "in_progress", role: "assistant", content: [] }
  #|             }],
  #|             ["response.output_text.delta", { output_index: 0, delta: "partial answer" }]
  #|           ];
  #|           const sse = events.map(([event, data]) => `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`).join("");
  #|           controller.enqueue(new TextEncoder().encode(sse));
  #|         }
  #|       },
  #|       cancel() { fixture.closed = true; }
  #|     });
  #|     return Promise.resolve(new Response(body, { status: mode === "error-body" ? 500 : 200 }));
  #|   };
  #|   return fixture;
  #| }

///|
extern "js" fn FetchFixture::restore(self : FetchFixture) -> Unit =
  #| (fixture) => { globalThis.fetch = fixture.original; }

///|
extern "js" fn FetchFixture::calls(self : FetchFixture) -> Int32 =
  #| (fixture) => fixture.calls

///|
extern "js" fn FetchFixture::aborted(self : FetchFixture) -> Bool =
  #| (fixture) => fixture.aborted

///|
extern "js" fn FetchFixture::closed(self : FetchFixture) -> Bool =
  #| (fixture) => fixture.closed

///|
extern "js" fn FetchFixture::request_body(self : FetchFixture) -> String =
  #| (fixture) => fixture.body

///|
fn empty_context() -> @agent_loop.Context {
  { system_prompt: "", messages: [], tools: [], }
}

///|
async test "pre-aborted provider makes no HTTP request" {
  fetch_gate.acquire()
  defer fetch_gate.release()
  let fixture = install_fetch("headers")
  defer fixture.restore()
  let controller = @agent_loop.AbortController::new()
  controller.abort()
  let llm = @providers.DeepSeekProvider(api_key="offline").new_llm("test-model")
  let message = llm.generate(
    empty_context(),
    sink=_ => fail("pre-aborted generation emitted an event"),
    abort=controller.signal(),
  )
  assert_true(message.stop_reason is Aborted)
  assert_eq(fixture.calls(), 0)
}

///|
async test "abort cancels headers error body and retry backoff" {
  fetch_gate.acquire()
  defer fetch_gate.release()
  for mode in ["headers", "error-body", "backoff"] {
    let fixture = install_fetch(mode)
    defer fixture.restore()
    let controller = @agent_loop.AbortController::new()
    let llm = @providers.DeepSeekProvider(api_key="offline").new_llm(
      "test-model",
    )
    let message = @async.with_timeout(1000, () => {
      @async.with_task_group() <| group => {
        group.spawn_bg(async fn() {
          @async.sleep(50)
          assert_eq(fixture.calls(), 1)
          controller.abort()
        })
        llm.generate(
          empty_context(),
          sink=_ => fail("request without SSE emitted an event"),
          abort=controller.signal(),
        )
      }
    })
    assert_true(message.stop_reason is Aborted)
    assert_true(message.content.is_empty())
    assert_eq(message.model, "test-model")
    if mode == "headers" {
      assert_true(fixture.aborted())
    } else if mode == "error-body" {
      assert_true(fixture.closed())
    }
    // Waiting past the first backoff proves no retry escaped cancellation.
    @async.sleep(550)
    assert_eq(fixture.calls(), 1)
  }
}

///|
async test "provider abort retains streamed text and closes response" {
  fetch_gate.acquire()
  defer fetch_gate.release()
  let fixture = install_fetch("stream")
  defer fixture.restore()
  let controller = @agent_loop.AbortController::new()
  let llm = @providers.DeepSeekProvider(api_key="offline").new_llm("test-model")
  let message = @async.with_timeout(1000, () => {
    llm.generate(
      empty_context(),
      sink=event => if event is TextDelta(..) { controller.abort() },
      abort=controller.signal(),
    )
  })
  assert_true(message.stop_reason is Aborted)
  assert_true(fixture.closed())
  assert_eq(fixture.calls(), 1)
  match message.content {
    [Text(text, ..)] => assert_eq(text, "partial answer")
    _ => fail("aborted provider lost its partial text")
  }
}

///|
/// pi's `input_image` encoding (`openai-responses-shared.ts`) through the
/// public LLM: a vision model gets `detail:"auto"` data-URL items in both user
/// message content and tool result output.
async test "image blocks encode as input_image for vision models" {
  fetch_gate.acquire()
  defer fetch_gate.release()
  let fixture = install_fetch("capture")
  defer fixture.restore()
  let image = @agent_loop.InputMessageContent::Image(
    data="aGVsbG8=",
    mime_type="image/png",
  )
  let context : @agent_loop.Context = {
    system_prompt: "sys",
    messages: [
      @agent_loop.AgentMessage::User({
        content: [@agent_loop.InputMessageContent::Text("look"), image],
        timestamp: 1,
      }),
      @agent_loop.AgentMessage::ToolResult({
        tool_call_id: "call-1",
        tool_name: "screenshot",
        content: [@agent_loop.InputMessageContent::Text("ok"), image],
        details: None,
        usage: None,
        is_error: false,
        timestamp: 2,
      }),
    ],
    tools: [],
  }
  let llm = @providers.DeepSeekResponsesAPILLM(
    "offline",
    model_id="vision-test",
    supports_images=true,
  )
  let message = llm.generate(
    context,
    sink=_ => (),
    abort=@agent_loop.AbortController::new().signal(),
  )
  assert_true(message.stop_reason is @agent_loop.StopReason::Stop)
  assert_eq(fixture.calls(), 1)
  guard @json.parse(fixture.request_body()) is { "input": input, .. } else {
    abort("request carried no input")
  }
  json_inspect(input, content=[
    {
      "role": "user",
      "content": [
        { "type": "input_text", "text": "look" },
        {
          "type": "input_image",
          "detail": "auto",
          "image_url": "data:image/png;base64,aGVsbG8=",
        },
      ],
    },
    {
      "type": "function_call_output",
      "call_id": "call-1",
      "output": [
        { "type": "input_text", "text": "ok" },
        {
          "type": "input_image",
          "detail": "auto",
          "image_url": "data:image/png;base64,aGVsbG8=",
        },
      ],
    },
  ])
}

///|
/// A non-vision model instead receives pi's placeholder `input_text` in place
/// of the image block (see `transform_messages`).
async test "image blocks downgrade to placeholder for non-vision models" {
  fetch_gate.acquire()
  defer fetch_gate.release()
  let fixture = install_fetch("capture")
  defer fixture.restore()
  let context : @agent_loop.Context = {
    system_prompt: "sys",
    messages: [
      @agent_loop.AgentMessage::User({
        content: [
          @agent_loop.InputMessageContent::Text("look"),
          @agent_loop.InputMessageContent::Image(
            data="aGVsbG8=",
            mime_type="image/png",
          ),
        ],
        timestamp: 1,
      }),
    ],
    tools: [],
  }
  let llm = @providers.DeepSeekProvider(api_key="offline").new_llm("test-model")
  let message = llm.generate(
    context,
    sink=_ => (),
    abort=@agent_loop.AbortController::new().signal(),
  )
  assert_true(message.stop_reason is @agent_loop.StopReason::Stop)
  assert_eq(fixture.calls(), 1)
  guard @json.parse(fixture.request_body()) is { "input": input, .. } else {
    abort("request carried no input")
  }
  json_inspect(input, content=[
    {
      "role": "user",
      "content": [
        { "type": "input_text", "text": "look" },
        {
          "type": "input_text",
          "text": "(image omitted: model does not support images)",
        },
      ],
    },
  ])
}
