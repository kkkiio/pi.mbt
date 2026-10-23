///|
/// pi test/sandbox.test.ts 的宿主侧移植:faux VM 走公开 VmLauncher/
/// VmEvents/VmChannel 缝,只验证 Execution 状态机(VM 侧语义由真 VM 测)。
///
/// 消息语义约定(与 pi worker 一致):call id 唯一;终态消息后不再发消息;
/// host 应答经 VmChannel.post 进来。
priv struct FakeChannel {
  events : &@codemode.VmEvents
  sent : Array[@codemode.HostToVmMessage]
  mut stopped : Bool
}

///|
impl @codemode.VmChannel for FakeChannel with fn post(self, message) {
  self.sent.push(message)
}

///|
impl @codemode.VmChannel for FakeChannel with fn stop(self) {
  self.stopped = true
}

///|
/// 脚本化假 VM:启动时上报 messages(可能含 Call;应答到达后由测试驱动后续消息)。
fn fake_launcher(
  messages~ : Array[@codemode.VmToHostMessage] = [],
  data~ : Ref[@codemode.VmStartData?] = Ref(None),
  channel~ : Ref[FakeChannel?] = Ref(None),
) -> @codemode.VmLauncher {
  async fn(start_data, events) {
    @async.pause()
    let fake = FakeChannel::{ events, sent: [], stopped: false, }
    data.val = Some(start_data)
    channel.val = Some(fake)
    for message in messages {
      events.message(message)
    }
    fake
  }
}

///|
fn done_writes() -> @codemode.CodemodeStoreWrites {
  { set: Map([]), delete: [], }
}

///|
/// duration_ms 来自真实时钟,快照前归零。
fn scrub_durations(
  result : @codemode.CodemodeResult,
) -> @codemode.CodemodeResult {
  match result {
    Ok(calls~, ..) | Err(calls~, ..) =>
      for call in calls {
        call.duration_ms = 0.0
      }
  }
  result
}

///|
#warnings("-unused_async")
async fn echo_execute(
  args : Json?,
  _ctx : @codemode.CodemodeToolContext,
) -> Json? {
  args
}

///|
test "with_launcher: duplicate tool names rejected" {
  let message = try {
    ignore(
      @codemode.CodemodeSandbox::with_launcher(launch=fake_launcher(), tools=[
        @codemode.CodemodeTool::new(name="echo", execute=echo_execute),
        @codemode.CodemodeTool::new(name="echo", execute=echo_execute),
      ]),
    )
    abort("expected failure")
  } catch {
    @codemode.CodemodeSandboxError(message) => message
    error => error.to_string()
  }
  inspect(
    message,
    content=(
      #|Tool "echo" is already registered
    ),
  )
}

///|
test "with_launcher: reserved and malformed globals rejected" {
  let messages = []
  for name in ["tools", "bad name", "a.b.c"] {
    let message = try {
      ignore(
        @codemode.CodemodeSandbox::with_launcher(launch=fake_launcher(), globals=[
          @codemode.CodemodeTool::new(name~, execute=echo_execute),
        ]),
      )
      abort("expected failure for \{name}")
    } catch {
      @codemode.CodemodeSandboxError(message) => message
      error => error.to_string()
    }
    messages.push("\{name} => \{message}")
  }
  inspect(
    messages.join("\n"),
    content=(
      #|tools => Invalid global name "tools"
      #|bad name => Invalid global name "bad name"
      #|a.b.c => Invalid global name "a.b.c"
    ),
  )
}

///|
async test "execute: value, ordered output and store writes" {
  let sandbox = @codemode.CodemodeSandbox::with_launcher(
    launch=fake_launcher(messages=[
      @codemode.VmToHostMessage::Output(
        @codemode.CodemodeOutputItem::Text(text="hello", console=false),
      ),
      @codemode.VmToHostMessage::Output(
        @codemode.CodemodeOutputItem::Text(text="log line", console=true),
      ),
      @codemode.VmToHostMessage::Output(
        @codemode.CodemodeOutputItem::Image(
          data="iVBORw0KGgo=",
          mime_type="image/png",
        ),
      ),
      @codemode.VmToHostMessage::Done(value=Some(([1, 2] : Json)), store_writes={
        set: Map([("k", Json(1))]),
        delete: ["old"],
      }),
    ]),
  )
  json_inspect(sandbox.execute("text('hello')"), content=[
    "Ok",
    {
      "value": [1, 2],
      "output": [
        ["Text", { "text": "hello", "console": false }],
        ["Text", { "text": "log line", "console": true }],
        ["Image", { "data": "iVBORw0KGgo=", "mime_type": "image/png" }],
      ],
      "calls": [],
      "store_writes": { "set": { "k": 1 }, "delete": ["old"] },
    },
  ])
}

///|
async test "execute: start data carries tools, globals, store, memory limit" {
  let data : Ref[@codemode.VmStartData?] = Ref(None)
  let sandbox = @codemode.CodemodeSandbox::with_launcher(
    launch=fake_launcher(data~, messages=[
      @codemode.VmToHostMessage::Done(value=None, store_writes=done_writes()),
    ]),
    tools=[
      @codemode.CodemodeTool::new(
        name="my-tool",
        description="desc",
        execute=echo_execute,
      ),
    ],
    globals=[
      @codemode.CodemodeTool::new(
        name="ns.fun",
        spread=true,
        execute=echo_execute,
      ),
    ],
    memory_limit_bytes=Some(1024),
  )
  ignore(sandbox.execute("code", store=Map([("k", Json("v"))])))
  guard data.val is Some(data) else { abort("launcher never ran") }
  assert_eq(data.code, "code")
  assert_eq(data.memory_limit_bytes, Some(1024))
  assert_eq(data.store.get("k"), Some("\"v\""))
  guard data.tools is [tool] else { abort("bad tools") }
  assert_eq(tool.name, "my-tool")
  assert_eq(tool.js_name, "my_tool")
  assert_eq(tool.description, "desc")
  guard data.globals is [g] else { abort("bad globals") }
  assert_eq(g.name, "ns.fun")
  assert_true(g.spread)
}

///|
async test "execute: script error keeps output and reports Script" {
  let sandbox = @codemode.CodemodeSandbox::with_launcher(
    launch=fake_launcher(messages=[
      @codemode.VmToHostMessage::Output(
        @codemode.CodemodeOutputItem::Text(text="before", console=false),
      ),
      @codemode.VmToHostMessage::ScriptError(error={
        kind: @codemode.CodemodeErrorKind::Script,
        name: Some("TypeError"),
        message: "boom",
        stack: Some("at line 3"),
      }),
    ]),
  )
  json_inspect(sandbox.execute("throw new TypeError('boom')"), content=[
    "Err",
    {
      "error": {
        "kind": "Script",
        "name": "TypeError",
        "message": "boom",
        "stack": "at line 3",
      },
      "output": [["Text", { "text": "before", "console": false }]],
      "calls": [],
    },
  ])
}

///|
async test "execute: crash maps to sandbox error" {
  let sandbox = @codemode.CodemodeSandbox::with_launcher(
    launch=fake_launcher(messages=[
      @codemode.VmToHostMessage::Crash(message="wasm trap"),
    ]),
  )
  json_inspect(sandbox.execute("crash"), content=[
    "Err",
    {
      "error": { "kind": "Sandbox", "message": "wasm trap" },
      "output": [],
      "calls": [],
    },
  ])
}

///|
async test "execute: launcher raise maps to sandbox error" {
  let sandbox = @codemode.CodemodeSandbox::with_launcher(launch=async fn(
    _data,
    _events,
  ) {
    @async.pause()
    fail("no wasm")
  })
  json_inspect(sandbox.execute("anything"), content=[
    "Err",
    {
      "error": { "kind": "Sandbox", "message": "no wasm" },
      "output": [],
      "calls": [],
    },
  ])
}

///|
async test "execute: transport failure maps to sandbox error" {
  let launch : @codemode.VmLauncher = async fn(_data, events) {
    @async.pause()
    events.failure({
      kind: @codemode.CodemodeErrorKind::Sandbox,
      name: None,
      message: "worker exited",
      stack: None,
    })
    FakeChannel::{ events, sent: [], stopped: false, }
  }
  let sandbox = @codemode.CodemodeSandbox::with_launcher(launch~)
  json_inspect(sandbox.execute("x"), content=[
    "Err",
    {
      "error": { "kind": "Sandbox", "message": "worker exited" },
      "output": [],
      "calls": [],
    },
  ])
}

///|
async test "execute: timeout stops the vm and reports Timeout" {
  let channel : Ref[FakeChannel?] = Ref(None)
  let sandbox = @codemode.CodemodeSandbox::with_launcher(
    launch=fake_launcher(channel~),
    timeout_ms=50,
  )
  json_inspect(sandbox.execute("while(true){}"), content=[
    "Err",
    {
      "error": {
        "kind": "Timeout",
        "message": "Execution timed out after 50 ms",
      },
      "output": [],
      "calls": [],
    },
  ])
  guard channel.val is Some(fake) else { abort("no channel") }
  assert_true(fake.stopped)
}

///|
async test "execute: pre-aborted signal reports Aborted" {
  let controller = @agent_loop.AbortController::new()
  controller.abort()
  let channel : Ref[FakeChannel?] = Ref(None)
  let sandbox = @codemode.CodemodeSandbox::with_launcher(
    launch=fake_launcher(channel~),
  )
  json_inspect(sandbox.execute("x", abort=controller.signal()), content=[
    "Err",
    {
      "error": { "kind": "Aborted", "message": "Execution aborted" },
      "output": [],
      "calls": [],
    },
  ])
}

///|
async test "execute: tool call round trip, reply payload, call record" {
  let channel : Ref[FakeChannel?] = Ref(None)
  let launch : @codemode.VmLauncher = async fn(_data, events) {
    @async.pause()
    let fake = FakeChannel::{ events, sent: [], stopped: false, }
    channel.val = Some(fake)
    events.message(
      @codemode.VmToHostMessage::Call(
        id=7,
        target=@codemode.CodemodeCallTarget::Tool,
        name="echo",
        args=Some(({ "x": 1 } : Json)),
      ),
    )
    fake
  }
  let seen_args : Ref[Json?] = Ref(None)
  let sandbox = @codemode.CodemodeSandbox::with_launcher(launch~, tools=[
    @codemode.CodemodeTool::new(name="echo", execute=async fn(args, _ctx) {
      @async.pause()
      seen_args.val = args
      args
    }),
  ])
  @async.with_task_group(async fn(group) {
    let task = group.spawn(async fn() { sandbox.execute("call echo") })
    while !(channel.val is Some(fake) && fake.sent.length() > 0) {
      @async.sleep(1)
    }
    guard channel.val is Some(fake) else { abort("no channel") }
    // host 应答形如 pi 的 settle(id, ok, payload)
    json_inspect(fake.sent, content=[
      ["Result", { "id": 7, "ok": true, "payload": "{\"x\":1}" }],
    ])
    fake.events.message(
      @codemode.VmToHostMessage::Done(value=None, store_writes=done_writes()),
    )
    let result = task.wait()
    assert_true(seen_args.val is Some(_))
    json_inspect(scrub_durations(result), content=[
      "Ok",
      {
        "output": [],
        "calls": [{ "name": "echo", "status": "Ok", "duration_ms": 0 }],
        "store_writes": { "set": {}, "delete": [] },
      },
    ])
  })
}

///|
async test "execute: unknown tool replies with error and records Error" {
  let channel : Ref[FakeChannel?] = Ref(None)
  let launch : @codemode.VmLauncher = async fn(_data, events) {
    @async.pause()
    let fake = FakeChannel::{ events, sent: [], stopped: false, }
    channel.val = Some(fake)
    events.message(
      @codemode.VmToHostMessage::Call(
        id=1,
        target=@codemode.CodemodeCallTarget::Tool,
        name="missing",
        args=None,
      ),
    )
    fake
  }
  let sandbox = @codemode.CodemodeSandbox::with_launcher(launch~)
  @async.with_task_group(async fn(group) {
    let task = group.spawn(async fn() { sandbox.execute("call missing") })
    while !(channel.val is Some(fake) && fake.sent.length() > 0) {
      @async.sleep(1)
    }
    guard channel.val is Some(fake) else { abort("no channel") }
    json_inspect(fake.sent, content=[
      [
        "Result",
        { "id": 1, "ok": false, "payload": "Unknown tool \"missing\"" },
      ],
    ])
    fake.events.message(
      @codemode.VmToHostMessage::Done(value=None, store_writes=done_writes()),
    )
    json_inspect(scrub_durations(task.wait()), content=[
      "Ok",
      {
        "output": [],
        "calls": [{ "name": "missing", "status": "Error", "duration_ms": 0 }],
        "store_writes": { "set": {}, "delete": [] },
      },
    ])
  })
}

///|
async test "execute: global call resolves without a call record" {
  let channel : Ref[FakeChannel?] = Ref(None)
  let launch : @codemode.VmLauncher = async fn(_data, events) {
    @async.pause()
    let fake = FakeChannel::{ events, sent: [], stopped: false, }
    channel.val = Some(fake)
    events.message(
      @codemode.VmToHostMessage::Call(
        id=1,
        target=@codemode.CodemodeCallTarget::Global,
        name="attach",
        args=Some(Json("a")),
      ),
    )
    fake
  }
  let sandbox = @codemode.CodemodeSandbox::with_launcher(launch~, globals=[
    @codemode.CodemodeTool::new(name="attach", execute=echo_execute),
  ])
  @async.with_task_group(async fn(group) {
    let task = group.spawn(async fn() { sandbox.execute("attach") })
    while !(channel.val is Some(fake) && fake.sent.length() > 0) {
      @async.sleep(1)
    }
    guard channel.val is Some(fake) else { abort("no channel") }
    json_inspect(fake.sent, content=[
      ["Result", { "id": 1, "ok": true, "payload": "\"a\"" }],
    ])
    fake.events.message(
      @codemode.VmToHostMessage::Done(value=None, store_writes=done_writes()),
    )
    json_inspect(task.wait(), content=[
      "Ok",
      { "output": [], "calls": [], "store_writes": { "set": {}, "delete": [] } },
    ])
  })
}

///|
async test "execute: script error cancels a pending tool call" {
  let channel : Ref[FakeChannel?] = Ref(None)
  let tool_started : Ref[Bool] = Ref(false)
  let launch : @codemode.VmLauncher = async fn(_data, events) {
    @async.pause()
    let fake = FakeChannel::{ events, sent: [], stopped: false, }
    channel.val = Some(fake)
    events.message(
      @codemode.VmToHostMessage::Call(
        id=1,
        target=@codemode.CodemodeCallTarget::Tool,
        name="slow",
        args=None,
      ),
    )
    fake
  }
  let sandbox = @codemode.CodemodeSandbox::with_launcher(launch~, tools=[
    @codemode.CodemodeTool::new(name="slow", execute=async fn(_args, _ctx) {
      tool_started.val = true
      @async.sleep(60_000)
      None
    }),
  ])
  @async.with_task_group(async fn(group) {
    let task = group.spawn(async fn() { sandbox.execute("x") })
    while !tool_started.val {
      @async.sleep(1)
    }
    guard channel.val is Some(fake) else { abort("no channel") }
    fake.events.message(
      @codemode.VmToHostMessage::ScriptError(error={
        kind: @codemode.CodemodeErrorKind::Script,
        name: None,
        message: "died",
        stack: None,
      }),
    )
    json_inspect(scrub_durations(task.wait()), content=[
      "Err",
      {
        "error": { "kind": "Script", "message": "died" },
        "output": [],
        "calls": [{ "name": "slow", "status": "Cancelled", "duration_ms": 0 }],
      },
    ])
    assert_true(fake.stopped)
  })
}

///|
async test "close: aborts in-flight executions and rejects new ones" {
  let channel : Ref[FakeChannel?] = Ref(None)
  let sandbox = @codemode.CodemodeSandbox::with_launcher(
    launch=fake_launcher(channel~),
  )
  @async.with_task_group(async fn(group) {
    let task = group.spawn(async fn() { sandbox.execute("hang") })
    while !(channel.val is Some(_)) {
      @async.sleep(1)
    }
    sandbox.close()
    json_inspect(task.wait(), content=[
      "Err",
      {
        "error": { "kind": "Aborted", "message": "Execution aborted" },
        "output": [],
        "calls": [],
      },
    ])
  })
  let message = try {
    ignore(sandbox.execute("late"))
    abort("expected failure")
  } catch {
    @codemode.CodemodeSandboxError(message) => message
    error => error.to_string()
  }
  inspect(
    message,
    content=(
      #|Sandbox is closed
    ),
  )
}

///|
async test "execute: duplicate call id breaks the bridge" {
  let sandbox = @codemode.CodemodeSandbox::with_launcher(
    launch=fake_launcher(messages=[
      @codemode.VmToHostMessage::Call(
        id=1,
        target=@codemode.CodemodeCallTarget::Tool,
        name="a",
        args=None,
      ),
      @codemode.VmToHostMessage::Call(
        id=1,
        target=@codemode.CodemodeCallTarget::Tool,
        name="b",
        args=None,
      ),
    ]),
    tools=[@codemode.CodemodeTool::new(name="a", execute=echo_execute)],
  )
  json_inspect(sandbox.execute("x"), content=[
    "Err",
    {
      "error": {
        "kind": "Sandbox",
        "message": "Sandbox host failed: duplicate call id 1",
      },
      "output": [],
      "calls": [{ "name": "a", "status": "Cancelled", "duration_ms": 0 }],
    },
  ])
}

///|
async test "execute: messages after a terminal event are ignored" {
  let launch : @codemode.VmLauncher = async fn(_data, events) {
    @async.pause()
    let fake = FakeChannel::{ events, sent: [], stopped: false, }
    events.message(
      @codemode.VmToHostMessage::Done(
        value=Some(Json("early")),
        store_writes=done_writes(),
      ),
    )
    // 终态后的消息必须被吞掉而不是破坏结果
    events.message(
      @codemode.VmToHostMessage::Output(
        @codemode.CodemodeOutputItem::Text(text="late", console=false),
      ),
    )
    events.message(@codemode.VmToHostMessage::Crash(message="late crash"))
    fake
  }
  let sandbox = @codemode.CodemodeSandbox::with_launcher(launch~)
  json_inspect(sandbox.execute("x"), content=[
    "Ok",
    {
      "value": "early",
      "output": [],
      "calls": [],
      "store_writes": { "set": {}, "delete": [] },
    },
  ])
}
