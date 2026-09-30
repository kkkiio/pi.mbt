///|
test "unknown theme name raises" {
  let raised = try {
    let _ = @tui_app.Theme::load("bogus")
    false
  } catch {
    _ => true
  }
  assert_true(raised)
}
