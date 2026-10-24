///|
/// Ports of pi's `transformMessages` cases
/// (`packages/ai/test/transform-messages-copilot-openai-to-anthropic.test.ts`)
/// plus the replay cases pi leaves untested: dropping errored/aborted turns.
///
/// The synthetic result's timestamp is the only nondeterministic input, so every
/// test pins it with `now`.

///|
const TM_TIMESTAMP : UInt64 = 1786903823973

///|
/// The value every synthetic result timestamp must take in these snapshots.
fn tm_now() -> UInt64 {
  7
}

///|
fn tm_user(text : String) -> @agent_loop.AgentMessage {
  @agent_loop.AgentMessage::User({
    content: [@agent_loop.InputMessageContent::Text(text)],
    timestamp: TM_TIMESTAMP,
  })
}

///|
fn tm_assistant(
  content : Array[@agent_loop.AssistantMessageContent],
  stop_reason~ : @agent_loop.StopReason,
) -> @agent_loop.AgentMessage {
  @agent_loop.AgentMessage::Assistant({
    content,
    api: "openai-responses",
    provider: "deepseek",
    model: "deepseek-v4-flash",
    stop_reason,
    error_message: None,
    usage: None,
    timestamp: TM_TIMESTAMP,
  })
}

///|
fn tm_text(text : String) -> @agent_loop.AssistantMessageContent {
  @agent_loop.AssistantMessageContent::Text(text, signature={})
}

///|
fn tm_call(id : String, name : String) -> @agent_loop.AssistantMessageContent {
  @agent_loop.AssistantMessageContent::ToolCall({ id, name, arguments: {}, }, signature={})
}

///|
fn tm_result(
  tool_call_id : String,
  tool_name : String,
  text : String,
) -> @agent_loop.AgentMessage {
  @agent_loop.AgentMessage::ToolResult({
    tool_call_id,
    tool_name,
    content: [@agent_loop.InputMessageContent::Text(text)],
    details: None,
    usage: None,
    is_error: false,
    timestamp: TM_TIMESTAMP,
  })
}

///|
fn tm_role(message : @agent_loop.AgentMessage) -> String {
  match message {
    User(_) => "user"
    Assistant(_) => "assistant"
    ToolResult(_) => "toolResult"
  }
}

///|
async test "orphaned tool call gets a synthetic error result" {
  let result = @providers.transform_messages(
    [
      tm_user("read the file"),
      tm_assistant(
        [tm_call("call-1", "read")],
        stop_reason=@agent_loop.StopReason::ToolUse,
      ),
    ],
    supports_images=true,
    now=tm_now,
  )
  json_inspect(result, content=[
    {
      "role": "user",
      "content": [{ "type": "text", "text": "read the file" }],
      "timestamp": 1786903823973,
    },
    {
      "role": "assistant",
      "content": [
        { "type": "toolCall", "id": "call-1", "name": "read", "arguments": {} },
      ],
      "api": "openai-responses",
      "provider": "deepseek",
      "model": "deepseek-v4-flash",
      "stopReason": "toolUse",
      "usage": {
        "input": 0,
        "output": 0,
        "cacheRead": 0,
        "cacheWrite": 0,
        "totalTokens": 0,
        "cost": {
          "input": 0,
          "output": 0,
          "cacheRead": 0,
          "cacheWrite": 0,
          "total": 0,
        },
      },
      "timestamp": 1786903823973,
    },
    {
      "role": "toolResult",
      "toolCallId": "call-1",
      "toolName": "read",
      "content": [{ "type": "text", "text": "No result provided" }],
      "isError": true,
      "timestamp": 7,
    },
  ])
}

///|
async test "only unanswered tool calls get synthetic results" {
  let result = @providers.transform_messages(
    [
      tm_user("run commands"),
      tm_assistant(
        [tm_call("call-1", "read"), tm_call("call-2", "bash")],
        stop_reason=@agent_loop.StopReason::ToolUse,
      ),
      tm_result("call-1", "read", "done"),
    ],
    supports_images=true,
    now=tm_now,
  )
  json_inspect(result, content=[
    {
      "role": "user",
      "content": [{ "type": "text", "text": "run commands" }],
      "timestamp": 1786903823973,
    },
    {
      "role": "assistant",
      "content": [
        { "type": "toolCall", "id": "call-1", "name": "read", "arguments": {} },
        { "type": "toolCall", "id": "call-2", "name": "bash", "arguments": {} },
      ],
      "api": "openai-responses",
      "provider": "deepseek",
      "model": "deepseek-v4-flash",
      "stopReason": "toolUse",
      "usage": {
        "input": 0,
        "output": 0,
        "cacheRead": 0,
        "cacheWrite": 0,
        "totalTokens": 0,
        "cost": {
          "input": 0,
          "output": 0,
          "cacheRead": 0,
          "cacheWrite": 0,
          "total": 0,
        },
      },
      "timestamp": 1786903823973,
    },
    {
      "role": "toolResult",
      "toolCallId": "call-1",
      "toolName": "read",
      "content": [{ "type": "text", "text": "done" }],
      "isError": false,
      "timestamp": 1786903823973,
    },
    {
      "role": "toolResult",
      "toolCallId": "call-2",
      "toolName": "bash",
      "content": [{ "type": "text", "text": "No result provided" }],
      "isError": true,
      "timestamp": 7,
    },
  ])
}

///|
async test "errored and aborted assistant messages are dropped" {
  let result = @providers.transform_messages(
    [
      tm_user("hi"),
      tm_assistant(
        [tm_text("half")],
        stop_reason=@agent_loop.StopReason::Aborted,
      ),
      tm_assistant([], stop_reason=@agent_loop.StopReason::Error),
      tm_assistant(
        [tm_text("final answer")],
        stop_reason=@agent_loop.StopReason::Stop,
      ),
    ],
    supports_images=true,
    now=tm_now,
  )
  json_inspect(result, content=[
    {
      "role": "user",
      "content": [{ "type": "text", "text": "hi" }],
      "timestamp": 1786903823973,
    },
    {
      "role": "assistant",
      "content": [{ "type": "text", "text": "final answer" }],
      "api": "openai-responses",
      "provider": "deepseek",
      "model": "deepseek-v4-flash",
      "stopReason": "stop",
      "usage": {
        "input": 0,
        "output": 0,
        "cacheRead": 0,
        "cacheWrite": 0,
        "totalTokens": 0,
        "cost": {
          "input": 0,
          "output": 0,
          "cacheRead": 0,
          "cacheWrite": 0,
          "total": 0,
        },
      },
      "timestamp": 1786903823973,
    },
  ])
}

///|

///|
async test "a dropped message does not owe a synthetic result" {
  let result = @providers.transform_messages(
    [
      tm_user("hi"),
      tm_assistant(
        [tm_call("call-1", "read")],
        stop_reason=@agent_loop.StopReason::Aborted,
      ),
      tm_assistant(
        [tm_text("final answer")],
        stop_reason=@agent_loop.StopReason::Stop,
      ),
    ],
    supports_images=true,
    now=tm_now,
  )
  json_inspect(result, content=[
    {
      "role": "user",
      "content": [{ "type": "text", "text": "hi" }],
      "timestamp": 1786903823973,
    },
    {
      "role": "assistant",
      "content": [{ "type": "text", "text": "final answer" }],
      "api": "openai-responses",
      "provider": "deepseek",
      "model": "deepseek-v4-flash",
      "stopReason": "stop",
      "usage": {
        "input": 0,
        "output": 0,
        "cacheRead": 0,
        "cacheWrite": 0,
        "totalTokens": 0,
        "cost": {
          "input": 0,
          "output": 0,
          "cacheRead": 0,
          "cacheWrite": 0,
          "total": 0,
        },
      },
      "timestamp": 1786903823973,
    },
  ])
}

///|
async test "synthetic result is flushed before the next assistant message" {
  let result = @providers.transform_messages(
    [
      tm_user("hi"),
      tm_assistant(
        [tm_call("call-1", "read")],
        stop_reason=@agent_loop.StopReason::ToolUse,
      ),
      tm_assistant(
        [tm_text("never answered the call")],
        stop_reason=@agent_loop.StopReason::Stop,
      ),
    ],
    supports_images=true,
    now=tm_now,
  )
  json_inspect(result.map(tm_role), content=[
    "user", "assistant", "toolResult", "assistant",
  ])
}

///|
/// Same rule for a user message that interrupts the batch.
async test "synthetic result is flushed before the next user message" {
  let result = @providers.transform_messages(
    [
      tm_user("hi"),
      tm_assistant(
        [tm_call("call-1", "read")],
        stop_reason=@agent_loop.StopReason::ToolUse,
      ),
      tm_user("interrupting question"),
    ],
    supports_images=true,
    now=tm_now,
  )
  json_inspect(result.map(tm_role), content=[
    "user", "assistant", "toolResult", "user",
  ])
}

///|
fn tm_image() -> @agent_loop.InputMessageContent {
  @agent_loop.InputMessageContent::Image(data="aGVsbG8=", mime_type="image/png")
}

///|
/// A non-vision model gets pi's `NON_VISION_USER_IMAGE_PLACEHOLDER` in place
/// of user image blocks; a run of consecutive images collapses into one.
async test "images in a user message downgrade to one placeholder" {
  let result = @providers.transform_messages(
    [
      @agent_loop.AgentMessage::User({
        content: [
          @agent_loop.InputMessageContent::Text("look"),
          tm_image(),
          tm_image(),
          @agent_loop.InputMessageContent::Text("what is it"),
        ],
        timestamp: TM_TIMESTAMP,
      }),
    ],
    supports_images=false,
    now=tm_now,
  )
  json_inspect(result, content=[
    {
      "role": "user",
      "content": [
        { "type": "text", "text": "look" },
        {
          "type": "text",
          "text": "(image omitted: model does not support images)",
        },
        { "type": "text", "text": "what is it" },
      ],
      "timestamp": 1786903823973,
    },
  ])
}

///|
/// pi's `replaceImagesWithPlaceholder` keeps `previousWasPlaceholder` set when
/// a text block already reads as the placeholder, so an image after it adds
/// no second placeholder.
async test "an image after existing placeholder text adds no second placeholder" {
  let result = @providers.transform_messages(
    [
      @agent_loop.AgentMessage::User({
        content: [
          @agent_loop.InputMessageContent::Text(
            "(image omitted: model does not support images)",
          ),
          tm_image(),
        ],
        timestamp: TM_TIMESTAMP,
      }),
    ],
    supports_images=false,
    now=tm_now,
  )
  json_inspect(result, content=[
    {
      "role": "user",
      "content": [
        {
          "type": "text",
          "text": "(image omitted: model does not support images)",
        },
      ],
      "timestamp": 1786903823973,
    },
  ])
}

///|
/// Tool results use pi's tool-specific placeholder text instead.
async test "images in a tool result downgrade to the tool placeholder" {
  let result = @providers.transform_messages(
    [
      @agent_loop.AgentMessage::ToolResult({
        tool_call_id: "call-1",
        tool_name: "screenshot",
        content: [tm_image(), @agent_loop.InputMessageContent::Text("done")],
        details: None,
        usage: None,
        is_error: false,
        timestamp: TM_TIMESTAMP,
      }),
    ],
    supports_images=false,
    now=tm_now,
  )
  json_inspect(result, content=[
    {
      "role": "toolResult",
      "toolCallId": "call-1",
      "toolName": "screenshot",
      "content": [
        {
          "type": "text",
          "text": "(tool image omitted: model does not support images)",
        },
        { "type": "text", "text": "done" },
      ],
      "isError": false,
      "timestamp": 1786903823973,
    },
  ])
}

///|
/// A vision model keeps image blocks untouched, serialized in pi's
/// `ImageContent` shape.
async test "supports_images keeps image blocks" {
  let result = @providers.transform_messages(
    [
      @agent_loop.AgentMessage::User({
        content: [@agent_loop.InputMessageContent::Text("look"), tm_image()],
        timestamp: TM_TIMESTAMP,
      }),
    ],
    supports_images=true,
    now=tm_now,
  )
  json_inspect(result, content=[
    {
      "role": "user",
      "content": [
        { "type": "text", "text": "look" },
        { "type": "image", "data": "aGVsbG8=", "mimeType": "image/png" },
      ],
      "timestamp": 1786903823973,
    },
  ])
}
