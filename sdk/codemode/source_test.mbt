///|
/// pi test/source.test.ts 的移植(黑盒,快照)。
test "parse_codemode_source: plain code unchanged" {
  json_inspect(
    [
      @codemode.parse_codemode_source("text('hi')"),
      @codemode.parse_codemode_source("// just a comment\nreturn 1"),
    ],
    content=[
      { "code": "text('hi')", "options": {} },
      { "code": "// just a comment\nreturn 1", "options": {} },
    ],
  )
}

///|
test "parse_codemode_source: options line, line numbers kept" {
  json_inspect(
    [
      @codemode.parse_codemode_source(
        "// @options: {\"timeout_ms\": 10}\nconst a = 1;\ntext(a)",
      ),
      @codemode.parse_codemode_source(
        "  // @options:{\"max_output_tokens\":0,\"timeout_ms\":1500}\r\ntext(1)",
      ),
      @codemode.parse_codemode_source("// @options: {}\ntext(1)"),
    ],
    content=[
      { "code": "\nconst a = 1;\ntext(a)", "options": { "timeout_ms": 10 } },
      {
        "code": "\ntext(1)",
        "options": { "max_output_tokens": 0, "timeout_ms": 1500 },
      },
      { "code": "\ntext(1)", "options": {} },
    ],
  )
}

///|
test "parse_codemode_source: only the first line is an options line" {
  json_inspect(
    [
      @codemode.parse_codemode_source("// @optionsx {}\ntext(1)"),
      @codemode.parse_codemode_source("text(\"// @options: {}\")"),
    ],
    content=[
      { "code": "// @optionsx {}\ntext(1)", "options": {} },
      { "code": "text(\"// @options: {}\")", "options": {} },
    ],
  )
}

///|
/// 所有用例都应报 CodemodeSourceError,逐用例快照错误消息。
test "parse_codemode_source: options line off the first line is rejected" {
  let inputs = [
    "// count things\n// @options: {\"timeout_ms\": 1000}\nwhile (true) {}", "\n  // @options: {\"timeout_ms\": 1000}\nwhile (true) {}",
    "text(1)\r\n// @options: {\"timeout_ms\": 1}", "// @options: {\"timeout_ms\": 1}\ntext(1)\n// @options: {\"timeout_ms\": 2}",
  ]
  let messages = []
  for input in inputs {
    let message = try {
      ignore(@codemode.parse_codemode_source(input))
      abort("expected CodemodeSourceError for \{input}")
    } catch {
      @codemode.CodemodeSourceError(message) => message
    }
    messages.push(message)
  }
  inspect(
    messages.join("\n---\n"),
    content=(
      #|The // @options: line must be the first line of the input; found one on line 2
      #|---
      #|The // @options: line must be the first line of the input; found one on line 2
      #|---
      #|The // @options: line must be the first line of the input; found one on line 2
      #|---
      #|The // @options: line must be the first line of the input; found one on line 3
    ),
  )
}

///|
test "parse_codemode_source: empty input and invalid options rejected" {
  let inputs = [
    "", "  \n", "// @options:\ntext(1)", "// @options: {timeout_ms: 1}\ntext(1)",
    "// @options: [1]\ntext(1)", "// @options: {\"yield\": 1}\ntext(1)", "// @options: {\"max_output_tokens\": 1.5}\ntext(1)",
    "// @options: {\"timeout_ms\": 0}\ntext(1)", "// @options: {\"timeout_ms\": 1}",
    "// @options: {\"timeout_ms\": 1}\n  \n",
  ]
  let messages = []
  for input in inputs {
    let message = try {
      ignore(@codemode.parse_codemode_source(input))
      abort("expected CodemodeSourceError for \{input}")
    } catch {
      @codemode.CodemodeSourceError(message) => message
    }
    messages.push(message)
  }
  inspect(
    messages.join("\n---\n"),
    content=(
      #|Expected JavaScript source text (non-empty). Provide JS only, optionally with a first line `// @options: {"max_output_tokens": 1000}`.
      #|---
      #|Expected JavaScript source text (non-empty). Provide JS only, optionally with a first line `// @options: {"max_output_tokens": 1000}`.
      #|---
      #|@options must be a JSON object with supported fields `max_output_tokens` and `timeout_ms`
      #|---
      #|@options must be valid JSON with supported fields `max_output_tokens` and `timeout_ms`: Invalid character 't' at line 1, column 1
      #|---
      #|@options must be a JSON object with supported fields `max_output_tokens` and `timeout_ms`
      #|---
      #|@options only supports `max_output_tokens` and `timeout_ms`; got `yield`
      #|---
      #|@options field `max_output_tokens` must be a non-negative safe integer
      #|---
      #|@options field `timeout_ms` must be a positive integer up to 2147483647
      #|---
      #|The @options line must be followed by JavaScript source on subsequent lines
      #|---
      #|The @options line must be followed by JavaScript source on subsequent lines
    ),
  )
}
