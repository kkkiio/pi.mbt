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
  #|     if (mode === "capture" || mode === "hosted") {
  #|       const message = {
  #|         type: "message", id: "msg_capture", role: "assistant", status: "completed",
  #|         content: [{ type: "output_text", text: "ok", annotations: [] }],
  #|       };
  #|       const search = {
  #|         type: "web_search_call", id: "ws_1", status: "completed", kind: "deep_search",
  #|         action: { type: "search", queries: ["MoonBit"], sources: [
  #|           { type: "url", url: "https://www.moonbitlang.com/", title: "MoonBit", snippet: "A programming language" }
  #|         ] }
  #|       };
  #|       if (mode === "hosted") {
  #|         message.content.push({ type: "output_text", text: " MoonBit", annotations: [
  #|           { type: "url_citation", url: "https://www.moonbitlang.com/", title: "MoonBit", start_index: 1, end_index: 8 }
  #|         ] });
  #|       }
  #|       const index = mode === "hosted" ? 1 : 0;
  #|       const events = [
  #|         ["response.created", { response: { status: "in_progress" } }],
  #|         ...(mode === "hosted" ? [
  #|           ["response.output_item.added", { output_index: 0, item: {
  #|             ...search, status: "in_progress", action: { type: "search", queries: ["MoonBit"] }
  #|           } }],
  #|           ...(fixture.calls === 1 ? [["response.output_item.done", { output_index: 0, item: search }]] : []),
  #|         ] : []),
  #|         ["response.output_item.added", {
  #|           output_index: index,
  #|           item: { ...message, content: [], status: "in_progress" },
  #|         }],
  #|         ["response.output_text.delta", { output_index: index, delta: "ok" }],
  #|         ["response.output_item.done", { output_index: index, item: message }],
  #|         ["response.completed", { response: {
  #|           status: "completed", output: mode === "hosted" ? [search, message] : [message], error: null, incomplete_details: null,
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
  { system_prompt: "", messages: [], tools: [], hosted_tools: [], }
}

///|
async test "cancelling a provider before startup makes no HTTP request" {
  fetch_gate.acquire()
  defer fetch_gate.release()
  let fixture = install_fetch("headers")
  defer fixture.restore()
  let llm = @providers.DeepSeekProvider(api_key="offline").new_llm("test-model")
  @async.with_task_group() <| group => {
    let task = group.spawn(() => {
      @async.handle_cancellation(() => {
        llm.generate(empty_context(), sink=_ => {
          fail("unexpected streaming event")
        })
      })
    })
    task.cancel()
    assert_true(task.wait() is None)
  }
  assert_eq(fixture.calls(), 0)
}

///|
async test "cancellation closes pending headers error bodies and retry backoff" {
  fetch_gate.acquire()
  defer fetch_gate.release()
  for mode in ["headers", "error-body", "backoff"] {
    let fixture = install_fetch(mode)
    defer fixture.restore()
    let llm = @providers.DeepSeekProvider(api_key="offline").new_llm(
      "test-model",
    )
    @async.with_timeout(1000, () => {
      @async.with_task_group(group => {
        let task = group.spawn(() => {
          @async.handle_cancellation(() => {
            llm.generate(empty_context(), sink=_ => {
              fail("unexpected streaming event")
            })
          })
        })
        @async.sleep(50)
        assert_eq(fixture.calls(), 1)
        task.cancel()
        assert_true(task.wait() is None)
      })
    })
    if mode == "headers" {
      assert_true(fixture.aborted())
    }
    if mode == "error-body" {
      assert_true(fixture.closed())
    }
    @async.sleep(550)
    assert_eq(fixture.calls(), 1)
  }
}

///|
async test "provider cancellation closes a streaming response" {
  fetch_gate.acquire()
  defer fetch_gate.release()
  let fixture = install_fetch("stream")
  defer fixture.restore()
  let llm = @providers.DeepSeekProvider(api_key="offline").new_llm("test-model")
  let partial : Ref[@agent_loop.AssistantMessage?] = Ref(None)
  @async.with_timeout(1000, () => {
    @async.with_task_group(group => {
      let active : Ref[@async.Task[@agent_loop.AssistantMessage?]?] = Ref(None)
      let task = group.spawn(() => {
        @async.handle_cancellation(() => {
          llm.generate(empty_context(), sink=event => {
            if event is TextDelta(partial=message, ..) {
              partial.val = Some(message)
              active.val.unwrap().cancel()
            }
          })
        })
      })
      active.val = Some(task)
      assert_true(task.wait() is None)
    })
  })
  assert_true(fixture.closed())
  assert_eq(fixture.calls(), 1)
  guard partial.val is Some({ content: [Text(text, ..)], .. }) else {
    fail("missing partial")
  }
  assert_eq(text, "partial answer")
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
    hosted_tools: [],
  }
  for index, model_id in ["deepseek-v4-flash", "deepseek-flash"] {
    let llm = @providers.DeepSeekProvider(api_key="offline").new_llm(model_id)
    let message = llm.generate(context, sink=_ => ())
    assert_true(message.stop_reason is @agent_loop.StopReason::Stop)
    assert_eq(fixture.calls(), index + 1)
    guard @json.parse(fixture.request_body())
      is { "model": String(sent_model), "input": input, .. } else {
      abort("request carried no input")
    }
    assert_eq(sent_model, model_id)
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
    hosted_tools: [],
  }
  let llm = @providers.DeepSeekProvider(api_key="offline").new_llm("test-model")
  let message = llm.generate(context, sink=_ => ())
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

///|
async test "hosted search is declared by model and its output items replay intact" {
  fetch_gate.acquire()
  defer fetch_gate.release()
  let fixture = install_fetch("hosted")
  defer fixture.restore()
  let provider = @providers.DeepSeekProvider(api_key="offline")
  let flash = provider.new_llm("deepseek-flash")
  let user : @agent_loop.AgentMessage = User({
    content: [Text("Search for MoonBit")],
    timestamp: 1,
  })
  let context : @agent_loop.Context = {
    ..empty_context(),
    messages: [user],
    hosted_tools: [WebSearch, WebSearch],
    tools: [
      {
        name: "test_function",
        description: "A client-executed function",
        parameters: { "type": "object" },
        constrained_sampling: JsonSchema(strict=false),
      },
    ],
  }
  let first = flash.generate(context, sink=_ => ())
  assert_true(first.stop_reason is Stop)
  guard @json.parse(fixture.request_body())
    is {
      "tools": [
        { "type": "deepseek_web_search", .. },
        { "type": "function", "name": "test_function", .. },
      ],
      ..
    } else {
    fail("expected one Flash hosted declaration alongside the local function")
  }
  guard first.content
    is [
      HostedToolCall(
        WebSearch(
          {
            action: Search(queries~, sources=Some([source])),
            id: "ws_1",
            status: "completed",
            ..
          },
        ),
        signature=search_item,
      ),
      Text("ok MoonBit", signature=text_item),
    ] else {
    fail("expected a completed web search followed by assistant text")
  }
  assert_eq(queries, ["MoonBit"])
  assert_eq(source.url, "https://www.moonbitlang.com/")
  assert_eq(source.snippet, Some("A programming language"))
  guard text_item
    is {
      "content": [
        { "text": "ok", .. },
        { "annotations": [{ "type": "url_citation", .. }], .. },
      ],
      ..
    } else {
    fail("expected annotations attached to the original text part")
  }
  let second = flash.generate(
    { ..context, messages: [user, Assistant(first), user], hosted_tools: [], },
    sink=_ => (),
  )
  guard @json.parse(fixture.request_body())
    is {
      "tools": [{ "type": "function", .. }],
      "input": [_, replayed_search, replayed_text, _],
      ..
    } else {
    fail("expected replay even when hosted search is disabled")
  }
  assert_eq(replayed_search, search_item)
  assert_eq(replayed_text, text_item)
  assert_eq(second.content[0].to_json(), first.content[0].to_json())
  let pro = provider.new_llm("deepseek-v4-pro")
  ignore(pro.generate({ ..context, tools: [], }, sink=_ => ()))
  guard @json.parse(fixture.request_body())
    is { "tools": [{ "type": "web_search", .. }], .. } else {
    fail("expected Pro hosted declaration")
  }
}
