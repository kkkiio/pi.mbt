///|
/// pi's `DEFAULT_INPUT_SCHEMA_MAX_CHARS`: the largest rendered input type, in
/// characters, before it becomes `unknown`.
pub const DEFAULT_INPUT_SCHEMA_MAX_CHARS = 16000

///|
/// pi's `MAX_REF_EXPANSIONS`: local `$ref` expansions per rendered schema, so
/// shared definitions cannot blow up the output.
const MAX_REF_EXPANSIONS = 32

///|
/// pi's `TAG_KEYWORDS`: JSON Schema keywords with a number or string value
/// shown as `@keyword value` property tags.
let tag_keywords : Array[String] = [
  "minimum", "exclusiveMinimum", "maximum", "exclusiveMaximum", "multipleOf", "minLength",
  "maxLength", "pattern", "format", "minItems", "maxItems",
]

///|
/// pi's `LOWER_BOUNDS`/`UPPER_BOUNDS`: tag keywords whose values all hold at
/// once, so only the largest (lower) or smallest (upper) matters.
let lower_bounds : Array[String] = [
  "minimum", "exclusiveMinimum", "minLength", "minItems",
]

///|
let upper_bounds : Array[String] = [
  "maximum", "exclusiveMaximum", "maxLength", "maxItems",
]

///|
/// pi's `MAX_TAG_CHARS`: the longest property tag; longer ones (large
/// defaults, long patterns) are left out.
const MAX_TAG_CHARS = 80

///|
/// pi's `INDENT`.
const INDENT = "  "

///|
/// Render TypeScript declarations for the script-visible API, pi's
/// `renderDeclarations`. Tools become members of `declare const tools`,
/// globals become `declare function` statements, and `ns.member` globals
/// become members of `declare const ns`. `tools`/`globals` are the
/// script-callable entries; the result is the declaration text, empty when
/// there is nothing to declare. Descriptions become doc comments and schemas
/// become types; a global's `signature` overrides the schema rendering.
pub fn render_declarations(
  tools~ : ArrayView[CodemodeTool] = [],
  globals~ : ArrayView[CodemodeTool] = [],
) -> String {
  let sections : Array[String] = []
  if tools.length() > 0 {
    let members = tools.map(tool => {
      "\{doc_comment(tool.description, INDENT)}\{INDENT}\{render_tool_signature(tool)}"
    })
    sections.push("declare const tools: {\n\{members.join("\n")}\n};")
  }
  let namespaces : Map[String, Array[String]] = Map([])
  for global in globals {
    match global.name.find(".") {
      None => {
        sections.push(
          render_global("declare function \{global.name}", global, ""),
        )
        continue
      }
      Some(dot) => {
        let ns_name = global.name[:dot].to_owned()
        let members = match namespaces.get(ns_name) {
          Some(existing) => existing
          None => {
            let created : Array[String] = []
            namespaces[ns_name] = created
            created
          }
        }
        members.push(
          render_global(global.name[dot + 1:].to_owned(), global, INDENT),
        )
      }
    }
  }
  for ns_name, members in namespaces {
    sections.push("declare const \{ns_name}: {\n\{members.join("\n")}\n};")
  }
  sections.join("\n\n")
}

///|
/// One tool as a member of the `tools` object, pi's `renderToolSignature`:
/// `name(args: T): Promise<R>;` with the identifier scripts use. `tool` is the
/// declared tool and `input_max_chars` the largest rendered input type; a
/// longer one renders as `unknown` (no tags first, then `unknown`).
pub fn render_tool_signature(
  tool : CodemodeTool,
  input_max_chars~ : Int32 = DEFAULT_INPUT_SCHEMA_MAX_CHARS,
) -> String {
  let input = match tool.input_schema {
    Some(schema) => schema_to_type(schema, max_chars=Some(input_max_chars))
    None => "unknown"
  }
  let js_name = tool.js_name.unwrap_or(to_codemode_identifier(tool.name))
  "\{js_name}(args: \{input}): Promise<\{render_tool_output_type(tool.output_schema)}>;"
}

///|
/// A tool's sample, pi's `renderToolSample`: the description followed by the
/// tool's declaration, for tool listings and `ALL_TOOLS` entries. `tool` is
/// the declared tool and `input_max_chars` the largest rendered input type;
/// the result is the sample text.
pub fn render_tool_sample(
  tool : CodemodeTool,
  input_max_chars~ : Int32 = DEFAULT_INPUT_SCHEMA_MAX_CHARS,
) -> String {
  let declaration = "declare const tools: { \{render_tool_signature(tool, input_max_chars~)} };"
  "\{tool.description.trim()}\n\ncodemode tool declaration:\n```ts\n\{declaration}\n```"
}

///|
/// The type a tool call resolves to, pi's `renderToolOutputType`: the output
/// schema's type, or `unknown` when `schema` is `None`.
pub fn render_tool_output_type(schema : Json?) -> String {
  match schema {
    Some(json) => schema_to_type(json)
    None => "unknown"
  }
}

///|
/// Convert a JSON Schema to a TypeScript type expression, pi's `schemaToType`:
/// objects on one line (`{ a: string; b?: number; }`) with properties sorted by
/// name, or one property per line with `//` comments when a property has a
/// description or constraints the type cannot express (`// @integer @minimum 1
/// @default 20`); `Array<T>` for arrays. Local references (`#/$defs/...`,
/// `#/definitions/...`) resolve against `schema`; recursive, remote and
/// malformed references render as `unknown`. When `max_chars` is `Some` and the
/// tagged result is longer, it is rendered again without the constraint tags,
/// and renders as `unknown` if it is still too long.
pub fn schema_to_type(schema : Json, max_chars~ : Int32? = None) -> String {
  fn render(tags : Bool) -> String {
    to_type(schema, SchemaContext::{
      root: schema,
      resolving: Map([]),
      expansions: 0,
      tags,
    })
  }
  let rendered = render(true)
  if max_chars is None || rendered.length() <= max_chars.unwrap() {
    return rendered
  }
  let untagged = render(false)
  if untagged.length() <= max_chars.unwrap() {
    return untagged
  }
  "unknown"
}

///|
priv struct SchemaContext {
  root : Json
  /// References being expanded on the current path, to stop at recursive types.
  resolving : Map[String, Bool]
  mut expansions : Int32
  /// Whether property comments include constraint tags.
  tags : Bool
}

///|
fn resolve_ref(reference : String, root : Json) -> Json? {
  if reference != "#" && !reference.has_prefix("#/") {
    return None
  }
  let mut current = root
  if reference != "#" {
    for segment in reference[2:].split("/") {
      if segment.length() == 0 {
        continue
      }
      let decoded = @percent.decode(segment) catch { _ => return None }
      let key = decoded
        .replace_all(old="~1", new="/")
        .replace_all(old="~0", new="~")
      guard current is Object(fields) && fields.contains(key) else {
        return None
      }
      current = fields[key]
    }
  }
  match current {
    Object(_) | True | False => Some(current)
    _ => None
  }
}

///|
fn to_type(schema : Json, context : SchemaContext) -> String {
  match schema {
    True => return "unknown"
    False => return "never"
    Object(_) => ()
    _ => return "unknown"
  }
  guard schema is Object(obj) else { return "unknown" }
  if obj.get("$ref") is Some(String(reference)) {
    if context.resolving.contains(reference) ||
      context.expansions >= MAX_REF_EXPANSIONS {
      return "unknown"
    }
    guard resolve_ref(reference, context.root) is Some(target) else {
      return "unknown"
    }
    context.expansions += 1
    context.resolving[reference] = true
    defer context.resolving.remove(reference)
    return to_type(target, context)
  }
  if obj.get("const") is Some(const_value) {
    return const_value.stringify()
  }
  if obj.get("enum") is Some(Array(values)) {
    return union(values.map(value => value.stringify()))
  }
  let variants = match obj.get("anyOf") {
    Some(Array(list)) => Some(list)
    _ =>
      match obj.get("oneOf") {
        Some(Array(list)) => Some(list)
        _ => None
      }
  }
  if variants is Some(list) {
    return union(list.map(variant => to_type(variant, context)))
  }
  if obj.get("allOf") is Some(Array(parts_json)) {
    let parts = parts_json
      .map(part => to_type(part, context))
      .filter(part => part != "unknown")
    if parts.is_empty() {
      return "unknown"
    }
    return parts
      .map(part => if part.contains(" | ") { "(\{part})" } else { part })
      .join(" & ")
  }
  match obj.get("type") {
    Some(Array(entries)) =>
      union(
        entries.map(entry => {
          let cloned = obj.copy()
          cloned["type"] = entry
          to_type(Json(cloned), context)
        }),
      )
    Some(String("string")) => "string"
    Some(String("number")) | Some(String("integer")) => "number"
    Some(String("boolean")) => "boolean"
    Some(String("null")) => "null"
    Some(String("array")) => array_type(obj, context)
    Some(String("object")) => object_type(obj, context)
    Some(_) => "unknown"
    None =>
      if obj.contains("properties") ||
        obj.contains("additionalProperties") ||
        obj.contains("required") {
        object_type(obj, context)
      } else if obj.contains("items") || obj.contains("prefixItems") {
        array_type(obj, context)
      } else {
        "unknown"
      }
  }
}

///|
fn array_type(obj : Map[String, Json], context : SchemaContext) -> String {
  if obj.get("items") is Some(items) && !(items is Array(_)) {
    return "Array<\{to_type(items, context)}>"
  }
  let tuple = match obj.get("prefixItems") {
    Some(Array(items)) => items
    _ =>
      match obj.get("items") {
        Some(Array(items)) => items
        _ => []
      }
  }
  if tuple.length() > 0 {
    return "[\{tuple.map(item => to_type(item, context)).join(", ")}]"
  }
  "unknown[]"
}

///|
/// Constraints of a property that its TypeScript type cannot express, as
/// JSDoc-style tags: `@integer @minimum 1 @maximum 100 @default 20`. `schema`
/// is the property value; the result is the tag text, empty when there are
/// none or it is not a schema object.
fn constraint_tags(schema : Json) -> String {
  guard schema is Object(property) else { return "" }
  // Optional fields such as Pydantic's `int | None` keep their constraints in
  // the non-null branch. The branch's constraints apply together with the
  // property's, so both are read.
  let variants = match property.get("anyOf") {
    Some(Array(list)) => list
    _ =>
      match property.get("oneOf") {
        Some(Array(list)) => list
        _ => []
      }
  }
  let non_null = variants.filter(variant => {
    !(variant is Object(fields) && fields.get("type") is Some(String("null")))
  })
  let branches : Array[Map[String, Json]] = if non_null.length() == 1 &&
    non_null[0] is Object(branch) {
    [property, branch]
  } else {
    [property]
  }
  // Draft-04 and OpenAPI 3.0 make `minimum`/`maximum` exclusive with a boolean
  // `exclusiveMinimum`/`exclusiveMaximum`.
  let schemas = branches.map(schema => {
    let normalized = schema.copy()
    if normalized.get("exclusiveMinimum") is Some(True) {
      match normalized.get("minimum") {
        Some(minimum) => normalized["exclusiveMinimum"] = minimum
        None => normalized.remove("exclusiveMinimum")
      }
      normalized.remove("minimum")
    }
    if normalized.get("exclusiveMaximum") is Some(True) {
      match normalized.get("maximum") {
        Some(maximum) => normalized["exclusiveMaximum"] = maximum
        None => normalized.remove("exclusiveMaximum")
      }
      normalized.remove("maximum")
    }
    normalized
  })
  let tags : Array[String] = []
  let is_integer = schemas
    .iter()
    .any(schema => {
      match schema.get("type") {
        Some(String("integer")) => true
        Some(Array(entries)) =>
          entries.iter().any(entry => entry is String("integer"))
        _ => false
      }
    })
  if is_integer {
    tags.push("@integer")
  }
  for keyword in tag_keywords {
    let values = schemas.map(schema => schema.get(keyword))
    if lower_bounds.contains(keyword) || upper_bounds.contains(keyword) {
      let numbers = values.filter_map(value => {
        match value {
          Some(Number(n, ..)) => Some(n)
          _ => None
        }
      })
      if numbers.is_empty() {
        continue
      }
      let bound = if lower_bounds.contains(keyword) {
        numbers.iter().fold(init=numbers[0], (a, b) => a.max(b))
      } else {
        numbers.iter().fold(init=numbers[0], (a, b) => a.min(b))
      }
      tags.push("@\{keyword} \{bound}")
      continue
    }
    let seen : Array[String] = []
    for value in values {
      match value {
        Some(Number(n, ..)) => {
          let key = "n\{n}"
          if !seen.contains(key) {
            seen.push(key)
            tags.push("@\{keyword} \{n}")
          }
        }
        Some(String(text)) => {
          let key = "s\{text}"
          if !seen.contains(key) {
            seen.push(key)
            tags.push("@\{keyword} \{text}")
          }
        }
        _ => ()
      }
    }
  }
  if schemas.iter().any(schema => schema.get("uniqueItems") is Some(True)) {
    tags.push("@uniqueItems")
  }
  // Annotations, unlike constraints, come from the property itself.
  if property.get("default") is Some(value) && !(value is Null) {
    tags.push("@default \{value.stringify()}")
  }
  if property.get("deprecated") is Some(True) {
    tags.push("@deprecated")
  }
  tags
  .filter(tag => tag.length() <= MAX_TAG_CHARS)
  .map(escape_line_terminators)
  .join(" ")
}

///|
fn object_type(obj : Map[String, Json], context : SchemaContext) -> String {
  let properties = match obj.get("properties") {
    Some(Object(props)) => props
    _ => Map([])
  }
  let required = match obj.get("required") {
    Some(Array(entries)) =>
      entries.filter_map(entry => {
        match entry {
          String(name) => Some(name)
          _ => None
        }
      })
    _ => []
  }
  let names = properties.keys().collect()
  names.sort_by(String::lexical_compare)
  let members = names.map(name => {
    let optional = if required.contains(name) { "" } else { "?" }
    "\{property_key(name)}\{optional}: \{to_type(properties[name], context)};"
  })
  match obj.get("additionalProperties") {
    Some(False) => ()
    Some(additional) => {
      let type_text = if additional is True {
        "unknown"
      } else {
        to_type(additional, context)
      }
      members.push("[key: string]: \{type_text};")
    }
    None => if names.is_empty() { members.push("[key: string]: unknown;") }
  }
  if members.is_empty() {
    return "{}"
  }
  let comments : Array[Array[String]] = names.map(name => {
    let lines = split_line_terminators(description_of(properties[name]))
      .map(line => line.trim().to_owned())
      .filter(line => line.length() > 0)
    let tags = if context.tags { constraint_tags(properties[name]) } else { "" }
    if tags.length() > 0 {
      lines.push(tags)
    }
    lines
  })
  if !comments.iter().any(comment => comment.length() > 0) {
    return "{ \{members.join(" ")} }"
  }
  let lines : Array[String] = ["{"]
  for index, comment in comments {
    for line in comment {
      lines.push("\{INDENT}// \{line}")
    }
    lines.push(
      "\{INDENT}\{members[index].replace_all(old="\n", new="\n\{INDENT}")}",
    )
  }
  for extra in members[names.length():] {
    lines.push("\{INDENT}\{extra}")
  }
  lines.push("}")
  lines.join("\n")
}

///|
fn render_global(
  head : String,
  global : CodemodeTool,
  indent : String,
) -> String {
  if global.signature is Some(signature) {
    return "\{doc_comment(global.description, indent)}\{indent}\{head}\{signature};"
  }
  let input = match global.input_schema {
    Some(schema) => schema_to_type(schema)
    None => "unknown"
  }
  let output = match global.output_schema {
    Some(schema) => schema_to_type(schema)
    None => "unknown"
  }
  "\{doc_comment(global.description, indent)}\{indent}\{head}(args: \{input}): Promise<\{output}>;"
}

///|
fn doc_comment(description : String, indent : String) -> String {
  let text = description.trim()
  if text.length() == 0 {
    return ""
  }
  let lines = split_crlf(text.replace_all(old="*/", new="*\\/"))
  if lines.length() == 1 {
    return "\{indent}/** \{lines[0]} */\n"
  }
  let rendered = lines.map(line => {
    if line.length() > 0 {
      "\{indent} * \{line}"
    } else {
      "\{indent} *"
    }
  })
  "\{indent}/**\n\{rendered.join("\n")}\n\{indent} */\n"
}

///|
fn property_key(name : String) -> String {
  if is_identifier(name) {
    name
  } else {
    Json::string(name).stringify()
  }
}

///|
fn is_identifier(name : String) -> Bool {
  if name.length() == 0 {
    return false
  }
  let mut first = true
  for c in name.iter() {
    if first {
      first = false
      if !(c is ('a'..<='z' | 'A'..<='Z' | '_' | '$')) {
        return false
      }
    } else if !(c is ('a'..<='z' | 'A'..<='Z' | '0'..<='9' | '_' | '$')) {
      return false
    }
  }
  true
}

///|
fn union(types : Array[String]) -> String {
  let unique : Array[String] = []
  for entry in types {
    if !unique.contains(entry) {
      unique.push(entry)
    }
  }
  if unique.contains("unknown") {
    return "unknown"
  }
  if unique.is_empty() {
    "never"
  } else {
    unique.join(" | ")
  }
}

///|
fn description_of(property : Json) -> String {
  match property {
    Object(fields) =>
      match fields.get("description") {
        Some(String(text)) => text.trim().to_owned()
        _ => ""
      }
    _ => ""
  }
}

///|
/// `\r`, `\n`, `\u2028` and `\u2029` each end a `//` comment.
fn is_line_terminator(c : Char) -> Bool {
  c == '\r' || c == '\n' || c == '\u2028' || c == '\u2029'
}

///|
fn split_line_terminators(text : String) -> Array[String] {
  let lines : Array[String] = []
  let mut current = StringBuilder()
  for c in text.iter() {
    if is_line_terminator(c) {
      lines.push(current.to_string())
      current = StringBuilder()
    } else {
      current.write_char(c)
    }
  }
  lines.push(current.to_string())
  lines
}

///|
/// Split on `\r?\n`: a `\r` is only a split point together with `\n`.
fn split_crlf(text : StringView) -> Array[String] {
  let lines : Array[String] = []
  let mut current = StringBuilder()
  for c in text.iter() {
    if c == '\n' {
      let segment = current.to_string()
      if segment.has_suffix("\r") {
        lines.push(segment[:segment.length() - 1].to_owned())
      } else {
        lines.push(segment)
      }
      current = StringBuilder()
    } else {
      current.write_char(c)
    }
  }
  lines.push(current.to_string())
  lines
}

///|
fn escape_line_terminators(tag : String) -> String {
  let builder = StringBuilder()
  for c in tag.iter() {
    match c {
      '\r' => builder.write_string("\\u000d")
      '\n' => builder.write_string("\\u000a")
      '\u2028' => builder.write_string("\\u2028")
      '\u2029' => builder.write_string("\\u2029")
      _ => builder.write_char(c)
    }
  }
  builder.to_string()
}
