///|
/// Session-level events delivered to `AgentSession.subscribe` listeners.
/// Loop events are wrapped so session-level signals (auto-retry) stay out of
/// the agent loop's `AgentEvent` protocol.
pub enum AgentSessionEvent {
  Loop(@agent_loop.AgentEvent)
  /// Emitted before the backoff sleep of each auto-retry of a failed prompt.
  AutoRetryStart(
    attempt~ : Int,
    max_attempts~ : Int,
    delay_ms~ : Int,
    error_message~ : String
  )
  /// Emitted once a retried prompt settles: success after a retry, or the
  /// budget exhausted / error not retryable.
  AutoRetryEnd(attempt~ : Int, success~ : Bool, final_error~ : String?)
}

///|
type EventListener = async (AgentSessionEvent) -> Unit

///|
pub struct FanOutListener {
  listeners : Array[EventListener]
}

///|
pub fn FanOutListener::FanOutListener() -> FanOutListener {
  FanOutListener::{ listeners: [] }
}

///|
pub async fn FanOutListener::on_event(
  self : FanOutListener,
  event : AgentSessionEvent,
) -> Unit {
  for listener in self.listeners {
    listener(event)
  }
}
