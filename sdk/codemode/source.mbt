///|
/// Prefix of the optional first-line `// @options: {...}` directive in codemode source.
pub const CODEMODE_OPTIONS_PREFIX = "// @options:"

///|
const SUPPORTED_FIELDS_TEXT = "`max_output_tokens` and `timeout_ms`"

///|
/// Maximum allowed value for `timeout_ms` in `@options`.
pub const MAX_TIMEOUT_MS : Int32 = 2147483647

///|
/// Lark grammar constraining the optional first-line `@options` directive.
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
/// Error raised when codemode source or its `@options` directive is invalid.
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
/// Parsed codemode source with the `@options` line replaced by a blank line to preserve line numbers.
pub(all) struct ParsedCodemodeSource {
  code : String
  options : CodemodeSourceOptions
}

///|
/// Execution options parsed from the leading `// @options:` directive.
pub(all) struct CodemodeSourceOptions {
  /// Maximum output token budget for the script.
  max_output_tokens : Int64?
  /// Hard execution timeout in milliseconds, including nested tool calls.
  timeout_ms : Int32?
}

///|
/// Parse JavaScript source and extract an optional first-line `// @options: {...}` directive.
///
/// - `input`: Raw JavaScript source text.
/// - Returns: `ParsedCodemodeSource` with extracted options and line-preserving source code.
/// - Raises `CodemodeSourceError` if `input` is empty, has no code after `@options`, has `@options` past line 1, or contains invalid options JSON/fields.
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
fn is_safe_integer(value : Double) -> Bool {
  value.trunc() == value && value.abs() <= 9007199254740991.0
}

///|
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

///|
/// Convert a tool name into a valid JavaScript identifier by replacing invalid characters with `_`.
/// Returns `"_"` when `name` is empty.
pub fn to_codemode_identifier(name : String) -> String {
  let builder = StringBuilder()
  for c in name.iter() {
    let valid = if builder.is_empty() {
      c is ('a'..<='z' | 'A'..<='Z' | '_' | '$')
    } else {
      c is ('a'..<='z' | 'A'..<='Z' | '0'..<='9' | '_' | '$')
    }
    builder.write_char(if valid { c } else { '_' })
  }
  if builder.is_empty() {
    "_"
  } else {
    builder.to_string()
  }
}
