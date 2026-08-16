///|
/// Create a new coding agent session pre-configured with the default
/// system prompt (including AGENTS.md project instructions and `.agents/skills/`)
/// and the native bash tool.
pub async fn new_coding_session(
  llm : &@agent_loop.LLM,
  cwd~ : String,
  journal? : &@agent_session.SessionJournal = @agent_session.InMemorySessionJournal(),
) -> @agent_session.AgentSession {
  let context_files = load_agents_files(cwd)
  let skills = discover_skills("\{cwd}/.agents/skills")
  let system_prompt = build_system_prompt(
    cwd~,
    project_context_files=context_files,
    skills~,
  )
  let session = @agent_session.AgentSession(llm, system_prompt~, journal~)
  session.register_tool(new_bash_tool_definition(cwd~))
  session
}
