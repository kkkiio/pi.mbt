///|
/// 真实 QuickJS VM 的端到端测试(native,pthread + 内嵌 QuickJS-NG)。
/// 不经 faux VM:验证 spawn/消息桥/嵌套调用/store/store 删除全链路。
/// 用例与 e2e_js_test.mbt 保持一致,改动请同步两份文件。

///|
fn echo_tool() -> @tools.ToolDefinition {
  @tools.ToolDefinition::{
    name: "echo",
    label: "echo",
    prompt_guidelines: [],
    description: "Echo the text argument back.",
    parameters: {
      "type": "object",
      "properties": { "text": { "type": "string" } },
      "required": ["text"],
    },
    constrained_sampling: @agent_loop.ConstrainedSampling::JsonSchema(
      strict=false,
    ),
    execute: async fn(_id, arguments, _update) {
      @async.pause()
      let text = match arguments {
        Object({ "text": String(text), .. }) => text
        _ => ""
      }
      {
        content: [@agent_loop.InputMessageContent::Text(text)],
        details: Json::null(),
        is_error: false,
        usage: None,
      }
    },
  }
}

///|
fn e2e_definition(
  run_tool~ : async (@agent_loop.ToolCall, @agent_loop.ToolExecUpdateCallback) -> @agent_loop.ToolResult,
) -> @tools.ToolDefinition {
  @codemode.new_codemode_tool_definition(
    callable_tools=fn() { [echo_tool()] },
    run_tool~,
  )
}

///|
/// 让嵌套调用走 run_tool:echo 回 text,其他名字按未注册处理。
async fn e2e_run_tool(
  call : @agent_loop.ToolCall,
  _update : @agent_loop.ToolExecUpdateCallback,
) -> @agent_loop.ToolResult {
  @async.pause()
  let text = match call.arguments {
    Object({ "text": String(text), .. }) => text
    _ => ""
  }
  {
    content: [@agent_loop.InputMessageContent::Text(text)],
    details: Json::null(),
    is_error: false,
    usage: None,
  }
}

///|
/// details.calls 里每次嵌套调用的 status 串(durationMs 非确定不断言)。
fn call_statuses(result : @agent_loop.ToolResult) -> Array[String] {
  guard result.details is Object({ "calls": Array(entries), .. }) else {
    return []
  }
  entries
  .iter()
  .filter_map(fn(entry) {
    if entry is Object({ "status": String(status), .. }) {
      Some(status)
    } else {
      None
    }
  })
  .collect()
}

///|
fn texts_of(result : @agent_loop.ToolResult) -> Array[String] {
  result.content
  .iter()
  .filter_map(fn(item) {
    if item is @agent_loop.InputMessageContent::Text(t) {
      Some(t)
    } else {
      None
    }
  })
  .collect()
}

///|
async test "e2e: script runs, nested call resolves, return value appended" {
  let def = e2e_definition(run_tool=e2e_run_tool)
  let result = (def.execute)(
    "tc-1",
    (
      {
        "code": "const v = await tools.echo({ text: 'hello' });\ntext(v);\nreturn 42;",
      } : Json),
    fn(_c, _d) {  },
  )
  assert_false(result.is_error)
  let texts = texts_of(result)
  // [header, "hello", "42"](return 值经 value_text 追加)
  assert_eq(texts.length(), 3)
  assert_true(texts[0].has_prefix("Script completed"))
  assert_eq(texts[1], "hello")
  assert_eq(texts[2], "42")
  assert_eq(call_statuses(result), ["ok"])
}

///|
async test "e2e: script error keeps output and reports calls" {
  let def = e2e_definition(run_tool=e2e_run_tool)
  let result = (def.execute)(
    "tc-2",
    (
      {
        "code": "text('before');\nawait tools.echo({text:'x'});\nthrow new TypeError('boom');",
      } : Json),
    fn(_c, _d) {  },
  )
  assert_true(result.is_error)
  let texts = texts_of(result)
  assert_eq(texts.length(), 3)
  assert_true(texts[0].has_prefix("Script failed"))
  assert_eq(texts[1], "before")
  assert_true(texts[2].has_prefix("Script error:"))
  assert_true(texts[2].contains("boom"))
  assert_eq(call_statuses(result), ["ok"])
}

///|
async test "e2e: unknown tool rejects in script" {
  let def = e2e_definition(run_tool=e2e_run_tool)
  let result = (def.execute)(
    "tc-3",
    (
      {
        "code": "try { await tools.nope({}); } catch (e) { text('caught:' + e.message); }",
      } : Json),
    fn(_c, _d) {  },
  )
  assert_false(result.is_error)
  let texts = texts_of(result)
  // 未知名字由 prelude 的 tools Proxy 就地拒绝,不经宿主 call
  assert_true(texts[1].contains("does not exist"))
}

///|
async test "e2e: timeout option aborts a spinning script" {
  let def = e2e_definition(run_tool=e2e_run_tool)
  let result = (def.execute)(
    "tc-4",
    ({ "code": "// @options: {\"timeout_ms\": 300}\nwhile (true) {}" } : Json),
    fn(_c, _d) {  },
  )
  assert_true(result.is_error)
  let texts = texts_of(result)
  assert_true(texts[1].contains("timed out"))
}

///|
async test "e2e: store writes reported only on success" {
  let writes : Ref[Json?] = Ref(None)
  let def = @codemode.new_codemode_tool_definition(
    callable_tools=fn() { [] },
    run_tool=e2e_run_tool,
    on_store_writes=fn(w) { writes.val = Some(Json(w)) },
  )
  let result = (def.execute)(
    "tc-5",
    (
      {
        "code": "store('k', {n: 1});\nstore('gone', undefined);\nreturn load('k').n;",
      } : Json),
    fn(_c, _d) {  },
  )
  assert_false(result.is_error)
  let texts = texts_of(result)
  assert_eq(texts[texts.length() - 1], "1")
  json_inspect(writes.val, content=[
    { "set": { "k": { "n": 1 } }, "delete": ["gone"] },
  ])
}

///|
/// image() → InputMessageContent::Image(对应 pi formatOutput)。Провайдер
/// сам разруливает:vision-модель получит input_image,non-vision —
/// placeholder через transform_messages(PR #38 P2 решён на main #39).
async test "e2e: image output produces image content" {
  let def = e2e_definition(run_tool=e2e_run_tool)
  let result = (def.execute)(
    "tc-6",
    (
      { "code": "image('data:image/png;base64,iVBORw0KGgo=');\nreturn 'ok';" } :
      Json),
    fn(_c, _d) {  },
  )
  assert_false(result.is_error)
  let mut saw = false
  for item in result.content {
    if item is @agent_loop.InputMessageContent::Image(data~, mime_type~) {
      saw = true
      assert_eq(data, "iVBORw0KGgo=")
      assert_eq(mime_type, "image/png")
    }
  }
  assert_true(saw)
}
