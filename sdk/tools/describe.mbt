///|
/// Description and TypeScript declaration for a callable tool, or None when
/// unavailable. Hosts can expose this as codemode's describeTool global.
pub fn ToolRegistry::describe_tool(
  self : ToolRegistry,
  name : String,
) -> String? {
  guard self.is_callable(name) && self.get_tool(name) is Some(tool) else {
    return None
  }
  let description = ([tool.description] + tool.prompt_guidelines).join("\n")
  Some(
    "\{description}\n\nCall as tools[\{Json::string(name).stringify()}].\n\n```ts\ndeclare const tools: { \{Json::string(name).stringify()}: (args: \{schema_type(tool.parameters)}) => Promise<unknown> };\n```",
  )
}

///|
/// Namespace description, instructions and declarations of all its callable
/// tools. An unknown namespace returns None. Discovery does not activate tools.
pub fn ToolRegistry::describe_namespace(
  self : ToolRegistry,
  name : String,
) -> String? {
  guard self.namespaces
    .iter()
    .find_first(ns => normalize_name(ns.name) == normalize_name(name))
    is Some(ns) else {
    return None
  }
  let parts = [ns.name, ns.description, ns.instructions]
  for tool in self.all_tools() {
    if self.tool_namespace(tool.name).map_or(false, n => n.name == ns.name) &&
      self.describe_tool(tool.name) is Some(description) {
      parts.push(description)
    }
  }
  Some(parts.filter(s => s != "").join("\n\n"))
}

///|
fn schema_type(schema : Json) -> String {
  guard schema is Object(fields) else { return "unknown" }
  if fields.get("enum") is Some(Array(values)) && !values.is_empty() {
    return values.map(v => v.stringify()).join(" | ")
  }
  for key in ["anyOf", "oneOf", "allOf"] {
    if fields.get(key) is Some(Array(variants)) && !variants.is_empty() {
      return variants
        .map(schema_type)
        .join(if key == "allOf" { " & " } else { " | " })
    }
  }
  match fields.get("type") {
    Some(String("string")) => "string"
    Some(String("integer" | "number")) => "number"
    Some(String("boolean")) => "boolean"
    Some(String("null")) => "null"
    Some(String("array")) =>
      "Array<\{schema_type(fields.get("items").unwrap_or(Json::null()))}>"
    Some(String("object")) => {
      let required = match fields.get("required") {
        Some(Array(names)) => names
        _ => []
      }
      let parts = []
      if fields.get("properties") is Some(Object(properties)) {
        for name, property in properties {
          let optional = if required.contains(Json::string(name)) {
            ""
          } else {
            "?"
          }
          parts.push(
            "\{Json::string(name).stringify()}\{optional}: \{schema_type(property)}",
          )
        }
      }
      if fields.get("additionalProperties") != Some(Json::boolean(false)) {
        parts.push("[key: string]: unknown")
      }
      "{ \{parts.join("; ")} }"
    }
    _ => "unknown"
  }
}
