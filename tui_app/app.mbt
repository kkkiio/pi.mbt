// TuiApp:全屏 TUI 的视图层(被动视图 + 输入源)。
//
//   - 渲染只读状态,由 pi-tui 调度(每个 mutator 末尾 request_render)。
//   - agent 会话与事件翻译在 `session_host.mbt`,命令解析与装配在 `run.mbt`。
//   - 运行状态嵌在输入框上边框,不占 dock 行。
//   - 退出靠一个信号量:输入监听器 release,主协程在 `wait_for_exit` 等。

///|
/// 排队中的用户消息(视图层内部类型,dock 最上面几行)。
pub struct PendingList {
  theme : Theme
  mut lines : Array[String]
}

///|
/// 构造排队列表。
pub fn PendingList::new(
  theme : Theme,
  lines? : Array[String] = [],
) -> PendingList {
  { theme, lines, }
}

///|
/// 每条排队消息渲染成 `Follow-up: <text>`,按宽度截断。
///
/// 与其他组件同样的行契约:一个元素 = 一行(pi-tui 的差分渲染按行索引写),
/// 所以多行消息必须按物理行拆开,续行缩进对齐,而不是把 `\n` 塞进一个元素 ——
/// 否则后半段会物理写到输入框所在的行上且永远不会被重画。
pub impl Widget for PendingList with fn render(self, width) {
  let out : Array[String] = []
  for line in self.lines {
    for index, row in physical_lines(line) {
      let prefix = if index == 0 { "  Follow-up: " } else { "    " }
      out.push(self.theme.f_dim(truncate_to_width(prefix + row, width)))
    }
  }
  out
}

///|
pub extend PendingList with Widget::{render, invalidate}

///|
/// 视图层的全部可变状态。
pub struct TuiApp {
  tui : Tui
  terminal : Terminal
  /// 已载入的主题(载入一次,按构造器注入各组件)。
  theme : Theme
  mut transcript : Transcript
  status : StatusLine
  mut footer : Footer
  editor : PromptEditor
  pending : Ref[PendingList]
  submissions : @aqueue.Queue[(String, Bool)]
  /// 第二个分量:提交时 agent 是否在工作(即这条消息被展示在"排队中")。
  quit : @semaphore.Semaphore
  /// agent 是否正在跑(决定是否把新消息放进"排队中")。
  mut running : Bool
  /// 是否已请求退出:让 ticker/命令循环自行结束(`with_task_group` 会等子任务)。
  mut shutting_down : Bool
  /// 中断(TuiApp 层的回调,接到 SessionHost::interrupt)。
  mut interrupt_handler : () -> Unit
  /// 上一次 Ctrl+C 的时刻(epoch 毫秒),用于"连按两次退出"。
  mut last_ctrl_c_ms : Double
}

///|
/// 构造 TUI 应用(async 伪构造器,同 `moonbitlang/async` 的
/// `TcpServer::TcpServer` 惯用法):载入 pi-tui 模块并构造全部 JS 侧对象。
/// 不碰终端状态 —— 副作用(进副屏/raw mode)留给 `start`。
pub async fn TuiApp::load(
  model : String,
  cwd : String,
  thinking : String,
) -> TuiApp {
  load_module()
  let theme = Theme::load("light")
  // terminal 与 Tui 绑定:pi-tui 的 `TuiAltScreen` 构造时只是拿引用,
  // 真正的 raw mode/副屏切换在 `Tui::start`。
  let terminal = terminal_new()
  let tui = tui_new(terminal)
  let editor = prompt_editor_new(tui, theme)
  let app = TuiApp::{
    tui,
    terminal,
    theme,
    transcript: Transcript::new(theme),
    status: StatusLine::new(theme),
    footer: Footer::new(theme, model, cwd, thinking),
    editor,
    pending: Ref(PendingList::new(theme)),
    submissions: @aqueue.Queue(kind=@aqueue.Unbounded),
    quit: @semaphore.Semaphore(1, initial_value=0),
    running: false,
    shutting_down: false,
    interrupt_handler: fn() { () },
    last_ctrl_c_ms: 0.0,
  }
  app.transcript.push_note(STARTUP_HELP)
  app
}

///|
/// 启动帮助行(只列 pim 实际支持的键位)。
const STARTUP_HELP : String = "Esc interrupt · Ctrl+C clear · Ctrl+D exit · Ctrl+O tools · Ctrl+T thinking · / commands"

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
/// 进入全屏:挂布局、焦点、输入监听,最后一行 `Tui::start` 进入副屏 + raw
/// mode —— 唯一的终端状态副作用屏障。调用之前的失败路径不碰终端;之后的
/// 失败路径由调用方 defer drain_input + stop 恢复(对齐 pi 的 shutdown:
/// drainInput → stop → dispose)。
/// 渲染闭包直接捕获 `self`:MoonBit 的 struct 是引用语义,闭包读到的永远是同一对象。
pub fn TuiApp::start(self : TuiApp) -> Unit {
  let transcript_component = component_of(fn(width) {
    Widget::render(self.transcript, width)
  })
  let pending_component = component_of(fn(width) {
    Widget::render(self.pending.val, width)
  })
  let footer_component = component_of(fn(width) {
    Widget::render(self.footer, width)
  })
  let editor_component = self.editor.component()
  // 运行状态嵌在输入框上边框:每帧按当前状态渲染整行。
  self.editor.set_border_provider(fn(width) {
    match self.status.render_border(width) {
      Some(line) => line
      None => ""
    }
  })
  self.editor.set_slash_commands(slash_commands(), self.footer.cwd())
  let viewport = chat_viewport_new(
    document=transcript_component,
    pending=pending_component,
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
/// slash 命令补全项(名称 + 描述),与 `run.mbt` 的命令解析保持一致。
fn slash_commands() -> Array[(String, String)] {
  [
    ("new", "Start a new session"),
    ("resume", "Resume a session from this directory"),
    ("quit", "Exit pim"),
    ("exit", "Exit pim"),
  ]
}

///|
fn TuiApp::on_input(self : TuiApp, data : String) -> Bool {
  if is_key_release(data) {
    return false
  }
  // app.interrupt == escape:补全菜单打开时不抢(交给编辑器关菜单);
  // 运行中则中断当前回合;空闲时空输入无动作。
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
  // app.clear == ctrl+c:清空输入;500ms 内连按两次退出。
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
  // app.tools.expand == ctrl+o:展开/折叠工具输出。
  if matches_key(data, "ctrl+o") {
    self.transcript.toggle_expanded_tool_output()
    self.tui.request_render()
    return true
  }
  // app.thinking.expand == ctrl+t:展开/折叠思考内容。
  if matches_key(data, "ctrl+t") {
    self.transcript.toggle_expanded_thinking()
    self.tui.request_render()
    return true
  }
  false
}

///|
/// 请求退出:置标志 + 中断正在跑的生成/工具 + 唤醒等待输入的循环 + 放行退出
/// 信号量。
///
/// 退出路径(ctrl+d / 双 ctrl+c / /quit)都要能打断 pending 的生成或长工
/// 具:否则 `run` 里的 `with_task_group` 会等命令 worker 结束,终端要等一整
/// 轮模型/工具跑完才恢复(对齐 pi:退出时先 `session.abort()`)。
pub fn TuiApp::request_exit(self : TuiApp) -> Unit {
  if self.shutting_down {
    return
  }
  self.shutting_down = true
  (self.interrupt_handler)()
  let _ = self.submissions.try_put(("", false)) catch { _ => false }
  self.quit.release()
}

///|
/// 是否已请求退出(循环据此结束)。
pub fn TuiApp::is_shutting_down(self : TuiApp) -> Bool {
  self.shutting_down
}

///|
/// 等用户提交的下一条输入,同时撤掉它的排队展示。队列与展示由视图层统一维护。
pub async fn TuiApp::take_submission(self : TuiApp) -> String {
  let (text, was_queued) = self.submissions.get()
  if was_queued {
    self.remove_pending_head()
  }
  text
}

///|
/// 等退出信号。
pub async fn TuiApp::wait_for_exit(self : TuiApp) -> Unit {
  self.quit.acquire()
}

///|
/// 恢复终端:离开副屏、恢复 raw mode(pi-tui `Tui::stop`)。
/// stdin 排空(drain_input)不在这里 —— 对齐 pi:调用方先 drain 再 stop,
/// drain 需要靠 stdin 还开着,stop 会 pause stdin。
pub fn TuiApp::stop(self : TuiApp) -> Unit {
  self.tui.stop()
}

///|
pub fn TuiApp::render(self : TuiApp) -> Unit {
  self.tui.request_render()
}

///|
/// 用户提交:本地回显 + 入队(同步,可在 JS 回调里调用)。第二条分量记录
/// 这条消息是否因 agent 忙而进了"排队中"展示(worker 取走时要撤销展示)。
pub fn TuiApp::submit(self : TuiApp, text : String) -> Unit {
  let trimmed = text.trim().to_owned()
  if trimmed.is_empty() || self.shutting_down {
    return
  }
  // 退出是即时控制输入,不能排在正在等待模型/工具的 worker 后面。
  if trimmed == "/quit" || trimmed == "/exit" {
    self.request_exit()
    return
  }
  let was_queued = self.running
  self.push_user(trimmed)
  let _ = self.submissions.try_put((trimmed, was_queued)) catch { _ => false }
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
  id~ : String,
) -> Unit {
  self.transcript.push_tool_call(name, arguments, id~)
  self.tui.request_render()
}

///|
pub fn TuiApp::tool_result(
  self : TuiApp,
  name : String,
  text : String,
  is_error : Bool,
  id~ : String,
) -> Unit {
  self.transcript.push_tool_result(name, text, is_error, id~)
  self.tui.request_render()
}

///|
pub fn TuiApp::set_usage(self : TuiApp, usage : @agent_loop.Usage) -> Unit {
  self.footer.set_usage(usage)
  self.tui.request_render()
}

///|
/// 进入工作态:状态嵌入输入框边框。
///
/// 会被 prompt 启动、AgentStart、重试、工具启动多次调用,所以只管状态,
/// 不动"排队中"列表 —— 撤销展示由 `take_submission` 在消费队列时做。
pub fn TuiApp::begin_work(self : TuiApp, label : String) -> Unit {
  self.running = true
  self.status.set_working(label)
  self.terminal.set_progress(true)
  self.tui.request_render()
}

///|
/// 从队列取走一条曾被排队展示的消息时,把队首展示行撤掉。
fn TuiApp::remove_pending_head(self : TuiApp) -> Unit {
  if self.pending.val.lines.length() > 0 {
    self.pending.val.lines = self.pending.val.lines[1:].to_owned()
    self.tui.request_render()
  }
}

///|
pub fn TuiApp::set_idle(self : TuiApp) -> Unit {
  self.running = false
  self.status.set_idle()
  self.terminal.set_progress(false)
  self.tui.request_render()
}

///|
/// spinner 前进一帧(由 ticker 定时调用)。
pub fn TuiApp::tick(self : TuiApp) -> Unit {
  guard self.running else { return }
  self.status.tick()
  self.tui.request_render()
}

///|
/// 清空消息流与排队区(`/resume` 回放前调用),保留 footer 用量。
pub fn TuiApp::reset_transcript(self : TuiApp) -> Unit {
  self.transcript = Transcript::new(self.theme)
  self.pending.val.lines = []
  self.tui.request_render()
}

///|
/// 回放一条历史用户消息:只写消息流,不进输入历史、不进排队区。
pub fn TuiApp::replay_user(self : TuiApp, text : String) -> Unit {
  self.transcript.push_user(text)
  self.tui.request_render()
}

///|
/// 清空会话相关显示(`/new` 用):transcript + 状态 + 用量。
pub fn TuiApp::reset(self : TuiApp) -> Unit {
  self.reset_transcript()
  self.footer = Footer::new(
    self.theme,
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
