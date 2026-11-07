///|
/// Create a new coding agent session pre-configured with the default
/// system prompt (including AGENTS.md project instructions and `.agents/skills/`)
/// and the bash tool. `tools` registers custom tools alongside the builtins and
/// nests them into `codemode`; their `exposure` decides whether scripts can
/// call them when they are not in `active_tools`.
pub fn new_coding_session(
  llm : &@agent_loop.LLM,
  cwd~ : String,
  journal~ : &@agent_session.SessionJournal = @agent_session.InMemorySessionJournal(),
  tools~ : ArrayView[@tools.ToolDefinition] = [],
  active_tools~ : ArrayView[String] = [BASH_TOOL_NAME, CODEMODE_TOOL_NAME],
) -> @agent_session.AgentSession {
  let tool_registry = @tools.ToolRegistry()
  let bash_tool = new_bash_tool_definition(cwd~)
  let all_tools : Array[@tools.ToolDefinition] = [bash_tool, ..tools]
  let declared : Ref[Array[String]] = Ref(active_tools.to_owned())
  let codemode_tool = new_codemode_tool_definition(
    tools=all_tools,
    journal=Some(journal),
    declared~,
  )
  for
    tool in @codemode_tool.prepare_codemode_loadout(
      all_tools,
      declared=active_tools,
    ) {
    tool_registry.register_tool(tool)
  }
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
    on_active_tools_changed=names => {
      declared.val = names.to_owned()
      for
        tool in @codemode_tool.prepare_codemode_loadout(
          all_tools,
          declared=names,
        ) {
        tool_registry.register_tool(tool)
      }
    },
  )
}
