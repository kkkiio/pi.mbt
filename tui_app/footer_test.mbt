///|
extern "js" fn plain(value : String) -> String =
  #|(value) => value.replace(/\x1b\[[0-?]*[ -\/]*[@-~]/g, '')

///|
fn usage(
  input : Int,
  output : Int,
  read : Int,
  write : Int,
) -> @agent_loop.Usage {
  @agent_loop.Usage::{
    input,
    output,
    cache_read: read,
    cache_write: write,
    cache_write_1h: None,
    reasoning: None,
    total_tokens: input + output + read + write,
    cost: @agent_loop.UsageCost::{
      input: 0.0,
      output: 0.0,
      cache_read: 0.0,
      cache_write: 0.0,
      total: 0.0,
    },
  }
}

///|
async test "footer accumulates usage and preserves assistant cache rate across tool usage" {
  @tui_app.load_module()
  let footer = @tui_app.Footer::new(
    @tui_app.Theme::load("light"),
    "model",
    "/tmp",
    "",
  )
  footer.set_usage(usage(1000, 2, 1000, 0))
  footer.set_usage(usage(999, 3, 0, 1), update_cache_hit=false)
  let lines = @tui_app.Widget::render(footer, 80)
  let stats = plain(lines[1])
  assert_true(stats.contains("↑2.0k ↓5 R1.0k W1 CH50.0%"))
}

///|
async test "footer hides cache hit without cache totals and reset is instance-local" {
  @tui_app.load_module()
  let theme = @tui_app.Theme::load("light")
  let first = @tui_app.Footer::new(theme, "m", "/tmp", "")
  let second = @tui_app.Footer::new(theme, "m", "/tmp", "")
  first.set_usage(usage(10, 0, 0, 0))
  assert_false(plain(@tui_app.Widget::render(first, 40)[1]).contains("CH"))
  first.reset_usage()
  assert_false(plain(@tui_app.Widget::render(first, 40)[1]).contains("↑"))
  assert_false(plain(@tui_app.Widget::render(second, 40)[1]).contains("↑"))
}

///|
async test "footer rounds boundaries, truncates right without ellipsis, and sanitizes labels" {
  @tui_app.load_module()
  let footer = @tui_app.Footer::new(
    @tui_app.Theme::load("light"),
    "long-model-name",
    "/tmp",
    "",
  )
  footer.set_branch(Some("main\nbranch"))
  footer.set_session_name(Some(" session\tname "))
  footer.set_usage(usage(1999, 0, 0, 0))
  let wide = @tui_app.Widget::render(footer, 80)
  assert_true(plain(wide[0]).contains("(main branch) • session name"))
  assert_true(plain(wide[1]).contains("↑2.0k"))
  let narrow = plain(@tui_app.Widget::render(footer, 12)[1])
  assert_false(narrow.contains("..."))
  assert_true(narrow.contains("long-"))
}

///|
async test "footer can display unknown occupancy with a known context window" {
  @tui_app.load_module()
  let footer = @tui_app.Footer::new(
    @tui_app.Theme::load("light"),
    "",
    "/tmp",
    "",
  )
  footer.set_context_unknown(1999)
  assert_true(plain(@tui_app.Widget::render(footer, 30)[1]).contains("?/2.0k"))
}
