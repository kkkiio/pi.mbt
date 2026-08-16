///|
pub fn build_system_prompt(
  cwd~ : String,
  guidelines? : ArrayView[String] = [],
  project_context_files? : ArrayView[ProjectContextFile] = [],
  skills? : ArrayView[Skill] = [],
) -> String {
  let builder = StringBuilder()
  builder <+
    #|You are an expert coding assistant operating inside pi, a coding agent harness. You help users by reading files, executing commands, editing code, and writing new files.
    #|
    #|
  if guidelines.length() > 0 {
    builder <+
      #|Guidelines:
      #|
    for g in guidelines {
      builder <+
        $|- \{g}
        $|
    }
    builder <+
      #|
  }
  if project_context_files.length() > 0 {
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
      #|
  }
  if skills.length() > 0 {
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
  }
  builder <+
    $|Current working directory: \{cwd}
    $|
  builder.to_string()
}

///|
/// Escape special XML characters in text
/// Replaces: < > & " '
pub fn escape(text : String) -> String {
  let buf = StringBuilder::new()
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
