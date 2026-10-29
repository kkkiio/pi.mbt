///|
/// Assemble an SDK session that exposes `codemode` over `streams`.
/// No default tools, filesystem, OS or network capabilities are registered.
pub fn new_ask_agent_session(
  llm : &@agent_loop.LLM,
  streams : WsStreams,
  system_prompt_contributes~ : Array[@agent_session.SystemPromptContributor] = [],
  journal~ : &@agent_session.SessionJournal = @agent_session.InMemorySessionJournal(),
  tools~ : ArrayView[@tools.ToolDefinition] = [],
  active_tools~ : ArrayView[String],
  finish_turn_hook~ : @agent_loop.FinishTurnHook = (_, _) => None,
) -> @agent_session.AgentSession {
  let tool_registry = @tools.ToolRegistry()
  for tool in tools {
    tool_registry.register_tool(tool)
  }
  let codemode_tool = new_codemode_tool_definition(
    streams,
    tools~,
    journal=Some(journal),
  )
  tool_registry.register_tool(codemode_tool)
  @agent_session.AgentSession(
    llm,
    system_prompt_contributes~,
    journal~,
    tool_registry~,
    active_tools~,
    finish_turn_hook~,
    retry_settings={
      ..@agent_session.RetrySettings::default(),
      enabled: false,
    },
  )
}
