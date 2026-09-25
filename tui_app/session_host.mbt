// 会话所有权:LLM 复用、journal 生命周期、多会话(`/new`)、agent 事件 → 视图。
//
// 视图层(`app.mbt`)不认识 agent;所有 `@agent_loop`/`@agent_session` 的耦合都集中在
// 这个文件里。会话切换时:`new_session()` 换 journal 与 AgentSession,
// 再 `attach()` 订阅新会话(pi 的 `subscribe` 不重放历史)。

///|
/// 一个会话宿主。持有当前 AgentSession 与其 journal 的关闭回调。
pub struct SessionHost {
  llm : &@agent_loop.LLM
  cwd : String
  session_dir : String?
  mut session : @agent_session.AgentSession
  mut close_journal : () -> Unit
  /// 当前 assistant 消息已消费的文本/思考长度(满量内容 → 增量)。
  mut text_len : Int
  mut thinking_len : Int
}

///|
/// 新建会话宿主(同时创建第一个会话)。
pub async fn SessionHost::new(
  llm : &@agent_loop.LLM,
  cwd : String,
  session_dir : String?,
) -> SessionHost {
  let (journal, close_journal) = open_journal(session_dir)
  SessionHost::{
    llm,
    cwd,
    session_dir,
    session: @coding_agent.new_coding_session(llm, cwd~, journal~),
    close_journal,
    text_len: 0,
    thinking_len: 0,
  }
}

///|
/// 打开 journal:有 session 目录就落盘(owner-only),否则用内存 journal。
async fn open_journal(
  session_dir : String?,
) -> (&@agent_session.SessionJournal, () -> Unit) {
  match session_dir {
    None => (@agent_session.InMemorySessionJournal(), () => ())
    Some(dir) => {
      @coding_agent.create_dir(dir)
      let rand = @random.Rand::new()
      let path = "\{dir}/\{@env.now()}_\{rand.uint64()}.jsonl"
      let file = @coding_agent.create_file(path)
      (
        @coding_agent.JsonlSessionJournal::JsonlSessionJournal(file)
        as &@agent_session.SessionJournal,
        () => file.close(),
      )
    }
  }
}

///|
/// 换一个全新会话(关掉旧 journal)。
pub async fn SessionHost::new_session(self : SessionHost) -> Unit {
  let active_tools = self.session.active_tool_names()
  (self.close_journal)()
  let (journal, close_journal) = open_journal(self.session_dir)
  self.close_journal = close_journal
  self.session = @coding_agent.new_coding_session(
    self.llm,
    cwd=self.cwd,
    journal~,
    active_tools~,
  )
  self.text_len = 0
  self.thinking_len = 0
}

///|
/// 关闭当前会话(进程退出前调用)。
pub fn SessionHost::close(self : SessionHost) -> Unit {
  (self.close_journal)()
  self.close_journal = () => ()
}

///|
/// 中断当前运行(ESC 且 agent 在跑时由视图层调用)。
pub fn SessionHost::interrupt(self : SessionHost) -> Unit {
  self.session.interrupt()
}

///|
/// 订阅当前会话的事件并投影到视图。
pub fn SessionHost::attach(self : SessionHost, app : TuiApp) -> Unit {
  self.text_len = 0
  self.thinking_len = 0
  self.session.subscribe(event => self.on_event(event, app))
}

///|
/// 结束会话的当前 assistant 增量(换会话/换消息时重置游标)。
fn SessionHost::sync_assistant(
  self : SessionHost,
  message : @agent_loop.AssistantMessage,
  app : TuiApp,
) -> Unit {
  let mut text = ""
  let mut thinking = ""
  for block in message.content {
    match block {
      Text(content, ..) => text = text + content
      Thinking(content, ..) => thinking = thinking + content
      _ => ()
    }
  }
  if text.length() > self.text_len {
    app.assistant_delta(text[self.text_len:].to_owned(), false)
    self.text_len = text.length()
  }
  if thinking.length() > self.thinking_len {
    app.assistant_delta(thinking[self.thinking_len:].to_owned(), true)
    self.thinking_len = thinking.length()
  }
}

///|
fn stop_reason_name(reason : @agent_loop.StopReason) -> String {
  match reason {
    Pending => "pending"
    Stop => "stop"
    Length => "length"
    ToolUse => "tool_use"
    Aborted => "aborted"
    Error => "error"
  }
}

///|
fn tool_result_text(message : @agent_loop.ToolResultMessage) -> String {
  let out = StringBuilder()
  for content in message.content {
    match content {
      Text(text) => out.write_string(text)
      Image(_) => out.write_string("[image]")
    }
  }
  out.to_string()
}

///|
/// agent/会话事件 → 视图(订阅回调,运行在 agent 的协程里)。
fn SessionHost::on_event(
  self : SessionHost,
  event : @agent_session.AgentSessionEvent,
  app : TuiApp,
) -> Unit {
  match event {
    AutoRetryStart(attempt~, max_attempts~, delay_ms~, error_message~) => {
      app.push_note(
        "retrying (\{attempt}/\{max_attempts}) in \{delay_ms}ms: \{error_message}",
      )
      app.begin_work("retrying")
    }
    AutoRetryEnd(attempt~, success~, final_error~) =>
      if success {
        app.push_note("retry succeeded (attempt \{attempt})")
      } else {
        let detail = match final_error {
          Some(message) => message
          None => "unknown error"
        }
        app.push_error("retry failed: \{detail}")
        app.set_idle()
      }
    Loop(loop_event) =>
      match loop_event {
        AgentStart => app.begin_work("thinking")
        TurnStart => ()
        MessageStart(Assistant(_)) => {
          self.text_len = 0
          self.thinking_len = 0
          app.assistant_start()
        }
        MessageStart(_) => ()
        MessageUpdate(Assistant(message)) => self.sync_assistant(message, app)
        MessageUpdate(_) => ()
        MessageEnd(Assistant(message)) => {
          self.sync_assistant(message, app)
          app.assistant_end(
            stop_reason_name(message.stop_reason),
            message.error_message,
          )
          match message.usage {
            Some(usage) => app.set_usage(usage)
            None => ()
          }
          if message.stop_reason is Error {
            app.set_idle()
          }
        }
        MessageEnd(_) => ()
        ToolExecutionStart(call) => {
          app.begin_work(call.name)
          app.tool_call(call.name, call.arguments)
        }
        ToolExecutionEnd(result) =>
          app.tool_result(
            result.tool_name,
            tool_result_text(result),
            result.is_error,
          )
        TurnEnd(_, _) => ()
        AgentEnd(_) => app.set_idle()
      }
  }
}

///|
/// 跑一轮:先把状态切到工作态,再 `session.prompt`(事件由订阅回调更新视图)。
pub async fn SessionHost::prompt(
  self : SessionHost,
  text : String,
  app : TuiApp,
) -> Unit {
  self.text_len = 0
  self.thinking_len = 0
  app.begin_work("thinking")
  let input : Array[@agent_loop.UserMessage] = [
    @agent_loop.UserMessage::{
      content: [@agent_loop.InputMessageContent::Text(text)],
      timestamp: @env.now(),
    },
  ]
  self.session.prompt(input)
  app.set_idle()
}
