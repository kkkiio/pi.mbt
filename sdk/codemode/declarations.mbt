///|
/// 渲染后入参类型最长字符数;超出先去掉约束 tag 重渲,仍超长则 unknown
/// (对应 pi DEFAULT_INPUT_SCHEMA_MAX_CHARS)。
pub const DEFAULT_INPUT_SCHEMA_MAX_CHARS : Int32 = 16_000

///|
/// 局部 $ref 展开次数上限,防止共享定义撑爆输出。
let max_ref_expansions : Int32 = 32

///|
/// 属性值是 number/string 时渲为 `@keyword value` tag 的 schema 关键字。
let tag_keywords : Array[String] = [
  "minimum", "exclusiveMinimum", "maximum", "exclusiveMaximum", "multipleOf", "minLength",
  "maxLength", "pattern", "format", "minItems", "maxItems",
]

///|
/// 所有取值同时成立的下界/上界关键字:下界取最大,上界取最小。
let lower_bounds : Array[String] = [
  "minimum", "exclusiveMinimum", "minLength", "minItems",
]

///|
let upper_bounds : Array[String] = [
  "maximum", "exclusiveMaximum", "maxLength", "maxItems",
]

///|
/// 最长 property tag;更长的(大 default、长 pattern)直接略过。
let max_tag_chars : Int32 = 80

///|
let indent : String = "  "

///|
/// 脚本可见 API 的完整 TS 声明(对应 pi renderDeclarations):
/// tools -> `declare const tools`,globals -> `declare function`
/// 或 `declare const <ns>`,描述渲成 doc comment。
pub fn render_declarations(
  tools~ : ArrayView[CodemodeTool] = [],
  globals~ : ArrayView[CodemodeTool] = [],
) -> String {
  let sections : Array[String] = []
  if tools.length() > 0 {
    let members = tools.map(fn(tool) {
      doc_comment(tool.description, indent) +
      indent +
      render_tool_signature(tool)
    })
    sections.push("declare const tools: {\n\{members.join("\n")}\n};")
  }
  let namespaces : Map[String, Array[String]] = Map([])
  for g in globals {
    match g.name.find(".") {
      None => sections.push(render_global("declare function \{g.name}", g, ""))
      Some(dot) => {
        let ns = g.name[:dot].to_owned()
        let head = g.name[dot + 1:].to_owned()
        match namespaces.get(ns) {
          Some(members) => members.push(render_global(head, g, indent))
          None => namespaces[ns] = [render_global(head, g, indent)]
        }
      }
    }
  }
  for ns, members in namespaces {
    sections.push("declare const \{ns}: {\n\{members.join("\n")}\n};")
  }
  sections.join("\n\n")
}

///|
/// 单个工具的 `id(args: T): Promise<R>;` 成员签名
/// (对应 pi renderToolSignature)。
pub fn render_tool_signature(
  tool : CodemodeTool,
  input_max_chars~ : Int32 = DEFAULT_INPUT_SCHEMA_MAX_CHARS,
) -> String {
  let input = match tool.input_schema {
    None => "unknown"
    Some(schema) => schema_to_type(schema, max_chars=Some(input_max_chars))
  }
  let id = to_codemode_identifier(tool.name)
  "\{id}(args: \{input}): Promise<\{render_tool_output_type(tool.output_schema)}>;"
}

///|
/// 工具描述 + 声明块(describeTool / ALL_TOOLS 条目用;
/// 对应 pi renderToolSample)。
pub fn render_tool_sample(
  tool : CodemodeTool,
  input_max_chars~ : Int32 = DEFAULT_INPUT_SCHEMA_MAX_CHARS,
) -> String {
  let declaration = "declare const tools: { \{render_tool_signature(tool, input_max_chars~)} };"
  let description = tool.description.trim().to_owned()
  "\{description}\n\ncodemode tool declaration:\n```ts\n\{declaration}\n```"
}

///|
/// 调用结果类型串;无 schema 为 "unknown"(对应 pi renderToolOutputType)。
pub fn render_tool_output_type(schema : Json?) -> String {
  match schema {
    None => "unknown"
    Some(schema) => schema_to_type(schema)
  }
}

///|
fn render_global(head : String, g : CodemodeTool, prefix : String) -> String {
  let comment = doc_comment(g.description, prefix)
  if g.signature is Some(signature) {
    return "\{comment}\{prefix}\{head}\{signature};"
  }
  let input = match g.input_schema {
    None => "unknown"
    Some(schema) => schema_to_type(schema)
  }
  "\{comment}\{prefix}\{head}(args: \{input}): Promise<\{render_tool_output_type(g.output_schema)}>;"
}

///|
fn doc_comment(description : String, prefix : String) -> String {
  let text = description.trim().to_owned()
  if text.is_empty() {
    return ""
  }
  let lines = text
    .replace_all(old="*/", new="*\\/")
    .replace_all(old="\r\n", new="\n")
    .split("\n")
    .collect()
  if lines.length() == 1 {
    return "\{prefix}/** \{lines[0]} */\n"
  }
  let body = lines
    .map(fn(line) {
      if line.is_empty() {
        "\{prefix} *"
      } else {
        "\{prefix} * \{line}"
      }
    })
    .join("\n")
  "\{prefix}/**\n\{body}\n\{prefix} */\n"
}

///|
fn property_key(name : String) -> String {
  if is_identifier(name) {
    name
  } else {
    Json(name).stringify()
  }
}

///|
fn is_identifier(name : String) -> Bool {
  if name.is_empty() {
    return false
  }
  for i, char in name {
    let valid = if i == 0 {
      char is ('a'..<='z' | 'A'..<='Z' | '_' | '$')
    } else {
      char is ('a'..<='z' | 'A'..<='Z' | '0'..<='9' | '_' | '$')
    }
    if !valid {
      return false
    }
  }
  true
}

///|
fn union_type(types : Array[String]) -> String {
  let unique : Array[String] = []
  for t in types {
    if !unique.contains(t) {
      unique.push(t)
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
priv struct SchemaContext {
  root : Json
  /// 当前展开路径上的 $ref,用于在递归类型处停住
  resolving : Map[String, Bool]
  mut expansions : Int32
  /// 属性注释是否带约束 tag
  tags : Bool
}

///|
/// JSON Schema -> TS 类型表达式(对应 pi schemaToType)。
/// schema=True -> unknown,False -> never;对象单行 `{ a: T; b?: U }`,
/// 有描述/约束 tag 时逐行展开并附 `//` 注释;局部 $ref 可展开,
/// 递归/远端 ref 渲染为 unknown。超出 max_chars 先去掉约束 tag 重渲,
/// 仍超长则 unknown。
pub fn schema_to_type(schema : Json, max_chars~ : Int32? = None) -> String {
  let type_ = schema_to_type_inner(schema, tags=true)
  if max_chars is Some(limit) && type_.length() > limit {
    let untagged = schema_to_type_inner(schema, tags=false)
    return if untagged.length() <= limit { untagged } else { "unknown" }
  }
  type_
}

///|
fn schema_to_type_inner(schema : Json, tags~ : Bool) -> String {
  let context : SchemaContext = {
    root: schema,
    resolving: Map([]),
    expansions: 0,
    tags,
  }
  to_type(schema, context)
}

///|
fn to_type(schema : Json, context : SchemaContext) -> String {
  guard schema is Object(fields) else {
    return match schema {
      True => "unknown"
      False => "never"
      _ => "unknown"
    }
  }
  if fields.get("$ref") is Some(String(reference)) {
    if context.resolving.contains(reference) ||
      context.expansions >= max_ref_expansions {
      return "unknown"
    }
    guard resolve_ref(reference, context.root) is Some(target) else {
      return "unknown"
    }
    context.expansions += 1
    context.resolving[reference] = true
    let result = to_type(target, context)
    context.resolving.remove(reference)
    return result
  }
  if fields.get("const") is Some(value) {
    return value.stringify()
  }
  if fields.get("enum") is Some(Array(values)) {
    return union_type(values.map(fn(value) { value.stringify() }))
  }
  let variants = match fields.get("anyOf") {
    Some(Array(variants)) => Some(variants)
    _ =>
      match fields.get("oneOf") {
        Some(Array(variants)) => Some(variants)
        _ => None
      }
  }
  if variants is Some(variants) {
    return union_type(variants.map(fn(variant) { to_type(variant, context) }))
  }
  if fields.get("allOf") is Some(Array(parts)) {
    let rendered = parts
      .map(fn(part) { to_type(part, context) })
      .filter(fn(part) { part != "unknown" })
    if rendered.is_empty() {
      return "unknown"
    }
    return rendered
      .map(fn(part) { if part.contains(" | ") { "(\{part})" } else { part } })
      .join(" & ")
  }
  match fields.get("type") {
    Some(Array(entries)) =>
      union_type(
        entries.map(fn(entry) {
          let copy : Map[String, Json] = Map([])
          for key, value in fields {
            copy[key] = value
          }
          copy["type"] = entry
          to_type(Json(copy), context)
        }),
      )
    Some(String(type_)) =>
      match type_ {
        "string" => "string"
        "number" | "integer" => "number"
        "boolean" => "boolean"
        "null" => "null"
        "array" => array_type(fields, context)
        "object" => object_type(fields, context)
        _ => "unknown"
      }
    None =>
      if fields.contains("properties") ||
        fields.contains("additionalProperties") ||
        fields.contains("required") {
        object_type(fields, context)
      } else if fields.contains("items") || fields.contains("prefixItems") {
        array_type(fields, context)
      } else {
        "unknown"
      }
    _ => "unknown"
  }
}

///|
fn array_type(fields : Map[String, Json], context : SchemaContext) -> String {
  if fields.get("items") is Some(items) && !(items is Array(_)) {
    return "Array<\{to_type(items, context)}>"
  }
  let tuple = match fields.get("prefixItems") {
    Some(Array(items)) => items
    _ =>
      match fields.get("items") {
        Some(Array(items)) => items
        _ => []
      }
  }
  if tuple.length() > 0 {
    return "[\{tuple.map(fn(item) { to_type(item, context) }).join(", ")}]"
  }
  "unknown[]"
}

///|
fn description_of(property : Json) -> String {
  if property is Object(fields) &&
    fields.get("description") is Some(String(description)) {
    description.trim().to_owned()
  } else {
    ""
  }
}

///|
/// 属性类型表达不了的约束渲成 JSDoc 风格 tag:
/// `@integer @minimum 1 @maximum 100 @default 20`。无约束则为空串。
fn constraint_tags(property : Json) -> String {
  guard property is Object(fields) else { return "" }
  // Pydantic 的 `int | None` 这类可选字段的约束在 non-null 分支上;
  // 分支约束与属性自身约束同时生效,两边都读。
  let variants = match fields.get("anyOf") {
    Some(Array(variants)) => Some(variants)
    _ =>
      match fields.get("oneOf") {
        Some(Array(variants)) => Some(variants)
        _ => None
      }
  }
  let non_null = match variants {
    Some(variants) =>
      variants.filter(fn(variant) {
        match variant {
          Object(branch) => !(branch.get("type") is Some(String("null")))
          _ => true
        }
      })
    None => []
  }
  let branches : Array[Map[String, Json]] = [fields]
  if non_null.length() == 1 && non_null[0] is Object(branch) {
    branches.push(branch)
  }
  // draft-04 / OpenAPI 3.0 用布尔 exclusiveMinimum/exclusiveMaximum 修饰
  // minimum/maximum;折算回独立数值字段。
  let schemas = branches.map(fn(schema) {
    let normalized : Map[String, Json] = Map([])
    for key, value in schema {
      normalized[key] = value
    }
    if schema.get("exclusiveMinimum") is Some(True) {
      normalized.remove("minimum")
      if schema.get("minimum") is Some(minimum) {
        normalized["exclusiveMinimum"] = minimum
      }
    }
    if schema.get("exclusiveMaximum") is Some(True) {
      normalized.remove("maximum")
      if schema.get("maximum") is Some(maximum) {
        normalized["exclusiveMaximum"] = maximum
      }
    }
    normalized
  })
  let tags : Array[String] = []
  let is_integer = fn(schema : Map[String, Json]) {
    schema.get("type") is Some(String("integer")) ||
    (
      schema.get("type") is Some(Array(entries)) &&
      entries.contains(Json("integer"))
    )
  }
  if schemas.iter().any(is_integer) {
    tags.push("@integer")
  }
  for keyword in tag_keywords {
    let values = schemas.filter_map(fn(schema) { schema.get(keyword) })
    let lower = lower_bounds.contains(keyword)
    if lower || upper_bounds.contains(keyword) {
      let numbers = values.filter_map(fn(value) {
        if value is Number(n, ..) {
          Some(n)
        } else {
          None
        }
      })
      if numbers.is_empty() {
        continue
      }
      let bound = numbers
        .iter()
        .fold(init=numbers[0], fn(acc, n) {
          if lower {
            if n > acc {
              n
            } else {
              acc
            }
          } else if n < acc {
            n
          } else {
            acc
          }
        })
      tags.push("@\{keyword} \{format_number(bound)}")
      continue
    }
    let unique : Array[Json] = []
    for value in values {
      if !unique.contains(value) {
        unique.push(value)
      }
    }
    for value in unique {
      match value {
        Number(n, ..) => tags.push("@\{keyword} \{format_number(n)}")
        String(s) => tags.push("@\{keyword} \{s}")
        _ => ()
      }
    }
  }
  if schemas.iter().any(fn(schema) { schema.get("uniqueItems") is Some(True) }) {
    tags.push("@uniqueItems")
  }
  // 注解(不同于约束)只读属性自身。
  if fields.get("default") is Some(value) && !(value is Null) {
    tags.push("@default \{value.stringify()}")
  }
  if fields.get("deprecated") is Some(True) {
    tags.push("@deprecated")
  }
  tags
  .filter(fn(tag) { tag.length() <= max_tag_chars })
  .map(escape_line_terminators)
  .join(" ")
}

///|
/// JS 的数字模板格式化:整数值不带小数点。
fn format_number(n : Double) -> String {
  if n.floor() == n && n >= -9007199254740991.0 && n <= 9007199254740991.0 {
    n.to_int64().to_string()
  } else {
    n.to_string()
  }
}

///|
/// `//` 注释里的行终止符转义为 \uXXXX。
fn escape_line_terminators(text : String) -> String {
  let buffer = StringBuilder()
  for char in text {
    if char is ('\r' | '\n' | '\u2028' | '\u2029') {
      buffer.write_string("\\u")
      let code = char.to_int()
      for shift in [12, 8, 4, 0] {
        let digit = (code >> shift) & 0xf
        buffer.write_char(
          if digit < 10 {
            ('0'.to_int() + digit).unsafe_to_char()
          } else {
            ('a'.to_int() + digit - 10).unsafe_to_char()
          },
        )
      }
    } else {
      buffer.write_char(char)
    }
  }
  buffer.to_string()
}

///|
fn split_lines(text : String) -> Array[String] {
  let lines : Array[String] = []
  let buffer = StringBuilder()
  for char in text {
    if char is ('\r' | '\n' | '\u2028' | '\u2029') {
      lines.push(buffer.to_string())
      buffer.reset()
    } else {
      buffer.write_char(char)
    }
  }
  lines.push(buffer.to_string())
  lines
}

///|
fn object_type(fields : Map[String, Json], context : SchemaContext) -> String {
  let properties = match fields.get("properties") {
    Some(Object(properties)) => properties
    _ => Map([])
  }
  let required = match fields.get("required") {
    Some(Array(entries)) =>
      entries.filter_map(fn(entry) {
        if entry is String(name) {
          Some(name)
        } else {
          None
        }
      })
    _ => []
  }
  let names = properties.keys().collect()
  names.sort()
  let members = names.map(fn(name) {
    let optional = if required.contains(name) { "" } else { "?" }
    "\{property_key(name)}\{optional}: \{to_type(properties[name], context)};"
  })
  match fields.get("additionalProperties") {
    Some(False) => ()
    Some(additional) => {
      let type_ = if additional is True {
        "unknown"
      } else {
        to_type(additional, context)
      }
      members.push("[key: string]: \{type_};")
    }
    None => if names.is_empty() { members.push("[key: string]: unknown;") }
  }
  if members.is_empty() {
    return "{}"
  }
  let comments = names.map(fn(name) {
    let lines = split_lines(description_of(properties[name]))
      .map(fn(line) { line.trim().to_owned() })
      .filter(fn(line) { !line.is_empty() })
    if context.tags {
      let tags = constraint_tags(properties[name])
      if !tags.is_empty() {
        lines.push(tags)
      }
    }
    lines
  })
  if !comments.iter().any(fn(comment) { !comment.is_empty() }) {
    return "{ \{members.join(" ")} }"
  }
  let lines : Array[String] = ["{"]
  for i, comment in comments {
    for line in comment {
      lines.push("\{indent}// \{line}")
    }
    lines.push(
      "\{indent}\{members[i].replace_all(old="\n", new="\n\{indent}")}",
    )
  }
  for entry in members[names.length():] {
    lines.push("\{indent}\{entry}")
  }
  lines.push("}")
  lines.join("\n")
}

///|
/// 解析 `#/$defs/...`、`#/definitions/...` 局部引用;远端 ref 返回 None。
fn resolve_ref(reference : String, root : Json) -> Json? {
  if reference == "#" {
    return Some(root)
  }
  guard reference.has_prefix("#/") else { return None }
  let tail = reference[2:]
  let mut current = root
  for segment in tail.split("/") {
    if segment.is_empty() {
      continue
    }
    let key = decode_uri_component(segment.to_owned())
      .replace_all(old="~1", new="/")
      .replace_all(old="~0", new="~")
    guard current is Object(fields) && fields.get(key) is Some(next) else {
      return None
    }
    current = next
  }
  if current is Object(_) || current is True || current is False {
    Some(current)
  } else {
    None
  }
}

///|
/// decodeURIComponent 的最小实现:%XX 解码为 UTF-8 字节序列。
/// 含非 ASCII 字符时原样返回($ref 段里出现是罕见情形)。
fn decode_uri_component(text : String) -> String {
  if !text.contains("%") {
    return text
  }
  let units = text.to_array()
  let bytes : Array[Byte] = []
  let mut i = 0
  while i < units.length() {
    let unit = units[i]
    guard unit.to_int() < 128 else { return text }
    if unit == '%' && i + 2 < units.length() {
      match (hex_digit(units[i + 1]), hex_digit(units[i + 2])) {
        (Some(hi), Some(lo)) => {
          bytes.push((hi * 16 + lo).to_byte())
          i += 3
          continue
        }
        _ => ()
      }
    }
    bytes.push(unit.to_int().to_byte())
    i += 1
  }
  @utf8.decode(Bytes::from_array(bytes)) catch {
    _ => text
  }
}

///|
fn hex_digit(char : Char) -> Int32? {
  match char {
    '0'..<='9' => Some(char.to_int() - '0'.to_int())
    'a'..<='f' => Some(char.to_int() - 'a'.to_int() + 10)
    'A'..<='F' => Some(char.to_int() - 'A'.to_int() + 10)
    _ => None
  }
}
