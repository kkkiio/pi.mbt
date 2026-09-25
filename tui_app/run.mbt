// TUI 应用的入口:装配视图与会话宿主,解析斜杠命令,收尾恢复终端。
//
// 与 pi 一致:命令解析放在应用层(只有它同时知道视图与会话)。

///|
/// spinner 刷新间隔(毫秒)。
const TICK_INTERVAL_MS : Int = 120

///|
/// 跑全屏 TUI,直到用户退出(ctrl+c / ctrl+d / `/quit`)。
///
/// `session_dir` 为 `None` 时用内存 journal;否则每个会话落一个 JSONL 文件。
pub async fn run(
  llm : &@agent_loop.LLM,
  model : String,
  cwd : String,
  thinking : String,
  session_dir : String?,
) -> Unit {
  let app = TuiApp::start(model, cwd, thinking)
  app.mount()
  app.on_submit(fn(text) { app.submit(text) })
  let host = SessionHost::new(llm, cwd, session_dir)
  app.on_interrupt(fn() { host.interrupt() })
  host.attach(app)
  @async.with_task_group() <| group => {
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
        match text.trim().to_owned() {
          "/new" => {
            host.new_session()
            host.attach(app)
            app.reset()
            app.flash("new session")
          }
          "/quit" | "/exit" => app.request_exit()
          _ => host.prompt(text, app)
        }
      }
    })
    app.wait_for_exit()
  }
  host.close()
  app.stop()
}
