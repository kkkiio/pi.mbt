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
/// the script and one message batch settles it with `done`, followed by the
/// `exit` stream marker.
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
          guard @json.parse(msg.read_all().text())
            is { "stream_id": id, "data": data, .. } else {
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
          ws.send_text(
            ({ "stream_id": id, "data": { "type": "exit" } } : Json).stringify(),
          )
        }
      } catch {
        _ => ()
      }
    })
    let result = @ask_agent.with_ws_streams(url="ws://127.0.0.1:\{port}", streams => {
      let codemode = @codemode.Codemode::Codemode(
        fn() -> &@codemode.VmServer { streams.new_stream() },
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
