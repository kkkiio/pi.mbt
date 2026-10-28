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
  mut active_run : Ref[(@async.Task[Unit?]?, Bool)]?
}

///|
pub fn AgentSession::AgentSession(
  llm : &@agent_loop.LLM,
  system_prompt_contributes~ : Array[SystemPromptContributor] = [],
  journal~ : &SessionJournal = InMemorySessionJournal(),
  tool_registry~ : @tools.ToolRegistry = @tools.ToolRegistry(),
  active_tools~ : ArrayView[String] = [],
  retry_settings~ : RetrySettings = RetrySettings::default(),
  finish_turn_hook~ : @agent_loop.FinishTurnHook = (_, _) => None,
  auto_refresh_system_prompt~ : Bool = false,
) -> AgentSession {
  let agent = Agent::Agent(
    llm,
    system_prompt_contributes~,
    tool_registry~,
    active_tools~,
    messages=project_messages(journal.get_entries()),
    finish_turn_hook~,
    auto_refresh_system_prompt~,
  )
  AgentSession::{
    journal,
    agent,
    fanout: FanOutListener::FanOutListener(),
    retry_settings,
    active_run: None,
  }
}

///|
/// Prompts the agent and owns its cancellable retry window.
/// User cancellation returns normally; extension and storage errors propagate.
/// Rejects overlapping prompts and restores journal-backed context on exit.
pub async fn AgentSession::prompt(
  self : AgentSession,
  input : Array[@agent_loop.UserMessage],
) -> Unit {
  guard self.active_run is None else {
    fail(
      "Agent is already processing. Use 'steer' or 'followUp' to queue the message.",
    )
  }
  for name in self.agent.active_tool_names() {
    guard self.agent.has_tool(name) else { fail("unknown tool: \{name}") }
  }
  let run : Ref[(@async.Task[Unit?]?, Bool)] = Ref((None, false))
  self.active_run = Some(run)
  defer {
    self.agent.set_messages(project_messages(self.journal.get_entries()))
    self.active_run = None
  }
  @async.with_task_group() <| group => {
    let task = group.spawn(allow_failure=true, () => {
      @async.handle_cancellation(() => {
        let mut failure : Error? = None
        let mut retry_attempt = 0
        let mut pending_retry_end : AgentSessionEvent? = None
        let mut last_assistant_entry_id : String? = None
        let settle_retry = (success : Bool, final_error : String?) => {
          let event = if pending_retry_end is Some(event) {
            Some(event)
          } else if retry_attempt > 0 {
            Some(AutoRetryEnd(attempt=retry_attempt, success~, final_error~))
          } else {
            None
          }
          retry_attempt = 0
          pending_retry_end = None
          if event is Some(event) {
            self.fanout.on_event(event)
          }
        }
        errdefer (if failure is None && @async.is_being_cancelled() {
          @async.protect_from_cancel(() => {
            settle_retry(false, Some("Retry cancelled"))
          })
        })
        let outcome : Result[Unit, Error] = try {
          let mut pending_prompts = input
          for ;; {
            let sink : async (@agent_loop.AgentEvent) -> Unit = event => {
              let content : SessionEntryContent? = match event {
                MessageEnd(User(_) as message) => Some(Message(message))
                MessageEnd(Assistant(message) as msg) => {
                  guard !(message.stop_reason is Pending) else {
                    fail(
                      "journal cannot persist a message with pending stop_reason",
                    )
                  }
                  Some(Message(msg))
                }
                ToolExecutionEnd(result) => Some(Message(ToolResult(result)))
                _ => None
              }
              if content is Some(content) {
                @async.protect_from_cancel(() => {
                  let stored = self.journal.append([
                    { id: self.journal.generate_id(), content, },
                  ])
                  if content is Message(Assistant(_)) {
                    last_assistant_entry_id = Some(stored[0].id)
                  }
                })
              }
              if retry_attempt > 0 &&
                event is MessageEnd(Assistant(message)) &&
                !(message.stop_reason is Error) {
                let attempt = retry_attempt
                retry_attempt = 0
                pending_retry_end = Some(
                  AutoRetryEnd(
                    attempt~,
                    success=!(message.stop_reason is Aborted),
                    final_error=if message.stop_reason is Aborted {
                      Some("Retry cancelled")
                    } else {
                      None
                    },
                  ),
                )
              }
              self.fanout.on_event(Loop(event))
              if pending_retry_end is Some(event) {
                pending_retry_end = None
                self.fanout.on_event(event)
              }
            }
            self.agent.run(pending_prompts, on_event=sink)
            self.agent.set_messages(
              project_messages(self.journal.get_entries()),
            )
            if self.agent.messages().last()
              is Some(
                @agent_loop.AgentMessage::Assistant(
                  { stop_reason: Error, error_message, .. }
                )
              ) {
              if self.retry_settings.enabled &&
                error_message is Some(message) &&
                is_retryable_error_message(message) &&
                retry_attempt < self.retry_settings.max_retries {
                retry_attempt += 1
                let delay_ms = self.retry_settings.delay_ms(retry_attempt)
                self.fanout.on_event(
                  AutoRetryStart(
                    attempt=retry_attempt,
                    max_attempts=self.retry_settings.max_retries,
                    delay_ms~,
                    error_message=message,
                  ),
                )
                @async.pause()
                if last_assistant_entry_id is Some(entry_id) {
                  @async.protect_from_cancel(() => {
                    ignore(
                      self.journal.append([
                        {
                          id: self.journal.generate_id(),
                          content: ContextEdit(target_id=entry_id),
                        },
                      ]),
                    )
                  })
                }
                self.agent.set_messages(
                  project_messages(self.journal.get_entries()),
                )
                @async.sleep(delay_ms)
                pending_prompts = []
                continue
              }
              settle_retry(false, error_message)
              break
            }
            settle_retry(false, Some("Retry cancelled"))
            break
          }
          Ok(())
        } catch {
          err => Err(err)
        }
        match outcome {
          Ok(_) => ()
          Err(err) => {
            failure = Some(err)
            raise err
          }
        }
      })
    })
    run.val = (Some(task), run.val.1)
    if run.val.1 {
      task.cancel()
    }
    ignore(task.wait())
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
/// Delegates to the inner agent.
pub fn AgentSession::set_active_tools(
  self : AgentSession,
  names : ArrayView[String],
) -> Unit raise {
  self.agent.set_active_tools(names)
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
  guard self.active_run is Some(run) else { return }
  if !run.val.1 {
    run.val = (run.val.0, true)
    if run.val.0 is Some(task) {
      task.cancel()
    }
  }
}

///|
/// A function that contributes to the system prompt based on the active tools.
pub type SystemPromptContributor = (ArrayView[String]) -> String

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
