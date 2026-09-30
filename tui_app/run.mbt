// TUI 应用的入口:装配视图与会话宿主,解析斜杠命令,收尾恢复终端。
//
// 与 pi 一致:命令解析放在应用层(只有它同时知道视图与会话)。

///|
/// spinner 刷新间隔(毫秒),对齐 pi Loader 的 80ms。
const TICK_INTERVAL_MS : Int = 80

///|
/// 跑全屏 TUI,直到用户退出(ctrl+c / ctrl+d / `/quit`)。
///
/// `session_dir` 为 `None` 时用内存 journal;否则每个会话落一个 JSONL 文件
/// (文件在第一次真正写入时才创建)。`resume_path` 不为空时启动即载入该会话。
pub async fn run(
  llm : &@agent_loop.LLM,
  model : String,
  cwd : String,
  thinking : String,
  session_dir : String?,
  resume_path? : String? = None,
) -> Unit {
  // 先建会话宿主(会创建 session 目录,可能抛 FsError),再碰终端:终端
  // 副作用只在 app.start() 里发生,这之前失败不需要恢复终端。
  let host = SessionHost::new(llm, cwd, session_dir)
  defer host.close()
  let app = TuiApp::load(model, cwd, thinking)
  defer app.stop()
  app.on_submit(fn(text) { app.submit(text) })
  app.on_interrupt(fn() { host.interrupt() })
  // 对齐 pi 的 shutdown:drainInput → stop → dispose。defer FILO 反转后:
  // drain_input → app.stop(恢复终端)→ host.close(关 journal)。
  // drain 的错误不覆盖原有错误(它只是清理,失败不改变退出原因)。
  defer (app.terminal.drain_input() catch { _ => () })
  app.start()
  @async.with_task_group() <| group => {
    match resume_path {
      Some(path) => host.load_session(path, app)
      None => host.attach(app)
    }
    group.spawn_bg(async fn() {
      while !app.is_shutting_down() {
        @async.sleep(TICK_INTERVAL_MS)
        app.tick()
      }
    })
    group.spawn_bg(async fn() {
      while !app.is_shutting_down() {
        let text = app.take_submission()
        if app.is_shutting_down() {
          break
        }
        match text.trim() {
          "/new" => {
            host.new_session()
            host.attach(app)
            app.reset()
            app.flash("new session")
          }
          "/resume" => host.resume_session("", app)
          command if command.has_prefix("/resume ") => {
            let rest = command[8:]
            host.resume_session(rest.trim().to_owned(), app)
          }
          _ => host.prompt(text, app)
        }
      }
    })
    app.wait_for_exit()
  }
}
