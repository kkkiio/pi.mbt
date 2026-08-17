///|
/// Lifecycle events emitted by `run_agent_loop`, ordered by nesting:
/// agent → turn → message → tool execution.
///
/// Streaming messages appear as in-flight snapshots: `MessageStart` fires
/// once when generation begins, `MessageUpdate` on each delta, and
/// `MessageEnd` once with the final complete message. An assistant message
/// observed before `MessageEnd` has `stop_reason` `Pending` and no `usage`;
/// metadata is only trustworthy from `MessageEnd` onwards.
pub enum AgentEvent {
  AgentStart
  TurnStart
  MessageStart(AgentMessage)
  MessageUpdate(AgentMessage)
  MessageEnd(AgentMessage)
  ToolExecutionStart(ToolCall)
  ToolExecutionEnd(ToolResultMessage)
  TurnEnd(AssistantMessage, ArrayView[ToolResultMessage])
  AgentEnd(ArrayView[AgentMessage])
}
