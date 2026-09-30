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
  /// budget exhausted / error not retryable / retry cancelled.
  AutoRetryEnd(attempt~ : Int, success~ : Bool, final_error~ : String?)
}

///|
/// pi 的 `--mode json` 事件形状。`Loop` 不套壳:展开成 agent loop 自己的事件,
/// 与 pi 的 `--mode json` 一致。
pub impl ToJson for AgentSessionEvent with fn to_json(self : AgentSessionEvent) -> Json {
  match self {
    Loop(agent_event) => agent_event.to_json()
    AutoRetryStart(attempt~, max_attempts~, delay_ms~, error_message~) =>
      {
        "type": "auto_retry_start",
        "attempt": attempt,
        "maxAttempts": max_attempts,
        "delayMs": delay_ms,
        "errorMessage": error_message,
      }
    AutoRetryEnd(attempt~, success~, final_error~) =>
      {
        "type": "auto_retry_end",
        "success": success,
        "attempt": attempt,
        "finalError": match final_error {
          Some(message) => message.to_json()
          None => null
        },
      }
  }
}

///|
pub extend AgentSessionEvent with ToJson::{to_json}

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
pub async fn FanOutListener::on_event(
  self : FanOutListener,
  event : AgentSessionEvent,
) -> Unit {
  for listener in self.listeners {
    listener(event)
  }
}
