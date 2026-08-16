///|
async test "output accumulator preserves split UTF-8 and truncates complete lines" {
  let output = @coding_agent.OutputAccumulator(max_lines=2, max_bytes=100)
  output.append(b"first\nsecond\n\xe4\xbd")
  output.append(b"\xa0\nlast")
  output.finish()
  let snapshot = output.snapshot()
  inspect(snapshot.content, content="你\nlast")
  json_inspect(snapshot.truncation, content={
    "content": "你\nlast",
    "truncated": true,
    "truncated_by": "lines",
    "total_lines": 4,
    "total_bytes": 21,
    "output_lines": 2,
    "output_bytes": 8,
    "last_line_partial": false,
    "first_line_exceeds_limit": false,
    "max_lines": 2,
    "max_bytes": 100,
  })
  output.close_temp_file()
}

///|
async test "output accumulator truncates a long final line at a UTF-8 boundary" {
  let output = @coding_agent.OutputAccumulator(max_lines=10, max_bytes=5)
  output.append(@utf8.encode("prefix你好"))
  output.finish()
  let snapshot = output.snapshot()
  inspect(snapshot.content, content="好")
  assert_eq(snapshot.truncation.truncated_by, Some("bytes"))
  inspect(snapshot.truncation.output_bytes, content="3")
  inspect(snapshot.truncation.last_line_partial, content="true")
  inspect(output.get_last_line_bytes(), content="12")
  output.close_temp_file()
}

///|
async test "output accumulator persists the original bytes after truncation" {
  let output = @coding_agent.OutputAccumulator(
    max_lines=10,
    max_bytes=4,
    temp_file_prefix="pim-output-accumulator-test",
  )
  output.append(b"abc")
  output.append(b"def")
  output.finish()
  let snapshot = output.snapshot(persist_if_truncated=true)
  guard snapshot.full_output_path is Some(path) else {
    fail("expected persisted output path")
  }
  output.close_temp_file()
  inspect(@fs.read_file(path).binary(), content="b\"abcdef\"")
  @fs.remove(path)
  guard path.rev_before("/") is Some(directory) else {
    fail("expected temporary output directory")
  }
  @fs.rmdir(directory)
}
