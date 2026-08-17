///|
/// Ported from pi's `NON_RETRYABLE_PROVIDER_LIMIT_ERROR_PATTERN`
/// (packages/ai/src/utils/retry.ts): subscription/account/budget exhaustion
/// that a retry cannot fix. Case-insensitive: the message is lowercased before
/// matching.
let non_retryable_limit_pattern : @string.Regex = @string.Regex::unsafe_from_string(
  "gousagelimiterror|freeusagelimiterror|monthly usage limit reached|available balance|insufficient_quota|out of budget|quota exceeded|billing",
)

///|
/// Ported from pi's `RETRYABLE_PROVIDER_ERROR_PATTERN`
/// (packages/ai/src/utils/retry.ts): provider load, HTTP 429/5xx, transport,
/// and premature-stream failures. `.?` preserves pi's "any separator" intent;
/// case-insensitive via message lowercasing.
let retryable_provider_pattern : @string.Regex = @string.Regex::unsafe_from_string(
  "overloaded|rate.?limit|too many requests|429|500|502|503|504|524|service.?unavailable|server.?error|internal.?error|provider.?returned.?error|exceeded request buffer limit while retrying upstream|network.?error|connection.?error|connection.?refused|connection.?lost|other side closed|fetch failed|getaddrinfo|enotfound|eai_again|upstream.?connect|reset before headers|socket hang up|socket connection was closed|timed? out|timeout|terminated|websocket.?closed|websocket.?error|ended without|stream ended before message_stop|stream ended before a terminal response event|http2 request did not get a response|retry delay|you can retry your request|try your request again|please retry your request|resourceexhausted",
)

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
