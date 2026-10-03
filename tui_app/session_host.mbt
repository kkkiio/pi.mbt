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
  /// 当前会话的 journal 文件路径;内存 journal 时为 `None`。
  mut session_path : String?
}

///|
/// 新建会话宿主(同时创建第一个会话)。
pub fn SessionHost::new(
  llm : &@agent_loop.LLM,
  cwd : String,
  session_dir : String?,
) -> SessionHost raise @coding_agent.FsError {
  let (journal, close_journal, session_path) = open_journal(session_dir)
  SessionHost::{
    llm,
    cwd,
    session_dir,
    session: @coding_agent.new_coding_session(llm, cwd~, journal~),
    close_journal,
    session_path,
  }
}

///|
/// 打开 journal:有 session 目录就落盘(owner-only),否则用内存 journal。
fn open_journal(
  session_dir : String?,
) -> (&@agent_session.SessionJournal, () -> Unit, String?) raise @coding_agent.FsError {
  match session_dir {
    None => (@agent_session.InMemorySessionJournal(), () => (), None)
    Some(dir) => {
      @coding_agent.create_dir(dir)
      let rand = @random.Rand::new()
      let path = "\{dir}/\{@env.now()}_\{rand.uint64()}.jsonl"
      // 文件不在启动时创建:第一次真正要写入时才建(见 `JsonlSessionJournal`)。
      let file = @coding_agent.open_lazy_file(path)
      (
        @coding_agent.JsonlSessionJournal::JsonlSessionJournal(file)
        as &@agent_session.SessionJournal,
        () => file.close(),
        Some(path),
      )
    }
  }
}

///|
/// 关闭当前 journal。没落盘的空会话根本不会留下文件(见 `JsonlSessionJournal`),
/// 所以这里不需要清理动作。
fn SessionHost::close_current(self : SessionHost) -> Unit {
  (self.close_journal)()
  self.close_journal = () => ()
  self.session_path = None
}

///|
/// 换一个全新会话(关掉旧 journal)。
pub fn SessionHost::new_session(
  self : SessionHost,
) -> Unit raise @coding_agent.FsError {
  let active_tools = self.session.active_tool_names()
  self.close_current()
  let (journal, close_journal, session_path) = open_journal(self.session_dir)
  self.close_journal = close_journal
  self.session_path = session_path
  self.session = @coding_agent.new_coding_session(
    self.llm,
    cwd=self.cwd,
    journal~,
    active_tools~,
  )
}

///|
/// 关闭当前会话(进程退出前调用)。
pub fn SessionHost::close(self : SessionHost) -> Unit {
  self.close_current()
}

///|
/// 中断当前运行(ESC 且 agent 在跑时由视图层调用)。
pub fn SessionHost::interrupt(self : SessionHost) -> Unit {
  self.session.abort()
}

///|
/// 订阅当前会话的事件并投影到视图。
pub fn SessionHost::attach(self : SessionHost, app : TuiApp) -> Unit {
  self.session.subscribe(event => self.on_event(event, app))
}

///|
/// 载入同目录下已有的会话替换当前会话,并把历史回放到消息流。
///
/// `prefix` 为空取最新一个;命中多个或无命中时把候选写进消息流并返回,
/// 当前会话不变。
pub fn SessionHost::resume_session(
  self : SessionHost,
  prefix : String,
  app : TuiApp,
) -> Unit {
  let dir = match self.session_dir {
    Some(dir) => dir
    None => {
      app.push_note("resume: this session is not persisted")
      return
    }
  }
  let sessions = @coding_agent.list_sessions(dir) catch {
    err => {
      app.push_error("resume: \{err}")
      return
    }
  }
  // 启动时已经建了一个空会话,它总是最新的 —— 不能把自己选出来。
  let candidates = match self.session_path {
    Some(path) => {
      let current = session_stem(path)
      sessions.filter(name => name != current)
    }
    None => sessions
  }
  let name = match @coding_agent.pick_session(candidates, prefix) {
    Found(name) => name
    None => {
      if prefix.is_empty() {
        app.push_note("resume: no sessions in \{dir}")
      } else {
        app.push_note("resume: no session matches '\{prefix}'")
      }
      return
    }
    Ambiguous(candidates) => {
      app.push_note(
        "resume: '\{prefix}' matches \{candidates.length()} sessions:",
      )
      for candidate in candidates {
        app.push_note("  \{candidate}")
      }
      return
    }
  }
  let path = "\{dir}/\{name}.jsonl"
  self.load_session(path, app)
}

///|
/// 载入指定会话文件替换当前会话,并把历史回放到消息流。
///
/// 文件已存在,所以以追加方式打开、`fresh=false`(不重写 header);
/// 未写入任何内容前不会碰这个文件。
pub fn SessionHost::load_session(
  self : SessionHost,
  path : String,
  app : TuiApp,
) -> Unit {
  let entries = @coding_agent.fetch_active_entries(path) catch {
    err => {
      app.push_error("resume: \{err}")
      return
    }
  }
  let file = @coding_agent.open_lazy_file(path, append=true)
  let active_tools = self.session.active_tool_names()
  self.close_current()
  let journal = @coding_agent.JsonlSessionJournal::JsonlSessionJournal(
      file,
      entries~,
      fresh=false,
    )
    as &@agent_session.SessionJournal
  self.close_journal = () => file.close()
  self.session_path = Some(path)
  self.session = @coding_agent.new_coding_session(
    self.llm,
    cwd=self.cwd,
    journal~,
    active_tools~,
  )
  app.reset_transcript()
  replay(entries, app)
  self.attach(app)
  app.push_note("Resumed session")
}

///|
/// `<dir>/<name>.jsonl` → `<name>`。
fn session_stem(path : String) -> String {
  let name = match path.rev_split_once("/") {
    Some((_, name)) => name.to_owned()
    None => path
  }
  match name.strip_suffix(".jsonl") {
    Some(stem) => stem.to_owned()
    None => name
  }
}

///|
/// 把已落盘的当前分支历史投影回消息流。
///
/// 只渲染会出现在消息流里的内容;`ModelChange` / `Compaction` / `Custom`
/// 本期不渲染。
fn replay(entries : Array[@agent_session.SessionEntry], app : TuiApp) -> Unit {
  for entry in entries {
    match entry.content {
      Message(User(message)) =>
        for block in message.content {
          match block {
            Text(text) => app.replay_user(text)
            _ => ()
          }
        }
      Message(Assistant(message)) => replay_assistant(message, app)
      Message(ToolResult(result)) => {
        app.tool_result(
          result.tool_name,
          tool_result_text(result),
          result.is_error,
          id=result.tool_call_id,
          details=result.details,
        )
        if result.usage is Some(usage) {
          app.set_usage(usage, update_cache_hit=false)
        }
      }
      Metadata(Object(fields)) =>
        if fields.get("type") is Some(String("session_info")) {
          if fields.get("name") is Some(String(name)) {
            app.set_session_name(Some(name))
          }
        }
      _ => ()
    }
  }
}

///|
/// 回放一条 assistant 消息:思考/正文先进消息流,工具调用随后成块
/// (与实时事件同样按 call id 配对结果,不依赖同名调用的顺序)。
fn replay_assistant(
  message : @agent_loop.AssistantMessage,
  app : TuiApp,
) -> Unit {
  let calls : Array[@agent_loop.ToolCall] = []
  let content : Array[(String, Bool)] = []
  app.assistant_start()
  for block in message.content {
    match block {
      Text(text, ..) => content.push((text, false))
      Thinking(text, ..) => content.push((text, true))
      ToolCall(call, ..) => calls.push(call)
      _ => ()
    }
  }
  app.transcript.set_assistant_content(content)
  app.assistant_end(
    stop_reason_name(message.stop_reason),
    message.error_message,
  )
  if message.usage is Some(usage) {
    app.set_usage(usage)
  }
  for call in calls {
    app.tool_call(call.name, call.arguments, id=call.id)
  }
}

///|
/// Replace the current assistant snapshot, retaining text/thinking order.
fn SessionHost::sync_assistant(
  self : SessionHost,
  message : @agent_loop.AssistantMessage,
  app : TuiApp,
) -> Unit {
  let content : Array[(String, Bool)] = []
  for block in message.content {
    match block {
      Text(text, ..) => content.push((text, false))
      Thinking(text, ..) => content.push((text, true))
      _ => ()
    }
  }
  let _ = self
  app.transcript.set_assistant_content(content)
  app.render()
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
      app.begin_retry(attempt, max_attempts, delay_ms)
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
        MessageStart(Assistant(_)) => app.assistant_start()
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
          app.tool_call(call.name, call.arguments, id=call.id, timed=true)
        }
        ToolExecutionEnd(result) => {
          app.tool_result(
            result.tool_name,
            tool_result_text(result),
            result.is_error,
            id=result.tool_call_id,
            details=result.details,
          )
          if result.usage is Some(usage) {
            app.set_usage(usage, update_cache_hit=false)
          }
        }
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
