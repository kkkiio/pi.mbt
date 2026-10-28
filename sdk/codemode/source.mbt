///|
/// pi's `CODEMODE_OPTIONS_PREFIX`(codemode/src/source.ts):可选的第一行
/// `// @options: {...}` 指令。
pub const CODEMODE_OPTIONS_PREFIX = "// @options:"

///|
/// pi's `SUPPORTED_FIELDS_TEXT`:`@options` 仅支持的字段,错误信息原样引用。
const SUPPORTED_FIELDS_TEXT = "`max_output_tokens` and `timeout_ms`"

///|
/// pi's `MAX_TIMEOUT_MS`:`setTimeout` 支持的最大延迟,即 `timeout_ms` 上界。
pub const MAX_TIMEOUT_MS : Int32 = 2147483647

///|
/// pi's `CODEMODE_SOURCE_GRAMMAR`:约束 options 行形状的 Lark 文法,逐字保留。
/// pim 的 codemode 工具仍走 JsonSchema strict sampling,文法仅作对齐导出。
pub const CODEMODE_SOURCE_GRAMMAR : String =
  #|
  #|start: options_source | plain_source
  #|options_source: OPTIONS_LINE NEWLINE SOURCE
  #|plain_source: SOURCE
  #|
  #|OPTIONS_LINE: /[ \t]*\/\/ @options:[^\r\n]*/
  #|NEWLINE: /\r?\n/
  #|SOURCE: /[\s\S]+/

///|
/// pi's `CodemodeSourceError`。
pub(all) suberror CodemodeSourceError {
  CodemodeSourceError(String)
}

///|
pub impl Show for CodemodeSourceError with fn output(self, logger) {
  let CodemodeSourceError(message) = self
  logger.write_string(message)
}

///|
pub extend CodemodeSourceError with Show::{to_string, output}

///|
/// pi's `ParsedCodemodeSource`:`code` 中 options 行被替换为空行,行号不变。
pub(all) struct ParsedCodemodeSource {
  code : String
  options : CodemodeSourceOptions
}

///|
/// pi's `CodemodeSourceOptions`。
pub(all) struct CodemodeSourceOptions {
  /// 脚本输出的 token 预算。
  max_output_tokens : Int64?
  /// 整个脚本的硬超时(毫秒,含工具调用)。
  timeout_ms : Int32?
}

///|
/// pi's `parseCodemodeSource`:把可选的第一行 `// @options: {...}` 从脚本里
/// 剥出来。空输入、非法 options、options 行不在第一行(否则会被静默忽略)
/// 都抛 `CodemodeSourceError`。
pub fn parse_codemode_source(
  input : String,
) -> ParsedCodemodeSource raise CodemodeSourceError {
  if input.trim().is_empty() {
    raise CodemodeSourceError(
      "Expected JavaScript source text (non-empty). Provide JS only, optionally with a first line `// @options: {\"max_output_tokens\": 1000}`.",
    )
  }
  let lines = input.split("\n").to_array()
  let mut misplaced = -1
  for index, line in lines {
    if index > 0 && line.trim_start().has_prefix(CODEMODE_OPTIONS_PREFIX) {
      misplaced = index
      break
    }
  }
  if misplaced != -1 {
    raise CodemodeSourceError(
      "The \{CODEMODE_OPTIONS_PREFIX} line must be the first line of the input; found one on line \{misplaced + 1}",
    )
  }
  let first_line = lines[0].strip_suffix("\r").unwrap_or(lines[0])
  let trimmed = first_line.trim_start()
  guard trimmed.has_prefix(CODEMODE_OPTIONS_PREFIX) else {
    return {
      code: input,
      options: { max_output_tokens: None, timeout_ms: None, },
    }
  }
  let code = match input.find("\n") {
    Some(newline) => input[newline:].to_owned()
    None => ""
  }
  if code.trim().is_empty() {
    raise CodemodeSourceError(
      "The @options line must be followed by JavaScript source on subsequent lines",
    )
  }
  {
    code,
    options: parse_codemode_options(
      trimmed[CODEMODE_OPTIONS_PREFIX.length():].trim().to_owned(),
    ),
  }
}

///|
/// pi's `isSafeInteger`:整数且 `|v| <= 2^53 - 1`。
fn is_safe_integer(value : Double) -> Bool {
  value.trunc() == value && value.abs() <= 9007199254740991.0
}

///|
/// pi's `parseOptions`:options 必须是 JSON object、只允许已知字段、字段值
/// 必须是非负 safe integer(`timeout_ms` 另要求 `1..=MAX_TIMEOUT_MS`)。
fn parse_codemode_options(
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
  for key, _ in fields {
    if key != "max_output_tokens" && key != "timeout_ms" {
      raise CodemodeSourceError(
        "@options only supports \{SUPPORTED_FIELDS_TEXT}; got `\{key}`",
      )
    }
  }
  let mut max_output_tokens : Int64? = None
  let mut timeout_ms : Int32? = None
  match fields.get("max_output_tokens") {
    None => ()
    Some(Number(n, ..)) if is_safe_integer(n) && n >= 0.0 =>
      max_output_tokens = Some(n.to_int64())
    Some(_) =>
      raise CodemodeSourceError(
        "@options field `max_output_tokens` must be a non-negative safe integer",
      )
  }
  match fields.get("timeout_ms") {
    None => ()
    Some(Number(n, ..)) if is_safe_integer(n) &&
      n > 0.0 &&
      n <= MAX_TIMEOUT_MS.to_double() => timeout_ms = Some(n.to_int())
    Some(_) =>
      raise CodemodeSourceError(
        "@options field `timeout_ms` must be a positive integer up to \{MAX_TIMEOUT_MS}",
      )
  }
  { max_output_tokens, timeout_ms, }
}
