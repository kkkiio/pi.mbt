///|
/// Lists session names (without `.jsonl` suffix) in `dir`, newest first.
/// Returns an empty array if `dir` does not exist; raises `FsError` if `dir` cannot be read.
pub fn list_sessions(dir : String) -> Array[String] raise FsError {
  guard path_exists(dir) else { return [] }
  let names : Array[String] = []
  for entry in read_dir(dir) {
    guard entry.has_suffix(".jsonl") else { continue }
    names.push(entry[:entry.length() - 6].to_owned())
  }
  names.sort()
  let newest_first : Array[String] = []
  for i in 0..<names.length() {
    newest_first.push(names[names.length() - 1 - i])
  }
  newest_first
}

///|
/// Result of picking a session by prefix.
#derive(Eq, Debug)
pub(all) enum SessionPick {
  /// Unique matching session name.
  Found(String)
  /// No sessions exist or no session matches the prefix.
  None
  /// Multiple sessions match the prefix.
  Ambiguous(Array[String])
}

///|
pub extend SessionPick with Eq::{not_equal, equal}

///|
pub extend SessionPick with @debug.Debug::{to_repr}

///|
/// Selects a session from `sessions` by `prefix` (an empty prefix selects `sessions[0]`).
pub fn pick_session(
  sessions : ArrayView[String],
  prefix : String,
) -> SessionPick {
  if prefix.is_empty() {
    if sessions.length() == 0 {
      SessionPick::None
    } else {
      SessionPick::Found(sessions[0])
    }
  } else {
    let matches : Array[String] = []
    for name in sessions {
      if name.has_prefix(prefix) {
        matches.push(name)
      }
    }
    if matches.length() == 0 {
      SessionPick::None
    } else if matches.length() == 1 {
      SessionPick::Found(matches[0])
    } else {
      SessionPick::Ambiguous(matches)
    }
  }
}

///|
/// Startup session selection mode.
pub(all) enum SessionStart {
  /// Start a new session.
  Fresh
  /// Resume the newest session, or start a new session if none exist.
  Latest
  /// Resume the session matching the given prefix.
  Named(String)
}

///|
/// Resolves the session to resume in `dir` according to `start`.
/// Returns `SessionPick::None` when starting a fresh session or when `Latest` finds no existing sessions.
pub fn resolve_session_start(
  dir : String,
  start : SessionStart,
) -> SessionPick raise FsError {
  match start {
    Fresh => SessionPick::None
    Latest => pick_session(list_sessions(dir), "")
    Named(prefix) => pick_session(list_sessions(dir), prefix)
  }
}
