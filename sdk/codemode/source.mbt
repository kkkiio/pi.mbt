///|
/// codemode 源码格式:JavaScript,可选一行 `// @options:` 前缀
/// (对应 pi source.ts)。
///
/// ```js
/// // @options: {"max_output_tokens": 2000, "timeout_ms": 30000}
/// const text = await tools.read({ path: "package.json" });
/// text(JSON.parse(text).name);
/// ```
pub const CODEMODE_OPTIONS_PREFIX : String = "// @options:"

///|
/// Lark 语法,供 ConstrainedSampling::Grammar 约束 code 参数;
/// 只固定 @options 首行形状,options JSON 与代码本身由
/// parse_codemode_source 校验(对应 pi CODEMODE_SOURCE_GRAMMAR)。
pub const CODEMODE_SOURCE_GRAMMAR : String =
  #|start: options_source | plain_source
  #|options_source: OPTIONS_LINE NEWLINE SOURCE
  #|plain_source: SOURCE
  #|
  #|OPTIONS_LINE: /[ \t]*\/\/ @options:[^\r\n]*/
  #|NEWLINE: /\r?\n/
  #|SOURCE: /[\s\S]+/
  #|

///|
const SUPPORTED_FIELDS_TEXT : String = "`max_output_tokens` and `timeout_ms`"

///|
/// setTimeout 支持的最大延时,界住 timeout_ms。
const MAX_TIMEOUT_MS : Int32 = 2_147_483_647

///|
pub(all) struct CodemodeSourceOptions {
  /// 脚本输出的 token 预算
  max_output_tokens : Int32?
  /// 含工具调用在内的整体时限(ms)
  timeout_ms : Int32?
} derive(ToJson)

///|
pub(all) struct ParsedCodemodeSource {
  /// @options 行替换为空行后的脚本,保持报错行号不变
  code : String
  options : CodemodeSourceOptions
} derive(ToJson)

///|
pub suberror CodemodeSourceError {
  CodemodeSourceError(String)
}

///|
/// 拆出可选首行 `// @options: {...}`(对应 pi parseCodemodeSource)。
/// 空输入、非法 options、非首行出现的 @options 均报错。
pub fn parse_codemode_source(
  input : String,
) -> ParsedCodemodeSource raise CodemodeSourceError {
  if input.trim() == "" {
    raise CodemodeSourceError(
      "Expected JavaScript source text (non-empty). Provide JS only, optionally with a first line `// @options: {\"max_output_tokens\": 1000}`.",
    )
  }
  let lines = input.split("\n").collect()
  for i = 1; i < lines.length(); i = i + 1 {
    if lines[i].trim_start().has_prefix(CODEMODE_OPTIONS_PREFIX) {
      raise CodemodeSourceError(
        "The \{CODEMODE_OPTIONS_PREFIX} line must be the first line of the input; found one on line \{i + 1}",
      )
    }
  }
  let first_line = lines[0].strip_suffix("\r").unwrap_or(lines[0])
  let trimmed = first_line.trim_start()
  guard trimmed.strip_prefix(CODEMODE_OPTIONS_PREFIX) is Some(directive) else {
    return {
      code: input,
      options: { max_output_tokens: None, timeout_ms: None, },
    }
  }
  // 等价于 pi 的 input.slice(newline):options 行变成空行,行号不变
  let code = if lines.length() > 1 {
    let buffer = StringBuilder()
    for i = 1; i < lines.length(); i = i + 1 {
      buffer.write_char('\n')
      buffer.write_string(lines[i].to_owned())
    }
    buffer.to_string()
  } else {
    ""
  }
  if code.trim() == "" {
    raise CodemodeSourceError(
      "The @options line must be followed by JavaScript source on subsequent lines",
    )
  }
  { code, options: parse_options(directive.trim().to_owned()), }
}

///|
fn parse_options(
  directive : String,
) -> CodemodeSourceOptions raise CodemodeSourceError {
  if directive == "" {
    raise CodemodeSourceError(
      "@options must be a JSON object with supported fields \{SUPPORTED_FIELDS_TEXT}",
    )
  }
  let value = @json.parse(directive) catch {
    error =>
      raise CodemodeSourceError(
        "@options must be valid JSON with supported fields \{SUPPORTED_FIELDS_TEXT}: \{error}",
      )
  }
  guard value is Object(fields) else {
    raise CodemodeSourceError(
      "@options must be a JSON object with supported fields \{SUPPORTED_FIELDS_TEXT}",
    )
  }
  let mut max_output_tokens : Int32? = None
  let mut timeout_ms : Int32? = None
  for key, field in fields {
    match key {
      "max_output_tokens" => {
        guard field is Number(n, ..) && is_safe_integer(n) else {
          raise CodemodeSourceError(
            "@options field `max_output_tokens` must be a non-negative safe integer",
          )
        }
        max_output_tokens = Some(n.to_int())
      }
      "timeout_ms" => {
        guard field is Number(n, ..) && is_safe_integer(n) else {
          raise CodemodeSourceError(
            "@options field `timeout_ms` must be a positive integer up to \{MAX_TIMEOUT_MS}",
          )
        }
        let milliseconds = n.to_int()
        guard milliseconds > 0 && milliseconds <= MAX_TIMEOUT_MS else {
          raise CodemodeSourceError(
            "@options field `timeout_ms` must be a positive integer up to \{MAX_TIMEOUT_MS}",
          )
        }
        timeout_ms = Some(milliseconds)
      }
      _ =>
        raise CodemodeSourceError(
          "@options only supports \{SUPPORTED_FIELDS_TEXT}; got `\{key}`",
        )
    }
  }
  { max_output_tokens, timeout_ms, }
}

///|
fn is_safe_integer(n : Double) -> Bool {
  n >= 0.0 && n.floor() == n && n <= 9007199254740991.0
}

///|
pub extend CodemodeSourceOptions with ToJson::{to_json}

///|
pub extend ParsedCodemodeSource with ToJson::{to_json}
