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
struct PromptCapturingLLM {
  cwd : String
  prompts : Array[String]
  requests : Array[Json]
}

///|
impl @agent_loop.LLM for PromptCapturingLLM with fn generate(
  self : PromptCapturingLLM,
  context : @agent_loop.Context,
  sink~ : async (@agent_loop.GenerationEvent) -> Unit,
  abort~ : @agent_loop.AbortSignal,
) -> @agent_loop.AssistantMessage {
  ignore(abort)
  let prompt = context.system_prompt.replace_all(old=self.cwd, new="/work")
  self.prompts.push(prompt)
  self.requests.push({
    "prompt": prompt,
    "tools": [
      for tool in context.tools => {
        match tool {
          @agent_loop.Function(definition) => Json(definition.name)
          @agent_loop.Hosted(WebSearch) => Json("web_search")
        }
      }
    ],
  })
  let message = @faux.faux_message([@faux.faux_text("ok")])
  sink(@agent_loop.Start(partial=message))
  message
}

///|
async test "coding session updates guidelines with its active tools" {
  let cwd = @coding_agent.create_temp_dir("pim-prompt-tools-")
  defer @coding_agent.remove_dir(cwd)
  let path = "\{cwd}/AGENTS.md"
  @coding_agent.write_bytes_file(path, b"Keep project guidance.")
  defer @coding_agent.remove_file(path)
  let llm = PromptCapturingLLM::{ cwd, prompts: [], requests: [], }
  let session = @coding_agent.new_coding_session(llm, cwd~, active_tools=[
    "web_search",
  ])
  session.prompt([user_message("initial")])
  session.set_active_tools(["bash"])
  session.prompt([user_message("enable bash")])
  session.set_active_tools(["web_search"])
  session.prompt([user_message("disable bash")])
  assert_true(llm.prompts[0] != llm.prompts[1])
  assert_eq(llm.prompts[0], llm.prompts[2])
  json_inspect(llm.requests, content=[
    {
      "prompt": "You are an expert coding assistant operating inside pi, a coding agent harness. You help users by reading files, executing commands, editing code, and writing new files.\n\n<project_context>\n\nProject-specific instructions and guidelines:\n<project_instructions path=\"/work/AGENTS.md\">\n\nKeep project guidance.\n\n</project_instructions>\n</project_context>\n\nCurrent working directory: /work\n",
      "tools": ["web_search"],
    },
    {
      "prompt": "You are an expert coding assistant operating inside pi, a coding agent harness. You help users by reading files, executing commands, editing code, and writing new files.\n\nGuidelines:\n- Use bash for file operations like ls, rg, find\n<project_context>\n\nProject-specific instructions and guidelines:\n<project_instructions path=\"/work/AGENTS.md\">\n\nKeep project guidance.\n\n</project_instructions>\n</project_context>\n\nCurrent working directory: /work\n",
      "tools": ["bash"],
    },
    {
      "prompt": "You are an expert coding assistant operating inside pi, a coding agent harness. You help users by reading files, executing commands, editing code, and writing new files.\n\n<project_context>\n\nProject-specific instructions and guidelines:\n<project_instructions path=\"/work/AGENTS.md\">\n\nKeep project guidance.\n\n</project_instructions>\n</project_context>\n\nCurrent working directory: /work\n",
      "tools": ["web_search"],
    },
  ])
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
