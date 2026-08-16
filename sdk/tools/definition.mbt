///|
using @agent_loop {type ToolCall, type ToolResult}

///|
pub async fn run_tool(
  tools : Map[String, ToolDefinition],
  tool_call : ToolCall,
  on_update : @agent_loop.ToolExecUpdateSink,
) -> ToolResult {
  guard tools.get(tool_call.name)
    is Some({ callable_definition: Some(def), .. }) else {
    return ToolResult::{
      content: [],
      is_error: true,
      terminate: false,
      details: { "error": "Tool not found" },
      usage: None,
    }
  }
  (def.execute)(tool_call.id, tool_call.arguments, on_update)
}

///|
pub(all) struct ToolDefinition {
  name : String
  /// Readable label for the tool, used in the UI.
  label : String
  /// Optional guideline bullets appended to the default system prompt Guidelines section when this tool is active.
  prompt_guidelines : Array[String]
  callable_definition : CallableDefinition?
}

///|
pub(all) struct CallableDefinition {
  description : String
  parameters : Json
  constrained_sampling : @agent_loop.ConstrainedSampling
  execute : async (String, Json, @agent_loop.ToolExecUpdateSink) -> ToolResult
}
