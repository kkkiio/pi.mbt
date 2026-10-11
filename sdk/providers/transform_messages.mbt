///|
/// Normalize a transcript into the shape a provider request may replay.
///
/// Mirrors pi's `transformMessages` (`packages/ai/src/api/transform-messages.ts`)
/// for the parts pi.mbt can express today:
///
/// - **Drop `Error` / `Aborted` assistant messages.** They stay in the journal
///   and in the UI — pi keeps them too, and so does pi.mbt — but they are
///   incomplete turns: their blocks may still carry an unfinalized `signature`
///   (signatures are only attached on the `*End` stream events), so replaying
///   them fails the encoder and asks the provider to continue from a turn that
///   never finished. pi's rationale verbatim: "These are incomplete turns that
///   shouldn't be replayed".
/// - **Answer orphaned tool calls.** Every call the transcript never answered
///   gets a synthetic `isError: true` result, so a dropped or short-circuited
///   turn cannot leave a `function_call` without its `function_call_output`.
///
/// A tool result has to follow the call it answers without another message in
/// between, so the outstanding batch is flushed before the next assistant or
/// user message, and once at the end. Calls carried by a dropped message are
/// never registered: dropping the message drops the call with it, so no
/// synthetic result is owed.
///
/// Not ported here, because pi.mbt has no equivalent input yet: per-provider
/// tool call id normalization (the Responses family is the only wire format),
/// non-vision image downgrade (a model carries no input-modality flag), and
/// cross-model thinking downgrade (pi's `isSameModel` branch).
pub fn transform_messages(
  messages : ArrayView[@agent_loop.AgentMessage],
  now? : () -> UInt64 = @env.now,
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
      // pi: "Skip errored/aborted assistant messages entirely."
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
