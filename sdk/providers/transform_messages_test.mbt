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
/// pi "adds synthetic tool results for trailing orphaned tool calls": a turn
/// that requested a tool and never reported a result still encodes as a
/// well-formed request.
async test "orphaned tool call gets a synthetic error result" {
  let result = @providers.transform_messages(
    [
      tm_user("read the file"),
      tm_assistant(
        [tm_call("call-1", "read")],
        stop_reason=@agent_loop.StopReason::ToolUse,
      ),
    ],
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
/// pi "adds synthetic results only for trailing tool calls that are still
/// missing results": answered calls are left alone.
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
/// pi: "Skip errored/aborted assistant messages entirely." They stay in the
/// journal, but an unfinished turn is never replayed to the provider.
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
/// A dropped message takes its tool calls with it, so nothing is owed: the
/// encoder must not invent a result for a call the request no longer contains.
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
/// A tool result has to follow its call, so the synthetic result is inserted
/// before the message that interrupts the batch, not appended at the end.
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
    now=tm_now,
  )
  json_inspect(result.map(tm_role), content=[
    "user", "assistant", "toolResult", "user",
  ])
}
