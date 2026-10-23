///|
/// Create a new coding agent session pre-configured with the default
/// system prompt (including AGENTS.md project instructions and `.agents/skills/`)
/// and the bash tool.
pub fn new_coding_session(
  llm : &@agent_loop.LLM,
  cwd~ : String,
  journal~ : &@agent_session.SessionJournal = @agent_session.InMemorySessionJournal(),
  active_tools~ : ArrayView[String] = [BASH_TOOL_NAME],
) -> @agent_session.AgentSession {
  let tool_registry = @tools.ToolRegistry()
  let bash_tool = new_bash_tool_definition(cwd~)
  tool_registry.register_tool(bash_tool)
  let session = @agent_session.AgentSession(
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
  session
}
