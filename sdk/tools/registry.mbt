///|
struct ToolRegistry {
  all_tools : Map[String, ToolDefinition]
  activate_tools : Array[String]
}

///|
pub fn ToolRegistry::ToolRegistry() -> ToolRegistry {
  ToolRegistry::{ all_tools: {}, activate_tools: [] }
}

///|
pub fn ToolRegistry::register_tool(
  self : ToolRegistry,
  tool_def : ToolDefinition,
  activate? : Bool = true,
) -> Unit {
  self.all_tools[tool_def.name] = tool_def
  if activate && !self.activate_tools.contains(tool_def.name) {
    self.activate_tools.push(tool_def.name)
  }
}

///|
pub fn ToolRegistry::get_active_tools(
  self : ToolRegistry,
) -> ArrayView[ToolDefinition] {
  self.activate_tools.map(n => self.all_tools[n])
}
