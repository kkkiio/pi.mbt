///|
/// Normalize a transcript into the shape a provider request may replay,
/// mirroring pi's `transformMessages`
/// (`packages/ai/src/api/transform-messages.ts`):
///
/// - Drop `Error` / `Aborted` assistant messages.
/// - Answer unanswered tool calls with a synthetic `isError: true` result.
/// - When `supports_images` is false, replace image blocks in user and tool
///   result messages with a text placeholder (pi's
///   `downgradeUnsupportedImages`).
///
/// A tool result has to follow the call it answers, so the outstanding batch is
/// flushed before the next assistant or user message and once at the end.
///
/// Not ported: tool call id normalization and cross-model thinking downgrade.
/// `splitErrorToolResultImages` is also not ported: it exists for Anthropic,
/// which rejects images in error results.
pub fn transform_messages(
  messages : ArrayView[@agent_loop.AgentMessage],
  supports_images~ : Bool,
  now~ : () -> UInt64 = @env.now,
) -> Array[@agent_loop.AgentMessage] {
  let downgraded = if supports_images {
    None
  } else {
    Some(downgrade_unsupported_images(messages))
  }
  let messages = match downgraded {
    Some(images) => images[:]
    None => messages
  }
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

///|
/// pi's `NON_VISION_USER_IMAGE_PLACEHOLDER` / `NON_VISION_TOOL_IMAGE_PLACEHOLDER`.
const NON_VISION_USER_IMAGE_PLACEHOLDER = "(image omitted: model does not support images)"

///|
const NON_VISION_TOOL_IMAGE_PLACEHOLDER = "(tool image omitted: model does not support images)"

///|
/// pi's `downgradeUnsupportedImages`: image blocks become a text placeholder
/// for models without vision input.
fn downgrade_unsupported_images(
  messages : ArrayView[@agent_loop.AgentMessage],
) -> Array[@agent_loop.AgentMessage] {
  messages.map(message => {
    match message {
      @agent_loop.AgentMessage::User(user) =>
        @agent_loop.AgentMessage::User({
          ..user,
          content: replace_images_with_placeholder(
            user.content,
            NON_VISION_USER_IMAGE_PLACEHOLDER,
          ),
        })
      @agent_loop.AgentMessage::ToolResult(tool_result) =>
        @agent_loop.AgentMessage::ToolResult({
          ..tool_result,
          content: replace_images_with_placeholder(
            tool_result.content,
            NON_VISION_TOOL_IMAGE_PLACEHOLDER,
          ),
        })
      _ => message
    }
  })
}

///|
/// pi's `replaceImagesWithPlaceholder`: a run of consecutive image blocks
/// collapses into a single placeholder. A text block that already reads as the
/// placeholder keeps the flag set, so an image following it produces no second
/// placeholder.
fn replace_images_with_placeholder(
  content : Array[@agent_loop.InputMessageContent],
  placeholder : String,
) -> Array[@agent_loop.InputMessageContent] {
  let result : Array[@agent_loop.InputMessageContent] = []
  let mut previous_was_placeholder = false
  for block in content {
    match block {
      @agent_loop.InputMessageContent::Image(..) => {
        if !previous_was_placeholder {
          result.push(@agent_loop.InputMessageContent::Text(placeholder))
        }
        previous_was_placeholder = true
        continue
      }
      @agent_loop.InputMessageContent::Text(text) => {
        result.push(block)
        previous_was_placeholder = text == placeholder
      }
    }
  }
  result
}
