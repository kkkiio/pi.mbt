///|
/// pi 线协议的回归测试。
///
/// 为什么这里不是 `ToJson`:`ToJson` 是「一定能序列化」的 trait,而投影在
/// `toolcall_start` 的快照不合约时必须报错(丢掉快照后 `id`/`toolName` 没有别的
/// 载体,编不出一个不骗人的值),所以用自由函数 + `raise`,由调用方(`--mode json`
/// 的订阅回调)翻译成单行诊断。`AgentEvent`/`GenerationEvent` 还来自
/// `agent_loop`,MoonBit 也不允许为外来类型实现外来 trait(4061)。
///
/// 断言整行而不是内层事件 —— 顶层 `usage` 也是线契约的一部分。构造用的 helper
/// (`user_message` / `probe_tools`)与 `session_test.mbt` 共用。

///|
/// 每个 `message_update` 的线形状:delta-only。累积快照留给 SDK 订阅方
/// (`partial~`),线上由 `message_start` 起头、`message_end` 收尾,所以
/// `--mode json` 的字节数随回复长度线性增长(issue #7)。
async test "message_update exposes the delta and stays delta-only on the wire" {
  let llm = @faux.FauxLLM::FauxLLM(chunk_size=5)
  llm.set_responses([@faux.faux_message([@faux.faux_text("0123456789")])])
  let session = @agent_session.AgentSession(llm)
  let updates : Array[@agent_loop.GenerationEvent] = []
  let lines : Array[String] = []
  session.subscribe(event => {
    guard event is Loop(MessageUpdate(update)) else { return }
    updates.push(update)
    lines.push(@agent_session.to_pi_json(event).stringify())
  })
  session.prompt([user_message("go")])
  // 增量原样透出,消费方可以只按 delta 追加而不用管快照。
  inspect(
    updates
    .map(update => {
      match update {
        TextStart(content_index~, ..) => "text_start:\{content_index}"
        TextDelta(content_index~, delta~, ..) =>
          "text_delta:\{content_index}:\{delta}"
        TextEnd(content_index~, content~, ..) =>
          "text_end:\{content_index}:\{content}"
        _ => "other"
      }
    })
    .join("\n"),
    content=(
      #|text_start:0
      #|text_delta:0:01234
      #|text_delta:0:56789
      #|text_end:0:0123456789
    ),
  )
  inspect(
    lines.join("\n"),
    content=(
      #|{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"text_start","contentIndex":0}}
      #|{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"01234"}}
      #|{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"56789"}}
      #|{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"text_end","contentIndex":0,"content":"0123456789"}}
    ),
  )
}

///|
/// `toolcall_start` 剥掉快照后必须把 `id`/`toolName` 补回来(pi `json-event.ts`
/// 的 `toJsonAssistantMessageEvent` 同样从快照里取它们)。
async test "toolcall_start keeps id and toolName on the wire" {
  let llm = @faux.FauxLLM::FauxLLM(chunk_size=16)
  llm.set_responses([
    @faux.faux_message(
      [@faux.faux_tool_call("probe", {}, id="call-1")],
      stop_reason=@agent_loop.StopReason::ToolUse,
    ),
    @faux.faux_message([@faux.faux_text("done")]),
  ])
  let session = @agent_session.AgentSession(
    llm,
    tool_registry=probe_tools([]),
    active_tools=["probe"],
  )
  let lines : Array[String] = []
  session.subscribe(event => {
    guard event is Loop(MessageUpdate(_)) else { return }
    lines.push(@agent_session.to_pi_json(event).stringify())
  })
  session.prompt([user_message("go")])
  inspect(
    lines.join("\n"),
    content=(
      #|{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"toolcall_start","contentIndex":0,"id":"call-1","toolName":"probe"}}
      #|{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"toolcall_delta","contentIndex":0,"delta":"{}"}}
      #|{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"toolcall_end","contentIndex":0,"toolCall":{"type":"toolCall","id":"call-1","name":"probe","arguments":{}}}}
      #|{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"text_start","contentIndex":0}}
      #|{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"done"}}
      #|{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"text_end","contentIndex":0,"content":"done"}}
    ),
  )
}

///|
/// 一个不合约的 provider:`ToolCallStart` 指向的块由脚本决定,默认与 `content_index`
/// 不匹配,用来验证投影报错而不是编值。真 provider 不会这样(我们的 `responses` /
/// `faux` 都是先 push 带 id/name 的 `ToolCall` 再发 `ToolCallStart`)。
struct BadSnapshotLLM {
  content : Array[@agent_loop.AssistantMessageContent]
  content_index : Int32
}

///|
impl @agent_loop.LLM for BadSnapshotLLM with fn generate(
  self : BadSnapshotLLM,
  _ctx : @agent_loop.Context,
  sink~ : async (@agent_loop.GenerationEvent) -> Unit,
  abort~ : @agent_loop.AbortSignal,
) -> @agent_loop.AssistantMessage {
  ignore(abort)
  let pending : @agent_loop.AssistantMessage = {
    content: self.content,
    api: "faux",
    provider: "faux",
    model: "faux-1",
    stop_reason: @agent_loop.StopReason::Pending,
    error_message: None,
    usage: None,
    timestamp: 0,
  }
  sink(@agent_loop.GenerationEvent::Start(partial=pending))
  sink(
    @agent_loop.GenerationEvent::ToolCallStart(
      content_index=self.content_index,
      partial=pending,
    ),
  )
  { ..pending, stop_reason: @agent_loop.StopReason::Stop, }
}

///|
/// 位置对不上时线段无从写起,只能报错;两种不合约各自带自己的理由。
///
/// 断言订阅方观察到的诊断而不是 `prompt` 抛出的错误:loop 把 `event_sink` 的
/// raise 收进 `generate` 的 catch,会把它变成一次假的 Error 回合 —— 所以线协议
/// 的消费者必须在订阅回调里就 catch 住(`--mode json` 就是这么做的)。
async test "toolcall_start without a tool call raises instead of inventing fields" {
  let text : @agent_loop.AssistantMessageContent = @agent_loop.AssistantMessageContent::Text(
    "hi",
    signature={},
  )
  let wrong_block = wire_failure_of({ content: [text], content_index: 0, })
  assert_true(wrong_block.contains("is not a tool call"))
  let out_of_range = wire_failure_of({ content: [], content_index: 7, })
  assert_true(out_of_range.contains("is out of range"))
}

///|
/// 跑一次不合约的 run,返回投影抛出的诊断文本。
async fn wire_failure_of(llm : BadSnapshotLLM) -> String {
  let session = @agent_session.AgentSession(llm)
  let diagnostics : Array[String] = []
  session.subscribe(event => {
    ignore(@agent_session.to_pi_json(event)) catch {
      err => diagnostics.push(err.to_string())
    }
  })
  session.prompt([user_message("go")])
  match diagnostics {
    [message, ..] => message
    [] => ""
  }
}

///|
/// pi 的 `7290-json-stream-linear.test.ts`:wire 上每条 update 都是常量大小,
/// 所以总字节随文本线性增长(2KB → 4KB 的比值接近 2)。带累积快照时每条 update
/// 都重复全文,总字节是 O(n²),比值会接近 4。
async test "json message updates stay linear in response length" {
  let small = json_update_bytes(2_000)
  let large = json_update_bytes(4_000)
  assert_true(large > small)
  assert_true(large.to_double() / small.to_double() < 2.2)
}

///|
/// 一条回复的 `message_update` 线字节总和。分片数随长度线性增长,每片大小固定。
async fn json_update_bytes(characters : Int32) -> Int32 {
  let llm = @faux.FauxLLM::FauxLLM()
  llm.set_responses([
    @faux.faux_message([@faux.faux_text("x".repeat(characters))]),
  ])
  let session = @agent_session.AgentSession(llm)
  let mut bytes = 0
  session.subscribe(event => {
    guard event is Loop(MessageUpdate(_)) else { return }
    bytes += @agent_session.to_pi_json(event).stringify().length()
  })
  session.prompt([user_message("go")])
  bytes
}
