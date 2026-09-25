// TuiApp:全屏 TUI 的视图层(被动视图 + 输入源)。
//
//   - 渲染只读状态,由 pi-tui 调度(每个 mutator 末尾 request_render)。
//   - agent 会话与事件翻译在 `session_host.mbt`,命令解析与装配在 `run.mbt`。
//   - 退出靠一个信号量:输入监听器 release,主协程在 `wait_for_exit` 等。

///|
/// 排队中的用户消息(dock 最上面几行)。

///|
/// 排队中的用户消息(视图层内部类型,dock 最上面几行)。
pub struct PendingList {
  mut lines : Array[String]
}

///|
impl Widget for PendingList with fn render(self, width) {
  let out : Array[String] = []
  for line in self.lines {
    out.push(dim(truncate_to_width("  queued: \{line}", width)))
  }
  out
}

///|
/// 视图层的全部可变状态。
pub struct TuiApp {
  tui : Tui
  terminal : Terminal
  mut transcript : Transcript
  status : StatusLine
  mut footer : Footer
  editor : PromptEditor
  pending : Ref[PendingList]
  submissions : @aqueue.Queue[String]
  quit : @semaphore.Semaphore
  /// agent 是否正在跑(决定是否把新消息放进"排队中")。
  mut running : Bool
  /// 是否已请求退出:让 ticker/命令循环自行结束(`with_task_group` 会等子任务)。
  mut shutting_down : Bool
  /// 中断(TuiApp 层的回调,接到 SessionHost::interrupt)。
  mut interrupt_handler : () -> Unit
  /// 上一次 Ctrl+C 的时刻(epoch 毫秒),用于"连按两次退出"(对齐 pi)。
  mut last_ctrl_c_ms : Double
  /// 当前工作的起始时刻(epoch 毫秒),用于状态行的已用时间。
  mut work_started_ms : Double
}

///|
/// 启动 TUI(载入 pi-tui、进副屏、挂布局)。调用方随后用返回的句柄驱动视图。
pub async fn TuiApp::start(
  model : String,
  cwd : String,
  thinking : String,
) -> TuiApp {
  load()
  let terminal = terminal_new()
  let tui = tui_new(terminal)
  let editor = prompt_editor_new(tui, fn(_text) { () })
  let app = TuiApp::{
    tui,
    terminal,
    transcript: Transcript::new(),
    status: StatusLine::new(),
    footer: Footer::new(model, cwd, thinking),
    editor,
    pending: Ref(PendingList::{ lines: [], }),
    submissions: @aqueue.Queue(kind=@aqueue.Unbounded),
    quit: @semaphore.Semaphore(1, initial_value=1),
    running: false,
    shutting_down: false,
    interrupt_handler: fn() { () },
    last_ctrl_c_ms: 0.0,
    work_started_ms: 0.0,
  }
  app
}

///|
/// 把提交回调接到外部处理器(避免构造顺序上的循环依赖)。
pub fn TuiApp::on_submit(self : TuiApp, handler : (String) -> Unit) -> Unit {
  self.editor.set_on_submit(handler)
}

///|
/// 注册中断回调(ESC 且正在运行时触发)。
pub fn TuiApp::on_interrupt(self : TuiApp, handler : () -> Unit) -> Unit {
  self.interrupt_handler = handler
}

///|
/// epoch 毫秒。Int 是 32 位,装不下(会被截断成负数),所以用 Double。
fn now_ms() -> Double {
  @env.now().to_double()
}

///|
/// 挂载布局并把焦点给输入框。
/// 渲染闭包直接捕获 `self`:MoonBit 的 struct 是引用语义,闭包读到的永远是同一对象。
pub fn TuiApp::mount(self : TuiApp) -> Unit {
  let transcript_component = component_of(fn(width) {
    Widget::render(self.transcript, width)
  })
  let pending_component = component_of(fn(width) {
    Widget::render(self.pending.val, width)
  })
  let status_component = component_of(fn(width) {
    Widget::render(self.status, width)
  })
  let footer_component = component_of(fn(width) {
    Widget::render(self.footer, width)
  })
  let editor_component = self.editor.component()
  let viewport = chat_viewport_new(
    document=transcript_component,
    pending=pending_component,
    status=status_component,
    editor=editor_component,
    footer=footer_component,
  )
  self.tui.set_layout_root(viewport.root())
  self.tui.set_focus(editor_component)
  self.terminal.set_title("pim")
  let _unlisten = self.tui.add_input_listener(fn(data) { self.on_input(data) })
  self.tui.start()
}

///|
/// 全局键位(alt screen 自己处理的滚动/搜索/选择不经过这里)。

///|
fn TuiApp::on_input(self : TuiApp, data : String) -> Bool {
  if is_key_release(data) {
    return false
  }
  // app.interrupt == escape:补全菜单打开时不抢(交给编辑器关菜单);
  // 运行中则中断当前回合;空闲时空输入无动作(pi 的双击 ESC 我们不做)。
  if matches_key(data, "escape") {
    if self.editor.is_showing_autocomplete() {
      return false
    }
    if self.running {
      (self.interrupt_handler)()
      return true
    }
    return false
  }
  // app.clear == ctrl+c:清空输入;500ms 内连按两次退出(pi handleCtrlC)。
  if matches_key(data, "ctrl+c") {
    let now = now_ms()
    if now - self.last_ctrl_c_ms < 500.0 {
      self.request_exit()
    } else {
      self.editor.set_text("")
      self.last_ctrl_c_ms = now
      self.tui.request_render()
    }
    return true
  }
  // app.exit == ctrl+d:输入为空时退出;非空时放行(编辑器删光标后字符)。
  if matches_key(data, "ctrl+d") {
    if self.editor.text().length() == 0 {
      self.request_exit()
      return true
    }
    return false
  }
  false
}

///|
/// 请求退出:置标志 + 唤醒等待输入的循环 + 放行退出信号量。
pub fn TuiApp::request_exit(self : TuiApp) -> Unit {
  self.shutting_down = true
  let _ = self.submissions.try_put("") catch { _ => false }
  self.quit.release()
}

///|
/// 是否已请求退出(循环据此结束)。
pub fn TuiApp::is_shutting_down(self : TuiApp) -> Bool {
  self.shutting_down
}

///|
/// 等用户提交的下一条输入(阻塞)。
pub async fn TuiApp::take_submission(self : TuiApp) -> String {
  self.submissions.get()
}

///|
/// 等退出信号。
pub async fn TuiApp::wait_for_exit(self : TuiApp) -> Unit {
  self.quit.acquire()
}

///|
/// 退出:排空 stdin、离开副屏、恢复终端。
pub async fn TuiApp::stop(self : TuiApp) -> Unit {
  self.terminal.drain_input()
  self.tui.stop()
}

///|
pub fn TuiApp::render(self : TuiApp) -> Unit {
  self.tui.request_render()
}

///|
/// 用户提交:本地回显 + 入队(同步,可在 JS 回调里调用)。
pub fn TuiApp::submit(self : TuiApp, text : String) -> Unit {
  let trimmed = text.trim().to_owned()
  if trimmed.length() == 0 {
    return
  }
  self.push_user(trimmed)
  let _ = self.submissions.try_put(trimmed) catch { _ => false }
}

///|
/// 本地回显一条用户消息。agent 忙时同时进"排队中"列表。
pub fn TuiApp::push_user(self : TuiApp, text : String) -> Unit {
  self.transcript.push_user(text)
  self.editor.add_to_history(text)
  if self.running {
    self.pending.val.lines.push(text)
  }
  self.tui.request_render()
}

///|
pub fn TuiApp::push_note(self : TuiApp, text : String) -> Unit {
  self.transcript.push_note(text)
  self.tui.request_render()
}

///|
pub fn TuiApp::push_error(self : TuiApp, text : String) -> Unit {
  self.transcript.push_error(text)
  self.tui.request_render()
}

///|
/// 开一条 assistant 消息。
pub fn TuiApp::assistant_start(self : TuiApp) -> Unit {
  self.transcript.start_assistant()
  self.tui.request_render()
}

///|
/// 追加 assistant 内容(满量内容里的增量)。
pub fn TuiApp::assistant_delta(
  self : TuiApp,
  text : String,
  thinking : Bool,
) -> Unit {
  if thinking {
    self.transcript.append_thinking(text)
  } else {
    self.transcript.append_text(text)
  }
  self.tui.request_render()
}

///|
/// 结束当前 assistant 消息。
pub fn TuiApp::assistant_end(
  self : TuiApp,
  stop_reason : String,
  error_message : String?,
) -> Unit {
  self.transcript.finish_assistant(stop_reason, error_message)
  self.tui.request_render()
}

///|
pub fn TuiApp::tool_call(
  self : TuiApp,
  name : String,
  arguments : Json,
) -> Unit {
  self.transcript.push_tool_call(name, arguments)
  self.tui.request_render()
}

///|
pub fn TuiApp::tool_result(
  self : TuiApp,
  name : String,
  text : String,
  is_error : Bool,
) -> Unit {
  self.transcript.push_tool_result(name, text, is_error)
  self.tui.request_render()
}

///|
pub fn TuiApp::set_usage(self : TuiApp, usage : @agent_loop.Usage) -> Unit {
  self.footer.set_usage(usage)
  self.tui.request_render()
}

///|
pub fn TuiApp::set_hint(self : TuiApp, hint : String) -> Unit {
  self.footer.set_hint(hint)
  self.tui.request_render()
}

///|
/// 进入工作态:状态行 spinner + 终端进度指示;同时把队首消息移出"排队中"。
pub fn TuiApp::begin_work(self : TuiApp, label : String) -> Unit {
  if self.pending.val.lines.length() > 0 {
    self.pending.val.lines = self.pending.val.lines[1:].to_owned()
  }
  self.running = true
  self.work_started_ms = now_ms()
  self.status.set_working(label, self.work_started_ms)
  self.footer.set_hint("esc to interrupt")
  self.terminal.set_progress(true)
  self.tui.request_render()
}

///|
pub fn TuiApp::set_idle(self : TuiApp) -> Unit {
  self.running = false
  self.status.set_idle()
  self.footer.set_hint("")
  self.terminal.set_progress(false)
  self.tui.request_render()
}

///|
/// spinner 前进一帧(由 ticker 定时调用)。
pub fn TuiApp::tick(self : TuiApp) -> Unit {
  guard self.running else { return }
  self.status.tick()
  self.status.set_elapsed((now_ms() - self.work_started_ms).to_int())
  self.tui.request_render()
}

///|
/// 清空会话相关显示(`/new` 用):transcript + 状态 + 用量。
pub fn TuiApp::reset(self : TuiApp) -> Unit {
  self.transcript = Transcript::new()
  self.pending.val.lines = []
  self.footer = Footer::new(
    self.footer.model(),
    self.footer.cwd(),
    self.footer.thinking(),
  )
  self.set_idle()
}

///|
/// 短暂的 toast 提示。
pub fn TuiApp::flash(self : TuiApp, message : String) -> Unit {
  self.tui.flash(message)
}
