///|
pub struct AgentSession {
  journal : &SessionJournal
  llm : &@agent_loop.LLM
  tool_registry : ToolRegistry
  fanout : FanOutListener
  message_buffer : Array[@agent_loop.AgentMessage]
  system_prompt : String
  mut active_run_exists : Bool
}

///|
pub fn AgentSession::AgentSession(
  llm : &@agent_loop.LLM,
  system_prompt~ : String,
  journal? : &SessionJournal = InMemorySessionJournal(),
) -> AgentSession {
  AgentSession::{
    tool_registry: ToolRegistry(),
    journal,
    fanout: FanOutListener::FanOutListener(),
    llm,
    system_prompt,
    message_buffer: [],
    active_run_exists: false,
  }
}

///|
/// Register a tool definition with the session.
pub fn AgentSession::register_tool(
  self : AgentSession,
  tool_def : @tools.ToolDefinition,
  activate? : Bool = true,
) -> Unit {
  self.tool_registry.register_tool(tool_def, activate~)
}

///|
pub async fn AgentSession::prompt(
  self : AgentSession,
  input : Array[@agent_loop.UserMessage],
) -> Unit {
  if self.active_run_exists {
    fail(
      "Agent is already processing. Use 'steer' or 'followUp' to queue the message.",
    ) // TODO: support steer/follow_up
  }
  let tool_registry = self.tool_registry
  let tools = tool_registry.get_active_tools()
  let tool_map = tools.iter().map(t => (t.name, t)) |> Map::from_iter
  let agent_tools = tools.map(d => {
    if d.callable_definition is Some(c) {
      @agent_loop.Function({
        name: d.name,
        description: c.description,
        parameters: c.parameters,
        constrained_sampling: c.constrained_sampling,
      })
    } else {
      match d.name {
        "web_search" => @agent_loop.Hosted(@agent_loop.WebSearch)
        _ => fail("unknown hosted tool \\{d.name}")
      }
    }
  })
  self.active_run_exists = true
  defer (() => self.active_run_exists = false)()
  let _ = @agent_loop.run_agent_loop(
    self.llm,
    self.system_prompt,
    self.message_buffer,
    agent_tools,
    input,
    tool_executor=(c, hook) => @tools.run_tool(tool_map, c, hook),
    event_sink=event => {
      let message = match event {
        MessageEnd(m) => m
        _ => return
      }
      self.journal.persist([
        {
          id: self.journal.generate_id(),
          timestamp: @env.now(),
          content: Message(message),
        },
      ])
      self.message_buffer.push(message)
      self.fanout.on_event(event)
    },
  )
}

///|
/// Subscribe to events starting from the next prompt. This will not replay past events.
pub fn AgentSession::subscribe(
  self : AgentSession,
  listener : EventListener,
) -> Unit {
  self.fanout.listeners.push(listener)
}
