///|
fn empty_deepseek_context(
  system_prompt? : String = "fixture prompt",
) -> @agent_loop.Context {
  { system_prompt, messages: [], tools: [], }
}

///|
let responses_sse_prefix =
  #|event: response.created
  #|data: {"type":"response.created","response":{"id":"resp_1","status":"in_progress","output":[],"usage":null}}
  #|
  #|event: response.in_progress
  #|data: {"type":"response.in_progress","response":{"id":"resp_1","status":"in_progress","output":[],"usage":null}}
  #|
  #|event: response.output_item.added
  #|data: {"type":"response.output_item.added","output_index":0,"item":{"id":"msg_1","type":"message","status":"in_progress","role":"assistant","content":[]}}
  #|
  #|event: response.content_part.added
  #|data: {"type":"response.content_part.added","item_id":"msg_1","output_index":0,"content_index":0,"part":{"type":"output_text","text":"","annotations":[]}}
  #|
  #|event: response.output_text.delta
  #|data: {"type":"response.output_text.delta","item_id":"msg_1","output_index":0,"content_index":0,"delta":"fixture answer"}
  #|
  #|

///|
let responses_sse_terminal =
  #|event: response.output_text.done
  #|data: {"type":"response.output_text.done","item_id":"msg_1","output_index":0,"content_index":0,"text":"fixture answer"}
  #|
  #|event: response.content_part.done
  #|data: {"type":"response.content_part.done","item_id":"msg_1","output_index":0,"content_index":0,"part":{"type":"output_text","text":"fixture answer","annotations":[]}}
  #|
  #|event: response.output_item.done
  #|data: {"type":"response.output_item.done","output_index":0,"item":{"id":"msg_1","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"fixture answer","annotations":[]}]}}
  #|
  #|event: response.completed
  #|data: {"type":"response.completed","response":{"id":"resp_1","status":"completed","output":[{"id":"msg_1","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"fixture answer","annotations":[]}]}],"usage":{"input_tokens":19,"input_tokens_details":{"cached_tokens":7,"cache_write_tokens":3},"output_tokens":5,"output_tokens_details":{"reasoning_tokens":2},"total_tokens":24}}}
  #|
  #|

///|
async test "max_retries zero sends one Responses request with configured limits" {
  @async.with_task_group() <| group => {
    let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
    group.add_defer(() => server.close())
    let requests : Array[String] = []
    group.spawn_bg(no_wait=true) <| () => {
      server.run_forever() <| ((request, body, conn) => {
        requests.push("\{request.path}|\{body.read_all().text()}")
        conn.send_response(429, "Too Many Requests")
        conn..write("rate limited").end_response()
      })
    }
    let llm = @providers.DeepSeekResponsesAPILLM(
      "fixture-key",
      model_id="fixture-model",
      thinking="none",
      base_url="http://127.0.0.1:\{server.addr.port()}",
      max_retries=0,
      max_output_tokens=Some(321),
    )
    let failed = try {
      ignore(
        llm.generate(
          empty_deepseek_context(),
          sink=_ => fail("429 emitted an event"),
          abort=@agent_loop.AbortController::new().signal(),
        ),
      )
      false
    } catch {
      _ => true
    }
    assert_true(failed)
    assert_eq(requests.length(), 1)
    let request = requests[0]
    assert_true(request.contains("/v1/responses|"))
    assert_true(request.contains("\"reasoning\":{\"effort\":\"none\"}"))
    assert_true(request.contains("\"max_output_tokens\":321"))
  }
}

///|
async test "complete Responses SSE streams before completion and reports token splits" {
  @async.with_task_group() <| group => {
    let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
    group.add_defer(() => server.close())
    let release_terminal = [false]
    let delta_arrived_early = [false]
    group.spawn_bg(no_wait=true) <| () => {
      server.run_forever() <| ((_, body, conn) => {
        body.read_all() |> ignore
        conn.send_response(200, "OK", extra_headers={
          "Content-Type": "text/event-stream",
        })
        conn..write(responses_sse_prefix).flush()
        @async.with_timeout(3000, () => {
          while !release_terminal[0] {
            @async.sleep(10)
          }
        })
        conn.write(responses_sse_terminal)
        conn.end_response()
      })
    }
    let llm = @providers.DeepSeekResponsesAPILLM(
      "fixture-key",
      base_url="http://127.0.0.1:\{server.addr.port()}",
      max_retries=0,
    )
    let result = llm.generate(
      empty_deepseek_context(),
      sink=event => {
        if event is TextDelta(delta="fixture answer", ..) {
          delta_arrived_early[0] = true
          release_terminal[0] = true
        }
      },
      abort=@agent_loop.AbortController::new().signal(),
    )
    assert_true(delta_arrived_early[0])
    assert_true(result.stop_reason is Stop)
    guard result.usage is Some(usage) else { fail("missing response usage") }
    assert_eq(usage.input, 9)
    assert_eq(usage.cache_read, 7)
    assert_eq(usage.cache_write, 3)
    assert_eq(usage.output, 5)
    assert_eq(usage.reasoning, Some(2))
  }
}

///|
async test "oversize input is rejected without HTTP" {
  @async.with_task_group() <| group => {
    let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
    group.add_defer(() => server.close())
    let requests = [0]
    group.spawn_bg(no_wait=true) <| () => {
      server.run_forever() <| ((_, body, conn) => {
        requests[0] = requests[0] + 1
        body.read_all() |> ignore
        conn.send_response(500, "unexpected request")
        conn.end_response()
      })
    }
    let llm = @providers.DeepSeekResponsesAPILLM(
      "fixture-key",
      base_url="http://127.0.0.1:\{server.addr.port()}",
      max_retries=0,
      max_input_chars=Some(10),
    )
    let failed = try {
      ignore(
        llm.generate(
          empty_deepseek_context(system_prompt="far longer than ten characters"),
          sink=_ => fail("oversize input emitted an event"),
          abort=@agent_loop.AbortController::new().signal(),
        ),
      )
      false
    } catch {
      _ => true
    }
    assert_true(failed)
    @async.sleep(50)
    assert_eq(requests[0], 0)
  }
}

///|
async test "sink failure stops the HTTP stream promptly" {
  @async.with_task_group() <| group => {
    let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
    group.add_defer(() => server.close())
    let terminal_sent = [false]
    group.spawn_bg(no_wait=true) <| () => {
      server.run_forever() <| ((_, body, conn) => {
        body.read_all() |> ignore
        conn.send_response(200, "OK", extra_headers={
          "Content-Type": "text/event-stream",
        })
        conn.write(responses_sse_prefix)
        conn.flush()
        @async.sleep(2000)
        terminal_sent[0] = true
        conn.write(responses_sse_prefix)
        conn.write(responses_sse_terminal)
        conn.end_response()
      })
    }
    let llm = @providers.DeepSeekResponsesAPILLM(
      "fixture-key",
      base_url="http://127.0.0.1:\{server.addr.port()}",
      max_retries=0,
    )
    let emitted = [0]
    let failed = @async.with_timeout(1000, () => {
      try {
        ignore(
          llm.generate(
            empty_deepseek_context(),
            sink=_ => {
              emitted[0] = emitted[0] + 1
              fail("consumer stopped")
            },
            abort=@agent_loop.AbortController::new().signal(),
          ),
        )
        false
      } catch {
        _ => true
      }
    })
    assert_true(failed)
    assert_eq(emitted[0], 1)
    assert_false(terminal_sent[0])
  }
}
