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
  mut closed : Bool
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
  self.closed = true
  self.inbox.close()
}

///|
fn BlockingChannel::BlockingChannel() -> BlockingChannel {
  { sent: [], inbox: @aqueue.Queue(kind=@aqueue.Unbounded), closed: false, }
}

///|
async test "cancelling execution propagates and closes the vm" {
  let channel = BlockingChannel::BlockingChannel()
  let started : @aqueue.Queue[Unit] = @aqueue.Queue(kind=@aqueue.Unbounded)
  let codemode = @codemode.Codemode::Codemode(
    async fn() -> &@codemode.VmServer {
      started.put(())
      channel
    },
    timeout_ms=0,
  )
  @async.with_task_group(group => {
    let task = group.spawn(() => {
      @async.handle_cancellation(() => codemode.execute("x"))
    })
    started.get()
    task.cancel()
    assert_true(task.wait() is None)
  })
  assert_true(channel.closed)
}

///|
/// Script completion cancels unfinished calls and waits for protected cleanup.
async test "a call in flight when the script ends is cancelled and cleaned up" {
  let channel = BlockingChannel::BlockingChannel()
  let started : @aqueue.Queue[Unit] = @aqueue.Queue(kind=@aqueue.Unbounded)
  let never : @aqueue.Queue[Unit] = @aqueue.Queue(kind=@aqueue.Unbounded)
  let cleaned = Ref(false)
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
        execute: (_args : Json?) => {
          defer @async.protect_from_cancel(() => {
            @async.pause()
            cleaned.val = true
          })
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
  assert_true(cleaned.val)
  assert_true(channel.closed)
}

///|
async test "every execution exit cancels tools and globals before returning" {
  for ending in ["done", "script-error", "eof", "timeout", "cancel"] {
    let channel = BlockingChannel::BlockingChannel()
    let started : @aqueue.Queue[Unit] = @aqueue.Queue(kind=@aqueue.Unbounded)
    let never : @aqueue.Queue[Unit] = @aqueue.Queue(kind=@aqueue.Unbounded)
    let cleaned = Ref(0)
    let wait : @codemode.CodemodeTool = {
      name: "wait",
      js_name: None,
      description: "",
      input_schema: None,
      output_schema: None,
      spread: false,
      signature: None,
      execute: _ => {
        defer @async.protect_from_cancel(() => {
          @async.pause()
          cleaned.val += 1
        })
        started.put(())
        never.get()
        Json::null()
      },
    }
    let codemode = @codemode.Codemode::Codemode(
      fn() -> &@codemode.VmServer { channel },
      tools=[wait],
      globals=[wait],
      timeout_ms=if ending == "timeout" { 100 } else { 0 },
    )
    channel.inbox.put({
      "type": "output",
      "item": { "type": "text", "text": "partial" },
    })
    channel.inbox.put({
      "type": "call",
      "target": "tool",
      "id": 1,
      "name": "wait",
    })
    channel.inbox.put({
      "type": "call",
      "target": "global",
      "id": 2,
      "name": "wait",
    })
    @async.with_timeout(3000, () => {
      @async.with_task_group(group => {
        let task = group.spawn(() => {
          @async.handle_cancellation(() => codemode.execute("x"))
        })
        started.get()
        started.get()
        match ending {
          "done" =>
            channel.inbox.put({ "type": "done", "ok": true, "writes": "[]" })
          "script-error" =>
            channel.inbox.put({
              "type": "done",
              "ok": false,
              "error": "{\"message\":\"boom\"}",
            })
          "eof" => channel.inbox.close()
          "cancel" => task.cancel()
          _ => ()
        }
        let result = task.wait()
        assert_eq(cleaned.val, 2)
        assert_true(channel.closed)
        assert_eq(channel.sent.length(), 1)
        match (ending, result) {
          ("cancel", None) => ()
          (
            "done",
            Some(
              Ok(
                calls=[{ status: "cancelled", .. }],
                output=[Text(text="partial", ..)],
                ..
              )
            ),
          ) => ()
          ("script-error", Some(Err(error={ kind: Script, .. }, ..))) => ()
          ("eof", Some(Err(error={ kind: Sandbox, .. }, ..))) => ()
          (
            "timeout",
            Some(
              Err(
                error={ kind: Timeout, .. },
                calls=[{ status: "cancelled", .. }],
                output=[Text(text="partial", ..)],
                ..
              )
            ),
          ) => ()
          _ => fail("unexpected result for \{ending}")
        }
      })
    })
  }
}

///|
async test "launch obeys both external cancellation and the execution deadline" {
  for timed_out in [false, true] {
    let started : @aqueue.Queue[Unit] = @aqueue.Queue(kind=@aqueue.Unbounded)
    let never : @aqueue.Queue[Unit] = @aqueue.Queue(kind=@aqueue.Unbounded)
    let cleaned = Ref(false)
    let codemode = @codemode.Codemode::Codemode(
      async fn() -> &@codemode.VmServer {
        defer {
          cleaned.val = true
        }
        started.put(())
        never.get()
        fail("unreachable")
      },
      timeout_ms=if timed_out { 30 } else { 0 },
    )
    @async.with_timeout(3000, () => {
      @async.with_task_group(group => {
        let task = group.spawn(() => {
          @async.handle_cancellation(() => codemode.execute("x"))
        })
        started.get()
        if !timed_out {
          task.cancel()
        }
        let result = task.wait()
        assert_true(cleaned.val)
        if timed_out {
          assert_true(result is Some(Err(error={ kind: Timeout, .. }, ..)))
        } else {
          assert_true(result is None)
        }
      })
    })
  }
}

///|
async test "ordinary cleanup errors propagate instead of becoming cancellation or timeout" {
  for timed_out in [false, true] {
    let channel = BlockingChannel::BlockingChannel()
    let started : @aqueue.Queue[Unit] = @aqueue.Queue(kind=@aqueue.Unbounded)
    let never : @aqueue.Queue[Unit] = @aqueue.Queue(kind=@aqueue.Unbounded)
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
          execute: _ => {
            defer @async.protect_from_cancel(() => {
              @async.pause()
              fail("cleanup failed")
            })
            started.put(())
            never.get()
            Json::null()
          },
        },
      ],
      timeout_ms=if timed_out { 100 } else { 0 },
    )
    channel.inbox.put({
      "type": "call",
      "target": "tool",
      "id": 1,
      "name": "wait",
    })
    let failure = @async.with_timeout(3000, () => {
      @async.with_task_group(group => {
        let task = group.spawn(allow_failure=true, () => {
          @async.handle_cancellation(() => codemode.execute("x"))
        })
        started.get()
        if !timed_out {
          task.cancel()
        }
        let error = try {
          ignore(task.wait())
          None
        } catch {
          error => Some(error.to_string())
        }
        error
      })
    })
    assert_true(failure is Some(text) && text.contains("cleanup failed"))
    assert_true(channel.closed)
  }
}

///|
priv struct StalledSend {
  entered : @aqueue.Queue[Unit]
  never : @aqueue.Queue[Unit]
  mut closed : Bool
}

///|
impl @codemode.VmServer for StalledSend with fn send(
  self : StalledSend,
  _ : Json,
) -> Unit {
  self.entered.put(())
  self.never.get()
}

///|
impl @codemode.VmServer for StalledSend with fn recv(_ : StalledSend) -> Json {
  fail("unreachable")
}

///|
impl @codemode.VmServer for StalledSend with fn close(self : StalledSend) -> Unit {
  self.closed = true
}

///|
async test "a blocked start send remains cancellable and obeys the deadline" {
  for timed_out in [false, true] {
    let vm = StalledSend::{
      entered: @aqueue.Queue(kind=@aqueue.Unbounded),
      never: @aqueue.Queue(kind=@aqueue.Unbounded),
      closed: false,
    }
    let codemode = @codemode.Codemode::Codemode(
      fn() -> &@codemode.VmServer { vm },
      timeout_ms=if timed_out { 30 } else { 0 },
    )
    @async.with_timeout(3000, () => {
      @async.with_task_group(group => {
        let task = group.spawn(() => {
          @async.handle_cancellation(() => codemode.execute("x"))
        })
        vm.entered.get()
        if !timed_out {
          task.cancel()
        }
        let result = task.wait()
        assert_true(vm.closed)
        if timed_out {
          assert_true(result is Some(Err(error={ kind: Timeout, .. }, ..)))
        } else {
          assert_true(result is None)
        }
      })
    })
  }
}
