///|
/// Render session journal entries into a deterministic YAML transcript.
///
/// - `entries`: `SessionEntry` sequence from a session journal.
/// - Returns: YAML conversation transcript after applying `ContextEdit` omissions, or `"[]\n"` when no messages remain.
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
/// Render `AgentMessage` items into a deterministic YAML transcript.
///
/// - `messages`: `AgentMessage` sequence (`User`, `Assistant`, `ToolResult`).
/// - Returns: Human-readable YAML transcript string, or `"[]\n"` when `messages` is empty.
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
              let entry = if call is { "error": String(err), .. } {
                "\{name}(\{args}) -> \{status}: \{err}"
              } else {
                "\{name}(\{args}) -> \{status}"
              }
              write_yaml_list_item(buf, entry, 4)
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
  if !needs_yaml_block(trimmed) {
    buf.write_string("\{key}: \{trimmed}\n")
    return
  }
  buf.write_string("\{key}: |-\n")
  write_yaml_block_lines(buf, trimmed, block_indent)
}

///|
fn write_yaml_list_item(
  buf : StringBuilder,
  value : String,
  indent : Int32,
) -> Unit {
  let pad = " ".repeat(indent)
  let trimmed = value.trim_end(chars="\n")
  if !needs_yaml_block(trimmed) {
    buf.write_string("\{pad}- \{trimmed}\n")
    return
  }
  buf.write_string("\{pad}- |-\n")
  write_yaml_block_lines(buf, trimmed, indent + 2)
}

///|
fn write_yaml_block_lines(
  buf : StringBuilder,
  value : StringView,
  indent : Int32,
) -> Unit {
  let pad = " ".repeat(indent)
  for line_view in value.split("\n") {
    let line = line_view.trim_end(chars=" \t\r")
    if line.is_empty() {
      buf.write_string("\n")
    } else {
      buf.write_string("\{pad}\{line}\n")
    }
  }
}

///|
fn needs_yaml_block(value : StringView) -> Bool {
  if value.contains("\n") ||
    value.contains(": ") ||
    value.contains(" #") ||
    value.has_suffix(":") ||
    value.has_prefix(" ") {
    return true
  }
  let indicators = [
    "-", "?", ":", ",", "[", "]", "{", "}", "#", "&", "*", "!", "|", ">", "'", "\"",
    "%", "@", "`", "~", "=",
  ]
  for ind in indicators {
    if value.has_prefix(ind) {
      return true
    }
  }
  let parsed : Json = @json.parse(value) catch { _ => return false }
  match parsed {
    Json::String(text) => text != value.to_owned()
    _ => true
  }
}
