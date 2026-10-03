// Transcript 渲染契约测试。
//
// pi-tui 的差分渲染把 `render(width)` 的**每个元素当成终端的一行**写:
//
//   \x1b[<row>;1H \x1b[2K <line>
//
// 元素里如果含 `\n`/`\r`,终端会把换行后的内容写到下一个物理行(通常是底部 dock,
// 也就是输入框所在的那几行),而差分渲染只重画「模型串变了」的行 —— 溅进输入框的
// 那段 transcript 文字就再也不会被修掉。所以这里钉住不变量:
//
//   每个元素 = 一行、不含换行、不超过渲染宽度。

///|
/// 测试辅助:剥掉 ANSI 颜色,便于把渲染结果 inspect 成纯文本。
extern "js" fn strip_ansi(text : String) -> String =
  #| (text) => text.split(new RegExp(String.fromCharCode(27) + '\\[[0-9;]*m', 'g')).join('')

///|
/// 剥色 + 逐行断言「一行 = 一个元素」契约。
fn assert_rows(lines : Array[String], width : Int) -> Array[String] raise {
  let rows : Array[String] = []
  for index, line in lines {
    let text = strip_ansi(line)
    assert_false(
      text.contains("\n") || text.contains("\r"),
      msg="row \{index} carries an embedded line break: \{text}",
    )
    assert_true(
      @tui_app.visible_width(line) <= width,
      msg="row \{index} is wider than \{width}: \{text}",
    )
    rows.push(text)
  }
  rows
}

///|
/// 渲染一条聊天记录并断言行契约。
fn render_rows(
  transcript : @tui_app.Transcript,
  width : Int,
) -> Array[String] raise {
  assert_rows(@tui_app.Widget::render(transcript, width), width)
}

///|
/// 多行 bash 命令(heredoc)必须按物理行拆成多个元素。
async test "multi-line bash command renders one row per element" {
  @tui_app.load_module()
  let transcript = @tui_app.Transcript::new(@tui_app.Theme::load("light"))
  transcript.push_user("run the snippet")
  transcript.push_tool_call(
    "bash",
    { "command": "python3 - <<'PY'\nprint(\"greeting\")\nPY" },
    id="call-bash",
  )
  inspect(
    render_rows(transcript, 40).join("\n"),
    content=(
      #|                                        
      #| run the snippet                        
      #|                                        
      #|
      #|                                        
      #| $ python3 - <<'PY'                     
      #| print("greeting")                      
      #| PY                                     
      #|                                        
    ),
  )
}

///|
/// Long physical lines must wrap before the preview limit is applied. Bash
/// keeps the tail (the final diagnostic); generic tools keep the beginning.
async test "tool previews count visual rows and preserve expanded output" {
  @tui_app.load_module()
  for (name, limit) in [("bash", 5), ("grep", 10)] {
    let transcript = @tui_app.Transcript::new(@tui_app.Theme::load("light"))
    let output = "012345678".repeat(limit + 2)
    transcript.push_tool_call(
      name,
      { "command": "run", "pattern": "match" },
      id=name,
    )
    transcript.push_tool_result(
      name,
      "HEAD\n" + output + "\nTAIL",
      false,
      id=name,
    )
    let collapsed = render_rows(transcript, 11)
    let rows = collapsed.map(row => row.trim().to_owned())
    assert_eq(
      rows.filter(row => row == "012345678").length(),
      if name == "bash" {
        4
      } else {
        9
      },
    )
    assert_eq(rows.contains("HEAD"), name != "bash")
    assert_eq(rows.contains("TAIL"), name == "bash")
    let theme = @tui_app.Theme::load("light")
    let foreground = theme
      .fg("toolOutput", "")
      .strip_suffix("\u{1b}[39m")
      .unwrap()
      .to_owned()
    for line in @tui_app.Widget::render(transcript, 11) {
      if strip_ansi(line).contains("012345678") {
        assert_true(line.contains(foreground))
      }
    }
    transcript.set_expanded_tool_output(true)
    let expanded = render_rows(transcript, 11)
    let rows = expanded.map(row => row.trim().to_owned())
    assert_eq(rows.filter(row => row == "012345678").length(), limit + 2)
    assert_true(rows.contains("HEAD"))
    assert_true(rows.contains("TAIL"))
    // A resize must rewrap the raw text, not a cached preview.
    let wider = render_rows(transcript, 20)
    assert_true(
      wider.map(row => row.trim().to_owned()).contains("012345678012345678"),
    )
  }
}

///|
async test "tool rows respect narrow widths and wide unicode with ANSI" {
  @tui_app.load_module()
  let transcript = @tui_app.Transcript::new(@tui_app.Theme::load("light"))
  for name in ["bash", "grep", "read"] {
    transcript.push_tool_call(
      name,
      { "command": "echo diagnostic", "path": "/a/very/long/path/to/a/file" },
      id=name,
    )
    transcript.push_tool_result(
      name,
      "\u{1b}[31m中文🙂é\u{1b}[0m".repeat(30),
      true,
      id=name,
    )
  }
  for expanded in [false, true] {
    transcript.set_expanded_tool_output(expanded)
    for width in [0, 1, 2, 8, 40] {
      let _ = render_rows(transcript, width)
    }
  }
}

///|
/// 其他工具的摘要参数也可能带换行(这里用 `grep` 的 pattern)。
async test "multi-line tool summary renders one row per element" {
  @tui_app.load_module()
  let transcript = @tui_app.Transcript::new(@tui_app.Theme::load("light"))
  transcript.push_tool_call(
    "grep",
    { "pattern": "first\nsecond" },
    id="call-grep",
  )
  inspect(
    render_rows(transcript, 40).join("\n"),
    content=(
      #|                                        
      #| grep                                   
      #|                                        
      #| {                                      
      #|   "pattern": "first\nsecond"           
      #| }                                      
      #|                                        
    ),
  )
}

///|
/// 文本来自模型/用户,换行风格不受控:多行用户消息与 CRLF 工具结果都不能带出
/// 裸换行(`\n` 或 `\r`)。
async test "multi-line user message and CRLF tool result render one row per element" {
  @tui_app.load_module()
  let transcript = @tui_app.Transcript::new(@tui_app.Theme::load("light"))
  transcript.push_user("line one\nline two")
  transcript.push_tool_call("bash", { "command": "printf a" }, id="call-bash")
  transcript.push_tool_result("bash", "a\r\nb", false, id="call-bash")
  inspect(
    render_rows(transcript, 40).join("\n"),
    content=(
      #|                                        
      #| line one                               
      #| line two                               
      #|                                        
      #|
      #|                                        
      #| $ printf a                             
      #|                                        
      #| a                                      
      #| b                                      
      #|                                        
    ),
  )
}

///|
/// 错误背景保留工具提供的真实退出原因。
async test "a failed bash result marks failure without inventing an exit code" {
  @tui_app.load_module()
  let transcript = @tui_app.Transcript::new(@tui_app.Theme::load("light"))
  transcript.push_tool_call("bash", { "command": "exit 2" }, id="call-bash")
  transcript.push_tool_result(
    "bash",
    "Command exited with code 2",
    true,
    id="call-bash",
  )
  inspect(
    render_rows(transcript, 40).join("\n"),
    content=(
      #|                                        
      #| $ exit 2                               
      #|                                        
      #| Command exited with code 2             
      #|                                        
    ),
  )
}

///|
/// Live execution adds each call before its result, but replay adds both calls
/// first. Neither path may exchange outputs between calls to the same tool.
async test "resumed same-name tool calls retain their live output pairing" {
  let dir = @coding_agent.create_temp_dir("pim-replay-tools-")
  defer @coding_agent.remove_dir(dir)
  let llm = @faux.FauxLLM::FauxLLM()
  llm.set_responses([
    @faux.faux_message(
      [
        @faux.faux_tool_call("bash", { "command": "printf ALPHA" }, id="call-z"),
        @faux.faux_tool_call("bash", { "command": "printf OMEGA" }, id="call-a"),
      ],
      stop_reason=@agent_loop.StopReason::ToolUse,
    ),
    @faux.faux_message([@faux.faux_text("DONE")]),
  ])
  let host = @tui_app.SessionHost::new(llm, dir, Some(dir))
  defer host.close()
  let app = @tui_app.TuiApp::load("test", dir, "high")
  defer app.stop()
  app.reset_transcript()
  host.attach(app)
  app.submit("go")
  host.prompt(app.take_submission(), app)
  let live = render_rows(app.transcript, 60)
    .map(row => row.trim().to_owned())
    .filter(row => !row.is_empty() && !row.has_prefix("Took "))
  assert_eq(
    live.join("\n"),
    "go\n$ printf ALPHA\nALPHA\n$ printf OMEGA\nOMEGA\nDONE",
  )
  let sessions = @coding_agent.list_sessions(dir)
  assert_eq(sessions.length(), 1)
  host.load_session("\{dir}/\{sessions[0]}.jsonl", app)
  let replayed = render_rows(app.transcript, 60)
    .map(row => row.trim().to_owned())
    .filter(row => !row.is_empty() && row != "Resumed session")
  assert_eq(replayed, live)
}

///|
/// Results can arrive in either order; neither name nor FIFO/LIFO order is an ID.
async test "same-name tool results match call IDs in either result order" {
  @tui_app.load_module()
  for reversed in [false, true] {
    let transcript = @tui_app.Transcript::new(@tui_app.Theme::load("light"))
    transcript.push_tool_call(
      "bash",
      { "command": "printf ALPHA" },
      id="call-z",
    )
    transcript.push_tool_call(
      "bash",
      { "command": "printf OMEGA" },
      id="call-a",
    )
    let results = if reversed {
      [("call-a", "OMEGA"), ("call-z", "ALPHA")]
    } else {
      [("call-z", "ALPHA"), ("call-a", "OMEGA")]
    }
    for (id, text) in results {
      transcript.push_tool_result("bash", text, false, id~)
    }
    let rendered = render_rows(transcript, 60)
      .map(row => row.trim().to_owned())
      .filter(row => !row.is_empty())
      .join("\n")
    assert_eq(transcript.item_count(), 2)
    assert_eq(rendered, "$ printf ALPHA\nALPHA\n$ printf OMEGA\nOMEGA")
  }
}

///|
async test "tool status backgrounds survive bold and embedded ANSI reset" {
  @tui_app.load_module()
  let theme = @tui_app.Theme::load("light")
  let transcript = @tui_app.Transcript::new(theme)
  transcript.push_tool_call("bash", { "command": "echo OK" }, id="call")
  let pending = @tui_app.Widget::render(transcript, 40)
  assert_eq(pending[0], theme.bg("toolPendingBg", " ".repeat(40)))
  assert_false(pending[1].contains("\u{1b}[0m"))
  transcript.push_tool_result(
    "bash",
    "\u{1b}[31mOK\u{1b}[0m END",
    false,
    id="call",
  )
  let success = @tui_app.Widget::render(transcript, 40)
  assert_eq(success[0], theme.bg("toolSuccessBg", " ".repeat(40)))
  let open = theme
    .bg("toolSuccessBg", "")
    .strip_suffix("\u{1b}[49m")
    .unwrap()
    .to_owned()
  assert_true(success[3].contains("\u{1b}[0m" + open))
  let failed = @tui_app.Transcript::new(theme)
  failed.push_tool_call("bash", { "command": "exit 7" }, id="failure")
  failed.push_tool_result(
    "bash",
    "Command exited with code 7",
    true,
    id="failure",
  )
  assert_eq(
    @tui_app.Widget::render(failed, 40)[0],
    theme.bg("toolErrorBg", " ".repeat(40)),
  )
}

///|
async test "assistant preserves alternating content and termination notices" {
  @tui_app.load_module()
  let transcript = @tui_app.Transcript::new(@tui_app.Theme::load("light"))
  transcript.start_assistant()
  transcript.set_assistant_content([
    ("First", false),
    ("Reason", true),
    ("Last", false),
  ])
  transcript.finish_assistant("length", None)
  inspect(
    render_rows(transcript, 60).join("\n"),
    content=(
      #| First                                                      
      #|
      #| Reason                                                     
      #|
      #| Last                                                       
      #|
      #| Response was truncated before completion.
    ),
  )
  transcript.set_expanded_thinking(false)
  transcript.finish_assistant("aborted", Some("Request was aborted"))
  inspect(
    render_rows(transcript, 60).join("\n"),
    content=(
      #| First                                                      
      #|
      #| Thinking...
      #|
      #| Last                                                       
      #|
      #| Operation aborted
    ),
  )
}

///|
async test "read errors remain visible when collapsed and ranges retain offset" {
  @tui_app.load_module()
  let transcript = @tui_app.Transcript::new(@tui_app.Theme::load("light"))
  transcript.push_tool_call(
    "read",
    { "path": "src/main.ts", "offset": 7, "limit": 3 },
    id="read",
  )
  transcript.push_tool_result("read", "ENOENT: src/main.ts", true, id="read")
  inspect(
    render_rows(transcript, 50).join("\n"),
    content=(
      #|                                                  
      #| read src/main.ts:7-9                             
      #|                                                  
      #| ENOENT: src/main.ts                              
      #|                                                  
    ),
  )
}

///|
async test "status retains spinner and editor overflow at narrow widths" {
  @tui_app.load_module()
  let status = @tui_app.StatusLine::new(
    @tui_app.Theme::load("light"),
    thinking="high",
  )
  status.set_working("thinking")
  let line = status.render_border(40, hidden_lines=7).unwrap()
  assert_true(strip_ansi(line).contains("⠋"))
  assert_true(strip_ansi(line).contains("↑ 7 more"))
  for width in [0, 1, 2, 8, 40] {
    assert_eq(
      @tui_app.visible_width(status.render_border(width).unwrap()),
      width,
    )
  }
  status.set_retry(2, 3, 3000)
  assert_true(
    strip_ansi(status.render_border(80).unwrap()).contains(
      "Retrying (2/3) in 3s",
    ),
  )
}

///|
async test "individual clicks preserve other blocks and global toggles reset overrides" {
  @tui_app.load_module()
  let transcript = @tui_app.Transcript::new(@tui_app.Theme::load("light"))
  transcript.start_assistant()
  transcript.set_assistant_content([
    ("Reason A", true),
    ("Reason B", true),
    ("Text", false),
    ("Reason C", true),
  ])
  assert_true(transcript.click(0, 60))
  let collapsed = render_rows(transcript, 60).join("\n")
  assert_false(collapsed.contains("Reason A"))
  assert_false(collapsed.contains("Reason B"))
  assert_true(collapsed.contains("Reason C"))
  transcript.set_expanded_thinking(true)
  assert_true(render_rows(transcript, 60).join("\n").contains("Reason B"))
  let tools = @tui_app.Transcript::new(@tui_app.Theme::load("light"))
  for id in ["first", "second"] {
    tools.push_tool_call("bash", { "command": id }, id~)
    tools.push_tool_result(
      "bash",
      "HEAD \{id}\n2\n3\n4\n5\nTAIL \{id}",
      false,
      id~,
    )
  }
  assert_false(tools.click(1, 60)) // command is not the result click target
  assert_true(tools.click(3, 60))
  let expanded = render_rows(tools, 60).join("\n")
  assert_true(expanded.contains("HEAD first"))
  assert_false(expanded.contains("HEAD second"))
  tools.set_expanded_tool_output(false)
  assert_false(render_rows(tools, 60).join("\n").contains("HEAD first"))
  // Reflow before clicking the second result; do not use the old wide-row position.
  let narrow = render_rows(tools, 16)
  let mut tail_row = -1
  for index, row in narrow {
    if row.contains("TAIL second") {
      tail_row = index
    }
  }
  assert_true(tools.click(tail_row, 16))
  assert_true(render_rows(tools, 60).join("\n").contains("HEAD second"))
}

///|
async test "bash truncation distinguishes byte limits and preserves untruncated footers" {
  @tui_app.load_module()
  for truncated in [true, false] {
    let transcript = @tui_app.Transcript::new(@tui_app.Theme::load("light"))
    transcript.push_tool_call("bash", { "command": "run" }, id="call")
    transcript.push_tool_result(
      "bash",
      "output\n\n[Original /tmp/output]",
      false,
      id="call",
      details=Some({
        "fullOutputPath": "/tmp/output",
        "truncation": {
          "truncated": truncated,
          "truncatedBy": "bytes",
          "outputLines": 3,
          "totalLines": 7,
          "maxBytes": 2048,
        },
      }),
    )
    let rows = render_rows(transcript, 80).join("\n")
    assert_eq(rows.contains("Original"), !truncated)
    assert_eq(rows.contains("3 lines shown (2.0KB limit)"), truncated)
    assert_false(rows.contains("showing 3 of 7 lines"))
  }
}

///|
async test "bash preview and expansion retain whitespace-sensitive output" {
  @tui_app.load_module()
  for truncated in [false, true] {
    let transcript = @tui_app.Transcript::new(@tui_app.Theme::load("light"))
    transcript.push_tool_call(
      "bash",
      { "command": "printf indented" },
      id="call",
    )
    let text = "  value\n\n" +
      (if truncated {
        "\n\n[Showing lines 4-6 of 6. Full output: /tmp/full]"
      } else {
        ""
      })
    transcript.push_tool_result(
      "bash",
      text,
      false,
      id="call",
      details=if truncated {
        Some({
          "fullOutputPath": "/tmp/full",
          "truncation": {
            "truncated": true,
            "truncatedBy": "lines",
            "outputLines": 3,
            "totalLines": 6,
          },
        })
      } else {
        None
      },
    )
    for expanded in [false, true] {
      transcript.set_expanded_tool_output(expanded)
      let rows = render_rows(transcript, 80)
      assert_eq(rows.length(), if truncated { 9 } else { 7 })
      assert_eq(rows[3], "   value" + " ".repeat(72))
      assert_eq(rows[4], " ".repeat(80))
      assert_eq(rows[5], " ".repeat(80))
      assert_false(rows.join("\n").contains("Showing lines"))
    }
  }
}

///|
async test "card backgrounds restore shorthand and combined resets without mistaking RGB zeroes" {
  @tui_app.load_module()
  let theme = @tui_app.Theme::load("light")
  let open = theme
    .bg("toolSuccessBg", "")
    .strip_suffix("\u{1b}[49m")
    .unwrap()
    .to_owned()
  for reset in ["\u{1b}[m", "\u{1b}[0;32m", "\u{1b}[1;49m", "\u{1b}[;32m"] {
    assert_true(
      theme
      .bg("toolSuccessBg", "before" + reset + "after")
      .contains(reset + open),
    )
  }
  for
    color in [
      "\u{1b}[38;2;0;49;0m", "\u{1b}[48;2;0;49;0m", "\u{1b}[38:2::0:49:0m",
    ] {
    assert_false(
      theme.bg("toolSuccessBg", color + "text").contains(color + open),
    )
  }
}

///|
async test "cached markdown follows content, width, and thinking changes" {
  @tui_app.load_module()
  let transcript = @tui_app.Transcript::new(@tui_app.Theme::load("light"))
  transcript.push_user("A user **message**")
  transcript.start_assistant()
  transcript.set_assistant_content([("Alpha **bold** omega", false)])
  let first = @tui_app.Widget::render(transcript, 50)
  assert_eq(@tui_app.Widget::render(transcript, 50), first)
  transcript.set_assistant_content([("Replacement", false)])
  let replacement = render_rows(transcript, 50).join("\n")
  assert_true(replacement.contains("Replacement"))
  assert_false(replacement.contains("Alpha"))
  let text = @tui_app.Widget::render(transcript, 50)
  transcript.set_assistant_content([("Replacement", true)])
  assert_true(@tui_app.Widget::render(transcript, 50) != text)
  transcript.set_expanded_thinking(false)
  assert_true(render_rows(transcript, 50).join("\n").contains("Thinking..."))
  transcript.set_expanded_thinking(true)
  let narrow = render_rows(transcript, 12)
  assert_true(narrow.length() > render_rows(transcript, 50).length())
  assert_eq(render_rows(transcript, 12), narrow)
}
