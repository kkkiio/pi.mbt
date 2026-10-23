///|
pub struct ProjectContextFile {
  path : String
  content : String
} derive(Debug)

///|
pub extend ProjectContextFile with @debug.Debug::{to_repr}

///|
pub struct Skill {
  name : String
  description : String
  path : String
  /// `disable-model-invocation: true` in `SKILL.md` frontmatter: keep the
  /// skill out of the system prompt so only an explicit `/skill:<name>`
  /// command can load it.
  disable_model_invocation : Bool
} derive(Debug)

///|
pub extend Skill with @debug.Debug::{to_repr}

///|
fn Skill::Skill(
  name~ : String,
  description~ : String,
  path~ : String,
  disable_model_invocation~ : Bool,
) -> Skill {
  { name, description, path, disable_model_invocation, }
}

///|
fn agents_file_names() -> Array[String] {
  ["AGENTS.override.md", "AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD"]
}

///|
/// Walk upward from `cwd` looking for AGENTS.md / AGENTS.override.md /
/// CLAUDE.md. Returns files from the repository root toward `cwd`.
pub fn load_agents_files(cwd : String) -> Array[ProjectContextFile] {
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
fn try_load_context_file(dir : String) -> ProjectContextFile? {
  for name in agents_file_names() {
    let path = "\{dir}/\{name}"
    if !path_exists(path) {
      continue
    }
    if !is_regular_file(path) {
      continue
    }
    let content = read_text_file(path) catch { _ => continue }
    return Some({ path, content, })
  }
  None
}

///|
/// Discover skills under `dir`: every `<dir>/<name>.md`, plus every
/// `<dir>/<name>/SKILL.md`. A missing or unreadable directory returns empty.
pub fn discover_skills(dir : String) -> Array[Skill] {
  let skills : Array[Skill] = []
  let entries = read_dir(dir) catch { _ => return skills }
  for entry in entries {
    if entry.has_prefix(".") {
      continue
    }
    let entry_path = "\{dir}/\{entry}"
    if entry.has_suffix(".md") {
      add_skill_file(skills, entry_path)
    } else {
      let nested = "\{entry_path}/SKILL.md"
      // A non-directory entry simply has no nested `SKILL.md`.
      let has_nested = path_exists(nested)
      if has_nested {
        add_skill_file(skills, nested)
      }
    }
  }
  skills.sort_by((a, b) => a.name.compare(b.name))
  skills
}

///|
fn add_skill_file(skills : Array[Skill], path : String) -> Unit {
  let text = read_text_file(path) catch { _ => return }
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
  let frontmatter = parse_frontmatter(text, fallback)
  skills.push(
    Skill(
      name=frontmatter.name,
      description=frontmatter.description,
      path~,
      disable_model_invocation=frontmatter.disable_model_invocation,
    ),
  )
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
/// The `SKILL.md` frontmatter fields pim understands. Unknown keys are ignored.
pub struct SkillFrontmatter {
  name : String
  description : String
  disable_model_invocation : Bool
} derive(Debug)

///|
pub extend SkillFrontmatter with @debug.Debug::{to_repr}

///|
/// Parse `name:`, `description:`, and `disable-model-invocation:` from a
/// markdown frontmatter block. Missing fields fall back to `fallback_name`,
/// an empty description, and `false`.
pub fn parse_frontmatter(
  text : String,
  fallback_name : String,
) -> SkillFrontmatter {
  let mut name = fallback_name
  let mut description = ""
  let mut disable_model_invocation = false
  let lines = [..text.split("\n")]
  guard lines is [first, .. rest] && first.trim() == "---" else {
    return { name, description, disable_model_invocation, }
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
        "disable-model-invocation" =>
          disable_model_invocation = value.to_lower() == "true"
        _ => ()
      }
    }
  }
  { name, description, disable_model_invocation, }
}
