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
