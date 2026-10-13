///|
/// pi wraps a compaction summary in these markers when it projects the summary
/// into the model context (`COMPACTION_SUMMARY_PREFIX` / `_SUFFIX`).
const COMPACTION_SUMMARY_PREFIX : String = "The conversation history before this point was compacted into the following summary:\n\n<summary>\n"

///|
const COMPACTION_SUMMARY_SUFFIX : String = "\n</summary>"

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

///|
pub struct AgentSession {
  journal : &SessionJournal
  llm : &@agent_loop.LLM
  tool_registry : @tools.ToolRegistry
  active_tools : Array[String]
  fanout : FanOutListener
  mut message_buffer : Array[@agent_loop.AgentMessage]
  system_prompt : String
  /// Agent-level auto-retry policy, read at every retryable failure.
  retry_settings : RetrySettings
  /// Called after a completed assistant turn and all of its tool results, but
  /// before `turn_end`. Read at every run, so a caller may replace or wrap it.
  mut finish_turn_hook : @agent_loop.FinishTurnHook
  /// 当前运行的中断控制器(每次 prompt 新建,结束后清空)。只有它能置位。
  mut active_run_abort_controller : @agent_loop.AbortController?
}

///|
pub fn AgentSession::AgentSession(
  llm : &@agent_loop.LLM,
  system_prompt~ : String,
  journal~ : &SessionJournal = InMemorySessionJournal(),
  tool_registry~ : @tools.ToolRegistry = @tools.ToolRegistry(),
  active_tools~ : ArrayView[String] = [],
  retry_settings~ : RetrySettings = RetrySettings::default(),
  finish_turn_hook~ : @agent_loop.FinishTurnHook = (_, _, _) => None,
) -> AgentSession {
  AgentSession::{
    tool_registry,
    active_tools: active_tools.to_owned(),
    journal,
    fanout: FanOutListener::FanOutListener(),
    llm,
    system_prompt,
    retry_settings,
    finish_turn_hook,
    active_run_abort_controller: None,
    message_buffer: project_messages(journal.get_entries()),
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
    self.message_buffer = project_messages(self.journal.get_entries())
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
    let mut assistant_metadata : @agent_loop.AssistantMessage? = None
    let sink : async (@agent_loop.AgentEvent) -> Unit = event => {
      match event {
        MessageStart(Assistant(message)) | MessageEnd(Assistant(message)) =>
          assistant_metadata = Some(message)
        _ => ()
      }
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
        let stored = self.journal.append([
          { id: self.journal.generate_id(), content, },
        ])
        if content is Message(Assistant(_)) {
          last_assistant_entry_id = Some(stored[0].id)
        }
        if content is Message(message) {
          self.message_buffer.push(message)
        }
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
    }
    // 有 prompt 就是新回合;没有 prompt 就是从现有 transcript 续跑(重试走这条)。
    // 后者校验尾部,所以重试能进行本身就说明失败回合已被 `context_edit` 剔除。
    try {
      if pending_prompts.length() > 0 {
        @agent_loop.run_agent_loop(
          self.llm,
          self.system_prompt,
          self.message_buffer.copy(),
          agent_tools,
          pending_prompts,
          tool_executor=(c, hook) => @tools.run_tool(tool_map, c, hook),
          abort=abort_controller.signal(),
          event_sink=sink,
          finish_turn_hook=self.finish_turn_hook,
        )
      } else {
        @agent_loop.run_agent_loop_continue(
          self.llm,
          self.system_prompt,
          self.message_buffer.copy(),
          agent_tools,
          tool_executor=(c, hook) => @tools.run_tool(tool_map, c, hook),
          abort=abort_controller.signal(),
          event_sink=sink,
          finish_turn_hook=self.finish_turn_hook,
        )
      }
    } catch {
      err => {
        let failure : @agent_loop.AssistantMessage = {
          content: [@agent_loop.AssistantMessageContent::Text("", signature={})],
          api: assistant_metadata.map(m => m.api).unwrap_or(""),
          provider: assistant_metadata.map(m => m.provider).unwrap_or(""),
          model: assistant_metadata.map(m => m.model).unwrap_or(""),
          stop_reason: if abort_controller.signal().is_aborted() {
            Aborted
          } else {
            Error
          },
          error_message: Some(err.to_string()),
          usage: None,
          timestamp: @env.now(),
        }
        // pi's handleRunFailure uses the same event path, including listeners.
        sink(MessageStart(Assistant(failure)))
        sink(MessageEnd(Assistant(failure)))
        sink(TurnEnd(failure, []))
        sink(AgentEnd([Assistant(failure)]))
      }
    }
    self.message_buffer = project_messages(self.journal.get_entries())
    if self.message_buffer.last()
      is Some(
        @agent_loop.AgentMessage::Assistant(
          { stop_reason: Error, error_message, .. }
        )
      ) {
      if self.retry_settings.enabled &&
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
        self.message_buffer = project_messages(self.journal.get_entries())
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
/// Replace the finish-turn hook, mirroring pi's `agent.finishTurn = ...`. A
/// wrapper can read the current hook first and delegate to it, which is how pi
/// layers a further policy on top of the app's.
pub fn AgentSession::set_finish_turn_hook(
  self : AgentSession,
  hook : @agent_loop.FinishTurnHook,
) -> Unit {
  self.finish_turn_hook = hook
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
