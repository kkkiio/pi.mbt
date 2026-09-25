///|
struct ToolRegistry {
  tools : Map[String, ToolDefinition]
}

///|
pub fn ToolRegistry::ToolRegistry() -> ToolRegistry {
  ToolRegistry::{ tools: {}, }
}

///|
pub fn ToolRegistry::register_tool(
  self : ToolRegistry,
  tool_def : ToolDefinition,
) -> Unit {
  self.tools[tool_def.name] = tool_def
}

///|
pub fn ToolRegistry::get_tool(
  self : ToolRegistry,
  name : String,
) -> ToolDefinition? {
  self.tools.get(name)
}
