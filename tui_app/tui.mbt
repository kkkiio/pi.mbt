// pi-tui 的终端与全屏 TUI 包装(`ProcessTerminal` + `TuiAltScreen`)。
//
// 我们只用 pi-tui 的全屏渲染器:它自带差分渲染、滚动视窗、鼠标选择、搜索,
// 并在退出时把最终画面倒回主屏。

///|
extern "js" fn js_callback_string_fn(callback : () -> String) -> Value = "(callback) => callback"

///|
/// stdin/stdout 是否连到终端。TUI 模式的前提。
pub extern "js" fn stdin_is_tty() -> Bool = "() => process.stdin.isTTY === true"

///|
pub extern "js" fn stdout_is_tty() -> Bool = "() => process.stdout.isTTY === true"

///|
/// 进程终端(pi-tui `ProcessTerminal`):raw mode、resize、Kitty 键盘协议都在里面。
pub struct Terminal {
  handle : Value
}

///|
pub async fn terminal_new() -> Terminal {
  load()
  Terminal::{ handle: ns_get("ProcessTerminal").new(no_args()), }
}

///|
/// 排空 stdin,避免退出时残留的按键/转义序列漏给父 shell。
pub async fn Terminal::drain_input(
  self : Terminal,
  max_ms? : Int = 1000,
) -> Unit {
  let promise : @js_async.Promise[Unit] = call(self.handle, "drainInput", [
    Value::cast_from(max_ms),
  ])
  let _ = @js_async.Promise::wait(promise)
}

///|
/// 全屏 TUI(pi-tui `TuiAltScreen`)。
pub struct Tui {
  handle : Value
}

///|
/// 取消输入监听器的句柄。
pub struct Unlisten {
  handle : Value
}

///|
pub fn Unlisten::unlisten(self : Unlisten) -> Unit {
  let _ : Value = call(self.handle, "", no_args())
}

///|
pub async fn tui_new(
  terminal : Terminal,
  show_hardware_cursor? : Bool = true,
  mouse? : Bool = true,
  wheel_scroll_lines? : Int = 1,
  copy_on_select? : Bool = true,
  scroll_to_end_indicator? : (() -> String)? = None,
) -> Tui {
  load()
  let options = Object::new()
  options["mouse"] = mouse
  options["wheelScrollLines"] = wheel_scroll_lines
  options["copyOnSelect"] = copy_on_select
  match scroll_to_end_indicator {
    Some(render) =>
      options["scrollToEndIndicator"] = js_callback_string_fn(render)
    None => ()
  }
  let args : Array[Value] = [
    terminal.handle,
    Value::cast_from(show_hardware_cursor),
    Value::undefined(),
    options.to_value(),
  ]
  Tui::{ handle: ns_get("TuiAltScreen").new(args), }
}

///|
pub fn Tui::start(self : Tui) -> Unit {
  let _ : Value = call(self.handle, "start", no_args())
}

///|
/// 停止并恢复终端。`preserve_screen` 为假时把最终画面倒回主屏。
pub fn Tui::stop(self : Tui, preserve_screen? : Bool = false) -> Unit {
  let options = Object::new()
  options["preserveScreen"] = preserve_screen
  let _ : Value = call(self.handle, "stop", [options.to_value()])
}

///|
/// 排一次渲染(节流 16ms)。
pub fn Tui::request_render(self : Tui, force? : Bool = false) -> Unit {
  let _ : Value = call(self.handle, "requestRender", [Value::cast_from(force)])
}

///|
/// 立即渲染一帧。
pub fn Tui::render_now(self : Tui, force? : Bool = false) -> Unit {
  let _ : Value = call(self.handle, "renderNow", [Value::cast_from(force)])
}

///|
pub fn Tui::add_child(self : Tui, component : Component) -> Unit {
  let _ : Value = call(self.handle, "addChild", [component.handle])
}

///|
/// 全屏布局根(替代默认的隐式 transcript 视窗)。
pub fn Tui::set_layout_root(self : Tui, component : Component) -> Unit {
  let _ : Value = call(self.handle, "setLayoutRoot", [component.handle])
}

///|
pub fn Tui::set_focus(self : Tui, component : Component) -> Unit {
  let _ : Value = call(self.handle, "setFocus", [component.handle])
}

///|
/// 终端标题(OSC 0;title BEL)。
pub fn Terminal::set_title(self : Terminal, title : String) -> Unit {
  let _ : Value = call(self.handle, "setTitle", [Value::cast_from(title)])
}

///|
/// 终端进度指示(OSC 9;4)。
pub fn Terminal::set_progress(self : Terminal, active : Bool) -> Unit {
  let _ : Value = call(self.handle, "setProgress", [Value::cast_from(active)])
}

///|
/// 短暂提示(全屏 toast)。
pub fn Tui::flash(
  self : Tui,
  message : String,
  duration_ms? : Int = 2000,
) -> Unit {
  let args : Array[Value] = [
    Value::cast_from(message),
    Value::cast_from(duration_ms),
  ]
  let _ : Value = call(self.handle, "flash", args)
}

///|
/// 监听原始输入;返回真表示吞掉该输入(不再给焦点组件)。
pub fn Tui::add_input_listener(
  self : Tui,
  handle : (String) -> Bool,
) -> Unlisten {
  let unlisten : Value = call(self.handle, "addInputListener", [
    js_input_listener(handle),
  ])
  Unlisten::{ handle: unlisten, }
}

///|
/// 主滚动视窗的滚动位置。
pub fn Tui::viewport_top(self : Tui) -> Int {
  get(self.handle, "viewportTop")
}

///|
/// 主滚动视窗是否跟随输出尾部。
pub fn Tui::is_following_output(self : Tui) -> Bool {
  get(self.handle, "isFollowingOutput")
}

///|
pub fn Tui::scroll_to_top(self : Tui) -> Unit {
  let _ : Value = call(self.handle, "scrollToTop", no_args())
}

///|
pub fn Tui::scroll_to_bottom(self : Tui) -> Unit {
  let _ : Value = call(self.handle, "scrollToBottom", no_args())
}
