///|
/// Create a new coding agent session pre-configured with the default
/// system prompt (including AGENTS.md project instructions and `.agents/skills/`),
/// the bash tool and the codemode tool.
///
/// codemode 的嵌套调用走与直接调用相同的 `@tools.run_tool` 管线;
/// `store()` 写入以 `codemode-store` custom entry 落进 journal,
/// `load()` 由条目顺序回放(单分支假设;分支感知回放留待后续)。
pub fn new_coding_session(
  llm : &@agent_loop.LLM,
  cwd~ : String,
  journal~ : &@agent_session.SessionJournal = @agent_session.InMemorySessionJournal(),
  active_tools~ : ArrayView[String] = [
    BASH_TOOL_NAME,
    @codemode.CODEMODE_TOOL_NAME,
  ],
) -> @agent_session.AgentSession {
  let tool_registry = @tools.ToolRegistry()
  let bash_tool = new_bash_tool_definition(cwd~)
  tool_registry.register_tool(bash_tool)
  let session = @agent_session.AgentSession(
    llm,
    system_prompt_contributes=[
      coding_assistant_system_prompt_contributor(),
      tools_guidelines_system_prompt_contributor(tool_registry),
      project_context_system_prompt_contributor(cwd~),
      skills_system_prompt_contributor(cwd~),
      cwd_system_prompt_contributor(cwd~),
    ],
    journal~,
    tool_registry~,
    active_tools~,
  )
  // 嵌套工具集读 session 的活跃工具表(set_active_tools 可改),
  // 不是构造期快照——否则 codemode 能调到已被停用的工具。
  let resolve_tools = fn() -> Array[@tools.ToolDefinition] {
    let resolved : Array[@tools.ToolDefinition] = []
    for name in session.active_tool_names() {
      if tool_registry.get_tool(name) is Some(tool) {
        resolved.push(tool)
      }
    }
    resolved
  }
  tool_registry.register_tool(
    @codemode.new_codemode_tool_definition(
      callable_tools=fn() { resolve_tools()[:] },
      run_tool=async fn(call, update) {
        @tools.run_tool(
          Map::from_iter(
            resolve_tools().iter().map(fn(tool) { (tool.name, tool) }),
          ),
          call,
          update,
        )
      },
      load_store=fn() { codemode_store(journal) },
      on_store_writes=async fn(writes) {
        ignore(
          journal.append([
            {
              id: journal.generate_id(),
              content: Custom(
                custom_type=@codemode.CODEMODE_STORE_ENTRY_TYPE,
                data=Some(
                  Json(@codemode.CodemodeStoreEntryData::{
                    set: writes.set,
                    delete: writes.delete,
                  }),
                ),
              ),
            },
          ]) catch {
            _ => []
          },
        )
      },
      spill_output=async fn(text) {
        @async.pause()
        let path = try {
          let dir = create_temp_dir("pim-codemode-")
          let path = "\{dir}/output.txt"
          write_bytes_file(path, @utf8.encode(text))
          path
        } catch {
          _ => return None
        }
        Some(path)
      },
    ),
  )
  session
}

///|
/// load() 数据源:顺序回放 journal 里的 codemode-store 条目
/// (对应 pi readCodemodeStore;无分支感知的扁平实现)。
fn codemode_store(
  journal : &@agent_session.SessionJournal,
) -> Map[String, Json] {
  let store : Map[String, Json] = Map([])
  for entry in journal.get_entries() {
    guard entry.content is Custom(custom_type~, data~) &&
      custom_type == @codemode.CODEMODE_STORE_ENTRY_TYPE &&
      data is Some(data) else {
      continue
    }
    let decoded : @codemode.CodemodeStoreEntryData = @json.from_json(data) catch {
      _ => continue
    }
    for key, value in decoded.set {
      store[key] = value
    }
    for key in decoded.delete {
      ignore(store.remove(key))
    }
  }
  store
}
