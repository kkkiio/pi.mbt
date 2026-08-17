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
    ]),
    env=@env.get_env_vars(),
  ) catch {
    err => arg_error("\{err}")
  }
  let prompts = match matches.values {
    { "print": prompts, .. } => prompts
    _ => fatal("Error: only '-p' support for now")
  }
  let deepseek = @providers.DeepSeekProvider()
  // provider 构造失败(如缺 DEEPSEEK_API_KEY)是诊断,按输出流契约走 stderr;
  // 剥离 MoonBit 的 Failure(<loc> FAILED: msg) 包装,保留干净消息。
  let llm = deepseek.new_llm("deepseek-v4-flash") catch {
    err => fatal("Error: \{clean_error_message("\{err}")}")
  }
  let cwd = @env.current_dir().unwrap()
  let session_dir = match matches.values.get("session_dir") {
    Some(dirs) if dirs.length() > 0 => Some(dirs[0])
    _ => None
  }
  let (journal, cleanup) = match session_dir {
    Some(dir) => {
      @fs.mkdir(dir, recursive=true)
      let rand = @random.Rand::new()
      let timestamp = @env.now().to_string()
      let id = rand.uint64().to_string()
      let path = "\{dir}/\{timestamp}_\{id}.jsonl"
      let file = @fs.create(path, allow_existing=true)
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
  session.subscribe(event => {
    match event {
      MessageEnd(m) => last_message = Some(m)
      _ => ()
    }
  })
  session.prompt(
    prompts.map(p => @agent_loop.UserMessage::{
      content: [@agent_loop.InputMessageContent::Text(p)],
    }),
  )
  guard last_message
    is Some(Assistant({ content: [_, ..] as reply, .. })) else {
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
