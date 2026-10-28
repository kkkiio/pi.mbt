///|
/// A scripted stand-in for the remote frame channel: feeds queued frames
/// on `recv` (each one a message or a batch array) and captures `send`s.
priv struct FakeChannel {
  feed : Array[Json]
  sent : Array[Json]
}

///|
impl @codemode.VmServer for FakeChannel with fn send(
  self : FakeChannel,
  data : Json,
) -> Unit {
  self.sent.push(data)
}

///|
impl @codemode.VmServer for FakeChannel with fn recv(self : FakeChannel) -> Json {
  if self.feed is [] {
    fail("channel closed")
  } else {
    self.feed.remove(0)
  }
}

///|
impl @codemode.VmServer for FakeChannel with fn close(self : FakeChannel) -> Unit {
  self.feed.clear()
}

///|
fn FakeChannel::FakeChannel(feed : Array[Json]) -> FakeChannel {
  FakeChannel::{ feed, sent: [], }
}

///|
/// A batch — one `Json::Array` frame — feeds its messages to the execution
/// loop one by one, so `output` and `call` still arrive in order.
async test "a batch frame feeds its messages in order" {
  let channel = FakeChannel([
    [
      { "type": "output", "item": { "type": "text", "text": "a" } },
      { "type": "output", "item": { "type": "text", "text": "b" } },
      { "type": "done", "ok": true, "writes": "[]" },
    ],
  ])
  let codemode = @codemode.Codemode::Codemode(
    fn() -> &@codemode.VmServer { channel },
    timeout_ms=0,
  )
  guard codemode.execute("x")
    is @codemode.CodemodeResult::Ok(
      value=None,
      output=[
        @codemode.CodemodeOutputItem::Text(text="a", ..),
        @codemode.CodemodeOutputItem::Text(text="b", ..),
      ],
      ..
    ) else {
    fail("unexpected result")
  }
}

///|
/// A stream that ends before a terminal frame is a sandbox failure.
async test "eof before a terminal frame is a sandbox error" {
  let channel = FakeChannel([])
  let codemode = @codemode.Codemode::Codemode(
    fn() -> &@codemode.VmServer { channel },
    timeout_ms=0,
  )
  guard codemode.execute("x")
    is @codemode.CodemodeResult::Err(
      error={ kind: @codemode.CodemodeErrorKind::Sandbox, .. },
      ..
    ) else {
    fail("unexpected result")
  }
}

///|
/// A `@codemode.VmServer` whose `recv` blocks until `inbox` gets a frame or
/// `close` releases it — how `stop`/abort reach the loop. `send` is captured.
priv struct BlockingChannel {
  sent : Array[Json]
  inbox : @aqueue.Queue[Json]
}

///|
impl @codemode.VmServer for BlockingChannel with fn send(
  self : BlockingChannel,
  data : Json,
) -> Unit {
  self.sent.push(data)
}

///|
impl @codemode.VmServer for BlockingChannel with fn recv(self : BlockingChannel) -> Json {
  self.inbox.get()
}

///|
impl @codemode.VmServer for BlockingChannel with fn close(
  self : BlockingChannel,
) -> Unit {
  self.inbox.close()
}

///|
fn BlockingChannel::BlockingChannel() -> BlockingChannel {
  { sent: [], inbox: @aqueue.Queue(kind=@aqueue.Unbounded), }
}

///|
/// `abort` 触发后:先给 VM 发 stop 再关流,执行以 `Aborted` 错误结束。
async test "abort stops the vm and ends the execution" {
  let channel = BlockingChannel::BlockingChannel()
  let codemode = @codemode.Codemode::Codemode(
    fn() -> &@codemode.VmServer { channel },
    timeout_ms=0,
  )
  let controller = @agent_loop.AbortController::new()
  let result = @async.with_task_group(group => {
    group.spawn_bg(() => {
      @async.sleep(20)
      controller.abort()
    })
    codemode.execute("x", abort=controller.signal())
  })
  guard result
    is @codemode.CodemodeResult::Err(
      error={ kind: @codemode.CodemodeErrorKind::Aborted, message, .. },
      ..
    ) else {
    fail("unexpected result")
  }
  assert_eq(message, "Execution aborted")
  // 首个 send 是 StartVmRequest,其后是 stop。
  assert_true(channel.sent.iter().any(frame => frame is { "type": "stop", .. }))
}

///|
/// 脚本结束时仍在运行的调用(pi `finish()` 的行为):它的 per-call signal
/// 被 abort,`calls` 台账行保持 cancelled 并记下时长。
async test "a call in flight when the script ends sees its signal aborted" {
  let channel = BlockingChannel::BlockingChannel()
  let started : @aqueue.Queue[Unit] = @aqueue.Queue(kind=@aqueue.Unbounded)
  let never : @aqueue.Queue[Unit] = @aqueue.Queue(kind=@aqueue.Unbounded)
  let signal_seen : Ref[@agent_loop.AbortSignal?] = Ref(None)
  let codemode = @codemode.Codemode::Codemode(
    fn() -> &@codemode.VmServer { channel },
    tools=[
      {
        name: "wait",
        js_name: None,
        description: "",
        input_schema: None,
        output_schema: None,
        spread: false,
        signature: None,
        execute: (_args : Json?, ctx : @codemode.CodemodeToolContext) => {
          signal_seen.val = Some(ctx.signal)
          started.put(())
          never.get()
          Json::null()
        },
      },
    ],
    timeout_ms=0,
  )
  channel.inbox.put({
    "type": "call",
    "id": 7,
    "target": "tool",
    "name": "wait",
    "args": "{}",
  })
  let result = @async.with_task_group(group => {
    group.spawn_bg(() => {
      started.get()
      channel.inbox.put({ "type": "done", "ok": true, "writes": "[]" })
    })
    codemode.execute("x")
  })
  guard result is @codemode.CodemodeResult::Ok(calls=[call], ..) else {
    fail("unexpected result")
  }
  assert_eq(call.name, "wait")
  assert_eq(call.status, "cancelled")
  guard signal_seen.val is Some(signal) else {
    fail("the tool never saw its context")
  }
  assert_true(signal.is_aborted())
}
