///|
/// Session-level events delivered to `AgentSession.subscribe` listeners.
/// Loop events are wrapped so session-level signals (auto-retry) stay out of
/// the agent loop's `AgentEvent` protocol.
pub enum AgentSessionEvent {
  Loop(@agent_loop.AgentEvent)
  /// Emitted before the backoff sleep of each auto-retry of a failed prompt.
  AutoRetryStart(
    attempt~ : Int32,
    max_attempts~ : Int32,
    delay_ms~ : Int32,
    error_message~ : String
  )
  /// Emitted once a retried prompt settles: success after a retry, or the
  /// budget exhausted / error not retryable / retry cancelled.
  AutoRetryEnd(attempt~ : Int32, success~ : Bool, final_error~ : String?)
}

///|
type EventListener = async (AgentSessionEvent) -> Unit

///|
pub struct FanOutListener {
  listeners : Array[EventListener]
}

///|
pub fn FanOutListener::FanOutListener() -> FanOutListener {
  FanOutListener::{ listeners: [], }
}

///|
/// Delivers events sequentially, awaiting each listener before the next.
/// With `is_cancelling=true`, each listener enters an independently cancelled task.
/// Native cancellation advances to the next listener; ordinary errors propagate.
/// Callers must protect cancellation cleanup while waiting for all listeners.
pub async fn FanOutListener::on_event(
  self : FanOutListener,
  event : AgentSessionEvent,
  is_cancelling~ : Bool = false,
) -> Unit {
  for listener in self.listeners {
    if is_cancelling {
      @async.with_task_group() <| group => {
        let gate = @async.Semaphore(1, initial_value=0)
        group.spawn_bg(() => {
          ignore(@async.handle_cancellation(() => gate.acquire()))
          listener(event)
        })
        group.return_immediately(())
      }
    } else {
      listener(event)
    }
  }
}
