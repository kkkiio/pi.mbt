///|
/// Stateful wrapper around `@agent_loop.run_agent_loop` that owns the transcript,
/// active tool set, and assembled system prompt.
pub struct Agent {
  llm : &@agent_loop.LLM
  tool_registry : @tools.ToolRegistry
  active_tools : Array[String]
  system_prompt_contributes : Array[SystemPromptContributor]
  auto_refresh_system_prompt : Bool
  mut system_prompt_cache : (String, Array[String])?
  mut messages : Array[@agent_loop.AgentMessage]
  mut finish_turn_hook : @agent_loop.FinishTurnHook
  on_active_tools_changed : (ArrayView[String]) -> Unit
}

///|
pub fn Agent::Agent(
  llm : &@agent_loop.LLM,
  system_prompt_contributes~ : Array[SystemPromptContributor] = [],
  tool_registry~ : @tools.ToolRegistry = @tools.ToolRegistry(),
  active_tools~ : ArrayView[String] = [],
  messages~ : ArrayView[@agent_loop.AgentMessage] = [],
  finish_turn_hook~ : @agent_loop.FinishTurnHook = (_, _) => None,
  auto_refresh_system_prompt~ : Bool = false,
  on_active_tools_changed~ : (ArrayView[String]) -> Unit = _ => (),
) -> Agent {
  Agent::{
    llm,
    tool_registry,
    active_tools: active_tools.to_owned(),
    system_prompt_contributes,
    auto_refresh_system_prompt,
    system_prompt_cache: None,
    messages: messages.to_owned(),
    finish_turn_hook,
    on_active_tools_changed,
  }
}

///|
/// Returns the transcript for the next run.
pub fn Agent::messages(self : Agent) -> ArrayView[@agent_loop.AgentMessage] {
  self.messages
}

///|
/// Replaces the agent's transcript with `messages`.
pub fn Agent::set_messages(
  self : Agent,
  messages : ArrayView[@agent_loop.AgentMessage],
) -> Unit {
  self.messages = messages.to_owned()
}

///|
/// Sets the active tool names. Raises if any name in `names` is not registered.
pub fn Agent::set_active_tools(
  self : Agent,
  names : ArrayView[String],
) -> Unit raise {
  for name in names {
    guard self.tool_registry.get_tool(name) is Some(_) else {
      fail("unknown tool: \{name}")
    }
  }
  let next = names.to_owned()
  self.active_tools.clear()
  for name in next {
    self.active_tools.push(name)
  }
  (self.on_active_tools_changed)(self.active_tools)
}

///|
pub fn Agent::active_tool_names(self : Agent) -> ArrayView[String] {
  self.active_tools
}

///|
/// Replaces the finish-turn hook.
pub fn Agent::set_finish_turn_hook(
  self : Agent,
  hook : @agent_loop.FinishTurnHook,
) -> Unit {
  self.finish_turn_hook = hook
}

///|
/// Returns whether `name` resolves in the tool registry.
pub fn Agent::has_tool(self : Agent, name : String) -> Bool {
  self.tool_registry.get_tool(name) is Some(_)
}

///|
/// Returns the assembled system prompt, recomputing only when `auto_refresh_system_prompt` is enabled.
pub fn Agent::system_prompt(self : Agent) -> String {
  let contributions = () => {
    let parts = self.system_prompt_contributes.filter_map(f => {
      match f(self.active_tools) {
        "" => None
        s => Some(s)
      }
    })
    let prompt = parts.join("\n")
    (prompt, parts)
  }
  match self.system_prompt_cache {
    Some(cached) =>
      if self.auto_refresh_system_prompt {
        let next = contributions()
        if next.1 != cached.1 {
          self.system_prompt_cache = Some(next)
          next.0
        } else {
          cached.0
        }
      } else {
        cached.0
      }
    None => {
      let next = contributions()
      self.system_prompt_cache = Some(next)
      next.0
    }
  }
}

///|
/// Runs one attempt, delivering ordered events and delivery context to `on_event`.
/// Empty prompts continue the transcript; extension errors propagate.
/// Cancellation closes the current turn before leaving the task.
pub async fn Agent::run(
  self : Agent,
  prompts : ArrayView[@agent_loop.UserMessage],
  on_event~ : @agent_loop.EventSink,
) -> Unit {
  let tools : Array[@tools.ToolDefinition] = []
  for name in self.active_tools {
    guard self.tool_registry.get_tool(name) is Some(tool) else {
      fail("unknown tool: \{name}")
    }
    if tool.exposure is @tools.ToolExposure::Hidden {
      continue
    }
    tools.push(tool)
  }
  let tool_map = tools.iter().map(t => (t.name, t)) |> Map::from_iter
  let agent_tools = tools.map(d => @agent_loop.ToolDefinition::{
    name: d.name,
    description: d.description,
    parameters: d.parameters,
    constrained_sampling: d.constrained_sampling,
  })
  let system_prompt = self.system_prompt()
  let sink : @agent_loop.EventSink = (event, context) => {
    match event {
      MessageEnd(User(message)) => self.messages.push(User(message))
      MessageEnd(Assistant(message)) => self.messages.push(Assistant(message))
      ToolExecutionEnd(result) =>
        self.messages.push(@agent_loop.ToolResult(result))
      _ => ()
    }
    on_event(event, context)
  }
  if prompts.length() > 0 {
    @agent_loop.run_agent_loop(
      self.llm,
      system_prompt,
      self.messages.copy(),
      agent_tools,
      prompts,
      tool_executor=(c, hook) => @tools.run_tool(tool_map, c, hook),
      event_sink=sink,
      finish_turn_hook=self.finish_turn_hook,
    )
  } else {
    @agent_loop.run_agent_loop_continue(
      self.llm,
      system_prompt,
      self.messages.copy(),
      agent_tools,
      tool_executor=(c, hook) => @tools.run_tool(tool_map, c, hook),
      event_sink=sink,
      finish_turn_hook=self.finish_turn_hook,
    )
  }
}
