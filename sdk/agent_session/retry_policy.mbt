///|
/// Ported from pi's `NON_RETRYABLE_PROVIDER_LIMIT_ERROR_PATTERN`
/// (packages/ai/src/utils/retry.ts): subscription/account/budget exhaustion
/// that a retry cannot fix.
let non_retryable_limit_pattern : @string.Regex = @string.Regex::unsafe_from_string(
  "gousagelimiterror|freeusagelimiterror|monthly usage limit reached|available balance|insufficient_quota|out of budget|quota exceeded|billing",
)

///|
/// Ported from pi's `RETRYABLE_PROVIDER_ERROR_PATTERN`
/// (packages/ai/src/utils/retry.ts): provider load, HTTP 429/5xx, transport,
/// and premature-stream failures. `.?` preserves pi's "any separator" intent;
/// case-insensitive via message lowercasing.
let retryable_provider_pattern : @string.Regex = @string.Regex::unsafe_from_string(
  "overloaded|rate.?limit|too many requests|429|500|502|503|504|524|service.?unavailable|server.?error|internal.?error|provider.?returned.?error|exceeded request buffer limit while retrying upstream|network.?error|connection.?error|connection.?refused|connection.?lost|other side closed|fetch failed|getaddrinfo|enotfound|eai_again|upstream.?connect|reset before headers|socket hang up|socket connection was closed|timed? out|timeout|terminated|websocket.?closed|websocket.?error|ended without|stream ended before message_stop|stream ended before a terminal response event|http2 request did not get a response|retry delay|you can retry your request|try your request again|please retry your request|resourceexhausted|readerclosed|pipeclosed|connectionclosed|resolvehostname|econnreset|epipe|etimedout",
)

///|
/// Agent-level retry policy: pi's `RetrySettings` (the `retry.*` settings
/// half) in the resolved form `SettingsManager.getRetrySettings()` returns,
/// with every optional field defaulted. pi keeps the provider-level knobs
/// (`retry.provider.*`) in a separate accessor, so they are not here.
pub(all) struct RetrySettings {
  /// Whether a retryable failure re-runs the turn at all.
  enabled : Bool
  /// Max consecutive retries after a retryable error. The initial attempt does
  /// not count, matching pi's `maxRetries` / `maxAttempts`.
  max_retries : Int
  /// Exponential-backoff base in milliseconds: the first retry waits this long.
  base_delay_ms : Int
  /// Ceiling on a single backoff delay, not on the total wait.
  max_agent_delay_ms : Int
}

///|
/// pi's `SETTINGS_DEFAULTS.retry` (`enabled`, `maxRetries`, `baseDelayMs`,
/// `maxAgentDelayMs`): three retries waiting 2s, 4s, then 8s.
pub fn RetrySettings::default() -> RetrySettings {
  {
    enabled: true,
    max_retries: 3,
    base_delay_ms: 2000,
    max_agent_delay_ms: 60_000,
  }
}

///|
/// pi's `retryDelayMs`: exponential backoff `baseDelayMs * 2^(attempt-1)` from
/// a 1-indexed attempt, capped per attempt by `maxAgentDelayMs`. Doubling
/// saturates at the cap instead of shifting, so a large attempt count cannot
/// overflow into a negative delay that would then slip past the cap. pi has
/// the same guard via `Number.isSafeInteger`.
pub fn RetrySettings::delay_ms(self : RetrySettings, attempt : Int) -> Int {
  let max = self.max_agent_delay_ms
  let mut delay = if self.base_delay_ms > max {
    max
  } else {
    self.base_delay_ms
  }
  // An Int saturates after 63 doublings, so clamping the exponent keeps this
  // loop bounded even when `attempt` is far larger than the cap can notice.
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
/// Whether a failed assistant turn's `error_message` looks like a transient
/// provider or transport error worth retrying the whole prompt. Mirrors pi's
/// `isRetryableAssistantError`: quota/billing blacklist first, then the
/// retryable whitelist. Once errors cross layer boundaries they are text, and
/// pi does the same.
pub fn is_retryable_error_message(error_message : String) -> Bool {
  let lowered = error_message.to_lower()
  if non_retryable_limit_pattern.execute(lowered) is Some(_) {
    return false
  }
  retryable_provider_pattern.execute(lowered) is Some(_)
}
