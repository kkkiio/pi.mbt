///|
pub struct ProjectContextFile {
  path : String
  content : String
} derive(Debug)

///|
pub struct Skill {
  name : String
  description : String
  path : String
} derive(Debug)

///|
fn Skill::Skill(name~ : String, description~ : String, path~ : String) -> Skill {
  { name, description, path }
}

///|
fn agents_file_names() -> Array[String] {
  ["AGENTS.override.md", "AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD"]
}

///|
/// Walk upward from `cwd` looking for AGENTS.md / AGENTS.override.md /
/// CLAUDE.md. Returns files from the repository root toward `cwd`.
pub async fn load_agents_files(cwd : String) -> Array[ProjectContextFile] {
  let files : Array[ProjectContextFile] = []
  let mut current = cwd
  let visited = Set::from_array([current])
  while true {
    match try_load_context_file(current) {
      Some(file) => files.insert(0, file)
      None => ()
    }
    let parent = parent_dir(current)
    if parent == current || visited.contains(parent) {
      break
    }
    visited.add(parent)
    current = parent
  }
  files
}

///|
fn parent_dir(path : String) -> String {
  match path.rev_split_once("/") {
    Some(("", _)) => "/"
    Some((parent, _)) => "\{parent}"
    None => "/"
  }
}

///|
async fn try_load_context_file(dir : String) -> ProjectContextFile? {
  for name in agents_file_names() {
    let path = "\{dir}/\{name}"
    let exists = @fs.exists(path) catch { _ => false }
    if !exists {
      continue
    }
    let is_file = @fs.kind(path) is Regular
    if !is_file {
      continue
    }
    let content = @fs.read_file(path).text() catch { _ => continue }
    return Some({ path, content })
  }
  None
}

///|
/// Discover skills under `dir`: every `<dir>/<name>.md`, plus every
/// `<dir>/<name>/SKILL.md`. A missing or unreadable directory returns empty.
pub async fn discover_skills(dir : String) -> Array[Skill] {
  let skills : Array[Skill] = []
  let entries = @fs.readdir(dir) catch { _ => return skills }
  for entry in entries {
    if entry.has_prefix(".") {
      continue
    }
    let entry_path = "\{dir}/\{entry}"
    if entry.has_suffix(".md") {
      add_skill_file(skills, entry_path)
    } else {
      let nested = "\{entry_path}/SKILL.md"
      // exists() raises ENOTDIR when entry_path is a plain file; either way
      // there is no nested skill here.
      let has_nested = @fs.exists(nested) catch { _ => false }
      if has_nested {
        add_skill_file(skills, nested)
      }
    }
  }
  skills.sort_by((a, b) => a.name.compare(b.name))
  skills
}

///|
async fn add_skill_file(skills : Array[Skill], path : String) -> Unit {
  let text = @fs.read_file(path).text() catch { _ => return }
  let fallback = match skill_fallback_name(path) {
    "SKILL" => {
      // For <name>/SKILL.md layouts the directory carries the name.
      let parent = match path.rev_split_once("/") {
        Some((parent, _)) => parent
        None => path
      }
      match parent.rev_split_once("/") {
        Some((_, name)) => "\{name}"
        None => "\{parent}"
      }
    }
    stem => stem
  }
  let (name, description) = parse_frontmatter(text, fallback)
  skills.push(Skill(name~, description~, path~))
}

///|
fn skill_fallback_name(path : String) -> String {
  let base = match path.rev_split_once("/") {
    Some((_, base)) => "\{base}"
    None => path
  }
  match base.rev_split_once(".") {
    Some((stem, _)) => "\{stem}"
    None => base
  }
}

///|
/// Parse `name:` and `description:` from a markdown frontmatter block.
pub fn parse_frontmatter(
  text : String,
  fallback_name : String,
) -> (String, String) {
  let mut name = fallback_name
  let mut description = ""
  let lines = [..text.split("\n")]
  guard lines is [first, .. rest] && first.trim() == "---" else {
    return (name, description)
  }
  for line in rest {
    if line.trim() == "---" {
      break
    }
    if line.split_once(":") is Some((key, value)) {
      let key = key.trim()
      let value = value.trim()
      match key {
        "name" => if value != "" { name = "\{value}" }
        "description" => description = "\{value}"
        _ => ()
      }
    }
  }
  (name, description)
}
