///|
pub const CODEMODE_TOOL_NAME = "codemode"

///|
/// Where the sidecar script lives: `PIM_CODEMODE_SIDECAR` wins, then
/// `codemode-sidecar.mjs` next to the running entry file (`argv[1]` is the
/// npm layout's `dist/pim.js`; `import.meta.url` would fit better but is
/// module syntax the CJS test bundle cannot parse), then
/// `scripts/codemode-sidecar.mjs` under the working directory so `moon run`
/// from the repo root just works.
pub fn codemode_sidecar_path() -> String {
  match @env.get_env_var("PIM_CODEMODE_SIDECAR") {
    Some(path) if path.length() > 0 => path
    _ => default_codemode_sidecar_path()
  }
}

///|
extern "js" fn default_codemode_sidecar_path() -> String =
  #| () => {
  #|   const fs = process.getBuiltinModule("node:fs");
  #|   const path = process.getBuiltinModule("node:path");
  #|   const candidates = [
  #|     path.join(path.dirname(process.argv[1] ?? ""), "codemode-sidecar.mjs"),
  #|     path.join(process.cwd(), "scripts", "codemode-sidecar.mjs"),
  #|   ];
  #|   return candidates.find((p) => fs.existsSync(p)) ?? candidates[0];
  #| }

///|
/// Spawn the process-wide sidecar: one `node codemode-sidecar.mjs` child
/// multiplexes every execution's VM over these `NdJsonStreams`. Spawning is
/// lazy so sessions that never run `codemode` pay nothing; if the child dies,
/// `run` closes the queues and later `execute`s fail as sandbox errors (no
/// respawn, matching pi's one-remote-per-process posture). The child exits on
/// its own once pim's pipe closes.
fn spawn_codemode_sidecar(
  script : String,
) -> NdJsonStreams[SidecarStdout, SidecarStdin] {
  let process = SidecarProcess::spawn(script)
  let streams = NdJsonStreams::new(process.stdout, process.stdin)
  // Detached: `run` only ends when the child dies. Its failure is observed
  // through closed queues, so the promise's rejection (if any) is swallowed
  // here instead of surfacing as an unhandled rejection.
  ignore(@js_async.Promise::from_async(() => streams.run() catch { _ => () }))
  streams
}

///|
/// The `codemode` tool: the model writes JavaScript that calls the session's
/// other tools. Mirrors pi's extension (coding-agent/.../codemode/tool.ts)
/// with a documented subset:
/// - `tools.<name>` is every `tools` entry except codemode itself; scripts see
///   the tool's description plus its prompt guidelines (upstream renders a
///   full declaration sample; `input_schema`/`output_schema` stay off the
///   wire because the remote protocol's `Tool` record has no schema fields).
/// - A nested call resolves to the tool result's text, or `details` when the
///   text is empty (upstream resolves `structuredContent`; `ToolDefinition`
///   has no output schema to declare it).
/// - `// @options:` on the first line is not parsed; `timeout_ms` applies to
///   the whole execution.
/// - Output keeps the upstream shape: "Script completed|failed" header,
///   `==> text N/M <==` for several text items, one `<console_output>` block;
///   image items pass through as image content instead of temp-file spills.
/// - `store()`/`load()` work within one execution but writes are not
///   persisted to the journal (no `codemode-store` custom entry yet).
pub fn new_codemode_tool_definition(
  tools~ : ArrayView[@tools.ToolDefinition],
  sidecar_path~ : String = codemode_sidecar_path(),
  timeout_ms~ : Int32 = 300000,
) -> @tools.ToolDefinition {
  // Nested calls get synthetic ids under one counter; they never reach the
  // journal, so `codemode-call-N` only needs to be unique per process.
  let call_seq = Ref(0)
  let nested : Array[@codemode.CodemodeTool] = []
  for tool in tools {
    if tool.name == CODEMODE_TOOL_NAME {
      continue
    }
    let description = StringBuilder()
    description.write_string(tool.description)
    for guideline in tool.prompt_guidelines {
      description.write_string("\n- \{guideline}")
    }
    nested.push({
      name: tool.name,
      js_name: None,
      description: description.to_string(),
      input_schema: Some(tool.parameters),
      output_schema: Some({ "type": "string" }),
      spread: false,
      execute: async fn(args : Json?) -> Json {
        call_seq.val += 1
        let result = (tool.execute)(
          "codemode-call-\{call_seq.val}",
          args.unwrap_or(Json::object({})),
          (_, _) => (),
        )
        let text = StringBuilder()
        let mut first = true
        for content in result.content {
          if content is @agent_loop.InputMessageContent::Text(part) {
            if first {
              first = false
            } else {
              text.write_string("\n")
            }
            text.write_string(part)
          }
        }
        let text = text.to_string()
        if result.is_error {
          fail(if text == "" { "Tool \"\{tool.name}\" failed" } else { text })
        }
        if text == "" {
          result.details
        } else {
          Json::string(text)
        }
      },
    })
  }
  let sidecar = @async.Lazy(() => spawn_codemode_sidecar(sidecar_path))
  let codemode = @codemode.Codemode::Codemode(
    async fn() -> &@codemode.Vm { sidecar.wait().new_stream() },
    tools=nested,
    timeout_ms~,
  )
  {
    name: CODEMODE_TOOL_NAME,
    label: CODEMODE_TOOL_NAME,
    prompt_guidelines: [
      "Use codemode to batch independent tool calls (Promise.allSettled), chain them, or filter large output, instead of many separate calls.",
    ],
    description: "Run JavaScript that calls other tools. The input is raw JavaScript (not JSON, no code fence), run as an async function body in a QuickJS sandbox: top-level `await` and `return` work. No Node, file system, network, or timers.\n- `await tools.<name>({ ...args })` resolves to a string and rejects with an Error on failure. Calls still running when the script ends are cancelled.\n- Globals: `text(value)`, `console.log(...)`, `exit()` ends the script, `store(key, value)`/`load(key)` keep JSON values within a run.",
    parameters: {
      "type": "object",
      "properties": {
        "code": { "type": "string", "description": "Raw JavaScript source." },
      },
      "required": ["code"],
      "additionalProperties": false,
    },
    constrained_sampling: @agent_loop.ConstrainedSampling::JsonSchema(
      strict=true,
    ),
    execute: (_, input, _on_update) => execute_codemode_tool(codemode, input),
  }
}

///|
struct CodemodeToolInput {
  code : String
} derive(FromJson)

///|
pub extend CodemodeToolInput with @json.FromJson::{from_json}

///|
async fn execute_codemode_tool(
  codemode : @codemode.Codemode,
  input : Json,
) -> @agent_loop.ToolResult {
  let params : CodemodeToolInput = @json.from_json(input)
  if params.code.length() <= 0 {
    fail("code should not be empty")
  }
  let started_at = @async.now()
  let result = codemode.execute(params.code)
  let wall_ms = @async.now() - started_at
  let wall_seconds = "\{wall_ms / 1000}.\{wall_ms % 1000 / 100}"
  let (ok, value) = match result {
    Ok(value~, ..) => (true, value)
    Err(..) => (false, None)
  }
  let output = match result {
    Ok(output~, ..) | Err(output~, ..) => output
  }
  let content : Array[@agent_loop.InputMessageContent] = [
    @agent_loop.InputMessageContent::Text(
      "\{if ok { "Script completed" } else { "Script failed" }}\nWall time \{wall_seconds} seconds\nOutput:\n",
    ),
  ]
  // pi appends the returned value like a `text()` call.
  let value_item : @codemode.CodemodeOutputItem? = match value {
    Some(String(text)) =>
      Some(@codemode.CodemodeOutputItem::Text(text~, console=false))
    Some(value) =>
      Some(
        @codemode.CodemodeOutputItem::Text(
          text=value.stringify(),
          console=false,
        ),
      )
    None => None
  }
  for item in format_codemode_output(output, value_item~) {
    content.push(item)
  }
  match result {
    Ok(..) => ()
    Err(error~, ..) =>
      content.push(
        @agent_loop.InputMessageContent::Text(
          (
            $|Script error:
            $|\{format_codemode_error(error)}
          ),
        ),
      )
  }
  { content, details: {}, is_error: !ok, usage: None, }
}

///|
/// Lay out the script's output like pi's `formatOutput`: more than one text
/// item gets a `==> text N/M <==` marker, `console.*` lines follow the rest in
/// one `<console_output>` block.
fn format_codemode_output(
  output : ArrayView[@codemode.CodemodeOutputItem],
  value_item~ : @codemode.CodemodeOutputItem?,
) -> Array[@agent_loop.InputMessageContent] {
  let output = match value_item {
    Some(item) => {
      let all = output.to_owned()
      all.push(item)
      all
    }
    None => output.to_owned()
  }
  let mut total = 0
  for item in output {
    if item is Text(console=false, ..) {
      total += 1
    }
  }
  let items : Array[@agent_loop.InputMessageContent] = []
  let console_lines : Array[String] = []
  let mut index = 0
  for item in output {
    match item {
      Text(text~, console=true) => console_lines.push(text)
      Text(text~, console=false) => {
        index += 1
        items.push(
          @agent_loop.InputMessageContent::Text(
            if total > 1 {
              "==> text \{index}/\{total} <==\n\{text}"
            } else {
              text
            },
          ),
        )
      }
      Image(data~, mimeType~) =>
        items.push(
          @agent_loop.InputMessageContent::Image(data~, mime_type=mimeType),
        )
    }
  }
  if console_lines.length() > 0 {
    items.push(
      @agent_loop.InputMessageContent::Text(
        (
          $|<console_output>
          $|\{console_lines.join("\n")}
          $|</console_output>
        ),
      ),
    )
  }
  items
}

///|
/// pi's `formatError` head: script errors show the script's own stack, the
/// other kinds get a prefixed message. Upstream also appends a call summary;
/// the call ledger is not surfaced here yet.
fn format_codemode_error(error : @codemode.CodemodeError) -> String {
  match error.kind {
    Script =>
      error.stack.unwrap_or(
        "\{error.name.unwrap_or("Error")}: \{error.message}",
      )
    Timeout => "Script timed out: \{error.message}"
    Aborted => "Script aborted: \{error.message}"
    Sandbox => "Script sandbox failed: \{error.message}"
  }
}
