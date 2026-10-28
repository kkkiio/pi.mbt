///|
fn tool(
  name : String,
  description : String,
  parameters~ : Json = { "type": "object" },
) -> @tools.ToolDefinition {
  {
    name,
    label: name,
    description,
    parameters,
    prompt_guidelines: [],
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
test "BM25 ranks relevance, exact names, suffix names and stable ties" {
  let registry = @tools.ToolRegistry()
  registry.register_tool(
    tool(
      "mcp__app__thread_read",
      "Read a thread and its messages. " + "history ".repeat(80),
    ),
  )
  registry.register_tool(tool("other", "Thread read"))
  registry.register_tool(tool("first", "Search issues"))
  registry.register_tool(tool("second", "Search issues"))
  assert_eq(registry.search_tools("thread_read", limit=1).map(t => t.name), [
    "mcp__app__thread_read",
  ])
  assert_eq(
    registry.search_tools("app__thread_read", limit=1).map(t => t.name),
    ["mcp__app__thread_read"],
  )
  assert_eq(
    registry.search_tools("MCP__APP__THREAD_READ", limit=1).map(t => t.name),
    ["mcp__app__thread_read"],
  )
  assert_eq(registry.search_tools("issues").map(t => t.name), [
    "first", "second",
  ])
  assert_eq(registry.search_tools("issue issue").map(t => t.name), [
    "first", "second",
  ])
  assert_eq(registry.search_tools("thread", limit=1).map(t => t.name), ["other"])
  registry.register_tool(tool("first", "Updated search issues"))
  assert_eq(registry.all_tools().map(t => t.name), [
    "mcp__app__thread_read", "other", "first", "second",
  ])
  assert_eq(
    registry.search_tools("issues", exclude=["second"]).map(t => t.description),
    ["Updated search issues"],
  )
}

///|
test "search splits camelCase and acronyms, stems plurals, ignores stop words" {
  let registry = @tools.ToolRegistry()
  registry.register_tool(tool("listHTTPEntries", "Search repository issues"))
  for query in ["http", "entry", "entries", "searches", "issue"] {
    assert_eq(registry.search_tools(query).map(t => t.name), ["listHTTPEntries"])
  }
  for query in ["", "  ", "the and for", "unrelated"] {
    assert_true(registry.search_tools(query).is_empty())
  }
  assert_true(registry.search_tools("http", limit=0).is_empty())
  assert_true(registry.search_tools("http", limit=-1).is_empty())
  assert_true(@tools.ToolRegistry().search_tools("http").is_empty())
}

///|
test "schema metadata, namespace metadata, filters and model-only exclusion" {
  let registry = @tools.ToolRegistry()
  registry.register_namespace({
    name: "dev-radius",
    prefix: "mcp__dev__",
    description: "Deployment dashboards",
    instructions: "Use for clusters",
  })
  registry.register_tool(
    tool("mcp__dev__one", "Perform operation", parameters={
      "type": "object",
      "properties": {
        "repositoryName": { "type": "string" },
        "options": {
          "type": "array",
          "items": { "anyOf": [{ "description": "Milestone filter" }] },
        },
      },
    }),
    exposure=@tools.Deferred,
  )
  registry.register_tool(
    tool("mcp__dev__two", "Build artifact"),
    exposure=@tools.Codemode,
  )
  registry.register_tool(tool("direct", "Deployment"))
  registry.register_tool(
    tool("model_only", "Deployment"),
    exposure=@tools.ModelOnly,
  )
  for query in ["repository", "milestone", "dashboards", "clusters"] {
    assert_true(
      registry.search_tools(query).map(t => t.name).contains("mcp__dev__one"),
    )
  }
  assert_eq(
    registry.search_tools("deployment", ns=Some("dev_radius")).map(t => t.name),
    ["mcp__dev__two", "mcp__dev__one"],
  )
  assert_true(
    registry.search_tools("deployment", ns=Some("unknown")).is_empty(),
  )
  assert_false(registry.all_tools().map(t => t.name).contains("model_only"))
  assert_true(registry.describe_tool("model_only") is None)
  assert_true(registry.describe_tool("unknown") is None)
  assert_true(registry.describe_namespace("unknown") is None)
  let description = registry.describe_tool("mcp__dev__one").unwrap()
  assert_true(description.contains("Perform operation"))
  assert_true(description.contains("repositoryName"))
  assert_true(description.contains("Promise<unknown>"))
  let ns = registry.describe_namespace("dev_radius").unwrap()
  assert_true(ns.contains("Use for clusters"))
  assert_true(ns.contains("mcp__dev__one"))
  assert_true(ns.contains("mcp__dev__two"))
  assert_false(ns.contains("model_only"))
  registry.register_namespace({
    name: "specific",
    prefix: "mcp__dev__one",
    description: "Specific",
    instructions: "",
  })
  assert_false(
    registry.describe_namespace("dev-radius").unwrap().contains("mcp__dev__one"),
  )
  assert_eq(
    registry.search_tools("milestone", ns=Some("specific")).map(t => t.name),
    ["mcp__dev__one"],
  )
}

///|
test "descriptions render required fields, arrays, enums and unions" {
  let registry = @tools.ToolRegistry()
  registry.register_tool(
    tool("read-file", "Read a file", parameters={
      "type": "object",
      "additionalProperties": false,
      "required": ["path"],
      "properties": {
        "path": { "type": "string" },
        "flags": { "type": "array", "items": { "enum": ["a", "b"] } },
        "offset": { "oneOf": [{ "type": "integer" }, { "type": "null" }] },
      },
    }),
  )
  let text = registry.describe_tool("read-file").unwrap()
  assert_true(text.contains("tools[\"read-file\"]"))
  assert_true(text.contains("\"path\": string"))
  assert_true(text.contains("\"flags\"?: Array<\"a\" | \"b\">"))
  assert_true(text.contains("\"offset\"?: number | null"))
}
