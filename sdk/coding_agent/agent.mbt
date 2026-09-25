///|
/// Create a new coding agent session pre-configured with the default
/// system prompt (including AGENTS.md project instructions and `.agents/skills/`)
/// and the bash tool.
pub fn new_coding_session(
  llm : &@agent_loop.LLM,
  cwd~ : String,
  journal? : &@agent_session.SessionJournal = @agent_session.InMemorySessionJournal(),
  active_tools? : ArrayView[String] = [
    BASH_TOOL_NAME,
    @agent_session.WEB_SEARCH_TOOL_NAME,
  ],
) -> @agent_session.AgentSession {
  let context_files = load_agents_files(cwd)
  let skills = discover_skills("\{cwd}/.agents/skills")
  let system_prompt = build_system_prompt(
    cwd~,
    project_context_files=context_files,
    skills~,
  )
  let tool_registry = @tools.ToolRegistry()
  let bash_tool = new_bash_tool_definition(cwd~)
  tool_registry.register_tool(bash_tool)
  tool_registry.register_tool(@agent_session.web_search_tool)
  let session = @agent_session.AgentSession(
    llm,
    system_prompt~,
    journal~,
    tool_registry~,
    active_tools~,
  )
  session
}
