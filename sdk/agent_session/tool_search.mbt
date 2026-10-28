///|
/// Name of the optional model-facing discovery tool provided by every session.
pub const TOOL_SEARCH_TOOL_NAME : String = "tool_search"

///|
/// Create a tool bound to this session's registry and journal. Searches only
/// currently undeclared callable tools and loads matches for the next request.
/// Each session provides its own definition and keeps it inactive by default.
pub fn new_tool_search_tool_definition(
  session : AgentSession,
) -> @tools.ToolDefinition {
  {
    name: TOOL_SEARCH_TOOL_NAME,
    label: TOOL_SEARCH_TOOL_NAME,
    prompt_guidelines: [],
    description: "Search deferred tool metadata with BM25 and load matching tools for the next model call. Use tool_search to discover tools that have not been provided upfront, including MCP tools.",
    parameters: {
      "type": "object",
      "properties": {
        "query": {
          "type": "string",
          "description": "Search query for tools that are not loaded yet.",
        },
        "limit": {
          "type": "integer",
          "minimum": 1,
          "maximum": 2147483647,
          "description": "Maximum number of tools to load (default 8).",
        },
      },
      "required": ["query"],
      "additionalProperties": false,
    },
    constrained_sampling: @agent_loop.JsonSchema(strict=false),
    execute: (_id, arguments, _on_update) => {
      guard arguments is Object(fields) &&
        fields.get("query") is Some(String(query)) &&
        !query.trim().is_empty() else {
        fail("query must be a non-empty string")
      }
      let limit = match fields.get("limit") {
        None => 8
        Some(Number(n, ..)) if n > 0 &&
          n <= 2147483647.0 &&
          n == n.to_int().to_double() => n.to_int()
        _ => fail("limit must be a positive integer")
      }
      let active = session.active_tool_names().to_owned()
      let matches = session.agent.tool_registry.search_tools(
        query,
        limit~,
        exclude=active,
      )
      let loaded = matches.map(t => t.name)
      if !loaded.is_empty() {
        session.set_active_tools(active + loaded)
      }
      let text = if matches.is_empty() {
        "No matching tools found."
      } else {
        let lines = matches.map(t => {
          "- \{t.name}: \{t.description.trim().to_owned().split("\n").next().unwrap_or("")}"
        })
        let noun = if matches.length() == 1 { "tool" } else { "tools" }
        "Loaded \{matches.length()} \{noun}. They are available from your next call:\n\{lines.join("\n")}"
      }
      {
        content: [@agent_loop.Text(text)],
        details: { "loaded": loaded },
        is_error: false,
        usage: None,
      }
    },
  }
}
