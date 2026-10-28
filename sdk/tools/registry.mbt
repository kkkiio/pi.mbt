///|
struct ToolRegistry {
  tools : Map[String, ToolDefinition]
  order : Array[String]
  exposures : Map[String, ToolExposure]
  namespaces : Array[ToolNamespace]
}

///|
pub fn ToolRegistry::ToolRegistry() -> ToolRegistry {
  ToolRegistry::{ tools: {}, order: [], exposures: {}, namespaces: [], }
}

///|
/// Register or replace a tool, preserving registration order for search ties.
/// Deferred and codemode tools remain callable without being declared to the model.
pub fn ToolRegistry::register_tool(
  self : ToolRegistry,
  tool_def : ToolDefinition,
  exposure~ : ToolExposure = Direct,
) -> Unit {
  if !self.tools.contains(tool_def.name) {
    self.order.push(tool_def.name)
  }
  self.tools[tool_def.name] = tool_def
  self.exposures[tool_def.name] = exposure
}

///|
/// Look up a registered tool, including tools not yet declared to the model.
pub fn ToolRegistry::get_tool(
  self : ToolRegistry,
  name : String,
) -> ToolDefinition? {
  self.tools.get(name)
}

///|
/// Host exposure metadata. ModelOnly tools are excluded from script discovery;
/// all other tools remain callable regardless of the host's active model set.
pub(all) enum ToolExposure {
  Direct
  Deferred
  Codemode
  ModelOnly
} derive(Eq)

///|
pub extend ToolExposure with Eq::{equal, not_equal}

///|
/// Metadata shared by tools with a name prefix, such as an MCP server.
pub(all) struct ToolNamespace {
  name : String
  prefix : String
  description : String
  instructions : String
}

///|
/// Register namespace metadata. A repeated name replaces its previous metadata.
/// The longest matching prefix determines a tool's namespace.
pub fn ToolRegistry::register_namespace(
  self : ToolRegistry,
  ns : ToolNamespace,
) -> Unit {
  for i, existing in self.namespaces {
    if existing.name == ns.name {
      self.namespaces[i] = ns
      return
    }
  }
  self.namespaces.push(ns)
}

///|
fn ToolRegistry::tool_namespace(
  self : ToolRegistry,
  name : String,
) -> ToolNamespace? {
  let mut selected : ToolNamespace? = None
  for ns in self.namespaces {
    if name.has_prefix(ns.prefix) &&
      selected.map_or(true, n => n.prefix.length() < ns.prefix.length()) {
      selected = Some(ns)
    }
  }
  selected
}

///|
fn ToolRegistry::is_callable(self : ToolRegistry, name : String) -> Bool {
  self.exposures.get(name) != Some(ModelOnly)
}
