///|
/// Runs `attempt` with bounded retries: a transient failure is retried with
/// exponential backoff (`base_backoff_ms << attempt_index`), up to
/// `max_attempts` attempts in total. The first non-transient failure, or the
/// last transient failure once attempts are exhausted, is re-raised unchanged.
///
/// Each retry invokes `attempt` afresh, so callers restart their request and
/// stream from scratch — no accumulation state survives from a failed attempt.
pub async fn[T] retry_transient(
  max_attempts~ : Int,
  base_backoff_ms~ : Int,
  is_transient~ : (Error) -> Bool,
  attempt~ : async () -> T,
) -> T {
  let mut attempt_index = 0
  while attempt_index < max_attempts {
    try {
      return attempt()
    } catch {
      err =>
        if is_transient(err) && attempt_index + 1 < max_attempts {
          @async.sleep(base_backoff_ms << attempt_index)
          attempt_index = attempt_index + 1
        } else {
          raise err
        }
    }
  }
  fail("retry_transient: attempts exhausted")
}
