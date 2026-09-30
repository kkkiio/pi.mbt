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
  #|   const fixture = { original: globalThis.fetch, calls: 0, aborted: false, closed: false };
  #|   globalThis.fetch = (_url, options) => {
  #|     fixture.calls++;
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
extern "js" fn FetchFixture::calls(self : FetchFixture) -> Int =
  #| (fixture) => fixture.calls

///|
extern "js" fn FetchFixture::aborted(self : FetchFixture) -> Bool =
  #| (fixture) => fixture.aborted

///|
extern "js" fn FetchFixture::closed(self : FetchFixture) -> Bool =
  #| (fixture) => fixture.closed

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
