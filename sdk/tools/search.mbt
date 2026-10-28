///|
/// A discovery result, also the metadata exposed by codemode's ALL_TOOLS.
pub(all) struct ToolInfo {
  name : String
  description : String
} derive(Eq, ToJson)

///|
pub extend ToolInfo with Eq::{equal, not_equal}

///|
pub extend ToolInfo with ToJson::{to_json}

///|
/// All script-callable tools in registration order, including deferred tools.
/// Model-only tools, such as tool_search, are excluded.
pub fn ToolRegistry::all_tools(self : ToolRegistry) -> Array[ToolInfo] {
  self
  .tool_names()
  .filter_map(name => {
    if self.is_callable(name) {
      self
      .get_tool(name)
      .map(t => ToolInfo::{ name, description: t.description, })
    } else {
      None
    }
  })
}

///|
/// BM25 discovery shared by hosts' searchTools and tool_search. Searches names,
/// descriptions, schema properties and descriptions, and namespace metadata.
/// Exact full names or suffixes after __ rank first; ties keep registration order.
pub fn ToolRegistry::search_tools(
  self : ToolRegistry,
  query : String,
  limit~ : Int32 = 8,
  ns~ : String? = None,
  exclude~ : ArrayView[String] = [],
) -> Array[ToolInfo] {
  let terms = Set::from_array(tokenize(query)).to_array()
  if terms.is_empty() || limit <= 0 {
    return []
  }
  let candidates = self
    .all_tools()
    .filter(t => {
      !exclude.contains(t.name) &&
      (match ns {
        None => true
        Some(name) =>
          self
          .tool_namespace(t.name)
          .map_or(false, n => normalize_name(n.name) == normalize_name(name))
      })
    })
  if candidates.is_empty() {
    return []
  }
  let counts = candidates.map(tool => {
    let definition = self.get_tool(tool.name).unwrap()
    let parts = [
      tool.name,
      tool.name.replace_all(old="_", new=" "),
      tool.description,
    ]
    schema_text(definition.parameters, parts)
    if self.tool_namespace(tool.name) is Some(ns) {
      parts.append([ns.name, ns.description, ns.instructions])
    }
    let counts : Map[String, Int32] = Map([])
    for term in tokenize(parts.join(" ")) {
      counts[term] = counts.get(term).unwrap_or(0) + 1
    }
    counts
  })
  let lengths = counts.map(c => c.values().fold(init=0, (sum, n) => sum + n))
  let average = lengths.iter().fold(init=0, (sum, n) => sum + n).to_double() /
    candidates.length().to_double()
  let average = if average > 0 { average } else { 1.0 }
  let idfs : Map[String, Double] = Map([])
  for term in terms {
    let frequency = counts.filter(c => c.contains(term)).length().to_double()
    idfs[term] = @math.ln(
      1.0 +
      (candidates.length().to_double() - frequency + 0.5) / (frequency + 0.5),
    )
  }
  let ranked : Array[(Int32, Bool, Double)] = []
  let name_query = normalize_name(query)
  for i, tool in candidates {
    let mut score = 0.0
    for term in terms {
      let count = counts[i].get(term).unwrap_or(0).to_double()
      if count > 0 {
        let norm = 1.2 * (0.25 + 0.75 * lengths[i].to_double() / average)
        score += idfs[term] * count * 2.2 / (count + norm)
      }
    }
    if score > 0 {
      let name = normalize_name(tool.name)
      ranked.push(
        (i, name == name_query || name.has_suffix("__" + name_query), score),
      )
    }
  }
  ranked.sort_by((a, b) => {
    if a.1 != b.1 {
      if a.1 {
        -1
      } else {
        1
      }
    } else if a.2 != b.2 {
      b.2.compare(a.2)
    } else {
      a.0.compare(b.0)
    }
  })
  ranked[:limit].to_owned().map(item => candidates[item.0])
}

///|
fn schema_text(schema : Json, parts : Array[String]) -> Unit {
  guard schema is Object(fields) else { return }
  if fields.get("description") is Some(String(description)) {
    parts.push(description)
  }
  if fields.get("properties") is Some(Object(properties)) {
    for name, property in properties {
      parts.push(name)
      schema_text(property, parts)
    }
  }
  if fields.get("items") is Some(items) {
    schema_text(items, parts)
  }
  for key in ["anyOf", "oneOf", "allOf"] {
    if fields.get(key) is Some(Array(variants)) {
      for variant in variants {
        schema_text(variant, parts)
      }
    }
  }
}

///|
fn lower(c : Char) -> Bool {
  c >= 'a' && c <= 'z'
}

///|
fn upper(c : Char) -> Bool {
  c >= 'A' && c <= 'Z'
}

///|
fn digit(c : Char) -> Bool {
  c >= '0' && c <= '9'
}

///|
fn normalize_name(text : String) -> String {
  let out = StringBuilder()
  for c in text.trim().to_owned().to_lower() {
    out.write_char(
      if lower(c) || digit(c) || c == '_' || c == '$' {
        c
      } else {
        '_'
      },
    )
  }
  out.to_string()
}

///|
fn tokenize(text : String) -> Array[String] {
  let chars = text.iter().to_array()
  let split = StringBuilder()
  for i, c in chars {
    if upper(c) &&
      i > 0 &&
      (
        lower(chars[i - 1]) ||
        digit(chars[i - 1]) ||
        (upper(chars[i - 1]) && i + 1 < chars.length() && lower(chars[i + 1]))
      ) {
      split.write_char(' ')
    }
    split.write_char(if lower(c) || upper(c) || digit(c) { c } else { ' ' })
  }
  split
  .to_string()
  .to_lower()
  .split(" ")
  .filter_map(word => {
    let word = word.to_owned()
    if word == "" ||
      [
        "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "in", "is",
        "it", "of", "on", "or", "that", "the", "this", "to", "with",
      ].contains(word) {
      None
    } else {
      Some(stem(word))
    }
  })
  .to_array()
}

///|
fn stem(word : String) -> String {
  if word.length() > 4 && word.has_suffix("ies") {
    word[:word.length() - 3].to_owned() + "y"
  } else if word.length() > 4 &&
    ["ches", "shes", "sses", "xes", "zes"].any(s => word.has_suffix(s)) {
    word[:word.length() - 2].to_owned()
  } else if word.length() > 3 && word.has_suffix("s") && !word.has_suffix("ss") {
    word[:word.length() - 1].to_owned()
  } else {
    word
  }
}
