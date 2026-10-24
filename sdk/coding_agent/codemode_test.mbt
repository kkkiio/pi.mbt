///|
/// session 里拿到 codemode 那次的 ToolResult 消息。
fn codemode_result(
  session : @agent_session.AgentSession,
) -> @agent_loop.ToolResultMessage {
  for message in session.messages() {
    if message is @agent_loop.AgentMessage::ToolResult(result) &&
      result.tool_name == "codemode" {
      return result
    }
  }
  abort("no codemode tool result in transcript")
}

///|
fn result_texts(result : @agent_loop.ToolResultMessage) -> Array[String] {
  result.content
  .iter()
  .filter_map(fn(item) {
    if item is @agent_loop.InputMessageContent::Text(text) {
      Some(text)
    } else {
      None
    }
  })
  .collect()
}

///|
/// codemode 嵌套调用必须对当前 active tools 求值,而不是构造期快照:
/// set_active_tools(["codemode"]) 停掉 bash 后,脚本里 tools.bash
/// 要被拒(prelude 报 "does not exist"),绝不能真执行。(PR #38 review)
async test "codemode nested calls resolve against the current active tools" {
  let dir = @coding_agent.create_temp_dir("pim-codemode-active-")
  let llm = @faux.FauxLLM::FauxLLM()
  llm.set_responses([
    @faux.faux_message([
      @faux.faux_tool_call("codemode", {
        "code": "return await tools.bash({ command: 'echo hi' });",
      }),
    ]),
    @faux.faux_message([@faux.faux_text("done")]),
  ])
  let session = @coding_agent.new_coding_session(llm, cwd=dir)
  session.set_active_tools(["codemode"])
  session.prompt([user_message("run it")])
  let result = codemode_result(session)
  assert_true(result.is_error)
  let text = result_texts(result).join("\n")
  assert_true(text.contains("does not exist"))
}

///|
/// 对照:默认 active tools 含 bash 时,同一个脚本能真正嵌套执行。
async test "codemode nested call runs an enabled tool" {
  let dir = @coding_agent.create_temp_dir("pim-codemode-active-")
  let llm = @faux.FauxLLM::FauxLLM()
  llm.set_responses([
    @faux.faux_message([
      @faux.faux_tool_call("codemode", {
        "code": "return await tools.bash({ command: 'echo hi' });",
      }),
    ]),
    @faux.faux_message([@faux.faux_text("done")]),
  ])
  let session = @coding_agent.new_coding_session(llm, cwd=dir)
  session.prompt([user_message("run it")])
  let result = codemode_result(session)
  assert_false(result.is_error)
  assert_true(result_texts(result).join("\n").contains("hi"))
}
