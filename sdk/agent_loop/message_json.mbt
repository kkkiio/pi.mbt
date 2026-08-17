///|
/// JSON projection shared by the `--mode json` wire format and the JSONL
/// session journal. These shapes intentionally mirror `pi`'s message JSON so
/// that wire output and persisted session entries stay isomorphic.

///|
pub impl ToJson for AgentMessage with fn to_json(self : AgentMessage) -> Json {
  match self {
    User(contents) => {
      let cs : Array[Json] = []
      for content in contents {
        cs.push(content.to_json())
      }
      Json::object({
        "role": "user".to_json(),
        "content": Json::array(cs),
      })
    }
    Assistant(message) => message.to_json()
    ToolResult(result) => {
      let cs : Array[Json] = []
      for content in result.content {
        cs.push(content.to_json())
      }
      Json::object({
        "role": "toolResult".to_json(),
        "toolCallId": result.tool_call_id.to_json(),
        "toolName": result.tool_name.to_json(),
        "content": Json::array(cs),
        "isError": result.is_error.to_json(),
        "timestamp": Json::number(result.timestamp.to_double()),
      })
    }
  }
}

///|
pub impl ToJson for InputMessageContent with fn to_json(
  self : InputMessageContent,
) -> Json {
  match self {
    Text(text) =>
      Json::object({ "type": "text".to_json(), "text": text.to_json() })
    Image(bytes) =>
      Json::object({
        "type": "image".to_json(),
        "length": bytes.length().to_json(),
      })
  }
}

///|
pub impl ToJson for AssistantMessage with fn to_json(
  self : AssistantMessage,
) -> Json {
  let cs : Array[Json] = []
  for content in self.content {
    cs.push(content.to_json())
  }
  let obj : Map[String, Json] = Map([])
  obj["role"] = "assistant".to_json()
  obj["content"] = Json::array(cs)
  obj["api"] = self.api.to_json()
  obj["provider"] = self.provider.to_json()
  obj["model"] = self.model.to_json()
  obj["stopReason"] = self.stop_reason.to_json()
  obj["errorMessage"] = match self.error_message {
    Some(message) => message.to_json()
    None => Json::null()
  }
  obj["usage"] = match self.usage {
    Some(usage) => usage.to_json()
    None => Json::null()
  }
  obj["timestamp"] = Json::number(self.timestamp.to_double())
  Json::object(obj)
}

///|
pub impl ToJson for StopReason with fn to_json(self : StopReason) -> Json {
  match self {
    Pending => "pending".to_json()
    Stop => "stop".to_json()
    Length => "length".to_json()
    ToolUse => "toolUse".to_json()
    Aborted => "aborted".to_json()
    Error => "error".to_json()
  }
}

///|
pub impl ToJson for AssistantMessageContent with fn to_json(
  self : AssistantMessageContent,
) -> Json {
  match self {
    Text(text, signature~) =>
      Json::object({
        "type": "text".to_json(),
        "text": text.to_json(),
        "textSignature": signature.stringify().to_json(),
      })
    Thinking(text, signature~) =>
      Json::object({
        "type": "thinking".to_json(),
        "thinking": text.to_json(),
        "thinkingSignature": signature.stringify().to_json(),
      })
    ToolCall(tool_call, signature~) =>
      Json::object({
        "type": "toolCall".to_json(),
        "id": tool_call.id.to_json(),
        "name": tool_call.name.to_json(),
        "arguments": tool_call.arguments,
        "thoughtSignature": signature.stringify().to_json(),
      })
    HostedToolCall(tool, signature~) =>
      Json::object({
        "type": "hostedToolCall".to_json(),
        "tool": tool.to_json(),
        "signature": signature.stringify().to_json(),
      })
  }
}

///|
pub impl ToJson for HostedTool with fn to_json(self : HostedTool) -> Json {
  match self {
    WebSearch => "web_search".to_json()
  }
}

///|
pub impl ToJson for Usage with fn to_json(self : Usage) -> Json {
  let obj : Map[String, Json] = Map([])
  obj["input"] = self.input.to_json()
  obj["output"] = self.output.to_json()
  obj["cacheRead"] = self.cache_read.to_json()
  obj["cacheWrite"] = self.cache_write.to_json()
  obj["cacheWrite1h"] = match self.cache_write_1h {
    Some(n) => n.to_json()
    None => Json::null()
  }
  obj["reasoning"] = match self.reasoning {
    Some(n) => n.to_json()
    None => Json::null()
  }
  obj["totalTokens"] = self.total_tokens.to_json()
  obj["cost"] = self.cost.to_json()
  Json::object(obj)
}

///|
pub impl ToJson for UsageCost with fn to_json(self : UsageCost) -> Json {
  Json::object({
    "input": self.input.to_json(),
    "output": self.output.to_json(),
    "cacheRead": self.cache_read.to_json(),
    "cacheWrite": self.cache_write.to_json(),
    "total": self.total.to_json(),
  })
}
