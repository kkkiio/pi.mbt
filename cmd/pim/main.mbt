///|
async fn main {
  let matches = @argparse.parse(
    Command(
      "pim",
      flags=[
        FlagArg("continue", short='c', about="continue the most recent session"),
        FlagArg(
          "no_session",
          long="no-session",
          about="don't save the session (ephemeral)",
        ),
      ],
      options=[
        OptionArg("print", short='p', about="prompt text"),
        OptionArg(
          "resume",
          short='r',
          about="continue the session whose name starts with this prefix",
        ),
        OptionArg(
          "session_dir",
          long="session-dir",
          env="PIM_SESSION_DIR",
          about="directory to store session JSONL files (default: <config>/sessions/<cwd>)",
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
      ],
    ),
    env=@env.get_env_vars(),
  ) catch {
    err => arg_error("\{err}")
  }
  let prompts = match matches.values {
    { "print": prompts, .. } => prompts
    _ => []
  }
  let mode = match matches.values {
    { "mode": [m, ..], .. } =>
      match m {
        "text" => Text
        "json" => Json
        "rpc" => fatal("Error: mode 'rpc' is not supported yet")
        _ => fatal("Error: invalid mode '\{m}' (expected text or json)")
      }
    _ => Text
  }
  let interactive = prompts.length() == 0 &&
    @tui_app.stdin_is_tty() &&
    @tui_app.stdout_is_tty()
  if !interactive && prompts.length() == 0 {
    fatal(
      "Error: no prompt (pass -p <prompt>, or run in a terminal for the TUI)",
    )
  }
  let no_session = matches.flags.get("no_session").unwrap_or(false)
  let continue_session = matches.flags.get("continue").unwrap_or(false)
  let resume_prefix = match matches.values.get("resume") {
    Some([name, ..]) => Some(name)
    _ => None
  }
  if no_session && (continue_session || resume_prefix is Some(_)) {
    fatal("Error: --no-session cannot be combined with --continue/--resume")
  }
  // 隐式让 --continue 优先会无声忽略用户指定的 resume 前缀,可能恢复到
  // 错误的会话:两个选择器同时给出直接报错。
  if continue_session && resume_prefix is Some(_) {
    fatal("Error: --continue cannot be combined with --resume")
  }
  let api_key = resolve_deepseek_api_key() catch {
    AuthConfigError(message) => fatal("Error: \{message}")
  }
  let deepseek = match api_key {
    Some(api_key) => @providers.DeepSeekProvider(api_key~)
    None => fatal("Error: \{missing_api_key_message()}")
  }
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
  let llm = deepseek.new_llm("deepseek-v4-flash", thinking~)
  let cwd = @env.current_dir().unwrap()
  let session_dir = if no_session {
    None
  } else {
    match matches.values.get("session_dir") {
      Some(dirs) if dirs.length() > 0 => Some(dirs[0])
      _ => Some(default_session_dir(cwd))
    }
  }
  let start = if continue_session {
    @coding_agent.SessionStart::Latest
  } else {
    match resume_prefix {
      Some(prefix) => @coding_agent.SessionStart::Named(prefix)
      None => @coding_agent.SessionStart::Fresh
    }
  }
  // 要续写的会话(没有则为 None)。`-r` 找不到 / 多命中都是错误;
  // `-c` 在没有会话时退化成新会话(对齐 pi `continueRecent`)。
  let resume_path = match session_dir {
    None => None
    Some(dir) => {
      let pick = @coding_agent.resolve_session_start(dir, start) catch {
        err => {
          let detail = err.to_string()
          fatal("Error: \{clean_error_message(detail)}")
        }
      }
      match pick {
        Found(name) => Some("\{dir}/\{name}.jsonl")
        None =>
          match resume_prefix {
            Some(prefix) => {
              let detail = "no session matches '\{prefix}'"
              fatal("Error: \{detail}")
            }
            None => None
          }
        Ambiguous(candidates) => {
          let label = resume_prefix.unwrap_or("")
          let detail = "'\{label}' matches \{candidates.length()} sessions: \{candidates.join(", ")}"
          fatal("Error: \{detail}")
        }
      }
    }
  }
  // TUI 模式:会话(含 journal)由 tui_app 的 SessionHost 负责,这里不再自建。
  if interactive {
    @tui_app.run(
      llm,
      "deepseek-v4-flash",
      cwd,
      thinking,
      session_dir,
      resume_path~,
    ) catch {
      err => fatal("Error: \{clean_error_message("\{err}")}")
    }
    return
  }
  // 续写已有会话,否则开新的。两条路都用延迟打开的 writer:没有任何条目写出时,
  // 磁盘上不会留下文件(见 `JsonlSessionJournal` 的 flush 规则)。
  let (journal, cleanup) = match resume_path {
    Some(path) => {
      let entries = @coding_agent.fetch_entries(path) catch {
        err => fatal("Error: \{clean_error_message("\{err}")}")
      }
      let file = @coding_agent.open_lazy_file(path, append=true)
      (
        @coding_agent.JsonlSessionJournal::JsonlSessionJournal(
          file,
          entries~,
          fresh=false,
        )
        as &@agent_session.SessionJournal,
        () => file.close(),
      )
    }
    None =>
      match session_dir {
        Some(dir) => {
          @coding_agent.create_dir(dir) catch {
            err => fatal("Error: \{clean_error_message("\{err}")}")
          }
          let rand = @random.Rand::new()
          let path = "\{dir}/\{@env.now()}_\{rand.uint64()}.jsonl"
          // Session journals contain prompts and tool output: owner-only (0600).
          let file = @coding_agent.open_lazy_file(path)
          (
            @coding_agent.JsonlSessionJournal::JsonlSessionJournal(file)
            as &@agent_session.SessionJournal,
            () => file.close(),
          )
        }
        None => (@agent_session.InMemorySessionJournal(), () => ())
      }
  }
  defer cleanup()
  let session = @coding_agent.new_coding_session(llm, cwd~, journal~)
  let mut last_message : @agent_loop.AgentMessage? = None
  if mode is Json {
    // JSONL 模式:每个 AgentSessionEvent 一行 JSON 输出到 stdout(对齐 pi --mode json)。
    session.subscribe(event => {
      write_stdout(event.to_json().stringify())
      // Like pi's JSON subscriber, wait for the stdout queue between events:
      // a slow reader then throttles the stream instead of buffering it.
      flush_output()
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
  // pi's `flushRawStdout`: never let the exit truncate queued output.
  flush_output()
}

///|
/// `pim` 的输出模式,对齐 pi 的 `--mode`。
enum OutputMode {
  /// 只把 agent 的最终回复文本写到 stdout。
  Text
  /// 把每个会话事件投影成一行 JSON(JSONL)写到 stdout。
  Json
} derive(Eq)

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
/// Exit with code 1 after the queued diagnostics have reached the OS. The
/// writes are queued on the shared output chain, so `process.exit` cannot drop
/// them; `panic()` after it only satisfies the type checker (`exit` never
/// returns).
async fn[T] fatal(message : String) -> T {
  write_stderr(message)
  flush_output()
  proc_exit_ffi(1)
  panic()
}
