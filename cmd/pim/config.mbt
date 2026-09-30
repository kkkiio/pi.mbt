///|
/// `pim` 的用户配置目录解析与凭证读取。
///
/// 环境变量的值为空时，视同未设置(例如`DEEPSEEK_API_KEY=` 是没配)
/// 认证配置优先级:
/// 1. 文件 auth.json` 
/// 2. 环境变量`DEEPSEEK_API_KEY`

///|
suberror AuthConfigError {
  AuthConfigError(String)
}

///|
/// 配置目录:`PIM_CONFIG_DIR` 覆盖,默认 `~/.pim`。
fn config_dir() -> String {
  match @env.get_env_var("PIM_CONFIG_DIR") {
    Some(dir) if !dir.is_empty() => dir
    _ => "\{@coding_agent.home_dir()}/.pim"
  }
}

///|
fn auth_json_path() -> String {
  "\{config_dir()}/auth.json"
}

///|
/// 展示用路径:落在 home 下的简化成 `~/...`。
fn display_path(path : String) -> String {
  match path.strip_prefix("\{@coding_agent.home_dir()}/") {
    Some(rest) => "~/\{rest}"
    None => path
  }
}

///|
fn not_an_api_key_message(path : String, provider_id : String) -> String {
  "\{display_path(path)}: \"\{provider_id}\" is not an api_key credential (expected {\"type\": \"api_key\", \"key\": \"sk-...\"})"
}

///|
fn missing_api_key_message() -> String {
  "no DeepSeek API key (set DEEPSEEK_API_KEY, or add a \"deepseek\" entry to \{display_path(auth_json_path())})"
}

///|
fn read_auth_api_key(provider_id : String) -> String? raise AuthConfigError {
  let path = auth_json_path()
  if !@coding_agent.path_exists(path) {
    return None
  }
  let text = @coding_agent.read_text_file(path) catch {
    err => raise AuthConfigError("cannot read \{display_path(path)}: \{err}")
  }
  let json = @json.parse(text) catch {
    err =>
      raise AuthConfigError("\{display_path(path)} is not valid JSON: \{err}")
  }
  let entries = match json {
    Object(entries) => entries
    _ =>
      raise AuthConfigError(
        "\{display_path(path)} must be a JSON object keyed by provider id",
      )
  }
  match entries.get(provider_id) {
    None => None
    Some(entry) =>
      match entry {
        // 文档要求 {"type": "api_key", "key": "sk-..."}。只看 key 非空
        // 会把 oauth 之类的错误条目当 API key 用,还压掉了环境变量回落,
        // 所以先验 type 再接受 key。
        Object(fields) =>
          match (fields.get("type"), fields.get("key")) {
            (Some(String("api_key")), Some(String(key))) if !key.is_empty() =>
              Some(key)
            _ =>
              raise AuthConfigError(not_an_api_key_message(path, provider_id))
          }
        _ => raise AuthConfigError(not_an_api_key_message(path, provider_id))
      }
  }
}

///|
fn resolve_deepseek_api_key() -> String? raise AuthConfigError {
  match read_auth_api_key("deepseek") {
    Some(key) => Some(key)
    None =>
      match @env.get_env_var("DEEPSEEK_API_KEY") {
        Some(key) if !key.is_empty() => Some(key)
        _ => None
      }
  }
}

///|
/// 把 cwd 转成安全的目录名,与 pi `getDefaultSessionDir` 同规则:
/// 去掉前导分隔符,再把 `/ \ :` 换成 `-`,外包一层 `--`。
fn encode_cwd(cwd : String) -> String {
  let chars = cwd.to_array()
  let mut start = 0
  while start < chars.length() && (chars[start] == '/' || chars[start] == '\\') {
    start += 1
  }
  let out = StringBuilder()
  for i in start..<chars.length() {
    match chars[i] {
      '/' | '\\' | ':' => out.write_string("-")
      c => out.write_char(c)
    }
  }
  "--\{out.to_string()}--"
}

///|
/// 默认会话目录:`<config_dir>/sessions/--<cwd 转义>--`。
/// 未显式给 `--session-dir` / `PIM_SESSION_DIR` 时,会话按 cwd 分桶落盘。
fn default_session_dir(cwd : String) -> String {
  "\{config_dir()}/sessions/\{encode_cwd(cwd)}"
}
