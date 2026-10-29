///|
/// In-process fake of `serveCodemodeRemote`: reads `{ stream_id, data }`
/// frames and answers each stream independently. Frames for two streams
/// interleave on one socket; each reply lands in its own stream queue.
/// Closing the connection fails pending `recv`.
async test "ws streams demultiplex frames and end on connection close" {
  @async.with_task_group(group => {
    let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
    let port = server.addr.port()
    group.spawn_bg(() => {
      defer server.close()
      let (conn, _) = server.accept()
      defer conn.close()
      let request = conn.read_request()
      let ws = @websocket.Conn::from_http_server(request, conn)
      defer ws.close()
      // Hold the first frame until the second arrives, then answer in
      // reverse order: replies must land in the right stream queue.
      let frames : Array[Json] = []
      while frames.length() < 2 {
        let msg = ws.recv() catch { _ => break }
        frames.push(@json.parse(msg.read_all().text()))
      }
      for i = frames.length() - 1; i >= 0; i = i - 1 {
        guard frames[i] is { "stream_id": id, "data": data, .. } else {
          fail("bad frame")
        }
        ws.send_text(
          ({ "stream_id": id, "data": [{ "echo": data }] } : Json).stringify(),
        )
      }
    })
    let (echo1, echo2, end) = @ask_agent.with_ws_streams(
      url="ws://127.0.0.1:\{port}",
      streams => {
        let s1 = streams.new_stream()
        let s2 = streams.new_stream()
        s1.send({ "n": 1 })
        s2.send({ "n": 2 })
        let echo2 = s2.recv()
        let echo1 = s1.recv()
        s1.close()
        s1.close()
        // Never used: fails when the server closes the connection.
        let s3 = streams.new_stream()
        let end = try {
          ignore(s3.recv())
          false
        } catch {
          _ => true
        }
        (echo1, echo2, end)
      },
    )
    assert_eq(echo1, [{ "echo": { "n": 1 } }])
    assert_eq(echo2, [{ "echo": { "n": 2 } }])
    assert_true(end)
  })
}

///|
/// A full `Codemode::execute` over a `WsStream`: the request frame starts
/// the script, one message batch settles it with `done`, then the stream closes.
async test "execute codemode over a ws stream" {
  @async.with_task_group(group => {
    let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
    let port = server.addr.port()
    group.spawn_bg(() => {
      defer server.close()
      let (conn, _) = server.accept()
      defer conn.close()
      let request = conn.read_request()
      let ws = @websocket.Conn::from_http_server(request, conn)
      defer ws.close()
      try {
        while true {
          let msg = ws.recv()
          let frame = @json.parse(msg.read_all().text())
          if frame is { "close": True, .. } {
            continue
          }
          guard frame is { "stream_id": id, "data": data, .. } else {
            fail("bad frame")
          }
          if data is { "type": "result", .. } {
            continue
          }
          ws.send_text(
            (
              {
                "stream_id": id,
                "data": [
                  { "type": "done", "ok": true, "value": "42", "writes": "[]" },
                ],
              } : Json).stringify(),
          )
          ws.send_text(({ "stream_id": id, "close": true } : Json).stringify())
        }
      } catch {
        _ => ()
      }
    })
    let result = @ask_agent.with_ws_streams(url="ws://127.0.0.1:\{port}", streams => {
      let codemode = @codemode.Codemode::Codemode(
        fn() -> &@codemode.VmChannel { streams.new_stream() },
        tools=[],
        timeout_ms=0,
      )
      codemode.execute("return 42")
    })
    guard result is @codemode.CodemodeResult::Ok(value=Some(Number(42, ..)), ..) else {
      fail("unexpected codemode result")
    }
  })
}

///|
async test "websocket stream cancellation retains close behind a full send queue" {
  @async.with_timeout(3000, () => {
    @async.with_task_group(group => {
      let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let stopped : @aqueue.Queue[Unit] = @aqueue.Queue(kind=@aqueue.Unbounded)
      group.spawn_bg(no_wait=true, () => {
        let (conn, _) = server.accept()
        defer conn.close()
        let request = conn.read_request()
        let ws = @websocket.Conn::from_http_server(request, conn)
        defer ws.close()
        for i in 0..<11 {
          let msg = ws.recv()
          let frame = @json.parse(msg.read_all().text())
          if i < 10 {
            assert_true(
              frame is { "data": { "n": Number(n, ..), .. }, .. } &&
              n == i.to_double(),
            )
          } else {
            assert_true(
              frame is { "stream_id": Number(1, ..), "close": True, .. },
            )
          }
        }
        stopped.put(())
        @async.sleep(10000)
      })
      let streams = @ask_agent.WsStreams::connect(
        url="ws://127.0.0.1:\{server.addr.port()}",
      )
      defer streams.close()
      let stream = streams.new_stream()
      for i in 0..<10 {
        stream.send({ "n": i })
      }
      let entered : @aqueue.Queue[Unit] = @aqueue.Queue(kind=@aqueue.Unbounded)
      let task = group.spawn(() => {
        @async.handle_cancellation(() => {
          defer stream.close()
          entered.put(())
          stream.send({ "n": 10 })
        })
      })
      entered.get()
      task.cancel()
      assert_true(task.wait() is None)
      stream.close()
      group.spawn_bg(no_wait=true, () => streams.run())
      stopped.get()
      let next = streams.new_stream()
      next.send({ "n": 11 })
      next.close()
    })
  })
}

///|
async test "ws streams wrap an existing connection" {
  @async.with_task_group(group => {
    let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
    let port = server.addr.port()
    group.spawn_bg(() => {
      defer server.close()
      let (conn, _) = server.accept()
      defer conn.close()
      let request = conn.read_request()
      let ws = @websocket.Conn::from_http_server(request, conn)
      defer ws.close()
      let msg = ws.recv()
      guard @json.parse(msg.read_all().text())
        is { "stream_id": id, "data": data, .. } else {
        fail("bad frame")
      }
      ws.send_text(
        ({ "stream_id": id, "data": [{ "echo": data }] } : Json).stringify(),
      )
    })
    let ws = @websocket.Conn::connect("ws://127.0.0.1:\{port}")
    let streams = @ask_agent.WsStreams::WsStreams(ws)
    group.spawn_bg(no_wait=true, () => streams.run())
    defer streams.close()
    let stream = streams.new_stream()
    stream.send({ "n": 1 })
    assert_eq(stream.recv(), [{ "echo": { "n": 1 } }])
  })
}
