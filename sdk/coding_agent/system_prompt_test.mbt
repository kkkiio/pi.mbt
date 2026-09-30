///|
/// With no guidelines, project context, or skills, the prompt is the role line
/// plus the working directory.
test "system prompt names the role and the working directory" {
  let system_prompt = @coding_agent.build_system_prompt(
    cwd="/workspaces/pi.mbt",
  )
  inspect(
    system_prompt,
    content=(
      #|You are an expert coding assistant operating inside pi, a coding agent harness. You help users by reading files, executing commands, editing code, and writing new files.
      #|
      #|Current working directory: /workspaces/pi.mbt
      #|
    ),
  )
}

///|
/// Active tools contribute their `prompt_guidelines` as an indented list between
/// the role line and the working directory; the bash tool contributes one.
test "system prompt lists active tool guidelines" {
  let system_prompt = @coding_agent.build_system_prompt(
    cwd="/workspaces/pi.mbt",
    guidelines=["Use bash for file operations like ls, rg, find"],
  )
  inspect(
    system_prompt,
    content=(
      #|You are an expert coding assistant operating inside pi, a coding agent harness. You help users by reading files, executing commands, editing code, and writing new files.
      #|
      #|Guidelines:
      #|- Use bash for file operations like ls, rg, find
      #|Current working directory: /workspaces/pi.mbt
      #|
    ),
  )
}
