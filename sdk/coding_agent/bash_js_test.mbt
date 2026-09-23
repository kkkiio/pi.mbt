///|
fn bash_tool() -> @tools.CallableDefinition raise {
  let definition = @coding_agent.new_bash_tool_definition(cwd="/tmp")
  guard definition.callable_definition is Some(callable) else {
    fail("bash tool has no callable definition")
  }
  callable
}

///|
/// The tool reports failures with `fail(...)`, whose text carries the raise
/// location; drop that wrapper so a snapshot pins the message itself.
fn failure_message(error_text : String) -> String {
  match error_text.rev_split_once(" FAILED: ") {
    Some((_, message)) =>
      match message.strip_suffix(")") {
        Some(rest) => rest.to_owned()
        None => message.to_owned()
      }
    None => error_text
  }
}

///|
async test "bash tool returns merged output, exit code and details" {
  let result = (bash_tool().execute)(
    "call-1",
    { "command": "echo out; echo err 1>&2" },
    (_, _) => (),
  )
  json_inspect(result, content={
    "content": [{ "type": "text", "text": "out\nerr\n" }],
    "details": { "truncation": null, "fullOutputPath": null },
    "isError": false,
    "terminate": false,
    "usage": null,
  })
}

///|
async test "bash tool reports a non-zero exit code" {
  let message = try {
    ignore(
      (bash_tool().execute)("call-2", { "command": "echo before; exit 3" }, (
        _,
        _,
      ) => ()),
    )
    fail("expected the tool to fail")
  } catch {
    err => failure_message(err.to_string())
  }
  inspect(message, content="before\n\n\nCommand exited with code 3")
}

///|
async test "bash tool kills the command on timeout" {
  let message = try {
    ignore(
      (bash_tool().execute)(
        "call-3",
        { "command": "echo started; sleep 5", "timeout": 1 },
        (_, _) => (),
      ),
    )
    fail("expected the tool to fail")
  } catch {
    err => failure_message(err.to_string())
  }
  inspect(message, content="started\n\n\nCommand timed out after 1 seconds")
}

///|
async test "bash tool streams throttled updates and a terminal update" {
  let updates : Array[Array[@agent_loop.InputMessageContent]] = []
  let result = (bash_tool().execute)(
    "call-4",
    { "command": "for i in 1 2 3 4; do echo tick$i; sleep 0.15; done" },
    (content, _detail) => updates.push(content),
  )
  json_inspect(result, content={
    "content": [{ "type": "text", "text": "tick1\ntick2\ntick3\ntick4\n" }],
    "details": { "truncation": null, "fullOutputPath": null },
    "isError": false,
    "terminate": false,
    "usage": null,
  })
  // The terminal update replays exactly what the tool returned; `> 2` also pins
  // that a mid-stream update arrived while the command was still running (the
  // JS timer's job). How many arrive depends on timing, so only the threshold
  // is asserted.
  assert_eq(updates[updates.length() - 1].to_json(), result.content.to_json())
  assert_true(updates.length() > 2)
}

///|
async test "bash tool spills truncated output to a temp file" {
  // 200 lines x 601 bytes = 120200 raw bytes, past the 50KB display limit.
  let result = (bash_tool().execute)(
    "call-5",
    { "command": "seq 1 200 | awk '{printf \"%0600d\\n\", $1}'" },
    (_, _) => (),
  )
  guard result.details is { "fullOutputPath": String(path), .. } else {
    fail(
      "expected a spilled output path, details=\{result.details.stringify()}",
    )
  }
  guard result.content is [@agent_loop.InputMessageContent::Text(text)] else {
    fail("expected a single text part, got \{result.details.stringify()}")
  }
  // The display text is 50KB of numbers plus a footer naming the spill file;
  // only the footer's stable prefix is snapshot, and the path it prints is
  // checked against the path in `details` rather than pinned.
  match text.rev_split_once("Full output: ") {
    Some((head, tail)) => {
      match head.rev_split_once("\n\n") {
        Some((_, footer)) =>
          inspect(
            footer,
            content="[Showing lines 116-200 of 200 (51200 byte limit). ",
          )
        None => fail("expected a truncation footer, got \{head}")
      }
      // The footer names the same path the details carry; assert the relation
      // instead of pinning a temp path into a snapshot.
      assert_eq(tail, "\{path}]")
    }
    None => fail("expected a truncation footer")
  }
  let spilled = @coding_agent.read_bytes_file(path)
  assert_eq(spilled.length(), 200 * 601)
  @coding_agent.remove_file(path)
  match path.rev_before("/") {
    Some(directory) => @coding_agent.remove_dir(directory.to_owned())
    None => ()
  }
}
