///|
/// Session files list newest first: names start with the creation timestamp, so
/// reverse name order needs no `stat`; non-`.jsonl` files are ignored.
test "list_sessions returns jsonl names newest first" {
  let dir = @coding_agent.create_temp_dir("pim-sessions-list-")
  @coding_agent.write_bytes_file("\{dir}/100_b.jsonl", b"")
  @coding_agent.write_bytes_file("\{dir}/300_d.jsonl", b"")
  @coding_agent.write_bytes_file("\{dir}/200_c.jsonl", b"")
  @coding_agent.write_bytes_file("\{dir}/notes.txt", b"")
  assert_eq(@coding_agent.list_sessions(dir), ["300_d", "200_c", "100_b"])
  @coding_agent.remove_dir(dir)
}

///|
/// A missing directory is an empty listing, not an error: the per-cwd session
/// directory only exists after the first session in that directory.
test "list_sessions tolerates a missing directory" {
  let dir = @coding_agent.create_temp_dir("pim-sessions-missing-")
  assert_eq(@coding_agent.list_sessions("\{dir}/nope"), [])
  @coding_agent.remove_dir(dir)
}

///|
/// No prefix picks the newest session; a unique prefix resolves; a prefix shared
/// by two reports every candidate so the caller can list them.
test "pick_session resolves by newest or by unique prefix" {
  let sessions : Array[String] = ["300_e", "300_d", "200_c", "100_b"]
  let empty : Array[String] = []
  assert_eq(
    @coding_agent.pick_session(sessions, ""),
    @coding_agent.SessionPick::Found("300_e"),
  )
  assert_eq(
    @coding_agent.pick_session(sessions, "200"),
    @coding_agent.SessionPick::Found("200_c"),
  )
  assert_eq(
    @coding_agent.pick_session(sessions, "300"),
    @coding_agent.SessionPick::Ambiguous(["300_e", "300_d"]),
  )
  assert_eq(
    @coding_agent.pick_session(sessions, "9"),
    @coding_agent.SessionPick::None,
  )
  assert_eq(
    @coding_agent.pick_session(empty, ""),
    @coding_agent.SessionPick::None,
  )
}
