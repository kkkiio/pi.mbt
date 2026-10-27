///|
/// A scripted stand-in for the remote frame channel: feeds queued frames
/// on `recv` (each one a message or a batch array) and captures `send`s.
priv struct FakeChannel {
  feed : Array[Json]
  sent : Array[Json]
}

///|
impl @codemode.Vm for FakeChannel with fn send(self : FakeChannel, data : Json) -> Unit {
  self.sent.push(data)
}

///|
impl @codemode.Vm for FakeChannel with fn recv(self : FakeChannel) -> Json {
  if self.feed is [] {
    fail("channel closed")
  } else {
    self.feed.remove(0)
  }
}

///|
impl @codemode.Vm for FakeChannel with fn close(self : FakeChannel) -> Unit {
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
    fn() -> &@codemode.Vm { channel },
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
    fn() -> &@codemode.Vm { channel },
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
