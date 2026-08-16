///|
/// Create a new coding agent session pre-configured with the default
/// system prompt and the native bash tool.
pub fn new_coding_session(
  llm : &@agent_loop.LLM,
  cwd~ : String,
  journal? : &@agent_session.SessionJournal = @agent_session.InMemorySessionJournal(),
) -> @agent_session.AgentSession {
  let system_prompt = build_system_prompt(cwd~)
  let session = @agent_session.AgentSession(llm, system_prompt~, journal~)
  session.register_tool(new_bash_tool_definition(cwd~))
  session
}
