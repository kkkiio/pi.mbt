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
    Assistant(contents) => {
      let cs : Array[Json] = []
      for content in contents {
        cs.push(content.to_json())
      }
      Json::object({
        "role": "assistant".to_json(),
        "content": Json::array(cs),
      })
    }
    ToolResult(result) => {
      let cs : Array[Json] = []
      for content in result.content {
        cs.push(content.to_json())
      }
      Json::object({
        "role": "tool".to_json(),
        "tool_call_id": result.tool_call_id.to_json(),
        "name": result.tool_name.to_json(),
        "content": Json::array(cs),
        "is_error": result.is_error.to_json(),
        "timestamp": result.timestamp.to_string().to_json(),
        "terminate": result.terminate.to_json(),
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
  obj["content"] = Json::array(cs)
  obj["stop_reason"] = stop_reason_to_json(self.stop_reason)
  obj["error_message"] = match self.error_message {
    Some(message) => message.to_json()
    None => Json::null()
  }
  obj["usage"] = match self.usage {
    Some(usage) => usage.to_json()
    None => Json::null()
  }
  Json::object(obj)
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
        "signature": signature,
      })
    Thinking(text, signature~) =>
      Json::object({
        "type": "thinking".to_json(),
        "thinking": text.to_json(),
        "signature": signature,
      })
    ToolCall(tool_call, signature~) =>
      Json::object({
        "type": "tool_call".to_json(),
        "id": tool_call.id.to_json(),
        "name": tool_call.name.to_json(),
        "arguments": tool_call.arguments,
        "signature": signature,
      })
    HostedToolCall(tool, signature~) =>
      Json::object({
        "type": "hosted_tool_call".to_json(),
        "tool": tool.to_json(),
        "signature": signature,
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
  obj["cache_read"] = self.cache_read.to_json()
  obj["cache_write"] = self.cache_write.to_json()
  obj["cache_write_1h"] = match self.cache_write_1h {
    Some(n) => n.to_json()
    None => Json::null()
  }
  obj["reasoning"] = match self.reasoning {
    Some(n) => n.to_json()
    None => Json::null()
  }
  obj["total_tokens"] = self.total_tokens.to_json()
  obj["cost"] = self.cost.to_json()
  Json::object(obj)
}

///|
pub impl ToJson for UsageCost with fn to_json(self : UsageCost) -> Json {
  Json::object({
    "input": self.input.to_json(),
    "output": self.output.to_json(),
    "cache_read": self.cache_read.to_json(),
    "cache_write": self.cache_write.to_json(),
    "total": self.total.to_json(),
  })
}

///|
fn stop_reason_to_json(stop_reason : StopReason) -> Json {
  match stop_reason {
    Stop => "stop".to_json()
    Length => "length".to_json()
    ToolUse => "toolUse".to_json()
    Aborted => "aborted".to_json()
    Error => "error".to_json()
  }
}
