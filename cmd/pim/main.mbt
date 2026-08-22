///|
/// `pim` 的输出模式,对齐 pi 的 `--mode`。
enum OutputMode {
  /// 只把 agent 的最终回复文本写到 stdout。
  Text
  /// 把每个会话事件投影成一行 JSON(JSONL)写到 stdout。
  Json
} derive(Eq)

///|
async fn main {
  let matches = @argparse.parse(
    Command("pim", options=[
      OptionArg("print", short='p', about="prompt text"),
      OptionArg(
        "session_dir",
        long="session-dir",
        env="PIM_SESSION_DIR",
        about="directory to store session JSONL files",
      ),
      OptionArg(
        "mode",
        long="mode",
        about="output mode: text or json (default text)",
      ),
      OptionArg(
        "thinking",
        long="thinking",
        about="thinking effort level: low, high (default), or max",
      ),
    ]),
    env=@env.get_env_vars(),
  ) catch {
    err => arg_error("\{err}")
  }
  let prompts = match matches.values {
    { "print": prompts, .. } => prompts
    _ => fatal("Error: only '-p' support for now")
  }
  let mode = match matches.values {
    { "mode": [m, ..], .. } =>
      match m {
        "text" => Text
        "json" => Json
        _ => fatal("Error: invalid mode '\{m}' (expected text or json)")
      }
    _ => Text
  }
  let deepseek = @providers.DeepSeekProvider()
  // provider 构造失败(如缺 DEEPSEEK_API_KEY)是诊断,按输出流契约走 stderr;
  // 剥离 MoonBit 的 Failure(<loc> FAILED: msg) 包装,保留干净消息。
  let thinking = match matches.values.get("thinking") {
    Some([level, ..]) => {
      guard level is ("low" | "high" | "max") else {
        fatal(
          "Error: invalid thinking level '\{level}' (expected low, high, or max)",
        )
      }
      level
    }
    _ => "high"
  }
  let llm = deepseek.new_llm("deepseek-v4-flash", thinking~) catch {
    err => fatal("Error: \{clean_error_message("\{err}")}")
  }
  let cwd = @env.current_dir().unwrap()
  let session_dir = match matches.values.get("session_dir") {
    Some(dirs) if dirs.length() > 0 => Some(dirs[0])
    _ => None
  }
  let (journal, cleanup) = match session_dir {
    Some(dir) => {
      let file = try {
        @fs.mkdir(dir, recursive=true)
        let rand = @random.Rand::new()
        let timestamp = @env.now().to_string()
        let id = rand.uint64().to_string()
        let path = "\{dir}/\{timestamp}_\{id}.jsonl"
        // Session journals contain prompts and tool output: owner-only,
        // and fail rather than truncate on collision/symlink.
        @fs.create(path, allow_existing=false, permission=0o600)
      } catch {
        err => fatal("Error: \{clean_error_message("\{err}")}")
      }
      (
        @coding_agent.JsonlSessionJournal::JsonlSessionJournal(file)
        as &@agent_session.SessionJournal,
        () => file.close(),
      )
    }
    None => (@agent_session.InMemorySessionJournal(), () => ())
  }
  defer cleanup()
  let session = @coding_agent.new_coding_session(llm, cwd~, journal~)
  let mut last_message : @agent_loop.AgentMessage? = None
  if mode is Json {
    // JSONL 模式:每个 AgentSessionEvent 一行 JSON 输出到 stdout(对齐 pi --mode json)。
    session.subscribe(event => {
      write_stdout(session_event_to_json(event).stringify())
    })
  } else {
    session.subscribe(event => {
      match event {
        Loop(MessageEnd(Assistant(_) as m)) => last_message = Some(m)
        _ => ()
      }
    })
  }
  session.prompt(
    prompts.map(p => @agent_loop.UserMessage::{
      content: [@agent_loop.InputMessageContent::Text(p)],
      timestamp: @env.now(),
    }),
  )
  if mode is Text {
    guard last_message is Some(Assistant({ content: [_, ..] as reply, .. })) else {
      fatal("no reply from agent")
    }
    let output = StringBuilder()
    for content in reply {
      match content {
        Text(text, ..) => output.write_string(text)
        ToolCall(_, ..) => fatal("unexpected tool call in reply")
        Thinking(_, ..) => ()
        HostedToolCall(WebSearch, ..) =>
          fatal("unexpected hosted tool call in reply")
      }
    }
    write_stdout(output.to_string())
  }
}

///|
/// 把 AgentSessionEvent 投影成 JSONL 事件(对齐 pi `--mode json` 的事件形状):
/// loop 事件保持原样,auto_retry 事件对齐 pi 的 `auto_retry_start` /
/// `auto_retry_end` 形状。
fn session_event_to_json(event : @agent_session.AgentSessionEvent) -> Json {
  match event {
    Loop(agent_event) => agent_event_to_json(agent_event)
    AutoRetryStart(attempt~, max_attempts~, delay_ms~, error_message~) =>
      {
        "type": "auto_retry_start",
        "attempt": attempt,
        "maxAttempts": max_attempts,
        "delayMs": delay_ms,
        "errorMessage": error_message,
      }
    AutoRetryEnd(attempt~, success~, final_error~) =>
      {
        "type": "auto_retry_end",
        "success": success,
        "attempt": attempt,
        "finalError": match final_error {
          Some(message) => message.to_json()
          None => null
        },
      }
  }
}

///|
/// 把 AgentEvent 投影成 JSONL 事件(对齐 pi `--mode json` 的事件形状)。
fn agent_event_to_json(event : @agent_loop.AgentEvent) -> Json {
  match event {
    AgentStart => { "type": "agent_start" }
    TurnStart => { "type": "turn_start" }
    MessageStart(message) =>
      { "type": "message_start", "message": message.to_json() }
    MessageUpdate(message) =>
      { "type": "message_update", "message": message.to_json() }
    MessageEnd(message) =>
      { "type": "message_end", "message": message.to_json() }
    ToolExecutionStart(call) =>
      {
        "type": "tool_execution_start",
        "toolName": call.name,
        "args": call.arguments,
      }
    ToolExecutionEnd(result) =>
      {
        "type": "tool_execution_end",
        "toolName": result.tool_name,
        "content": [
          for c in result.content => c.to_json()
        ],
        "isError": result.is_error,
      }
    TurnEnd(assistant_message, tool_results) =>
      {
        "type": "turn_end",
        "message": assistant_message.to_json(),
        "toolCalls": [
          for r in tool_results => r.tool_name
        ],
      }
    AgentEnd(_) => { "type": "agent_end" }
  }
}

///|
/// 把 argparse 错误按 pi 风格输出到 stderr 并退出：
/// 只取首行（丢弃 usage 块），去掉小写 "error: " 前缀，改写成单行
/// `Error: <detail>`。pi 的对应输出例如 `Error: Unknown option: --bogus`。
async fn[T] arg_error(message : String) -> T {
  let first_line = match message.split_once("\n") {
    Some((head, _)) => head.to_owned()
    None => message
  }
  let detail = match first_line.strip_prefix("error: ") {
    Some(rest) => rest.to_owned()
    None => first_line
  }
  fatal("Error: \{detail}")
}

///|
/// 从 Error 的字符串形式中提取干净消息(openseek `failure_message` 的等效实现):
/// - 去掉 argparse 已带的小写 `error: ` 前缀
/// - 对 `Failure(<loc> FAILED: <msg>)` 包装,取 ` FAILED: ` 之后的内容并去掉尾部 `)`
fn clean_error_message(error_text : String) -> String {
  let without_prefix = match error_text.strip_prefix("error: ") {
    Some(rest) => rest.to_owned()
    None => error_text
  }
  match without_prefix.rev_split_once(" FAILED: ") {
    Some((_, message)) =>
      match message.strip_suffix(")") {
        Some(rest) => rest.to_owned()
        None => message.to_owned()
      }
    None => without_prefix
  }
}

///|
async fn write_stdout(message : String) -> Unit {
  // pi 的 print mode 对每段文本输出带尾部换行(`writeRawStdout`),这里对齐。
  @stdio.stdout.write("\{message}\n") catch {
    e => fatal("failed to write stdout: \{e}")
  }
}

///|
#cfg(target="native")
extern "c" fn proc_exit_ffi(rval : Int) -> Unit = "exit"

///|
async fn[T] fatal(message : String) -> T {
  @stdio.stderr.write("\{message}\n") catch {
    _ => ()
  }
  proc_exit_ffi(1)
  panic()
}
