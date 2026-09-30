// 会话**目录**里的会话文件:列出、挑选、按启动模式解析。
//
// 名字里带 `dir` 是有意的:本地会话按目录组织(每个 cwd 一个桶);将来若加 remote
// sessions,那些多半按 project 组织,两者可以并存区分。
//
// 文件名形如 `<epoch_ms>_<rand>.jsonl`,所以**按名称倒序就是按创建时间倒序**,
// 不需要 stat。

///|
/// 列出 `dir` 下的会话名(去掉 `.jsonl`),创建时间新的在前。
///
/// 目录不存在时返回空表而不是报错:首次运行时它还没被建出来。
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
/// 前缀挑选的结果。
pub(all) enum SessionPick {
  /// 唯一命中。
  Found(String)
  /// 没有任何会话,或前缀无匹配。
  None
  /// 前缀命中多个,需要说得更具体。
  Ambiguous(Array[String])
} derive(Eq, Debug)

///|
pub extend SessionPick with Eq::{not_equal, equal}

///|
pub extend SessionPick with @debug.Debug::{to_repr}

///|
/// 按前缀挑会话:空前缀取最新的一个,有前缀时要求唯一命中。
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
/// 启动时如何选择会话。
pub(all) enum SessionStart {
  /// 开新会话。
  Fresh
  /// 续写最新的会话;一个都没有时就开新会话(对齐 pi `--continue`)。
  Latest
  /// 按前缀续写指定会话;无匹配或多匹配交给调用方报错。
  Named(String)
}

///|
/// 解析启动时要续写的会话。
///
/// `Fresh` 与「目录里还没有会话」都返回 `SessionPick::None` —— 两者都表示
/// 「开新会话」,调用方无需区分。
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
