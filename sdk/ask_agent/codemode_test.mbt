///|
async test "ask agent codemode tool runs a script over ws" {
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
      let tool = @ask_agent.new_codemode_tool_definition(streams, tools=[])
      (tool.execute)("call-1", { "code": "return 42" }, (_, _) => ())
    })
    assert_false(result.is_error)
    guard result.content is [_, @agent_loop.InputMessageContent::Text(text)] else {
      fail("unexpected content")
    }
    assert_eq(text, "42")
  })
}
