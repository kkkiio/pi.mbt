///|
/// Assemble an SDK session with explicit tools, streaming and a finish-turn hook.
/// No default tools, filesystem, OS or network capabilities are registered.
pub fn new_ask_agent_session(
  llm : &@agent_loop.LLM,
  system_prompt~ : String,
  journal~ : &@agent_session.SessionJournal = @agent_session.InMemorySessionJournal(),
  tool_registry~ : @tools.ToolRegistry,
  active_tools~ : ArrayView[String],
  finish_turn_hook~ : @agent_loop.FinishTurnHook = (_, _) => None,
  on_generation~ : async (@agent_loop.GenerationEvent) -> Unit = fn(_) { () },
) -> @agent_session.AgentSession {
  let session = @agent_session.AgentSession(
    llm,
    system_prompt_contributes=[_ => system_prompt],
    journal~,
    tool_registry~,
    active_tools~,
    finish_turn_hook~,
    retry_settings={
      ..@agent_session.RetrySettings::default(),
      enabled: false,
    },
  )
  session.subscribe(event => {
    if event is Loop(MessageUpdate(update)) {
      on_generation(update)
    }
  })
  session
}
