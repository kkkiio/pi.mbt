///|
pub struct AgentSession {
  journal : &SessionJournal
  llm : &@agent_loop.LLM
  tool_registry : @tools.ToolRegistry
  active_tools : Array[String]
  fanout : FanOutListener
  message_buffer : Array[@agent_loop.AgentMessage]
  system_prompt : String
  /// 当前运行的中断控制器(每次 prompt 新建,结束后清空)。只有它能置位。
  mut active_run_abort_controller : @agent_loop.AbortController?
}

///|
pub fn AgentSession::AgentSession(
  llm : &@agent_loop.LLM,
  system_prompt~ : String,
  journal? : &SessionJournal = InMemorySessionJournal(),
  tool_registry? : @tools.ToolRegistry = @tools.ToolRegistry(),
  active_tools? : ArrayView[String] = [],
) -> AgentSession {
  AgentSession::{
    tool_registry,
    active_tools: active_tools.to_owned(),
    journal,
    fanout: FanOutListener::FanOutListener(),
    llm,
    system_prompt,
    active_run_abort_controller: None,
    message_buffer: journal
    .get_entries()
    .filter_map(e => {
      match e.content {
        // Superseded or partial failure turns are kept in the journal (the
        // write-ahead log) but excluded from hydrated model context, so a
        // resumed session never replays an error turn into the prompt.
        Message(Assistant(m)) if m.stop_reason is Error => None
        Message(m) => Some(m)
        _ => None
      }
    }),
  }
}

///|
/// Prompt the agent with the given `input` messages.
/// 
/// Auto-retry loop: a prompt whose assistant turn ends with a retryable
/// error is re-run from the same context (bounded, exponential backoff),
/// mirroring pi's session-level auto-retry: the failed turn's terminal Error
/// message is dropped and the assistant generation continues — the user
/// prompt and any prior tool work stay in place and are journaled once.
pub async fn AgentSession::prompt(
  self : AgentSession,
  input : Array[@agent_loop.UserMessage],
) -> Unit {
  if self.active_run_abort_controller is Some(_) {
    fail(
      "Agent is already processing. Use 'steer' or 'followUp' to queue the message.",
    ) // TODO: support steer/follow_up
  }
  let tools : Array[@tools.ToolDefinition] = []
  for name in self.active_tools {
    guard self.tool_registry.get_tool(name) is Some(tool) else {
      fail("unknown tool: \{name}")
    }
    tools.push(tool)
  }
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
        WEB_SEARCH_TOOL_NAME => @agent_loop.Hosted(@agent_loop.WebSearch)
        _ => fail("unknown hosted tool \\{d.name}")
      }
    }
  })
  let abort_controller = @agent_loop.AbortController::new()
  self.active_run_abort_controller = Some(abort_controller)
  defer {
    self.active_run_abort_controller = None
  }
  let mut retry_attempt = 0
  // 结束当前重试窗口:只在真的发起过重试时才发 `AutoRetryEnd`,然后归零。
  let settle_retry = (success : Bool, final_error : String?) => {
    if retry_attempt > 0 {
      self.fanout.on_event(
        AgentSessionEvent::AutoRetryEnd(
          attempt=retry_attempt,
          success~,
          final_error~,
        ),
      )
      retry_attempt = 0
    }
  }
  let mut pending_prompts = input
  for ;; {
    let reason = @agent_loop.run_agent_loop(
      self.llm,
      self.system_prompt,
      self.message_buffer,
      agent_tools,
      pending_prompts,
      tool_executor=(c, hook) => @tools.run_tool(tool_map, c, hook),
      abort=abort_controller.signal(),
      event_sink=event => {
        // Persist complete messages at their terminal events. User and
        // assistant messages are complete at MessageEnd (assistant streaming
        // events in between carry in-flight snapshots whose stop_reason is
        // Pending); tool results complete at ToolExecutionEnd. Error turns
        // are persisted unconditionally — the journal is a complete
        // write-ahead log.
        let content : SessionEntryContent? = match event {
          MessageEnd(User(_) as m) => Some(Message(m))
          MessageEnd(Assistant(m) as msg) => {
            guard !(m.stop_reason is Pending) else {
              fail("journal cannot persist a message with pending stop_reason")
            }
            Some(Message(msg))
          }
          ToolExecutionEnd(result) => Some(Message(ToolResult(result)))
          _ => None
        }
        if content is Some(content) {
          self.journal.append([{ id: self.journal.generate_id(), content, }])
          |> ignore
        }
        self.fanout.on_event(AgentSessionEvent::Loop(event))
        // 成功的 assistant 响应结束当前重试窗口并归零,所以同一次 prompt 里后续的
        // 调用各自重新拿满预算(pi 在 message_end 上重置)。取消不报成功。
        match event {
          MessageEnd(Assistant(message)) if retry_attempt > 0 =>
            match message.stop_reason {
              Aborted => settle_retry(false, Some("Retry cancelled"))
              Error => ()
              _ => settle_retry(true, None)
            }
          _ => ()
        }
      },
    )
    if reason is @agent_loop.LoopStopReason::Error {
      let error_message = self.last_error_message()
      if error_message is Some(message) &&
        is_retryable_error_message(message) &&
        retry_attempt < MAX_AUTO_RETRIES {
        retry_attempt = retry_attempt + 1
        let delay_ms = auto_retry_delay_ms(retry_attempt)
        self.fanout.on_event(
          AgentSessionEvent::AutoRetryStart(
            attempt=retry_attempt,
            max_attempts=MAX_AUTO_RETRIES,
            delay_ms~,
            error_message=message,
          ),
        )
        // Drop the failed turn's terminal Error message so the retried run
        // continues from the same context; the prompt is already in the
        // buffer, so no new user message is pushed or journaled. Keep this
        // projection clean even when the backoff is interrupted.
        drop_trailing_error_message(self.message_buffer)
        if wait_backoff(delay_ms, abort_controller.signal()) is Aborted {
          // 退避窗口里被中断:这一轮不再发起。
          settle_retry(false, Some("Retry cancelled"))
          break
        }
        pending_prompts = []
        continue
      }
      settle_retry(false, error_message)
      break
    }
    // 重试窗口没等到新的 assistant 消息就结束了(例如退避睡完与 run 启动之间被中断)。
    settle_retry(false, Some("Retry cancelled"))
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

///|
pub fn AgentSession::set_active_tools(
  self : AgentSession,
  names : ArrayView[String],
) -> Unit raise {
  for name in names {
    guard self.tool_registry.get_tool(name) is Some(_) else {
      fail("unknown tool: \{name}")
    }
  }
  names.blit_to(self.active_tools)
}

///|
pub fn AgentSession::active_tool_names(
  self : AgentSession,
) -> ArrayView[String] {
  self.active_tools
}

///|
/// 中断当前运行(如果没有正在跑的,则无效果)。
pub fn AgentSession::abort(self : AgentSession) -> Unit {
  guard self.active_run_abort_controller is Some(controller) else { return }
  controller.abort()
}

///|
/// Max consecutive auto-retries after a retryable error, not counting the
/// initial attempt. pi reports the same number as `maxAttempts`.
const MAX_AUTO_RETRIES : Int = 2

///|
/// Base exponential-backoff delay in milliseconds for auto-retry sleeps.
const AUTO_RETRY_BASE_DELAY_MS : Int = 500

///|
/// Ceiling on a single backoff sleep, matching pi's
/// `DEFAULT_MAX_AGENT_RETRY_DELAY_MS`.
const AUTO_RETRY_MAX_DELAY_MS : Int = 60_000

///|
/// pi's `retryDelayMs`: exponential backoff from the base delay, capped per attempt.
fn auto_retry_delay_ms(attempt : Int) -> Int {
  let delay = AUTO_RETRY_BASE_DELAY_MS << (attempt - 1)
  if delay > AUTO_RETRY_MAX_DELAY_MS {
    AUTO_RETRY_MAX_DELAY_MS
  } else {
    delay
  }
}

///|
/// 退避竞速的结局。`@async.any` 只返回胜者的值、不告知下标,所以每个分支都要在
/// 返回值里带上自己的编码。
priv enum BackoffWait {
  Slept
  Aborted
}

///|
/// 退避睡眠与中断竞速:谁先到谁赢,输的一支被 `@async.any` 取消。
async fn wait_backoff(
  delay_ms : Int,
  abort : @agent_loop.AbortSignal,
) -> BackoffWait {
  @async.any([
    async fn() {
      @async.sleep(delay_ms)
      BackoffWait::Slept
    },
    async fn() {
      abort.wait_abort()
      BackoffWait::Aborted
    },
  ])
}
