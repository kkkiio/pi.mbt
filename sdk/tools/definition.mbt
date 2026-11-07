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
      structured_content: None,
      usage: None,
    }
  }
  (tool.execute)(tool_call.id, tool_call.arguments, on_update)
}

///|
/// How the model reaches a tool, pi's `ToolExposure`. "Callable" means
/// callable from other tools, as the `codemode` tool does.
#derive(Eq)
pub(all) enum ToolExposure {
  /// Declared to the model while active, and callable while active.
  Direct
  /// Declared to the model while active, never callable.
  ModelOnly
  /// Callable whenever registered; not declared unless activated. Codemode
  /// tools list it in their description.
  Codemode
  /// Like `Codemode`, but codemode tools do not list it; tool discovery such
  /// as `ALL_TOOLS` can still find it.
  Deferred
  /// Registered but unreachable; activating it has no effect.
  Hidden
}

///|
pub extend ToolExposure with Eq::{not_equal, equal}

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
  /// JSON Schema of `structured_content` in results, for programmatic callers
  /// such as codemode scripts. Tools that declare it should always set
  /// `structured_content`. pi's `outputSchema`.
  output_schema : Json?
  /// How the model reaches the tool. pi's `exposure`, default `"direct"`.
  exposure : ToolExposure
  constrained_sampling : @agent_loop.ConstrainedSampling
  execute : async (String, Json, @agent_loop.ToolExecUpdateCallback) -> ToolResult
}
