///|
/// Create a new coding agent session pre-configured with the default
/// system prompt (including AGENTS.md project instructions and `.agents/skills/`)
/// and the bash tool. `tools` registers custom tools alongside the builtins and
/// nests them into `codemode`, so scripts can call them whether or not they are
/// in `active_tools`.
pub fn new_coding_session(
  llm : &@agent_loop.LLM,
  cwd~ : String,
  journal~ : &@agent_session.SessionJournal = @agent_session.InMemorySessionJournal(),
  tools~ : ArrayView[@tools.ToolDefinition] = [],
  active_tools~ : ArrayView[String] = [BASH_TOOL_NAME, CODEMODE_TOOL_NAME],
) -> @agent_session.AgentSession {
  let tool_registry = @tools.ToolRegistry()
  let bash_tool = new_bash_tool_definition(cwd~)
  tool_registry.register_tool(bash_tool)
  for tool in tools {
    tool_registry.register_tool(tool)
  }
  let codemode_tool = new_codemode_tool_definition(
    tools=[bash_tool, ..tools],
    journal=Some(journal),
  )
  tool_registry.register_tool(codemode_tool)
  @agent_session.AgentSession(
    llm,
    system_prompt_contributes=[
      coding_assistant_system_prompt_contributor(),
      tools_guidelines_system_prompt_contributor(tool_registry),
      project_context_system_prompt_contributor(cwd~),
      skills_system_prompt_contributor(cwd~),
      cwd_system_prompt_contributor(cwd~),
    ],
    journal~,
    tool_registry~,
    active_tools~,
  )
}
