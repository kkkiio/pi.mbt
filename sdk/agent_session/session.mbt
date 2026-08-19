///|
/// Max total prompt attempts (1 initial + 2 auto-retries) at the session layer.
const MAX_PROMPT_ATTEMPTS : Int = 3

///|
/// Base exponential-backoff delay in milliseconds for auto-retry sleeps.
const AUTO_RETRY_BASE_DELAY_MS : Int = 500

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
        // Superseded or partial failure turns are kept in the journal (the
        // write-ahead log) but excluded from hydrated model context, so a
        // resumed session never replays an error turn into the prompt.
        Message(Assistant(m), ..) if m.stop_reason is Error => None
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
  // Auto-retry loop: a prompt whose assistant turn ends with a retryable
  // error is re-run from the same context (bounded, exponential backoff),
  // mirroring pi's session-level auto-retry: the failed turn's terminal Error
  // message is dropped and the assistant generation continues — the user
  // prompt and any prior tool work stay in place and are journaled once.
  let mut retry_index = 0
  let mut pending_prompts = input
  for ;; {
    let reason = @agent_loop.run_agent_loop(
      self.llm,
      self.system_prompt,
      self.message_buffer,
      agent_tools,
      pending_prompts,
      tool_executor=(c, hook) => @tools.run_tool(tool_map, c, hook),
      event_sink=event => {
        // Persist complete messages at their terminal events. User and
        // assistant messages are complete at MessageEnd (assistant streaming
        // events in between carry in-flight snapshots whose stop_reason is
        // Pending); tool results complete at ToolExecutionEnd. Error turns
        // are persisted unconditionally — the journal is a complete
        // write-ahead log.
        let content : SessionEntryContent? = match event {
          MessageEnd(User(_) as m) => Some(Message(m, terminate=false))
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
        self.fanout.on_event(AgentSessionEvent::Loop(event))
      },
    )
    if reason is @agent_loop.LoopStopReason::Error {
      let error_message = self.last_error_message()
      if error_message is Some(message) &&
        is_retryable_error_message(message) &&
        retry_index + 1 < MAX_PROMPT_ATTEMPTS {
        retry_index = retry_index + 1
        let delay_ms = AUTO_RETRY_BASE_DELAY_MS << (retry_index - 1)
        self.fanout.on_event(
          AgentSessionEvent::AutoRetryStart(
            attempt=retry_index,
            max_attempts=MAX_PROMPT_ATTEMPTS,
            delay_ms~,
            error_message=message,
          ),
        )
        @async.sleep(delay_ms)
        // Drop the failed turn's terminal Error message so the retried run
        // continues from the same context; the prompt is already in the
        // buffer, so no new user message is pushed or journaled.
        drop_trailing_error_message(self.message_buffer)
        pending_prompts = []
        continue
      }
      if retry_index > 0 {
        self.fanout.on_event(
          AgentSessionEvent::AutoRetryEnd(
            attempt=retry_index,
            success=false,
            final_error=error_message,
          ),
        )
      }
      break
    }
    // The prompt settled: success, or the user/system aborted it.
    if retry_index > 0 {
      self.fanout.on_event(
        AgentSessionEvent::AutoRetryEnd(
          attempt=retry_index,
          success=true,
          final_error=None,
        ),
      )
    }
    break
  }
}

///|
/// Drops the trailing Error assistant message, if the last run ended with one.
fn drop_trailing_error_message(
  messages : Array[@agent_loop.AgentMessage],
) -> Unit {
  if messages.length() > 0 {
    match messages[messages.length() - 1] {
      @agent_loop.AgentMessage::Assistant(m) if m.stop_reason is Error =>
        ignore(messages.pop())
      _ => ()
    }
  }
}

///|
/// The error message of the trailing assistant turn, when the last run ended
/// with an Error terminal message.
fn AgentSession::last_error_message(self : AgentSession) -> String? {
  if self.message_buffer.length() == 0 {
    return None
  }
  match self.message_buffer[self.message_buffer.length() - 1] {
    @agent_loop.AgentMessage::Assistant(m) if m.stop_reason is Error =>
      m.error_message
    _ => None
  }
}

///|
/// Subscribe to events starting from the next prompt. This will not replay past events.
pub fn AgentSession::subscribe(
  self : AgentSession,
  listener : EventListener,
) -> Unit {
  self.fanout.listeners.push(listener)
}
