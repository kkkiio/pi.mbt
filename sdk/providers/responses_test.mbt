///|
async test "openai web-page streaming example" {
  let response =
    #| event: response.created
    #| data: {"type":"response.created","response":{"id":"resp_67c9fdcecf488190bdd9a0409de3a1ec07b8b0ad4e5eb654","object":"response","created_at":1741290958,"status":"in_progress","error":null,"incomplete_details":null,"instructions":"You are a helpful assistant.","max_output_tokens":null,"model":"gpt-5.4","output":[],"parallel_tool_calls":true,"previous_response_id":null,"reasoning":{"effort":null,"summary":null},"store":true,"temperature":1.0,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[],"top_p":1.0,"truncation":"disabled","usage":null,"user":null,"metadata":{}}}
    #| 
    #| event: response.in_progress
    #| data: {"type":"response.in_progress","response":{"id":"resp_67c9fdcecf488190bdd9a0409de3a1ec07b8b0ad4e5eb654","object":"response","created_at":1741290958,"status":"in_progress","error":null,"incomplete_details":null,"instructions":"You are a helpful assistant.","max_output_tokens":null,"model":"gpt-5.4","output":[],"parallel_tool_calls":true,"previous_response_id":null,"reasoning":{"effort":null,"summary":null},"store":true,"temperature":1.0,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[],"top_p":1.0,"truncation":"disabled","usage":null,"user":null,"metadata":{}}}
    #| 
    #| event: response.output_item.added
    #| data: {"type":"response.output_item.added","output_index":0,"item":{"id":"msg_67c9fdcf37fc8190ba82116e33fb28c507b8b0ad4e5eb654","type":"message","status":"in_progress","role":"assistant","content":[]}}
    #| 
    #| event: response.content_part.added
    #| data: {"type":"response.content_part.added","item_id":"msg_67c9fdcf37fc8190ba82116e33fb28c507b8b0ad4e5eb654","output_index":0,"content_index":0,"part":{"type":"output_text","text":"","annotations":[]}}
    #| 
    #| event: response.output_text.delta
    #| data: {"type":"response.output_text.delta","item_id":"msg_67c9fdcf37fc8190ba82116e33fb28c507b8b0ad4e5eb654","output_index":0,"content_index":0,"delta":"Hi"}
    #| 
    #| event: response.output_text.done
    #| data: {"type":"response.output_text.done","item_id":"msg_67c9fdcf37fc8190ba82116e33fb28c507b8b0ad4e5eb654","output_index":0,"content_index":0,"text":"Hi there! How can I assist you today?"}
    #| 
    #| event: response.content_part.done
    #| data: {"type":"response.content_part.done","item_id":"msg_67c9fdcf37fc8190ba82116e33fb28c507b8b0ad4e5eb654","output_index":0,"content_index":0,"part":{"type":"output_text","text":"Hi there! How can I assist you today?","annotations":[]}}
    #| 
    #| event: response.output_item.done
    #| data: {"type":"response.output_item.done","output_index":0,"item":{"id":"msg_67c9fdcf37fc8190ba82116e33fb28c507b8b0ad4e5eb654","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Hi there! How can I assist you today?","annotations":[]}]}}
    #| 
    #| event: response.completed
    #| data: {"type":"response.completed","response":{"id":"resp_67c9fdcecf488190bdd9a0409de3a1ec07b8b0ad4e5eb654","object":"response","created_at":1741290958,"status":"completed","error":null,"incomplete_details":null,"instructions":"You are a helpful assistant.","max_output_tokens":null,"model":"gpt-5.4","output":[{"id":"msg_67c9fdcf37fc8190ba82116e33fb28c507b8b0ad4e5eb654","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Hi there! How can I assist you today?","annotations":[]}]}],"parallel_tool_calls":true,"previous_response_id":null,"reasoning":{"effort":null,"summary":null},"store":true,"temperature":1.0,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[],"top_p":1.0,"truncation":"disabled","usage":{"input_tokens":37,"output_tokens":11,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":48},"user":null,"metadata":{}}}

  let messages = []
  let final_message = @providers.read_responses_sse_stream(
    @io.MemoryReader::MemoryReader() <| w => { w.write(response) },
    sink=event => messages.push(event),
    api="openai-responses",
    provider="deepseek",
    model="deepseek-v4-flash",
    now=() => 1741290958000,
  )
  debug_inspect(
    messages,
    content=(
      #|[
      #|  Start(
      #|    partial={
      #|      content: [
      #|        Text(
      #|          "Hi there! How can I assist you today?",
      #|          signature=Object(
      #|            {
      #|              "type": String("message"),
      #|              "id": String("msg_67c9fdcf37fc8190ba82116e33fb28c507b8b0ad4e5eb654"),
      #|            },
      #|          ),
      #|        ),
      #|      ],
      #|      api: "openai-responses",
      #|      provider: "deepseek",
      #|      model: "deepseek-v4-flash",
      #|      stop_reason: Pending,
      #|      error_message: None,
      #|      usage: None,
      #|      timestamp: 1741290958000,
      #|    },
      #|  ),
      #|  TextStart(
      #|    content_index=0,
      #|    partial={
      #|      content: [
      #|        Text(
      #|          "Hi there! How can I assist you today?",
      #|          signature=Object(
      #|            {
      #|              "type": String("message"),
      #|              "id": String("msg_67c9fdcf37fc8190ba82116e33fb28c507b8b0ad4e5eb654"),
      #|            },
      #|          ),
      #|        ),
      #|      ],
      #|      api: "openai-responses",
      #|      provider: "deepseek",
      #|      model: "deepseek-v4-flash",
      #|      stop_reason: Pending,
      #|      error_message: None,
      #|      usage: None,
      #|      timestamp: 1741290958000,
      #|    },
      #|  ),
      #|  TextDelta(
      #|    content_index=0,
      #|    delta="Hi",
      #|    partial={
      #|      content: [
      #|        Text(
      #|          "Hi there! How can I assist you today?",
      #|          signature=Object(
      #|            {
      #|              "type": String("message"),
      #|              "id": String("msg_67c9fdcf37fc8190ba82116e33fb28c507b8b0ad4e5eb654"),
      #|            },
      #|          ),
      #|        ),
      #|      ],
      #|      api: "openai-responses",
      #|      provider: "deepseek",
      #|      model: "deepseek-v4-flash",
      #|      stop_reason: Pending,
      #|      error_message: None,
      #|      usage: None,
      #|      timestamp: 1741290958000,
      #|    },
      #|  ),
      #|  TextEnd(
      #|    content_index=0,
      #|    content="Hi there! How can I assist you today?",
      #|    partial={
      #|      content: [
      #|        Text(
      #|          "Hi there! How can I assist you today?",
      #|          signature=Object(
      #|            {
      #|              "type": String("message"),
      #|              "id": String("msg_67c9fdcf37fc8190ba82116e33fb28c507b8b0ad4e5eb654"),
      #|            },
      #|          ),
      #|        ),
      #|      ],
      #|      api: "openai-responses",
      #|      provider: "deepseek",
      #|      model: "deepseek-v4-flash",
      #|      stop_reason: Pending,
      #|      error_message: None,
      #|      usage: None,
      #|      timestamp: 1741290958000,
      #|    },
      #|  ),
      #|]
    ),
  )
  debug_inspect(
    final_message,
    content=(
      #|{
      #|  content: [
      #|    Text(
      #|      "Hi there! How can I assist you today?",
      #|      signature=Object(
      #|        {
      #|          "type": String("message"),
      #|          "id": String("msg_67c9fdcf37fc8190ba82116e33fb28c507b8b0ad4e5eb654"),
      #|        },
      #|      ),
      #|    ),
      #|  ],
      #|  api: "openai-responses",
      #|  provider: "deepseek",
      #|  model: "deepseek-v4-flash",
      #|  stop_reason: Stop,
      #|  error_message: None,
      #|  usage: Some(
      #|    {
      #|      input: 37,
      #|      output: 11,
      #|      cache_read: 0,
      #|      cache_write: 0,
      #|      cache_write_1h: None,
      #|      reasoning: Some(0),
      #|      total_tokens: 48,
      #|      cost: { input: 0, output: 0, cache_read: 0, cache_write: 0, total: 0 },
      #|    },
      #|  ),
      #|  timestamp: 1741290958000,
      #|}
    ),
  )
}

///|
/// 中断要及时:模型停止发送数据(流停滞)时置位 abort,读流应立即返回
/// `Aborted`,而不是阻塞到 120s 空闲超时。这是"读行与 abort 竞速"的回归
/// 测试(对应 pi:signal 交给 fetch 取消请求)。
async test "responses sse stream returns promptly on abort while stalled" {
  let (reader, writer) = @io.pipe()
  let controller = @agent_loop.AbortController::new()
  let messages : Array[@agent_loop.GenerationEvent] = []
  let start = @async.now()
  @async.with_task_group() <| group => {
    // 发一个 delta 事件后故意停滞:不关 pipe、不发终态事件。no_wait:
    // 这个任务永远不结束,不能挡住 group 收尾。
    group.spawn_bg(no_wait=true) <| async fn() {
      writer.write(
        (
          #|event: response.created
          #|data: {"type":"response.created","response":{"id":"resp_1","object":"response","created_at":1741290958,"status":"in_progress","error":null,"incomplete_details":null,"instructions":"You are a helpful assistant.","max_output_tokens":null,"model":"deepseek-v4-flash","output":[],"parallel_tool_calls":true,"previous_response_id":null,"reasoning":{"effort":null,"summary":null},"store":true,"temperature":1.0,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[],"top_p":1.0,"truncation":"disabled","usage":null,"user":null,"metadata":{}}}
          #|
          #|event: response.in_progress
          #|data: {"type":"response.in_progress","response":{"id":"resp_1","object":"response","created_at":1741290958,"status":"in_progress","error":null,"incomplete_details":null,"instructions":"You are a helpful assistant.","max_output_tokens":null,"model":"deepseek-v4-flash","output":[],"parallel_tool_calls":true,"previous_response_id":null,"reasoning":{"effort":null,"summary":null},"store":true,"temperature":1.0,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[],"top_p":1.0,"truncation":"disabled","usage":null,"user":null,"metadata":{}}}
          #|
          #|event: response.output_item.added
          #|data: {"type":"response.output_item.added","output_index":0,"item":{"id":"msg_1","type":"message","status":"in_progress","role":"assistant","content":[]}}
          #|
          #|event: response.content_part.added
          #|data: {"type":"response.content_part.added","item_id":"msg_1","output_index":0,"content_index":0,"part":{"type":"output_text","text":"","annotations":[]}}
          #|
          #|event: response.output_text.delta
          #|data: {"type":"response.output_text.delta","item_id":"msg_1","output_index":0,"content_index":0,"delta":"Hello"}
          #|
          #|
        ),
      )
    }
    group.spawn_bg(async fn() {
      // 模拟用户在流式输出中途按 Esc。
      @async.sleep(200)
      controller.abort()
    })
    let message = @providers.read_responses_sse_stream(
      reader,
      sink=event => messages.push(event),
      api="openai-responses",
      provider="deepseek",
      model="deepseek-v4-flash",
      abort=controller.signal,
    )
    // 在 abort 置位后远小于 120s 空闲超时内返回,且停因为 Aborted。
    let elapsed_ms = @async.now() - start
    debug_inspect(elapsed_ms < 10_000, content="true")
    match message.stop_reason {
      @agent_loop.StopReason::Aborted => debug_inspect(true, content="true")
      other => abort("expected Aborted, got \{other}")
    }
    // 已收到的部分内容保留在返回消息里。
    debug_inspect(messages.length() > 0, content="true")
  }
}
