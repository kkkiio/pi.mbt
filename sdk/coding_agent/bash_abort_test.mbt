///|
/// The bash tool's callable definition, for driving commands directly (outside
/// the session) and for the post-abort checks.
fn bash_callable() -> @tools.CallableDefinition raise {
  let definition = @coding_agent.new_bash_tool_definition(cwd="/tmp")
  guard definition.callable_definition is Some(callable) else {
    fail("bash tool has no callable definition")
  }
  callable
}

///|
fn text_of(content : Array[@agent_loop.InputMessageContent]) -> String raise {
  match content {
    [@agent_loop.InputMessageContent::Text(text)] => text
    _ =>
      fail(
        "expected a single text output, got \{content.to_json().stringify()}",
      )
  }
}

///|
/// Remove a temp file the test may have created, ignoring "already gone".
fn remove_maybe(path : String) -> Unit {
  @coding_agent.remove_file(path) catch {
    _ => ()
  }
}

///|
/// Aborting a running bash call must not just mark the result: cancelling the
/// tool coroutine unblocks `proc.exited().wait(...)`, `defer proc.kill()` kills
/// the process tree, so work scheduled after the abort point never happens.
/// Mirrors pi's `bash-close-hang-windows.test.ts`, which drives the tool with a
/// controller directly.
async test "bash tool kills the command when its coroutine is cancelled" {
  let marker = "/tmp/pim-bash-abort-tool-\{@env.now()}.txt"
  let raced : @agent_loop.ToolResult? = @async.with_task_group() <| group => {
    group.spawn_bg(async fn() {
      @async.sleep(100)
      group.return_immediately(None)
    })
    Some(
      (bash_callable().execute)(
        "call-abort",
        { "command": "sleep 0.5; echo done > '\{marker}'" },
        (_, _) => (),
      ),
    )
  }
  // 工具协程在 await 点被中断,group 以 None(aborted)返回。
  assert_true(raced is None)
  // 进程树已被 kill:`sleep 0.5` 之后的副作用不会发生。
  @async.sleep(700)
  let check = (bash_callable().execute)(
    "call-check",
    { "command": "test -f '\{marker}' && echo present || echo absent" },
    (_, _) => (),
  )
  assert_eq(text_of(check.content), "absent\n")
  remove_maybe(marker)
}

///|
/// Aborting a session while the bash tool is running must cancel the tool's
/// coroutine, kill the process tree, and record the running call as an aborted
/// tool result — the session-level counterpart, driven by the faux provider.
async test "aborting a running bash tool kills the command and records an aborted result" {
  let suffix = @env.now().to_string()
  let pid_file = "/tmp/pim-bash-abort-session-\{suffix}.pid"
  let done_file = "/tmp/pim-bash-abort-session-\{suffix}.done"
  let registry = @tools.ToolRegistry()
  registry.register_tool(@coding_agent.new_bash_tool_definition(cwd="/tmp"))
  let journal = @agent_session.InMemorySessionJournal()
  let llm = @faux.FauxLLM::FauxLLM()
  llm.set_responses([
    @faux.faux_message(
      [
        @faux.faux_tool_call("bash", {
          "command": "echo $$ > '\{pid_file}'; sleep 30; echo done > '\{done_file}'",
        }),
      ],
      stop_reason=@agent_loop.StopReason::ToolUse,
    ),
  ])
  let session = @agent_session.AgentSession(
    llm,
    system_prompt="",
    journal~,
    tool_registry=registry,
    active_tools=["bash"],
  )
  @async.with_task_group() <| group => {
    group.spawn_bg(async fn() {
      @async.sleep(300)
      session.interrupt()
    })
    session.prompt([
      @agent_loop.UserMessage::{
        content: [@agent_loop.InputMessageContent::Text("run it")],
        timestamp: 1786903823973,
      },
    ])
  }
  // The running call is recorded as aborted (the child never produced a result).
  let results = journal
    .get_entries()
    .filter_map(entry => {
      match entry.content {
        Message(@agent_loop.AgentMessage::ToolResult(result)) => Some(result)
        _ => None
      }
    })
  assert_eq(results.length(), 1)
  assert_true(results[0].is_error)
  assert_eq(text_of(results[0].content), "Operation aborted")
  // Prove the shell died rather than merely being abandoned: its recorded pid
  // is gone and the `sleep 30` side effect never happened.
  @async.sleep(200)
  let check = (bash_callable().execute)(
    "call-check",
    {
      "command": "test -f '\{pid_file}' && echo started || echo notstarted; " +
      "kill -0 $(cat '\{pid_file}' 2>/dev/null) 2>/dev/null && echo alive || echo dead; " +
      "test -f '\{done_file}' && echo finished || echo unfinished",
    },
    (_, _) => (),
  )
  let output = text_of(check.content)
  assert_true(output.contains("started"))
  assert_true(output.contains("dead"))
  assert_true(output.contains("unfinished"))
  remove_maybe(pid_file)
  remove_maybe(done_file)
}
