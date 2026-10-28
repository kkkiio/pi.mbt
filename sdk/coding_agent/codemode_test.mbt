///|
/// A scripted `@codemode.VmServer`: `recv` returns each queued frame (a
/// message or a batch array) and raises once the feed is empty; `send` is
/// captured so tests can inspect the `StartVmRequest`.
priv struct FakeVm {
  feed : Array[Json]
  sent : Array[Json]
}

///|
impl @codemode.VmServer for FakeVm with fn send(self : FakeVm, data : Json) -> Unit {
  self.sent.push(data)
}

///|
impl @codemode.VmServer for FakeVm with fn recv(self : FakeVm) -> Json {
  if self.feed is [] {
    fail("channel closed")
  } else {
    self.feed.remove(0)
  }
}

///|
impl @codemode.VmServer for FakeVm with fn close(self : FakeVm) -> Unit {
  self.feed.clear()
}

///|
/// A `@codemode.VmServer` that never answers: `recv` blocks on a queue until
/// `close` releases it, which is how the deadline's `stop` reaches the loop.
priv struct BlockingVm {
  sent : Array[Json]
  queue : @aqueue.Queue[Json]
}

///|
/// A `@codemode.VmServer` driven through `inbox`: `send` is captured, and
/// after `results_left` `{type:"result"}` sends it feeds a `done` frame
/// itself — the call-result round trip is then deterministic. A nonpositive
/// `results_left` never auto-finishes.
priv struct ScriptedVm {
  sent : Array[Json]
  inbox : @aqueue.Queue[Json]
  mut results_left : Int32
}

///|
impl @codemode.VmServer for ScriptedVm with fn send(
  self : ScriptedVm,
  data : Json,
) -> Unit {
  self.sent.push(data)
  if data is { "type": "result", .. } {
    self.results_left -= 1
    if self.results_left == 0 {
      self.inbox.put({ "type": "done", "ok": true, "writes": "[]" })
    }
  }
}

///|
impl @codemode.VmServer for ScriptedVm with fn recv(self : ScriptedVm) -> Json {
  self.inbox.get()
}

///|
impl @codemode.VmServer for ScriptedVm with fn close(self : ScriptedVm) -> Unit {
  self.inbox.close()
}

///|
fn call_frame(id : Int32, name : String, args : String) -> Json {
  { "type": "call", "id": id, "target": "tool", "name": name, "args": args }
}

///|
impl @codemode.VmServer for BlockingVm with fn send(
  self : BlockingVm,
  data : Json,
) -> Unit {
  self.sent.push(data)
}

///|
impl @codemode.VmServer for BlockingVm with fn recv(self : BlockingVm) -> Json {
  self.queue.get()
}

///|
impl @codemode.VmServer for BlockingVm with fn close(self : BlockingVm) -> Unit {
  self.queue.close()
}

///|
fn codemode_tool(vm : &@codemode.VmServer) -> @tools.ToolDefinition {
  @coding_agent.new_codemode_tool_definition(
    tools=[],
    vm_launcher=Some(fn() -> &@codemode.VmServer { vm }),
  )
}

///|
async fn run_codemode(
  tool : @tools.ToolDefinition,
  code : String,
  tool_call_id~ : String = "call-1",
  on_update~ : @agent_loop.ToolExecUpdateCallback = (_, _) => (),
  abort~ : @agent_loop.AbortSignal = @agent_loop.AbortSignal::never(),
) -> @agent_loop.ToolResult {
  (tool.execute)(tool_call_id, { "code": Json::string(code) }, on_update, abort)
}

///|
fn text_at(result : @agent_loop.ToolResult, index : Int32) -> String raise {
  guard result.content[index] is @agent_loop.InputMessageContent::Text(text) else {
    fail("expected a text item at \{index}")
  }
  text
}

///|
/// `// @options:` 的每个解析错误都是一个 is_error 结果("Script failed" +
/// "Script error:" + 消息),而不是抛出的失败。VM 从未启动,所以用默认的
/// sidecar 惰性启动器就够了。
async test "codemode tool reports @options parse errors as a failed result" {
  let tool = @coding_agent.new_codemode_tool_definition(tools=[])
  let cases : Array[(String, String)] = [
    (
      "   ", "Expected JavaScript source text (non-empty). Provide JS only, optionally with a first line `// @options: {\"max_output_tokens\": 1000}`.",
    ),
    (
      "work()\n// @options: {}", "The // @options: line must be the first line of the input; found one on line 2",
    ),
    (
      "// @options: {}\n   ", "The @options line must be followed by JavaScript source on subsequent lines",
    ),
    (
      "// @options: {\"foo\": 1}\nwork()", "@options only supports `max_output_tokens` and `timeout_ms`; got `foo`",
    ),
    (
      "// @options: [1]\nwork()", "@options must be a JSON object with supported fields `max_output_tokens` and `timeout_ms`",
    ),
    (
      "// @options: \nwork()", "@options must be a JSON object with supported fields `max_output_tokens` and `timeout_ms`",
    ),
    (
      "// @options: {\"max_output_tokens\": -1}\nwork()", "@options field `max_output_tokens` must be a non-negative safe integer",
    ),
    (
      "// @options: {\"max_output_tokens\": 1.5}\nwork()", "@options field `max_output_tokens` must be a non-negative safe integer",
    ),
    (
      "// @options: {\"timeout_ms\": 0}\nwork()", "@options field `timeout_ms` must be a positive integer up to 2147483647",
    ),
    (
      "// @options: {\"timeout_ms\": -1}\nwork()", "@options field `timeout_ms` must be a positive integer up to 2147483647",
    ),
    (
      "// @options: {\"timeout_ms\": 2147483648}\nwork()", "@options field `timeout_ms` must be a positive integer up to 2147483647",
    ),
  ]
  for pair in cases {
    let (input, expected) = pair
    let result = run_codemode(tool, input)
    assert_true(result.is_error)
    assert_eq(result.content.length(), 2)
    assert_true(text_at(result, 0).has_prefix("Script failed\nWall time "))
    assert_eq(text_at(result, 1), "Script error:\n" + expected)
  }
}

///|
/// 非法 JSON 的 options 也走同一条错误路径;只钉稳定前缀,解析器自己的
/// 报错文本不锁进测试。
async test "codemode tool reports invalid @options JSON" {
  let tool = @coding_agent.new_codemode_tool_definition(tools=[])
  let result = run_codemode(tool, "// @options: {oops\nwork()")
  assert_true(result.is_error)
  assert_true(
    text_at(result, 1).has_prefix(
      "Script error:\n@options must be valid JSON with supported fields `max_output_tokens` and `timeout_ms`: ",
    ),
  )
}

///|
/// options 行在送给 VM 的代码里被替换为空行;`timeout_ms` 透传到
/// `Codemode::execute`。
async test "codemode tool strips the @options line and honors its timeout" {
  let vm = FakeVm::{
    feed: [{ "type": "done", "ok": true, "writes": "[]" }],
    sent: [],
  }
  let result = run_codemode(
    codemode_tool(vm),
    "// @options: {\"timeout_ms\": 5000}\nwork()",
  )
  assert_false(result.is_error)
  guard vm.sent[0] is { "data": { "code": String(code), .. }, .. } else {
    fail("expected a StartVmRequest, sent=\{vm.sent[0].stringify()}")
  }
  assert_eq(code, "\nwork()")
}

///|
/// `timeout_ms` 覆盖默认值:50ms 的期限到期时 VM 收到 stop,结果是带
/// "Execution timed out after 50 ms" 的 Timeout,而不是默认的 300000。
async test "@options timeout_ms overrides the sandbox deadline" {
  let vm = BlockingVm::{
    sent: [],
    queue: @aqueue.Queue(kind=@aqueue.Blocking(4)),
  }
  let result = run_codemode(
    codemode_tool(vm),
    "// @options: {\"timeout_ms\": 50}\nloop()",
  )
  assert_true(result.is_error)
  assert_eq(
    text_at(result, 1),
    "Script error:\nScript timed out: Execution timed out after 50 ms\n\nNo tool calls were made.",
  )
}

///|
/// 超过 `max_output_tokens` 预算的文本折成一项(头尾各留一半),全文写到
/// 溢出文件;`details.fullOutputPath` 与文本里的路径一致。
async test "codemode output over the token budget truncates and spills" {
  let big = "x".repeat(1200)
  let vm = FakeVm::{
    feed: [
      {
        "type": "output",
        "item": { "type": "text", "text": Json::string(big) },
      },
      { "type": "done", "ok": true, "writes": "[]" },
    ],
    sent: [],
  }
  let result = run_codemode(
    codemode_tool(vm),
    "// @options: {\"max_output_tokens\": 50}\nwork()",
  )
  assert_false(result.is_error)
  guard result.details is { "fullOutputPath": String(path), .. } else {
    fail(
      "expected a spilled output path, details=\{result.details.stringify()}",
    )
  }
  guard result.content is [_, @agent_loop.InputMessageContent::Text(text)] else {
    fail("expected a single collapsed text item")
  }
  let head = "x".repeat(100)
  assert_true(
    text.has_prefix(
      "Warning: truncated output (original token count: 300)\nTotal output lines: 1\n\n\{head}…250 tokens truncated…\{head}",
    ),
  )
  assert_true(
    text.has_suffix("\n\n[Full output: \{path} (read with offset/limit)]"),
  )
  assert_true(path.contains("pi-codemode-"))
  assert_true(path.has_suffix("/output.log"))
  assert_eq(@coding_agent.read_text_file(path), big)
  @coding_agent.remove_file(path)
  match path.rev_before("/") {
    Some(directory) => @coding_agent.remove_dir(directory.to_owned())
    None => ()
  }
}

///|
/// 图片项落盘成临时文件,前面贴 `[Image saved to PATH (mimeType, SIZE)]`;
/// 相同 data 只保存一次。
async test "codemode image output is saved to a temp file with a label" {
  let bytes : Bytes = b"\x01\x02\x03"
  let data = @base64.encode(bytes[:])
  let vm = FakeVm::{
    feed: [
      {
        "type": "output",
        "item": {
          "type": "image",
          "data": Json::string(data),
          "mimeType": "image/png",
        },
      },
      {
        "type": "output",
        "item": {
          "type": "image",
          "data": Json::string(data),
          "mimeType": "image/png",
        },
      },
      { "type": "done", "ok": true, "writes": "[]" },
    ],
    sent: [],
  }
  let result = run_codemode(codemode_tool(vm), "work()")
  assert_false(result.is_error)
  guard result.content
    is [
      _,
      @agent_loop.InputMessageContent::Text(first_label),
      @agent_loop.InputMessageContent::Image(..),
      @agent_loop.InputMessageContent::Text(second_label),
      @agent_loop.InputMessageContent::Image(..),
    ] else {
    fail("expected label/image pairs")
  }
  assert_eq(first_label, second_label)
  guard first_label.strip_prefix("[Image saved to ") is Some(rest) else {
    fail("unexpected label \{first_label}")
  }
  guard rest.rev_before(" (image/png, 3B)]") is Some(path_view) else {
    fail("unexpected label \{first_label}")
  }
  let path = path_view.to_owned()
  assert_true(path.contains("pi-codemode-"))
  assert_true(path.has_suffix("/output.png"))
  assert_eq(@coding_agent.read_bytes_file(path), bytes)
  @coding_agent.remove_file(path)
  match path.rev_before("/") {
    Some(directory) => @coding_agent.remove_dir(directory.to_owned())
    None => ()
  }
}

///|
/// 相邻 text 项在 `joinAdjacentText` 里按行界合并:多段文本各带
/// `==> text N/M <==` 头,段间补换行。
async test "codemode adjacent text items join on line boundaries" {
  let vm = FakeVm::{
    feed: [
      { "type": "output", "item": { "type": "text", "text": "a" } },
      { "type": "output", "item": { "type": "text", "text": "b" } },
      { "type": "done", "ok": true, "writes": "[]" },
    ],
    sent: [],
  }
  let result = run_codemode(codemode_tool(vm), "work()")
  assert_false(result.is_error)
  assert_eq(text_at(result, 1), "==> text 1/2 <==\na\n==> text 2/2 <==\nb")
}

///|
/// 失败时 "Script error:" 文本块尾部带 call 台账;未登记的 tool 立即
/// `error`,于是摘要里是 `ghost (error)`。
async test "codemode failure appends the call summary to the script error" {
  let vm = FakeVm::{
    feed: [
      {
        "type": "call",
        "id": 1,
        "target": "tool",
        "name": "ghost",
        "args": "{}",
      },
      {
        "type": "done",
        "ok": false,
        "error": "{\"name\":\"Error\",\"message\":\"boom\"}",
      },
    ],
    sent: [],
  }
  let result = run_codemode(codemode_tool(vm), "work()")
  assert_true(result.is_error)
  assert_eq(
    text_at(result, 1),
    "Script error:\nError: boom\n\nTool calls made before the failure (they are not undone): ghost (error)",
  )
}

///|
/// A session tool with just enough shape for nested-call tests: `execute` is
/// supplied per case.
fn stub_tool(
  name : String,
  execute : async (
    String,
    Json,
    @agent_loop.ToolExecUpdateCallback,
    @agent_loop.AbortSignal,
  ) -> @agent_loop.ToolResult,
) -> @tools.ToolDefinition {
  {
    name,
    label: name,
    prompt_guidelines: [],
    description: "\{name} tool",
    parameters: { "type": "object", "properties": {} },
    constrained_sampling: @agent_loop.ConstrainedSampling::JsonSchema(
      strict=true,
    ),
    execute,
  }
}

///|
fn codemode_tool_with(
  vm : &@codemode.VmServer,
  tools : Array[@tools.ToolDefinition],
) -> @tools.ToolDefinition {
  @coding_agent.new_codemode_tool_definition(
    tools~,
    vm_launcher=Some(fn() -> &@codemode.VmServer { vm }),
  )
}

///|
/// 一个 nested call:工具结果返回 VM,台账行带 `<父调用id>/<n>` id、args 预览、
/// ok 状态与 durationMs;partial update 依次是空台账、running、ok。
async test "a nested call lands in details.calls and mirrors to on_update" {
  let echo = stub_tool("echo", (_id, args, _on_update, _signal) => {
    content: [@agent_loop.InputMessageContent::Text("echo:\{args.stringify()}")],
    details: {},
    is_error: false,
    usage: None,
  })
  let vm = ScriptedVm::{
    sent: [],
    inbox: @aqueue.Queue(kind=@aqueue.Unbounded),
    results_left: 1,
  }
  vm.inbox.put(call_frame(1, "echo", "{\"a\":1}"))
  let updates : Array[Json] = []
  let result = run_codemode(
    codemode_tool_with(vm, [echo]),
    "work()",
    tool_call_id="parent-9",
    on_update=(_, details) => updates.push(details),
  )
  assert_false(result.is_error)
  guard vm.sent
    .iter()
    .any(frame => {
      frame is { "type": "result", "id": Number(1, ..), "ok": True, .. }
    }) else {
    fail(
      "expected a result frame back to the vm, sent=\{Json::array(vm.sent).stringify()}",
    )
  }
  guard result.details is { "calls": [call], .. } else {
    fail("expected one ledger row, details=\{result.details.stringify()}")
  }
  guard call
    is {
      "id": "parent-9/1",
      "name": "echo",
      "args": "{\"a\":1}",
      "status": "ok",
      "durationMs": _,
      ..
    } else {
    fail("unexpected ledger row \{call.stringify()}")
  }
  // 初始 publish(脚本运行中)→ call start(running)→ call end(ok)。
  guard updates
    is [
      { "calls": [], .. },
      { "calls": [{ "status": "running", .. }], .. },
      { "calls": [{ "status": "ok", .. }], .. },
    ] else {
    fail("unexpected update sequence \{Json::array(updates).stringify()}")
  }
}

///|
/// 两个并发 call 各自在台账留行:两个工具都被放行前都已启动(由 started 闸
/// 门证明并发),结束后两行都是 ok。
async test "two concurrent nested calls each get a ledger row" {
  let started : @aqueue.Queue[Unit] = @aqueue.Queue(kind=@aqueue.Unbounded)
  let release : @aqueue.Queue[Unit] = @aqueue.Queue(kind=@aqueue.Unbounded)
  let gate = fn(name : String) -> @tools.ToolDefinition {
    stub_tool(name, (_id, _args, _on_update, _signal) => {
      started.put(())
      release.get()
      {
        content: [@agent_loop.InputMessageContent::Text("\{name}-ok")],
        details: {},
        is_error: false,
        usage: None,
      }
    })
  }
  let vm = ScriptedVm::{
    sent: [],
    inbox: @aqueue.Queue(kind=@aqueue.Unbounded),
    results_left: 2,
  }
  vm.inbox.put(call_frame(1, "first", "{}"))
  vm.inbox.put(call_frame(2, "second", "{}"))
  let result = @async.with_task_group(group => {
    group.spawn_bg(() => {
      started.get()
      started.get()
      release.put(())
      release.put(())
    })
    run_codemode(
      codemode_tool_with(vm, [gate("first"), gate("second")]),
      "work()",
      tool_call_id="p",
    )
  })
  assert_false(result.is_error)
  guard result.details is { "calls": [first, second], .. } else {
    fail("expected two ledger rows, details=\{result.details.stringify()}")
  }
  let rows = [first, second]
  assert_true(rows.iter().all(row => row is { "status": "ok", .. }))
  let ids = rows
    .iter()
    .filter_map(row => {
      if row is { "id": String(id), .. } {
        Some(id)
      } else {
        None
      }
    })
    .collect()
    ..sort()
  assert_eq(ids, ["p/1", "p/2"])
  let names = rows
    .iter()
    .filter_map(row => {
      if row is { "name": String(name), .. } {
        Some(name)
      } else {
        None
      }
    })
    .collect()
    ..sort()
  assert_eq(names, ["first", "second"])
}

///|
/// 脚本结束时仍在运行的 nested call 在台账里标 cancelled;工具的协程被
/// group 取消。
async test "a nested call still running at script end is marked cancelled" {
  let started : @aqueue.Queue[Unit] = @aqueue.Queue(kind=@aqueue.Unbounded)
  let never : @aqueue.Queue[Unit] = @aqueue.Queue(kind=@aqueue.Unbounded)
  let hang = stub_tool("hang", (_id, _args, _on_update, _signal) => {
    started.put(())
    never.get()
    fail("unreachable")
  })
  let vm = ScriptedVm::{
    sent: [],
    inbox: @aqueue.Queue(kind=@aqueue.Unbounded),
    results_left: 0,
  }
  vm.inbox.put(call_frame(1, "hang", "{}"))
  let result = @async.with_task_group(group => {
    group.spawn_bg(() => {
      started.get()
      vm.inbox.put({ "type": "done", "ok": true, "writes": "[]" })
    })
    run_codemode(codemode_tool_with(vm, [hang]), "work()")
  })
  assert_false(result.is_error)
  guard result.details is { "calls": [call], .. } else {
    fail("expected one ledger row, details=\{result.details.stringify()}")
  }
  guard call is { "name": "hang", "status": "cancelled", .. } else {
    fail("unexpected ledger row \{call.stringify()}")
  }
}

///|
/// 失败的 nested call:台账 status=error、error 文本入档,脚本拿到
/// reject(`ok:false` + payload 为错误文本)。
async test "a failing nested call records the error and rejects the call" {
  let boom = stub_tool("boom", (_id, _args, _on_update, _signal) => {
    fail("nested boom")
  })
  let vm = ScriptedVm::{
    sent: [],
    inbox: @aqueue.Queue(kind=@aqueue.Unbounded),
    results_left: 1,
  }
  vm.inbox.put(call_frame(1, "boom", "{}"))
  let result = run_codemode(codemode_tool_with(vm, [boom]), "work()")
  // 脚本本身正常结束:reject 只发生在 `tools.boom` 的 promise 上。
  assert_false(result.is_error)
  guard result.details is { "calls": [call], .. } else {
    fail("expected one ledger row, details=\{result.details.stringify()}")
  }
  guard call is { "status": "error", "error": String(recorded), .. } else {
    fail("unexpected ledger row \{call.stringify()}")
  }
  assert_true(recorded.contains("nested boom"))
  guard vm.sent
    .iter()
    .any(frame => {
      frame is { "type": "result", "ok": False, "payload": String(payload), .. } &&
      payload.contains("nested boom")
    }) else {
    fail("expected a reject frame, sent=\{Json::array(vm.sent).stringify()}")
  }
}

///|
/// nested 工具的 usage 汇总进 codemode 的 ToolResult.usage。
async test "nested call usage sums into the codemode result usage" {
  let usage : @agent_loop.Usage = {
    input: 3,
    output: 2,
    cache_read: 0,
    cache_write: 0,
    cache_write_1h: None,
    reasoning: None,
    total_tokens: 5,
    cost: {
      input: 0.1,
      output: 0.2,
      cache_read: 0,
      cache_write: 0,
      total: 0.3,
    },
  }
  let metered = stub_tool("meter", (_id, _args, _on_update, _signal) => {
    content: [@agent_loop.InputMessageContent::Text("ok")],
    details: {},
    is_error: false,
    usage: Some(usage),
  })
  let vm = ScriptedVm::{
    sent: [],
    inbox: @aqueue.Queue(kind=@aqueue.Unbounded),
    results_left: 1,
  }
  vm.inbox.put(call_frame(1, "meter", "{}"))
  let result = run_codemode(codemode_tool_with(vm, [metered]), "work()")
  assert_false(result.is_error)
  guard result.usage is Some(u) else { fail("expected summed usage") }
  assert_eq(u.total_tokens, 5)
  assert_eq(u.input, 3)
  assert_eq(u.output, 2)
  assert_eq(u.cost.total, 0.3)
}

///|
/// 中断信号:VM 收到 stop 帧后流关闭,执行结果为 Aborted 错误(工具结果层
/// 面是 "Script aborted" 的 is_error 结果)。
async test "aborting the run stops the vm and fails the script as aborted" {
  let vm = ScriptedVm::{
    sent: [],
    inbox: @aqueue.Queue(kind=@aqueue.Unbounded),
    results_left: 0,
  }
  let controller = @agent_loop.AbortController::new()
  let result = @async.with_task_group(group => {
    group.spawn_bg(() => {
      @async.sleep(30)
      controller.abort()
    })
    run_codemode(codemode_tool(vm), "work()", abort=controller.signal())
  })
  assert_true(result.is_error)
  assert_eq(
    text_at(result, 1),
    "Script error:\nScript aborted: Execution aborted\n\nNo tool calls were made.",
  )
  assert_true(vm.sent.iter().any(frame => frame is { "type": "stop", .. }))
}

///|
/// `store("k", v)` 的写入以 `codemode-store` 自定义条目落进 journal;第二次
/// execute 的 StartVmRequest 携带重放后的 store(`load()` 读到的就是它)。
/// 每次 execute 拿一个新的 FakeVm,但共享 feed/sent,两轮请求都留档。
async test "codemode store writes persist to the journal and feed the next run" {
  let journal : &@agent_session.SessionJournal = @agent_session.InMemorySessionJournal()
  let feed : Array[Json] = [
    { "type": "done", "ok": true, "writes": "[[\"k\",\"\\\"v\\\"\"]]" },
  ]
  let sent : Array[Json] = []
  let tool = @coding_agent.new_codemode_tool_definition(
    tools=[],
    journal=Some(journal),
    vm_launcher=Some(fn() -> &@codemode.VmServer { FakeVm::{ feed, sent, } }),
  )
  let first = run_codemode(tool, "store-run()", tool_call_id="run-1")
  assert_false(first.is_error)
  let store_data : Array[Json] = []
  for entry in journal.get_entries() {
    if entry.content
      is @agent_session.SessionEntryContent::Custom(custom_type~, data~) &&
      custom_type == "codemode-store" {
      store_data.push(data.unwrap_or(Json::null()))
    }
  }
  assert_eq(store_data, [
    Json::object({ "set": Json::object({ "k": "v" }), "delete": [] }),
  ])
  feed.push({ "type": "done", "ok": true, "writes": "[]" })
  let second = run_codemode(tool, "load-run()", tool_call_id="run-2")
  assert_false(second.is_error)
  // 第二个 StartVmRequest:store 的 wire 形状是 {key: 值 JSON 文本}。
  guard sent is [_, { "data": { "store": Object(store), .. }, .. }] else {
    fail(
      "expected the second run to carry the persisted store, sent=\{Json::array(sent).stringify()}",
    )
  }
  assert_eq(store.length(), 1)
  guard store.get("k") is Some(String("\"v\"")) else {
    fail(
      "expected k -> \"v\" in the store, got \{Json::object(store).stringify()}",
    )
  }
}

///|
/// 失败的执行不落盘 `codemode-store` 条目。
async test "a failed codemode run appends no codemode-store entry" {
  let journal : &@agent_session.SessionJournal = @agent_session.InMemorySessionJournal()
  let vm = FakeVm::{
    feed: [
      {
        "type": "done",
        "ok": false,
        "error": "{\"name\":\"Error\",\"message\":\"boom\"}",
      },
    ],
    sent: [],
  }
  let tool = @coding_agent.new_codemode_tool_definition(
    tools=[],
    journal=Some(journal),
    vm_launcher=Some(fn() -> &@codemode.VmServer { vm }),
  )
  let result = run_codemode(tool, "work()")
  assert_true(result.is_error)
  for entry in journal.get_entries() {
    if entry.content
      is @agent_session.SessionEntryContent::Custom(custom_type~, ..) {
      assert_not_eq(custom_type, "codemode-store")
    }
  }
}

///|
/// 形状不合法的 `codemode-store` 条目(缺 `set`/`delete`、`delete` 不是
/// 字符串数组、别的 custom_type)在重放时被跳过;每条先 delete 再 set,
/// 按 journal 顺序生效。
async test "malformed codemode-store entries are skipped when reading the store" {
  let journal : &@agent_session.SessionJournal = @agent_session.InMemorySessionJournal()
  let entry = fn(id : String, custom_type : String, data : Json) {
    @agent_session.NewSessionEntry::{
      id,
      content: @agent_session.SessionEntryContent::Custom(
        custom_type~,
        data=Some(data),
      ),
    }
  }
  ignore(
    journal.append([
      entry("e1", "codemode-store", { "set": { "a": 1 } }),
      entry("e2", "codemode-store", { "set": { "b": 2 }, "delete": [1] }),
      entry("e3", "codemode-store", {
        "set": { "keep": 1, "gone": 2 },
        "delete": [],
      }),
      entry("e4", "codemode-store", { "set": {}, "delete": ["gone", "zzz"] }),
      entry("e5", "other", { "set": { "x": 9 }, "delete": [] }),
    ]),
  )
  let vm = FakeVm::{
    feed: [{ "type": "done", "ok": true, "writes": "[]" }],
    sent: [],
  }
  let tool = @coding_agent.new_codemode_tool_definition(
    tools=[],
    journal=Some(journal),
    vm_launcher=Some(fn() -> &@codemode.VmServer { vm }),
  )
  let result = run_codemode(tool, "work()")
  assert_false(result.is_error)
  guard vm.sent[0] is { "data": { "store": Object(store), .. }, .. } else {
    fail(
      "expected only the valid entries replayed, sent=\{Json::array(vm.sent).stringify()}",
    )
  }
  assert_eq(store.length(), 1)
  guard store.get("keep") is Some(String("1")) else {
    fail(
      "expected keep -> 1 in the store, got \{Json::object(store).stringify()}",
    )
  }
}

///|
/// 工具自身的 description:INTRO + Globals + `Nested tools:` 下每个 callable
/// 工具一节 `### \`id\``(id 与原名不同附原名)加 declaration sample;送进
/// VM 的 `Tool.description`(ALL_TOOLS 条目)带 `codemode tool declaration:`。
async test "codemode description embeds declarations for its nested tools" {
  let unused = stub_tool("unused", (_id, _args, _on_update, _signal) => {
    content: [@agent_loop.InputMessageContent::Text("unused")],
    details: {},
    is_error: false,
    usage: None,
  })
  let bash = { ..unused, name: "bash", label: "bash", }
  let web = { ..unused, name: "web-search", label: "web-search", }
  let vm = FakeVm::{
    feed: [{ "type": "done", "ok": true, "writes": "[]" }],
    sent: [],
  }
  let tool = codemode_tool_with(vm, [bash, web])
  assert_true(tool.description.contains("Nested tools:"))
  assert_true(tool.description.contains("### `bash`"))
  assert_true(tool.description.contains("### `web_search` (`web-search`)"))
  assert_true(tool.description.contains("declare const tools"))
  assert_true(tool.description.contains("Promise<string>"))
  let result = run_codemode(tool, "work()")
  assert_false(result.is_error)
  guard vm.sent[0] is { "data": { "tools": Array(nested_tools), .. }, .. } else {
    fail(
      "expected a StartVmRequest with tools, sent=\{Json::array(vm.sent).stringify()}",
    )
  }
  assert_eq(nested_tools.length(), 2)
  for nested in nested_tools {
    guard nested is { "description": String(description), .. } else {
      fail("expected a tool description, got \{nested.stringify()}")
    }
    assert_true(description.contains("codemode tool declaration:"))
  }
}
