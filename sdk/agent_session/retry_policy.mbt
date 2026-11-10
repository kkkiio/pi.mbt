///|
let non_retryable_limit_pattern : @string.Regex = @string.Regex::unsafe_from_string(
  "gousagelimiterror|freeusagelimiterror|monthly usage limit reached|available balance|insufficient_quota|out of budget|quota exceeded|billing",
)

///|
let retryable_provider_pattern : @string.Regex = @string.Regex::unsafe_from_string(
  "overloaded|rate.?limit|too many requests|429|500|502|503|504|524|service.?unavailable|server.?error|internal.?error|provider.?returned.?error|exceeded request buffer limit while retrying upstream|network.?error|connection.?error|connection.?refused|connection.?lost|other side closed|fetch failed|getaddrinfo|enotfound|eai_again|upstream.?connect|reset before headers|socket hang up|socket connection was closed|timed? out|timeout|terminated|websocket.?closed|websocket.?error|ended without|stream ended before message_stop|stream ended before a terminal response event|http2 request did not get a response|retry delay|you can retry your request|try your request again|please retry your request|resourceexhausted|readerclosed|pipeclosed|connectionclosed|resolvehostname|econnreset|epipe|etimedout",
)

///|
/// Agent-level auto-retry settings for transient provider failures.
pub(all) struct RetrySettings {
  /// Whether retryable failures re-run the turn.
  enabled : Bool
  /// Maximum consecutive retries after the initial attempt.
  max_retries : Int32
  /// Initial backoff delay in milliseconds.
  base_delay_ms : Int32
  /// Maximum backoff delay per retry attempt in milliseconds.
  max_agent_delay_ms : Int32
}

///|
/// Returns the default retry settings (enabled, 3 retries, 2000ms base delay, 60000ms max delay).
pub fn RetrySettings::default() -> RetrySettings {
  {
    enabled: true,
    max_retries: 3,
    base_delay_ms: 2000,
    max_agent_delay_ms: 60_000,
  }
}

///|
/// Computes the exponential backoff delay in milliseconds for 1-indexed `attempt`, capped at `max_agent_delay_ms`.
pub fn RetrySettings::delay_ms(self : RetrySettings, attempt : Int32) -> Int32 {
  let max = self.max_agent_delay_ms
  let mut delay = if self.base_delay_ms > max {
    max
  } else {
    self.base_delay_ms
  }
  let mut doublings = if attempt > 64 {
    63
  } else if attempt > 1 {
    attempt - 1
  } else {
    0
  }
  while doublings > 0 && delay < max {
    doublings = doublings - 1
    delay = if delay > max - delay { max } else { delay + delay }
  }
  delay
}

///|
/// Returns whether `error_message` matches a transient provider or transport error eligible for auto-retry.
pub fn is_retryable_error_message(error_message : String) -> Bool {
  let lowered = error_message.to_lower()
  if non_retryable_limit_pattern.execute(lowered) is Some(_) {
    return false
  }
  retryable_provider_pattern.execute(lowered) is Some(_)
}
