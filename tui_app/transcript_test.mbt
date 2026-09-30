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
      #|────────────────────────────────────────
      #| $ python3 - <<'PY'
      #| print("greeting")
      #| PY
      #|────────────────────────────────────────
    ),
  )
}

///|
/// Long physical lines must wrap before the preview limit is applied. Bash
/// keeps the tail (the final diagnostic); generic tools keep the beginning.
async test "tool previews count visual rows and preserve expanded output" {
  @tui_app.load_module()
  for (name, limit) in [("bash", 20), ("grep", 10)] {
    let transcript = @tui_app.Transcript::new(@tui_app.Theme::load("light"))
    let output = "0123456789".repeat(limit + 2)
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
    assert_eq(
      collapsed[2],
      if name == "bash" {
        " 0123456789"
      } else {
        " HEAD      "
      },
    )
    if name == "bash" {
      assert_eq(collapsed[limit + 1], " TAIL")
    }
    transcript.set_expanded_tool_output(true)
    let expanded = render_rows(transcript, 11)
    // Framing/header = 2 rows, output = limit + 4 rows, final frame = 1 row.
    assert_eq(expanded.length(), limit + 7)
    for row in 3..<(limit + 5) {
      assert_eq(expanded[row].trim().to_owned(), "0123456789")
    }
    assert_eq(expanded[2].trim().to_owned(), "HEAD")
    assert_eq(expanded[limit + 5].trim().to_owned(), "TAIL")
    // A resize must rewrap the raw text, not a cached preview.
    let wider = render_rows(transcript, 21)
    assert_eq(wider[3].trim().to_owned(), "01234567890123456789")
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
      #| grep first...                          
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
      #|────────────────────────────────────────
      #| $ printf a
      #| a
      #| b
      #|────────────────────────────────────────
    ),
  )
}

///|
/// bash 的结果文本已经写了真实原因(`exit 2` / 超时 / 中断),所以块尾只标一个不
/// 谎报的失败记号;pi 的 `bash-execution.ts` 同样只在拿得到真实退出码时才写
/// `(exit N)`。
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
      #|────────────────────────────────────────
      #| $ exit 2
      #| Command exited with code 2
      #| (failed)
      #|────────────────────────────────────────
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
  let live = render_rows(app.transcript, 60).join("\n")
  assert_true(live.contains("$ printf ALPHA\n ALPHA"))
  assert_true(live.contains("$ printf OMEGA\n OMEGA"))
  let sessions = @coding_agent.list_sessions(dir)
  assert_eq(sessions.length(), 1)
  host.load_session("\{dir}/\{sessions[0]}.jsonl", app)
  assert_eq(render_rows(app.transcript, 60).join("\n"), live)
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
    let rendered = render_rows(transcript, 60).join("\n")
    assert_eq(transcript.item_count(), 2)
    assert_true(rendered.contains("$ printf ALPHA\n ALPHA"))
    assert_true(rendered.contains("$ printf OMEGA\n OMEGA"))
  }
}
