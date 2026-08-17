///|
test "trivial system prompt" {
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
test "bash system prompt" {

}
