///|
/// Journal-backed session over an `Agent`: it persists every loop event, owns
/// the auto-retry window and fans events out to subscribers. Transcript, tools
/// and the system prompt live on `agent`.
pub struct AgentSession {
  journal : &SessionJournal
  agent : Agent
  fanout : FanOutListener
  /// Agent-level auto-retry policy, read at every retryable failure.
  retry_settings : RetrySettings
  mut active_run_abort_controller : @agent_loop.AbortController?
  mut tools_recorded : Bool
}

///|
pub fn AgentSession::AgentSession(
  llm : &@agent_loop.LLM,
  system_prompt_contributes~ : Array[SystemPromptContributor] = [],
  journal~ : &SessionJournal = InMemorySessionJournal(),
  tool_registry~ : @tools.ToolRegistry = @tools.ToolRegistry(),
  active_tools~ : ArrayView[String] = [],
  retry_settings~ : RetrySettings = RetrySettings::default(),
  finish_turn_hook~ : @agent_loop.FinishTurnHook = (_, _, _) => None,
  auto_refresh_system_prompt~ : Bool = false,
) -> AgentSession {
  let (restored_tools, tools_recorded) = project_active_tools(
    journal.get_entries(),
    active_tools,
  )
  let agent = Agent::Agent(
    llm,
    system_prompt_contributes~,
    tool_registry~,
    active_tools=restored_tools,
    messages=project_messages(journal.get_entries()),
    finish_turn_hook~,
    auto_refresh_system_prompt~,
  )
  let session = AgentSession::{
    journal,
    agent,
    fanout: FanOutListener::FanOutListener(),
    retry_settings,
    active_run_abort_controller: None,
    tools_recorded,
  }
  session.agent.tool_search = Some(new_tool_search_tool_definition(session))
  session
}

///|
/// Prompt the agent with the given `input` messages.
/// 
/// Auto-retry loop: a prompt whose assistant turn ends with a retryable
/// error is re-run from the same context (bounded, exponential backoff),
/// mirroring pi's session-level auto-retry: the failed turn's terminal Error
/// message is dropped and the assistant generation continues — the user
/// prompt and any prior tool work stay in place and are journaled once.
///
/// Like pi's `Agent.runWithLifecycle`, a runtime/listener failure closes the
/// run with an assistant Error/Aborted message and terminal events. If a
/// listener also rejects those events, that error escapes; cleanup still runs.
pub async fn AgentSession::prompt(
  self : AgentSession,
  input : Array[@agent_loop.UserMessage],
) -> Unit {
  if self.active_run_abort_controller is Some(_) {
    fail(
      "Agent is already processing. Use 'steer' or 'followUp' to queue the message.",
    ) // TODO: support steer/follow_up
  }
  // Surface configuration errors before the run closes them as failures.
  for name in self.agent.active_tool_names() {
    guard self.agent.has_tool(name) else { fail("unknown tool: \{name}") }
  }
  let abort_controller = @agent_loop.AbortController::new()
  self.active_run_abort_controller = Some(abort_controller)
  defer {
    self.agent.set_messages(project_messages(self.journal.get_entries()))
    self.active_run_abort_controller = None
  }
  let mut retry_attempt = 0
  let mut last_assistant_entry_id : String? = None
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
    let sink : async (@agent_loop.AgentEvent) -> Unit = event => {
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
        if !self.tools_recorded {
          self.set_active_tools(self.agent.active_tool_names())
        }
        let stored = self.journal.append([
          { id: self.journal.generate_id(), content, },
        ])
        if content is Message(Assistant(_)) {
          last_assistant_entry_id = Some(stored[0].id)
        }
      }
      self.fanout.on_event(AgentSessionEvent::Loop(event))
      // reset retry window
      if retry_attempt > 0 && event is MessageEnd(Assistant(message)) {
        match message.stop_reason {
          Aborted => settle_retry(false, Some("Retry cancelled"))
          Error => ()
          _ => settle_retry(true, None)
        }
      }
    }
    // 有 prompt 就是新回合;没有 prompt 就是从现有 transcript 续跑(重试走这条)。
    // 后者校验尾部,所以重试能进行本身就说明失败回合已被 `context_edit` 剔除。
    // `run` raises only when the synthesized failure cannot be delivered either;
    // that error then escapes the session, matching pi.
    let run_escaped = self.agent.run(
      pending_prompts,
      abort=abort_controller.signal(),
      on_event=sink,
    )
    self.agent.set_messages(project_messages(self.journal.get_entries()))
    if self.agent.messages().last()
      is Some(
        @agent_loop.AgentMessage::Assistant(
          { stop_reason: Error, error_message, .. }
        )
      ) {
      if !run_escaped &&
        self.retry_settings.enabled &&
        error_message is Some(message) &&
        is_retryable_error_message(message) &&
        retry_attempt < self.retry_settings.max_retries {
        retry_attempt = retry_attempt + 1
        let delay_ms = self.retry_settings.delay_ms(retry_attempt)
        self.fanout.on_event(
          AgentSessionEvent::AutoRetryStart(
            attempt=retry_attempt,
            max_attempts=self.retry_settings.max_retries,
            delay_ms~,
            error_message=message,
          ),
        )
        if last_assistant_entry_id is Some(entry_id) {
          ignore(
            self.journal.append([
              {
                id: self.journal.generate_id(),
                content: ContextEdit(target_id=entry_id),
              },
            ]),
          )
        }
        self.agent.set_messages(project_messages(self.journal.get_entries()))
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
/// Subscribe to events starting from the next prompt. This will not replay past events.
pub fn AgentSession::subscribe(
  self : AgentSession,
  listener : EventListener,
) -> Unit {
  self.fanout.listeners.push(listener)
}

///|
/// The transcript the session projects from its journal.
pub fn AgentSession::messages(
  self : AgentSession,
) -> ArrayView[@agent_loop.AgentMessage] {
  self.agent.messages()
}

///|
/// Delegates to the inner agent.
pub fn AgentSession::set_finish_turn_hook(
  self : AgentSession,
  hook : @agent_loop.FinishTurnHook,
) -> Unit {
  self.agent.set_finish_turn_hook(hook)
}

///|
/// Persist a replacement tool set before making it active. Unknown names fail
/// without changing the journal or the agent. The last change on the selected
/// journal branch wins during hydration, including an explicitly empty set.
pub async fn AgentSession::set_active_tools(
  self : AgentSession,
  names : ArrayView[String],
) -> Unit {
  let next : Array[String] = []
  for name in names {
    guard self.agent.has_tool(name) else { fail("unknown tool: \{name}") }
    if !next.contains(name) {
      next.push(name)
    }
  }
  if self.tools_recorded && self.agent.active_tool_names() == next {
    return
  }
  ignore(
    self.journal.append([
      {
        id: self.journal.generate_id(),
        content: Custom(
          custom_type="pi.tools",
          data=Some({ "activeTools": next }),
        ),
      },
    ]),
  )
  self.agent.set_active_tools(next)
  self.tools_recorded = true
}

///|
fn project_active_tools(
  entries : ArrayView[SessionEntry],
  fallback : ArrayView[String],
) -> (Array[String], Bool) {
  let mut active = fallback.to_owned()
  let mut recorded = false
  for entry in entries {
    if entry.content
      is Custom(
        custom_type="pi.tools",
        data=Some({ "activeTools": Array(names), .. })
      ) {
      let next = names.filter_map(n => {
        match n {
          String(name) => Some(name)
          _ => None
        }
      })
      if next.length() == names.length() {
        active = next
        recorded = true
      }
    }
  }
  (active, recorded)
}

///|
/// Delegates to the inner agent.
pub fn AgentSession::active_tool_names(
  self : AgentSession,
) -> ArrayView[String] {
  self.agent.active_tool_names()
}

///|
/// 中断当前运行(如果没有正在跑的,则无效果)。
pub fn AgentSession::abort(self : AgentSession) -> Unit {
  guard self.active_run_abort_controller is Some(controller) else { return }
  controller.abort()
}

///|
/// A function that contributes to the system prompt based on the active tools.
/// The prompt should end with a newline.
pub type SystemPromptContributor = (ArrayView[String]) -> String

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
  delay_ms : Int32,
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

///|
/// 从 journal 条目投影出模型上下文。压缩条目把此前的历史换成"总结 + 保留尾部"
/// (pi 的 `buildContextEntries` + `sessionEntryToContextMessages`):总结作为一条
/// user 消息注入,被摘要掉的历史不再进上下文。
///
/// `context_edit` 条目剔除它指向的目标(pi 的 `projectContextEntry` 在
/// `replacement === null` 时返回空)。edits 从选中的条目里收集,所以被最新
/// 压缩丢掉的那一段里的 edit 不再生效。
fn project_messages(
  entries : ArrayView[SessionEntry],
) -> Array[@agent_loop.AgentMessage] {
  let messages : Array[@agent_loop.AgentMessage] = []
  let mut compaction_index : Int32? = None
  for i, entry in entries {
    if entry.content is Compaction(_) {
      compaction_index = Some(i)
    }
  }
  let selected = match compaction_index {
    None => entries.to_owned()
    Some(i) => {
      guard entries[i].content is Compaction(first_kept_entry_id~, ..) else {
        abort("expected compaction")
      }
      let selected = [entries[i]]
      let mut keep = false
      for j in 0..<i {
        keep = keep || entries[j].id == first_kept_entry_id
        if keep {
          selected.push(entries[j])
        }
      }
      selected.append(entries[i + 1:].to_owned())
      selected
    }
  }
  let omitted : Set[String] = Set([])
  for entry in selected {
    if entry.content is ContextEdit(target_id~) {
      omitted.add(target_id)
    }
  }
  for i, entry in selected {
    guard !omitted.contains(entry.id) else { continue }
    match entry.content {
      Compaction(_) if i > 0 => ()
      Compaction(summary~, ..) =>
        messages.push(
          @agent_loop.AgentMessage::User({
            content: [
              @agent_loop.InputMessageContent::Text(
                COMPACTION_SUMMARY_PREFIX + summary + COMPACTION_SUMMARY_SUFFIX,
              ),
            ],
            timestamp: entry.timestamp,
          }),
        )
      Message(m) => messages.push(m)
      _ => ()
    }
  }
  messages
}
