///|
/// With no guidelines, project context, or skills, the prompt is the role line
/// plus the working directory.
async test "system prompt names the role and the working directory" {
  let llm = PromptCapturingLLM::{
    cwd: "/nonexistent",
    prompts: [],
    requests: [],
  }
  let session = @agent_session.AgentSession(llm, system_prompt_contributes=[
    @coding_agent.coding_assistant_system_prompt_contributor(),
    @coding_agent.cwd_system_prompt_contributor(cwd="/workspaces/pi.mbt"),
  ])
  session.prompt([user_message("hi")])
  inspect(
    llm.prompts[0],
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
) -> @agent_loop.AssistantMessage {
  let prompt = context.system_prompt.replace_all(old=self.cwd, new="/work")
  self.prompts.push(prompt)
  self.requests.push({
    "prompt": prompt,
    "tools": [
      for tool in context.tools => Json(tool.name)
    ],
  })
  let message = @faux.faux_message([@faux.faux_text("ok")])
  sink(@agent_loop.Start(partial=message))
  message
}

///|
/// The session assembles the system prompt once and keeps it stable across
/// `set_active_tools` — only the offered tools change. Refreshing the prompt
/// mid-session is deferred until mid-conversation system messages land, so
/// that provider prefix caches keep hitting.
async test "coding session keeps a stable prompt as active tools change" {
  let cwd = @coding_agent.create_temp_dir("pim-prompt-tools-")
  defer @coding_agent.remove_dir(cwd)
  let path = "\{cwd}/AGENTS.md"
  @coding_agent.write_bytes_file(path, b"Keep project guidance.")
  defer @coding_agent.remove_file(path)
  let llm = PromptCapturingLLM::{ cwd, prompts: [], requests: [], }
  let session = @coding_agent.new_coding_session(llm, cwd~, active_tools=[])
  session.prompt([user_message("initial")])
  session.set_active_tools(["bash"])
  session.prompt([user_message("enable bash")])
  session.set_active_tools([])
  session.prompt([user_message("disable bash")])
  assert_eq(llm.prompts[0], llm.prompts[1])
  assert_eq(llm.prompts[1], llm.prompts[2])
  json_inspect(llm.requests, content=[
    {
      "prompt": "You are an expert coding assistant operating inside pi, a coding agent harness. You help users by reading files, executing commands, editing code, and writing new files.\n\n<project_context>\n\nProject-specific instructions and guidelines:\n<project_instructions path=\"/work/AGENTS.md\">\n\nKeep project guidance.\n\n</project_instructions>\n</project_context>\n\nCurrent working directory: /work\n",
      "tools": [],
    },
    {
      "prompt": "You are an expert coding assistant operating inside pi, a coding agent harness. You help users by reading files, executing commands, editing code, and writing new files.\n\n<project_context>\n\nProject-specific instructions and guidelines:\n<project_instructions path=\"/work/AGENTS.md\">\n\nKeep project guidance.\n\n</project_instructions>\n</project_context>\n\nCurrent working directory: /work\n",
      "tools": ["bash"],
    },
    {
      "prompt": "You are an expert coding assistant operating inside pi, a coding agent harness. You help users by reading files, executing commands, editing code, and writing new files.\n\n<project_context>\n\nProject-specific instructions and guidelines:\n<project_instructions path=\"/work/AGENTS.md\">\n\nKeep project guidance.\n\n</project_instructions>\n</project_context>\n\nCurrent working directory: /work\n",
      "tools": [],
    },
  ])
}

///|
/// Active tools contribute their `prompt_guidelines` as a Guidelines section
/// between the role line and the working directory; the bash tool contributes
/// one.
async test "system prompt lists active tool guidelines" {
  let tool_registry = @tools.ToolRegistry()
  tool_registry.register_tool(@coding_agent.new_bash_tool_definition())
  let llm = PromptCapturingLLM::{
    cwd: "/nonexistent",
    prompts: [],
    requests: [],
  }
  let session = @agent_session.AgentSession(
    llm,
    system_prompt_contributes=[
      @coding_agent.coding_assistant_system_prompt_contributor(),
      @coding_agent.tools_guidelines_system_prompt_contributor(tool_registry),
      @coding_agent.cwd_system_prompt_contributor(cwd="/workspaces/pi.mbt"),
    ],
    tool_registry~,
    active_tools=["bash"],
  )
  session.prompt([user_message("hi")])
  inspect(
    llm.prompts[0],
    content=(
      #|You are an expert coding assistant operating inside pi, a coding agent harness. You help users by reading files, executing commands, editing code, and writing new files.
      #|
      #|Guidelines:
      #|- Use bash for file operations like ls, rg, find
      #|
      #|Current working directory: /workspaces/pi.mbt
      #|
    ),
  )
}
