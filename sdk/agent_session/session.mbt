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
    message_buffer: journal
    .get_entries()
    .filter_map(e => {
      match e.content {
        Message(m, ..) => Some(m)
        _ => None
      }
    }),
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
      // Persist complete messages at their terminal events. User messages
      // arrive complete at MessageStart; assistant messages are complete at
      // MessageEnd (streaming events in between carry in-flight snapshots
      // whose stop_reason is Pending); tool results complete at
      // ToolExecutionEnd.
      let content : SessionEntryContent? = match event {
        MessageStart(User(_) as m) => Some(Message(m, terminate=false))
        MessageEnd(Assistant(m) as msg) => {
          guard !(m.stop_reason is Pending) else {
            fail("journal cannot persist a message with pending stop_reason")
          }
          Some(Message(msg, terminate=false))
        }
        ToolExecutionEnd(result) =>
          Some(Message(ToolResult(result), terminate=result.terminate))
        _ => None
      }
      if content is Some(content) {
        ignore(
          self.journal.append([{ id: self.journal.generate_id(), content }]),
        )
      }
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
