///|
/// Normalize a transcript into the shape a provider request may replay,
/// mirroring pi's `transformMessages`
/// (`packages/ai/src/api/transform-messages.ts`):
///
/// - Drop `Error` / `Aborted` assistant messages.
/// - Answer unanswered tool calls with a synthetic `isError: true` result.
///
/// A tool result has to follow the call it answers, so the outstanding batch is
/// flushed before the next assistant or user message and once at the end.
///
/// Not ported: tool call id normalization, non-vision image downgrade, and
/// cross-model thinking downgrade.
pub fn transform_messages(
  messages : ArrayView[@agent_loop.AgentMessage],
  now~ : () -> UInt64 = @env.now,
) -> Array[@agent_loop.AgentMessage] {
  let result : Array[@agent_loop.AgentMessage] = []
  let mut pending : Array[@agent_loop.ToolCall] = []
  let mut answered : Set[String] = Set([])
  let close_pending = () => {
    for call in pending {
      if !answered.contains(call.id) {
        result.push(
          @agent_loop.AgentMessage::ToolResult({
            tool_call_id: call.id,
            tool_name: call.name,
            content: [
              @agent_loop.InputMessageContent::Text("No result provided"),
            ],
            details: None,
            usage: None,
            is_error: true,
            timestamp: now(),
          }),
        )
      }
    }
    pending = []
    answered = Set([])
  }
  for message in messages {
    if message is @agent_loop.AgentMessage::Assistant(assistant) {
      close_pending()
      let incomplete = assistant.stop_reason is Error ||
        assistant.stop_reason is Aborted
      guard !incomplete else { continue }
      for content in assistant.content {
        if content is @agent_loop.AssistantMessageContent::ToolCall(call, ..) {
          pending.push(call)
        }
      }
      result.push(message)
    } else if message is @agent_loop.AgentMessage::ToolResult(tool_result) {
      answered.add(tool_result.tool_call_id)
      result.push(message)
    } else {
      close_pending()
      result.push(message)
    }
  }
  close_pending()
  result
}
