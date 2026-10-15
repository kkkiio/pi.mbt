///|
pub fn coding_assistant_system_prompt_contributor() -> (ArrayView[String]) -> String {
  _ => {
    "You are an expert coding assistant operating inside pi, a coding agent harness. You help users by reading files, executing commands, editing code, and writing new files.\n"
  }
}

///|
priv struct Cache[K, V] {
  mut last : (K, V)?
  f : (K) -> V
}

///|
fn[K, V] Cache::Cache(f : (K) -> V) -> Cache[K, V] {
  { last: None, f, }
}

///|
fn[K : Eq, V] Cache::get(self : Cache[K, V], key : K) -> V {
  match self.last {
    Some(c) if c.0 == key => c.1
    _ => {
      let v = (self.f)(key)
      self.last = Some((key, v))
      v
    }
  }
}

///|
pub fn tools_guidelines_system_prompt_contributor(
  tool_registry : @tools.ToolRegistry,
) -> (ArrayView[String]) -> String {
  let cache : Cache[Array[String], String] = Cache(tools => {
    tools_guidelines_system_prompt(tool_registry, tools)
  })
  tools => cache.get(tools.to_owned())
}

///|
pub fn tools_guidelines_system_prompt(
  tool_registry : @tools.ToolRegistry,
  tools : ArrayView[String],
) -> String {
  let guidelines = tools
    .iter()
    .flat_map(name => {
      tool_registry
      .get_tool(name)
      .map_or(Iter::empty(), t => t.prompt_guidelines.iter())
    })
    .to_array()
  if guidelines.length() > 0 {
    let builder = StringBuilder()
    builder <+
      #|Guidelines:
      #|
    for g in guidelines {
      builder <+
        $|- \{g}
        $|
    }
    builder.to_string()
  } else {
    ""
  }
}

///|
pub fn project_context_system_prompt_contributor(
  cwd~ : String,
) -> (ArrayView[String]) -> String {
  // TODO: watch for changes to AGENTS.md and reload
  let context_files = load_agents_files(cwd)
  let prompt = project_context_system_prompt(context_files)
  _ => prompt
}

///|
pub fn project_context_system_prompt(
  project_context_files : ArrayView[ProjectContextFile],
) -> String {
  if project_context_files.length() > 0 {
    let builder = StringBuilder()
    builder <+
      #|<project_context>
      #|
      #|Project-specific instructions and guidelines:
      #|
    for file in project_context_files {
      builder <+
        $|<project_instructions path="\{file.path}">
        $|
        $|\{file.content}
        $|
        $|</project_instructions>
        $|
    }
    builder <+
      #|</project_context>
      #|
    builder.to_string()
  } else {
    ""
  }
}

///|
pub fn skills_system_prompt_contributor(
  cwd~ : String,
) -> (ArrayView[String]) -> String {
  // TODO: watch for changes to skills and reload
  let skills = discover_skills("\{cwd}/.agents/skills")
  let prompt = skills_system_prompt(skills)
  _ => prompt
}

///|
pub fn skills_system_prompt(skills : ArrayView[Skill]) -> String {
  if skills.length() > 0 {
    let builder = StringBuilder()
    builder <+
      #|<available_skills>
      #|
    for skill in skills {
      builder <+
        $|  <skill>
        $|    <name>\{escape(skill.name)}</name>
        $|    <description>\{escape(skill.description)}</description>
        $|    <location>\{escape(skill.path)}</location>
        $|  </skill>
        $|
    }
    builder <+
      #|</available_skills>
      #|
    builder.to_string()
  } else {
    ""
  }
}

///|
pub fn cwd_system_prompt_contributor(
  cwd~ : String,
) -> (ArrayView[String]) -> String {
  let prompt = current_working_directory_system_prompt(cwd)
  _ => prompt
}

///|
pub fn current_working_directory_system_prompt(cwd : String) -> String {
  (
    $|Current working directory: \{cwd}
    $|
  )
}

///|
/// Escape special XML characters in text
/// Replaces: < > & " '
pub fn escape(text : String) -> String {
  let buf = StringBuilder()
  for c in text {
    match c {
      '<' => buf.write_string("&lt;")
      '>' => buf.write_string("&gt;")
      '&' => buf.write_string("&amp;")
      '"' => buf.write_string("&quot;")
      '\'' => buf.write_string("&apos;")
      _ => buf.write_char(c)
    }
  }
  buf.to_string()
}
