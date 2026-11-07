///|
/// 将会话日志条目转换为确定性的 YAML 转录文本。
///
/// - `entries`: 会话日志中的 `SessionEntry` 序列。
/// - 返回值: 经过 `ContextEdit` 过滤后的 YAML 格式对话转录字符串。
/// - 边界条件: 当没有有效消息条目时返回 `"[]\n"`。
pub fn from_entries(entries : ArrayView[@agent_session.SessionEntry]) -> String {
  let omitted : Set[String] = Set([])
  for entry in entries {
    if entry.content
      is @agent_session.SessionEntryContent::ContextEdit(target_id~) {
      omitted.add(target_id)
    }
  }
  let messages : Array[@agent_loop.AgentMessage] = []
  for entry in entries {
    if !omitted.contains(entry.id) &&
      entry.content is @agent_session.SessionEntryContent::Message(message) {
      messages.push(message)
    }
  }
  from_messages(messages)
}

///|
/// 将 Agent 消息序列转换为确定性的 YAML 转录文本。
///
/// - `messages`: 对话中的 `AgentMessage` 序列（包含 `User`、`Assistant`、`ToolResult`）。
/// - 返回值: 适合人类阅读与快照测试的 YAML 格式转录字符串。
/// - 边界条件: 空序列返回 `"[]\n"`。
pub fn from_messages(messages : ArrayView[@agent_loop.AgentMessage]) -> String {
  if messages.is_empty() {
    return "[]\n"
  }
  let buf = StringBuilder()
  for i, message in messages {
    if i > 0 {
      buf.write_string("\n")
    }
    match message {
      @agent_loop.AgentMessage::User(user) => {
        let text = format_input_contents(user.content)
        write_yaml_field(buf, "- user", text, 4)
      }
      @agent_loop.AgentMessage::Assistant(assistant) => {
        let normal_stop = assistant.stop_reason is @agent_loop.StopReason::Stop ||
          assistant.stop_reason is @agent_loop.StopReason::ToolUse
        if normal_stop &&
          assistant.error_message is None &&
          assistant.content
          is [@agent_loop.AssistantMessageContent::Text(text, ..)] {
          write_yaml_field(buf, "- assistant", text, 4)
        } else {
          buf.write_string("- assistant:\n")
          for block in assistant.content {
            match block {
              @agent_loop.AssistantMessageContent::Thinking(thinking, ..) =>
                write_yaml_field(buf, "    - thinking", thinking, 8)
              @agent_loop.AssistantMessageContent::Text(text, ..) =>
                write_yaml_field(buf, "    - text", text, 8)
              @agent_loop.AssistantMessageContent::ToolCall(call, ..) => {
                buf.write_string("    - tool_call: \{call.name}\n")
                if call.name == "codemode" &&
                  call.arguments is Object(fields) &&
                  fields.length() == 1 &&
                  fields.get("code") is Some(String(code)) {
                  write_yaml_field(buf, "      code", code, 8)
                } else if !(call.arguments is Object(fields) &&
                  fields.is_empty()) {
                  buf.write_string(
                    "      args: \{call.arguments.stringify()}\n",
                  )
                }
              }
            }
          }
          if !normal_stop {
            let reason = match assistant.stop_reason {
              @agent_loop.StopReason::Pending => "pending"
              @agent_loop.StopReason::Stop => "stop"
              @agent_loop.StopReason::Length => "length"
              @agent_loop.StopReason::ToolUse => "toolUse"
              @agent_loop.StopReason::Aborted => "aborted"
              @agent_loop.StopReason::Error => "error"
            }
            buf.write_string("    - stop_reason: \{reason}\n")
            if assistant.error_message is Some(err) {
              write_yaml_field(buf, "      error_message", err, 8)
            }
          }
        }
      }
      @agent_loop.AgentMessage::ToolResult(result) => {
        buf.write_string("- tool_result: \{result.tool_name}\n")
        if result.is_error {
          buf.write_string("  is_error: true\n")
        }
        if result.details is Some({ "calls": Array(calls), .. }) &&
          !calls.is_empty() {
          buf.write_string("  calls:\n")
          for call in calls {
            if call
              is {
                "name": String(name),
                "args": String(args),
                "status": String(status),
                ..
              } {
              if call is { "error": String(err), .. } {
                buf.write_string(
                  "    - \{name}(\{args}) -> \{status}: \{err}\n",
                )
              } else {
                buf.write_string("    - \{name}(\{args}) -> \{status}\n")
              }
            }
          }
        }
        let output = format_input_contents(result.content)
        write_yaml_field(buf, "  output", output, 4)
      }
    }
  }
  buf.to_string()
}

///|
fn format_input_contents(
  contents : ArrayView[@agent_loop.InputMessageContent],
) -> String {
  let parts : Array[String] = []
  for item in contents {
    match item {
      @agent_loop.InputMessageContent::Text(text) => parts.push(text)
      @agent_loop.InputMessageContent::Image(mime_type~, ..) =>
        parts.push("![image](\{mime_type})")
    }
  }
  parts.join("\n")
}

///|
fn write_yaml_field(
  buf : StringBuilder,
  key : String,
  value : String,
  block_indent : Int32,
) -> Unit {
  let trimmed = value.trim_end(chars="\n")
  if trimmed.is_empty() {
    buf.write_string("\{key}: \"\"\n")
    return
  }
  let needs_block = trimmed.contains("\n") ||
    trimmed.has_prefix("-") ||
    trimmed.has_prefix("#") ||
    trimmed.has_prefix("{") ||
    trimmed.has_prefix("[") ||
    trimmed.has_prefix(">") ||
    trimmed.has_prefix("!") ||
    trimmed.has_prefix(":") ||
    trimmed.contains(": ") ||
    trimmed.contains(" #")
  if !needs_block {
    buf.write_string("\{key}: \{trimmed}\n")
    return
  }
  let pad = " ".repeat(block_indent)
  buf.write_string("\{key}: |-\n")
  for line_view in trimmed.split("\n") {
    let line = line_view.trim_end(chars=" \t\r")
    if line.is_empty() {
      buf.write_string("\n")
    } else {
      buf.write_string("\{pad}\{line}\n")
    }
  }
}
