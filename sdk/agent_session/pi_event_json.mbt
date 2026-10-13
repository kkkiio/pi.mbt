///|
/// pi 的 `--mode json` 线协议:把会话/循环事件投影成线上一行的 JSON。
///
/// 参考 pi 的 `packages/coding-agent/src/modes/json-event.ts`。

///|
/// 一个会话事件的一行 JSON。`message_update` 是 delta-only 的:消息快照由
/// `message_start` / `message_end` 承载,累计 `usage` 单独挂在顶层。
///
/// 事件无法忠实投影时 raise(见 `agent_event_to_pi_json`)。
pub fn to_pi_json(event : AgentSessionEvent) -> Json raise {
  match event {
    Loop(agent_event) => agent_event_to_pi_json(agent_event)
    AutoRetryStart(attempt~, max_attempts~, delay_ms~, error_message~) =>
      {
        "type": "auto_retry_start",
        "attempt": attempt,
        "maxAttempts": max_attempts,
        "delayMs": delay_ms,
        "errorMessage": error_message,
      }
    AutoRetryEnd(attempt~, success~, final_error~) =>
      {
        "type": "auto_retry_end",
        "success": success,
        "attempt": attempt,
        "finalError": match final_error {
          Some(message) => message.to_json()
          None => null
        },
      }
  }
}

///|
/// 一个 agent loop 事件的一行 JSON。
///
/// `toolcall_start` 剥掉快照后要补上常量大小的 `id`/`toolName` —— 丢了快照,那是
/// 它们唯一的载体;快照里没有可补的值(位置不是 tool call 或越界)时 raise。
pub fn agent_event_to_pi_json(event : @agent_loop.AgentEvent) -> Json raise {
  match event {
    AgentStart => { "type": "agent_start" }
    TurnStart => { "type": "turn_start" }
    MessageStart(message) =>
      { "type": "message_start", "message": message.to_json() }
    MessageUpdate(update) =>
      {
        "type": "message_update",
        "usage": @agent_loop.usage_json(generation_partial(update).usage),
        "assistantMessageEvent": generation_event_to_pi_json(update),
      }
    MessageEnd(message) =>
      { "type": "message_end", "message": message.to_json() }
    ToolExecutionStart(call) =>
      {
        "type": "tool_execution_start",
        "toolName": call.name,
        "args": call.arguments,
      }
    ToolExecutionEnd(result) =>
      {
        "type": "tool_execution_end",
        "toolName": result.tool_name,
        "content": [
          for c in result.content => c.to_json()
        ],
        "isError": result.is_error,
      }
    TurnEnd(assistant_message, tool_results) =>
      {
        "type": "turn_end",
        "message": assistant_message.to_json(),
        "toolCalls": [
          for r in tool_results => r.tool_name
        ],
      }
    AgentEnd(_) => { "type": "agent_end" }
  }
}

///|
/// 流式事件携带的 in-flight 快照;线上去掉它之后,`usage` 是唯一还要从中取的字段。
fn generation_partial(
  event : @agent_loop.GenerationEvent,
) -> @agent_loop.AssistantMessage {
  match event {
    Start(partial~)
    | TextStart(partial~, ..)
    | TextDelta(partial~, ..)
    | TextEnd(partial~, ..)
    | ThinkingStart(partial~, ..)
    | ThinkingDelta(partial~, ..)
    | ThinkingEnd(partial~, ..)
    | ToolCallStart(partial~, ..)
    | ToolCallDelta(partial~, ..)
    | ToolCallEnd(partial~, ..) => partial
  }
}

///|
/// 流式增量的线上形状:累积的 `partial` 快照被剥掉,这样流的字节数随回复长度
/// 线性增长。
fn generation_event_to_pi_json(
  event : @agent_loop.GenerationEvent,
) -> Json raise {
  match event {
    Start(_) => { "type": "start" }
    TextStart(content_index~, ..) =>
      { "type": "text_start", "contentIndex": content_index }
    TextDelta(content_index~, delta~, ..) =>
      { "type": "text_delta", "contentIndex": content_index, "delta": delta }
    TextEnd(content_index~, content~, ..) =>
      { "type": "text_end", "contentIndex": content_index, "content": content }
    ThinkingStart(content_index~, ..) =>
      { "type": "thinking_start", "contentIndex": content_index }
    ThinkingDelta(content_index~, delta~, ..) =>
      {
        "type": "thinking_delta",
        "contentIndex": content_index,
        "delta": delta,
      }
    ThinkingEnd(content_index~, content~, ..) =>
      {
        "type": "thinking_end",
        "contentIndex": content_index,
        "content": content,
      }
    ToolCallStart(content_index~, partial~) => {
      guard content_index >= 0 && content_index < partial.content.length() else {
        fail("toolcall_start content at index \{content_index} is out of range")
      }
      let call = match partial.content[content_index] {
        ToolCall(call, ..) => call
        _ =>
          fail(
            "toolcall_start content at index \{content_index} is not a tool call",
          )
      }
      {
        "type": "toolcall_start",
        "contentIndex": content_index,
        "id": call.id,
        "toolName": call.name,
      }
    }
    ToolCallDelta(content_index~, delta~, ..) =>
      {
        "type": "toolcall_delta",
        "contentIndex": content_index,
        "delta": delta,
      }
    ToolCallEnd(content_index~, tool_call~, ..) =>
      {
        "type": "toolcall_end",
        "contentIndex": content_index,
        "toolCall": tool_call.to_json(),
      }
  }
}
