// dock 其他组件的行契约(断言与 `transcript_test.mbt` 共用同一套 helper)。

///|
/// 排队中的 follow-up 消息也占 dock 的行:多行消息必须一行一个元素,否则后半段会被
/// 终端写到编辑器边框/内容行上,而那些行的模型串没变 → 永远不会重画。
async test "multi-line pending message renders one row per element" {
  @tui_app.load_module()
  let pending = @tui_app.PendingList::new(@tui_app.Theme::load("light"), lines=[
    "first\nsecond",
  ])
  inspect(
    assert_rows(@tui_app.Widget::render(pending, 40), 40).join("\n"),
    content=(
      #|  Follow-up: first
      #|    second
    ),
  )
}

///|
async test "exit submissions interrupt immediately without waiting for the worker" {
  for command in [" /quit ", "/exit"] {
    let app = @tui_app.TuiApp::load("test", "/tmp", "high")
    defer app.stop()
    let mut interrupts = 0
    app.on_interrupt(() => interrupts += 1)
    app.begin_work("thinking")
    app.submit("queued prompt")
    app.submit(command)
    app.request_exit()
    assert_true(app.is_shutting_down())
    assert_eq(interrupts, 1)
    @async.with_timeout(1000, () => app.wait_for_exit())
  }
}

///|
async test "exit wait blocks until requested and wakes the idle worker" {
  let app = @tui_app.TuiApp::load("test", "/tmp", "high")
  defer app.stop()
  let mut exited = false
  @async.with_timeout(1000, () => {
    @async.with_task_group() <| group => {
      group.spawn_bg(async fn() {
        app.wait_for_exit()
        exited = true
      })
      @async.sleep(20)
      assert_false(exited)
      app.request_exit()
      assert_eq(app.take_submission(), "")
    }
  })
  assert_true(exited)
}

///|
async test "taking submissions consumes pending display in queue order" {
  let app = @tui_app.TuiApp::load("test", "/tmp", "high")
  defer app.stop()
  app.submit("first")
  app.begin_work("thinking")
  app.submit("second")
  app.submit("third")
  assert_eq(app.pending.val.lines.length(), 2)
  assert_eq(app.take_submission(), "first")
  assert_eq(app.pending.val.lines.length(), 2)
  assert_eq(app.take_submission(), "second")
  assert_eq(app.pending.val.lines.length(), 1)
  assert_eq(app.pending.val.lines[0], "third")
  assert_eq(app.take_submission(), "third")
  assert_true(app.pending.val.lines.is_empty())
}
