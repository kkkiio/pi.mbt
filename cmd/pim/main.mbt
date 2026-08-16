///|
async fn main {
  let matches = @argparse.parse(
    Command("pim", options=[OptionArg("print", short='p')]),
  )
  let prompts = match matches.values {
    { "print": prompts, .. } => prompts
    _ => fatal("only '-p' support for now")
  }
  let deepseek = @providers.DeepSeekProvider()
  let session = @coding_agent.new_coding_session(
    deepseek.new_llm("deepseek-v4-flash"),
    cwd=@env.current_dir().unwrap(),
  )
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
  guard last_message is Some(Assistant([_, ..] as reply)) else {
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
async fn write_stdout(message : String) -> Unit {
  @stdio.stdout.write(message) catch {
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
