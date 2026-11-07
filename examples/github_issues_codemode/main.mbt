///|
async fn main {
  let api_key = resolve_deepseek_api_key()
  let llm = @providers.DeepSeekProvider(api_key~).new_llm(
    "deepseek-v4-flash",
    thinking="low",
  )
  let journal = @agent_session.InMemorySessionJournal()
  let list_issues = github_list_issues_tool()
  let codemode = @coding_agent.new_codemode_tool_definition(
    tools=[list_issues],
    journal=Some(journal),
  )
  defer @coding_agent.close_codemode_sidecar()
  let registry = @tools.ToolRegistry()
  registry.register_tool(list_issues)
  registry.register_tool(codemode)
  let session = @agent_session.AgentSession(
    llm,
    system_prompt_contributes=[
      @coding_agent.coding_assistant_system_prompt_contributor(),
      @coding_agent.tools_guidelines_system_prompt_contributor(registry),
    ],
    journal~,
    tool_registry=registry,
    active_tools=[@coding_agent.CODEMODE_TOOL_NAME],
  )
  session.prompt([
    {
      content: [
        @agent_loop.InputMessageContent::Text(
          "Count all open issues (excluding pull requests) in https://github.com/earendil-works/pi and group them by label name (sorted by count descending, plus an `(unlabeled)` count for issues with no labels). Also report total open issues.",
        ),
      ],
      timestamp: @env.now(),
    },
  ])
  println(@transcript.from_entries(journal.get_entries()))
}

///|
fn resolve_deepseek_api_key() -> String raise {
  if @env.get_env_var("DEEPSEEK_API_KEY") is Some(key) && !key.is_empty() {
    return key
  }
  if @coding_agent.path_exists(".env") {
    let text = @coding_agent.read_text_file(".env")
    for line_view in text.split("\n") {
      let line = line_view.trim()
      if line.strip_prefix("DEEPSEEK_API_KEY=") is Some(val) {
        let key = val.trim(chars=" \"'\r").to_owned()
        if !key.is_empty() {
          return key
        }
      }
    }
  }
  let auth_path = "\{@coding_agent.home_dir()}/.pim/auth.json"
  if @coding_agent.path_exists(auth_path) {
    let json = @json.parse(@coding_agent.read_text_file(auth_path))
    if json is { "deepseek": { "type": "api_key", "key": String(key), .. }, .. } &&
      !key.is_empty() {
      return key
    }
  }
  fail("DEEPSEEK_API_KEY is not set in environment, .env, or ~/.pim/auth.json")
}

///|
#external
priv type GhApiResult

///|
extern "js" fn gh_api(endpoint : String) -> GhApiResult =
  #| (endpoint) => {
  #|   const r = process.getBuiltinModule("node:child_process")
  #|     .spawnSync("gh", ["api", endpoint], {
  #|       encoding: "utf8",
  #|       maxBuffer: 64 * 1024 * 1024,
  #|     });
  #|   return {
  #|     status: r.status ?? -1,
  #|     stdout: r.stdout ?? "",
  #|     stderr: r.stderr ?? "",
  #|     error: r.error ? String(r.error.message ?? r.error) : "",
  #|   };
  #| }

///|
extern "js" fn GhApiResult::status(self : GhApiResult) -> Int32 = "(r) => r.status"

///|
extern "js" fn GhApiResult::stdout(self : GhApiResult) -> String = "(r) => r.stdout"

///|
extern "js" fn GhApiResult::stderr(self : GhApiResult) -> String = "(r) => r.stderr"

///|
extern "js" fn GhApiResult::spawn_error(self : GhApiResult) -> String = "(r) => r.error"

///|
fn github_list_issues_tool() -> @tools.ToolDefinition {
  {
    name: "github_list_issues",
    label: "github_list_issues",
    prompt_guidelines: [
      "Returns a JSON array of GitHub REST issue objects (up to 100 per page). Note that the issues endpoint includes pull requests (which have a `pull_request` field).",
    ],
    description: "Fetch one page (100 items per page) of open issues from a GitHub repository.",
    parameters: {
      "type": "object",
      "properties": {
        "owner": { "type": "string", "description": "Repository owner" },
        "repo": { "type": "string", "description": "Repository name" },
        "page": {
          "type": "integer",
          "description": "1-based page number (100 items per page)",
        },
      },
      "required": ["owner", "repo", "page"],
      "additionalProperties": false,
    },
    output_schema: Some({
      "type": "array",
      "items": { "type": "object", "additionalProperties": true },
    }),
    exposure: @tools.ToolExposure::Codemode,
    constrained_sampling: @agent_loop.ConstrainedSampling::JsonSchema(
      strict=true,
    ),
    execute: (_, args, _) => {
      guard args
        is {
          "owner": String(owner),
          "repo": String(repo),
          "page": Number(page_num, ..),
          ..
        } else {
        fail("invalid arguments for github_list_issues")
      }
      let page = page_num.to_int()
      let endpoint = "repos/\{owner}/\{repo}/issues?state=open&per_page=100&page=\{page}"
      let result = gh_api(endpoint)
      if !result.spawn_error().is_empty() {
        fail(
          "`gh api` failed to run (is `gh` installed?): \{result.spawn_error()}",
        )
      }
      guard result.status() == 0 else {
        fail("`gh api \{endpoint}` failed: \{result.stderr()}")
      }
      {
        content: [@agent_loop.InputMessageContent::Text(result.stdout())],
        details: {},
        is_error: false,
        structured_content: Some(
          @json.parse(result.stdout()) catch {
            _ => Json::null()
          },
        ),
        usage: None,
      }
    },
  }
}
