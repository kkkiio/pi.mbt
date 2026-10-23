///|
/// `disable-model-invocation: true` is read from a `<name>/SKILL.md` directory
/// skill and defaults to `false`; the flag is exposed so command routing can
/// still reach a hidden skill.
test "discover_skills reads disable-model-invocation" {
  let dir = @coding_agent.create_temp_dir("pim-skills-flag-")
  defer @coding_agent.remove_dir(dir)
  @coding_agent.create_dir("\{dir}/by-command")
  @coding_agent.write_bytes_file(
    "\{dir}/by-command/SKILL.md",
    b"---\nname: by-command\ndescription: Only when the user asks for it.\ndisable-model-invocation: true\n---\n\nRun this only on request.\n",
  )
  @coding_agent.write_bytes_file(
    "\{dir}/routed.md",
    b"---\nname: routed\ndescription: Routed automatically.\n---\n\nUse whenever relevant.\n",
  )
  let skills = @coding_agent.discover_skills(dir)
  // Discovery sorts by name; the order itself is not what this test pins down.
  assert_eq(
    [
      for skill in skills => (skill.name, skill.disable_model_invocation)
    ],
    [("routed", false), ("by-command", true)],
  )
}

///|
/// A hidden skill is left out of `<available_skills>` even though discovery
/// still returns it.
test "skills_system_prompt omits a skill hidden from model invocation" {
  let dir = @coding_agent.create_temp_dir("pim-skills-prompt-")
  defer @coding_agent.remove_dir(dir)
  @coding_agent.create_dir("\{dir}/by-command")
  @coding_agent.write_bytes_file(
    "\{dir}/by-command/SKILL.md",
    b"---\nname: by-command\ndescription: Only when the user asks for it.\ndisable-model-invocation: true\n---\n\nRun this only on request.\n",
  )
  @coding_agent.write_bytes_file(
    "\{dir}/routed.md",
    b"---\nname: routed\ndescription: Routed automatically.\n---\n\nUse whenever relevant.\n",
  )
  let skills = @coding_agent.discover_skills(dir)
  assert_eq(skills.length(), 2)
  let prompt = @coding_agent.skills_system_prompt(skills)
  assert_true(prompt.contains("routed"))
  assert_false(prompt.contains("by-command"))
  assert_false(prompt.contains("Only when the user asks for it."))
}

///|
/// When every skill is hidden the prompt has no skills block at all, so the
/// model sees no empty `<available_skills>` element.
test "skills_system_prompt is empty when every skill is hidden" {
  let dir = @coding_agent.create_temp_dir("pim-skills-all-hidden-")
  defer @coding_agent.remove_dir(dir)
  @coding_agent.create_dir("\{dir}/by-command")
  @coding_agent.write_bytes_file(
    "\{dir}/by-command/SKILL.md",
    b"---\nname: by-command\ndescription: Only when the user asks for it.\ndisable-model-invocation: true\n---\n\nRun this only on request.\n",
  )
  assert_eq(
    @coding_agent.skills_system_prompt(@coding_agent.discover_skills(dir)),
    "",
  )
}

///|
/// Frontmatter parsing is the single place the flag is read, so a missing
/// block, a missing key, and a non-boolean value all mean "visible".
test "parse_frontmatter defaults disable-model-invocation to false" {
  assert_false(
    @coding_agent.parse_frontmatter("# No frontmatter\n", "fallback").disable_model_invocation,
  )
  assert_false(
    @coding_agent.parse_frontmatter(
      "---\nname: a\ndescription: d\n---\n", "fallback",
    ).disable_model_invocation,
  )
  assert_false(
    @coding_agent.parse_frontmatter(
      "---\nname: a\ndescription: d\ndisable-model-invocation: sometimes\n---\n",
      "fallback",
    ).disable_model_invocation,
  )
  assert_true(
    @coding_agent.parse_frontmatter(
      "---\nname: a\ndescription: d\ndisable-model-invocation: True\n---\n", "fallback",
    ).disable_model_invocation,
  )
}

///|
/// Writes `<dir>/.agents/skills/<name>/SKILL.md` and returns the skill path.
fn write_skill(
  dir : String,
  name : String,
  body : String,
  extra_frontmatter~ : String = "",
) -> String raise {
  let skill_dir = "\{dir}/.agents/skills/\{name}"
  @coding_agent.create_dir(skill_dir)
  let path = "\{skill_dir}/SKILL.md"
  @coding_agent.write_bytes_file(
    path,
    @utf8.encode(
      "---\nname: \{name}\ndescription: \{name} description.\n\{extra_frontmatter}---\n\n\{body}\n",
    ),
  )
  path
}

///|
/// `/skill:<name>` becomes the `<skill>` block pi sends: frontmatter dropped,
/// body verbatim, arguments appended; anything else passes through untouched.
test "expand_skill_command wraps the skill body" {
  let cwd = @coding_agent.create_temp_dir("pim-skill-expand-")
  defer @coding_agent.remove_dir(cwd)
  let path = write_skill(cwd, "write-doc", "Read references/formats.md first.")
  let expanded = @coding_agent.expand_skill_command(
    "/skill:write-doc extract report.pdf",
    cwd~,
  )
  assert_true(expanded.has_prefix("<skill name=\"write-doc\" location=\""))
  assert_true(expanded.contains(path))
  assert_true(
    expanded.contains(
      "References are relative to \{cwd}/.agents/skills/write-doc.",
    ),
  )
  assert_true(
    expanded.contains("\n\nRead references/formats.md first.\n</skill>"),
  )
  assert_true(expanded.has_suffix("</skill>\n\nextract report.pdf"))
  // The skill's own frontmatter must not leak into the prompt.
  assert_false(expanded.contains("description: write-doc description."))
  // Without arguments the block stands alone.
  let bare = @coding_agent.expand_skill_command("/skill:write-doc", cwd~)
  assert_true(bare.has_suffix("</skill>"))
}

///|
/// Non-commands and unknown skill names are not rewritten: the model sees the
/// text the user typed, matching pi's pass-through.
test "expand_skill_command passes other text through" {
  let cwd = @coding_agent.create_temp_dir("pim-skill-passthrough-")
  defer @coding_agent.remove_dir(cwd)
  ignore(write_skill(cwd, "write-doc", "Body."))
  inspect(
    @coding_agent.expand_skill_command("hello there", cwd~),
    content="hello there",
  )
  inspect(
    @coding_agent.expand_skill_command("/skill:missing now", cwd~),
    content="/skill:missing now",
  )
  inspect(
    @coding_agent.expand_skill_command("/resume 123", cwd~),
    content="/resume 123",
  )
}

///|
/// A skill hidden from model invocation is still reachable through its explicit
/// command — that is the whole point of `disable-model-invocation`.
test "expand_skill_command reaches a skill hidden from the model" {
  let cwd = @coding_agent.create_temp_dir("pim-skill-hidden-expand-")
  defer @coding_agent.remove_dir(cwd)
  ignore(
    write_skill(
      cwd,
      "by-command",
      "Only on request.",
      extra_frontmatter="disable-model-invocation: true\n",
    ),
  )
  let expanded = @coding_agent.expand_skill_command(
    "/skill:by-command go",
    cwd~,
  )
  assert_true(expanded.contains("<skill name=\"by-command\""))
  assert_true(expanded.has_suffix("\n\nOnly on request.\n</skill>\n\ngo"))
}

///|
/// The block a command expands into parses back into name/location/body/args —
/// that round trip is what lets the TUI render a journaled invocation as the
/// command the user typed.
test "parse_skill_block reads back an expanded command" {
  let cwd = @coding_agent.create_temp_dir("pim-skill-parse-")
  defer @coding_agent.remove_dir(cwd)
  let path = write_skill(cwd, "write-doc", "Read references/formats.md first.")
  let expanded = @coding_agent.expand_skill_command(
    "/skill:write-doc extract report.pdf",
    cwd~,
  )
  guard @coding_agent.parse_skill_block(expanded) is Some(invocation) else {
    fail("expected the expanded command to parse")
  }
  assert_eq(invocation.name, "write-doc")
  assert_eq(invocation.location, path)
  assert_eq(
    invocation.references,
    "References are relative to \{cwd}/.agents/skills/write-doc.",
  )
  assert_eq(invocation.body, "Read references/formats.md first.")
  assert_eq(invocation.args, "extract report.pdf")
  // Without arguments the args part is empty, not a newline.
  let bare = @coding_agent.expand_skill_command("/skill:write-doc", cwd~)
  guard @coding_agent.parse_skill_block(bare) is Some(invocation) else {
    fail("expected the argument-less command to parse")
  }
  assert_eq(invocation.args, "")
}

///|
/// Ordinary user text is not a skill block.
test "parse_skill_block ignores other text" {
  assert_true(@coding_agent.parse_skill_block("hello") is None)
  assert_true(@coding_agent.parse_skill_block("/skill:write-doc hi") is None)
  assert_true(@coding_agent.parse_skill_block("<skill name=\"x\">") is None)
}

///|
/// `parse_skill_block` and `block_text` are inverses, so a reader can rebuild a
/// block it had to bound without inventing the format again.
test "parse_skill_block round-trips through block_text" {
  let cwd = @coding_agent.create_temp_dir("pim-skill-roundtrip-")
  defer @coding_agent.remove_dir(cwd)
  ignore(write_skill(cwd, "write-doc", "Body text."))
  for command in ["/skill:write-doc", "/skill:write-doc extract it"] {
    let expanded = @coding_agent.expand_skill_command(command, cwd~)
    guard @coding_agent.parse_skill_block(expanded) is Some(invocation) else {
      fail("expected a parsed block for \{command}")
    }
    assert_eq(invocation.block_text(), expanded)
  }
}
