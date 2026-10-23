///|
using @agent_loop {type ToolCall, type ToolResult}

///|
pub async fn run_tool(
  tools : Map[String, ToolDefinition],
  tool_call : ToolCall,
  on_update : @agent_loop.ToolExecUpdateCallback,
) -> ToolResult {
  guard tools.get(tool_call.name) is Some(tool) else {
    return ToolResult::{
      content: [],
      is_error: true,
      details: { "error": "Tool not found" },
      usage: None,
    }
  }
  (tool.execute)(tool_call.id, tool_call.arguments, on_update)
}

///|
/// A tool the agent can run. Flat, like pi's `AgentTool`: the wire-facing
/// fields (description/parameters/constrained_sampling) sit next to the
/// runtime ones, and the session projects them into an
/// `@agent_loop.ToolDefinition` for the provider.
pub(all) struct ToolDefinition {
  name : String
  /// Readable label for the tool, used in the UI.
  label : String
  /// Optional guideline bullets appended to the default system prompt Guidelines section when this tool is active.
  prompt_guidelines : Array[String]
  description : String
  parameters : Json
  constrained_sampling : @agent_loop.ConstrainedSampling
  execute : async (String, Json, @agent_loop.ToolExecUpdateCallback) -> ToolResult
}
