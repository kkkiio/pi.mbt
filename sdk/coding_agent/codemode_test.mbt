///|
/// A scripted `@codemode.VmChannel`: `recv` returns each queued frame (a
/// message or a batch array) and raises once the feed is empty; `send` is
/// captured so tests can inspect the `StartVmRequest`.
priv struct FakeVm {
  feed : Array[Json]
  sent : Array[Json]
}

///|
impl @codemode.VmChannel for FakeVm with fn send(self : FakeVm, data : Json) -> Unit {
  self.sent.push(data)
}

///|
impl @codemode.VmChannel for FakeVm with fn recv(self : FakeVm) -> Json {
  if self.feed is [] {
    fail("channel closed")
  } else {
    self.feed.remove(0)
  }
}

///|
impl @codemode.VmChannel for FakeVm with fn close(self : FakeVm) -> Unit {
  self.feed.clear()
}

///|
fn codemode_tool(vm : &@codemode.VmChannel) -> @tools.ToolDefinition {
  @coding_agent.new_codemode_tool_definition(
    tools=[],
    vm_launcher=Some(fn() -> &@codemode.VmChannel { vm }),
  )
}

///|
async fn run_codemode(
  tool : @tools.ToolDefinition,
  code : String,
  tool_call_id~ : String = "call-1",
  on_update~ : @agent_loop.ToolExecUpdateCallback = (_, _) => (),
) -> @agent_loop.ToolResult {
  (tool.execute)(tool_call_id, { "code": Json::string(code) }, on_update)
}

///|
/// 超过 `max_output_tokens` 预算的文本折成一项(头尾各留一半),全文写到
/// 溢出文件;`details.fullOutputPath` 与文本里的路径一致。
async test "codemode output over the token budget truncates and spills" {
  let big = "x".repeat(1200)
  let vm = FakeVm::{
    feed: [
      {
        "type": "output",
        "item": { "type": "text", "text": Json::string(big) },
      },
      { "type": "done", "ok": true, "writes": "[]" },
    ],
    sent: [],
  }
  let result = run_codemode(
    codemode_tool(vm),
    "// @options: {\"max_output_tokens\": 50}\nwork()",
  )
  assert_false(result.is_error)
  guard result.details is { "fullOutputPath": String(path), .. } else {
    fail(
      "expected a spilled output path, details=\{result.details.stringify()}",
    )
  }
  guard result.content is [_, @agent_loop.InputMessageContent::Text(text)] else {
    fail("expected a single collapsed text item")
  }
  let head = "x".repeat(100)
  assert_true(
    text.has_prefix(
      "Warning: truncated output (original token count: 300)\nTotal output lines: 1\n\n\{head}…250 tokens truncated…\{head}",
    ),
  )
  assert_true(
    text.has_suffix("\n\n[Full output: \{path} (read with offset/limit)]"),
  )
  assert_true(path.contains("pi-codemode-"))
  assert_true(path.has_suffix("/output.log"))
  assert_eq(@coding_agent.read_text_file(path), big)
  @coding_agent.remove_file(path)
  match path.rev_before("/") {
    Some(directory) => @coding_agent.remove_dir(directory.to_owned())
    None => ()
  }
}

///|
/// 图片项落盘成临时文件,前面贴 `[Image saved to PATH (mimeType, SIZE)]`;
/// 相同 data 只保存一次。
async test "codemode image output is saved to a temp file with a label" {
  let bytes : Bytes = b"\x01\x02\x03"
  let data = @base64.encode(bytes[:])
  let vm = FakeVm::{
    feed: [
      {
        "type": "output",
        "item": {
          "type": "image",
          "data": Json::string(data),
          "mimeType": "image/png",
        },
      },
      {
        "type": "output",
        "item": {
          "type": "image",
          "data": Json::string(data),
          "mimeType": "image/png",
        },
      },
      { "type": "done", "ok": true, "writes": "[]" },
    ],
    sent: [],
  }
  let result = run_codemode(codemode_tool(vm), "work()")
  assert_false(result.is_error)
  guard result.content
    is [
      _,
      @agent_loop.InputMessageContent::Text(first_label),
      @agent_loop.InputMessageContent::Image(..),
      @agent_loop.InputMessageContent::Text(second_label),
      @agent_loop.InputMessageContent::Image(..),
    ] else {
    fail("expected label/image pairs")
  }
  assert_eq(first_label, second_label)
  guard first_label.strip_prefix("[Image saved to ") is Some(rest) else {
    fail("unexpected label \{first_label}")
  }
  guard rest.rev_before(" (image/png, 3B)]") is Some(path_view) else {
    fail("unexpected label \{first_label}")
  }
  let path = path_view.to_owned()
  assert_true(path.contains("pi-codemode-"))
  assert_true(path.has_suffix("/output.png"))
  assert_eq(@coding_agent.read_bytes_file(path), bytes)
  @coding_agent.remove_file(path)
  match path.rev_before("/") {
    Some(directory) => @coding_agent.remove_dir(directory.to_owned())
    None => ()
  }
}
