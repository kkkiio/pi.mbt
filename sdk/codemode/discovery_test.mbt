///|
fn tool(name : String) -> @tools.ToolDefinition {
  {
    name,
    label: name,
    description: "Read issue details",
    prompt_guidelines: [],
    parameters: {
      "type": "object",
      "properties": { "issue": { "type": "integer" } },
      "required": ["issue"],
    },
    constrained_sampling: @agent_loop.JsonSchema(strict=false),
    execute: (_, _, _) => {
      content: [],
      details: {},
      is_error: false,
      usage: None,
    },
  }
}

///|
/// A script host fixture: inject the public globals into trusted test scripts.
extern "js" fn run_script(
  globals : @codemode.DiscoveryGlobals,
  source : String,
) -> @js_async.Promise[String] =
  #| async (globals, source) => {
  #|   const AsyncFunction = Object.getPrototypeOf(async function() {}).constructor;
  #|   const names = ["ALL_TOOLS", "searchTools", "describeTool", "describeNamespace"];
  #|   const value = await new AsyncFunction(...names, source)(...names.map(name => globals[name]));
  #|   return JSON.stringify(value);
  #| }

///|
async test "scripts discover deferred tools, describe namespaces, and see new registrations" {
  let registry = @tools.ToolRegistry()
  registry.register_namespace({
    name: "GitHub",
    prefix: "mcp__github__",
    description: "Repository hosting",
    instructions: "Use for pull requests",
  })
  registry.register_tool(
    tool("mcp__github__read_issue"),
    exposure=@tools.Deferred,
  )
  registry.register_tool(tool("model_only"), exposure=@tools.ModelOnly)
  let globals = @codemode.new_discovery_globals(registry)
  let result = run_script(
    globals,
    (
      #| const [matches, description, namespace] = await Promise.all([
      #|   searchTools("issues", {limit: 1, namespace: "github"}),
      #|   describeTool("mcp__github__read_issue"), describeNamespace("github")
      #| ]);
      #| return {
      #|   all: ALL_TOOLS.map(t => t.name), matches,
      #|   schema: description.includes('"issue": number'),
      #|   instructions: namespace.includes("Use for pull requests"),
      #|   missingTool: await describeTool("missing") === undefined,
      #|   missingNamespace: await describeNamespace("missing") === undefined,
      #|   modelOnly: await describeTool("model_only") === undefined,
      #|   emptyNamespace: await searchTools("issue", { namespace: "" }),
      #| };
    ),
  ).wait()
  json_inspect(@json.parse(result), content={
    "all": ["mcp__github__read_issue"],
    "matches": [
      { "name": "mcp__github__read_issue", "description": "Read issue details" },
    ],
    "schema": true,
    "instructions": true,
    "missingTool": true,
    "missingNamespace": true,
    "modelOnly": true,
    "emptyNamespace": [],
  })
  registry.register_tool(
    tool("mcp__github__list_issues"),
    exposure=@tools.Codemode,
  )
  let next = run_script(
    globals,
    (
      #| return { count: ALL_TOOLS.length, matches: (await searchTools("issues")).length };
    ),
  ).wait()
  json_inspect(@json.parse(next), content={ "count": 2, "matches": 2 })
  ignore(run_script(globals, "ALL_TOOLS.length = 0; return null;").wait())
  assert_eq(run_script(globals, "return ALL_TOOLS.length;").wait(), "2")
}

///|
async test "discovery globals reject invalid options without leaking JS errors across FFI" {
  let globals = @codemode.new_discovery_globals(@tools.ToolRegistry())
  let result = run_script(
    globals,
    (
      #| const invalid = [
      #|   () => searchTools(null), () => searchTools("query", {limit: 0}),
      #|   () => searchTools("query", {limit: 1.5}), () => searchTools("query", {limit: Infinity}),
      #|   () => searchTools("query", {limit: 2147483648}),
      #|   () => searchTools("query", {namespace: 1}),
      #|   () => describeTool(null), () => describeNamespace(1),
      #| ];
      #| return await Promise.all(invalid.map(async f => {
      #|   try { await f(); return false; } catch (e) { return e instanceof TypeError; }
      #| }));
    ),
  ).wait()
  json_inspect(@json.parse(result), content=[
    true, true, true, true, true, true, true, true,
  ])
}
