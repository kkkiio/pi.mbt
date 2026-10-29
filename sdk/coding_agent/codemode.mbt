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
/// - `tools.<name>` is every `tools` entry except codemode itself; its
///   `ALL_TOOLS` entry is pi's `renderToolSample` output — the description
///   plus `- ` guideline bullets, then the `declare const tools` sample
///   rendered from `input_schema = tool.parameters` and a fixed `string`
///   output schema (the wire `Tool` record only carries `description`, so
///   the schemas ride inside that text). The tool's own `description` is
///   pi's `createCodemodeDescription` minus namespaces/deferred/budget:
///   the intro, a globals summary, then one `### \`id\`` section per tool.
/// - A nested call resolves to the tool result's text, or `details` when the
///   text is empty (upstream resolves `structuredContent`; `ToolDefinition`
///   has no output schema to declare it). An error result — or a raise in
///   `execute` — rejects the script's promise with the error text.
/// - Every nested call leaves a `CodemodeNestedCall`-style row in
///   `details.calls` — id `<tool_call_id>/<n>`, name, a truncated args
///   preview, status running|ok|error|cancelled, durationMs, a truncated
///   error — and the same snapshot is published as the partial result on
///   call start and finish. Calls still running when the script ends are
///   `cancelled`. Nested events never reach the agent loop or journal: the
///   ledger rides inside the parent's `ToolResult.details` instead of
///   upstream's `nestedCalls`/event plumbing.
/// - A nested call is cancelled when the script settles and its `usage`
///   sums into the result's `usage`. External task cancellation
///   stops the remote VM, waits for nested cleanup, and propagates to the caller.
/// - A `// @options: {...}` first line sets `max_output_tokens` and a
///   per-call `timeout_ms`, which overrides `timeout_ms` for that execution.
/// - Output keeps the upstream shape: "Script completed|failed" header,
///   `==> text N/M <==` for several text items, one `<console_output>` block;
///   adjacent text items join on line boundaries, text over the token budget
///   collapses to a head+tail marker plus a spill file, and image items are
///   saved to temp files under a `[Image saved to PATH (mime, size)]` label.
/// - `store()`/`load()` keep JSON values across executions when `journal`
///   is given: the `load()` snapshot is replayed from the journal's
///   `codemode-store` custom entries (malformed ones skipped), and a
///   successful run appends its writes as one new entry.
///
/// `vm_launcher` replaces the sidecar spawn when set — a real transport
/// seam, not just a test hook: hosts that reach the VM over another
/// transport (e.g. the ws streams in sdk/ask_agent) inject their own
/// `&@codemode.VmChannel` source, and `sidecar_path` is then unused.
/// `journal` is the session journal `store()`/`load()` persistence rides
/// on; `None` drops writes.
pub fn new_codemode_tool_definition(
  tools~ : ArrayView[@tools.ToolDefinition],
  journal~ : &@agent_session.SessionJournal? = None,
  sidecar_path~ : String = codemode_sidecar_path(),
  timeout_ms~ : Int32 = 0,
  vm_launcher~ : (async () -> &@codemode.VmChannel)? = None,
) -> @tools.ToolDefinition {
  let launcher : async () -> &@codemode.VmChannel = match vm_launcher {
    Some(launcher) => launcher
    None => {
      let sidecar = @async.Lazy(() => spawn_codemode_sidecar(sidecar_path))
      async fn() -> &@codemode.VmChannel { sidecar.wait().new_stream() }
    }
  }
  {
    name: CODEMODE_TOOL_NAME,
    label: CODEMODE_TOOL_NAME,
    prompt_guidelines: [
      "Use codemode to batch independent tool calls (Promise.allSettled), chain them, or filter large output, instead of many separate calls.",
    ],
    description: codemode_description(tools),
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
    execute: (id, input, on_update) => {
      execute_codemode_tool(
        launcher,
        tools,
        journal,
        timeout_ms~,
        id,
        input,
        on_update,
      )
    },
  }
}

///|
/// pi's `DESCRIPTION_INTRO`. The resolves-to line keeps "a string":
/// pi.mbt's nested declarations fix the output schema at `{"type":"string"}`.
const DESCRIPTION_INTRO : String =
  #|Run JavaScript that calls other tools. The input is raw JavaScript (not JSON, no code fence), run as an async function body in a QuickJS sandbox: top-level `await` and `return` work. No Node, file system, network, or timers.
  #|- `await tools.<name>({ ...args })` resolves to a string and rejects with an Error on failure. Calls still running when the script ends are cancelled.
  #|- Optional first line: `// @options: {"max_output_tokens": 10000, "timeout_ms": 60000}`

///|
/// pi's `describeGlobals` restricted to the globals the prelude implements:
/// no `searchTools`/`describeTool`/`describeNamespace`/`models` lines.
const DESCRIBE_GLOBALS : String =
  #|Globals:
  #|- `text(value)`, `image(dataUrlOrImageBlock)`, `console.log(...)`, and top-level `return` add output; `exit()` ends the script. With several text items, each starts with a `==> text N/M <==` line, and `console` lines follow the other output in one `<console_output>` block. `image()` also saves the image to a temp file and the result names its path.
  #|- `store(key, value)` and `load(key)` keep JSON values across codemode calls.
  #|- `ALL_TOOLS`: every callable tool's `{ name, description }`, where `description` is the same declaration sample as its `Nested tools:` section.

///|
/// pi's `toCodemodeDeclaration`: what a script sees of a tool — the
/// description plus `- ` bullets of the non-empty prompt guidelines,
/// `input_schema` from the tool's parameters, and a fixed `string` output
/// schema (a nested call resolves to result text). `execute` is a render
/// placeholder; real calls go through `nested_codemode_tools`.
fn to_codemode_declaration(
  tool : @tools.ToolDefinition,
) -> @codemode.CodemodeTool {
  let bullets : Array[String] = []
  for guideline in tool.prompt_guidelines {
    let trimmed = guideline.trim()
    if !trimmed.is_empty() {
      bullets.push("- \{trimmed}")
    }
  }
  {
    name: tool.name,
    js_name: None,
    description: if bullets.is_empty() {
      tool.description
    } else {
      "\{tool.description.trim()}\n\n\{bullets.join("\n")}"
    },
    input_schema: Some(tool.parameters),
    output_schema: Some({ "type": "string" }),
    spread: false,
    signature: None,
    execute: fn(_args : Json?) -> Json { Json::null() },
  }
}

///|
/// pi's `renderToolSection`: `### \`id\``, or `### \`id\` (\`raw name\`)`
/// when the script identifier differs from the tool name, followed by the
/// tool's declaration sample.
fn render_tool_section(tool : @codemode.CodemodeTool) -> String {
  let id = @codemode.to_codemode_identifier(tool.name)
  let heading = if id == tool.name {
    "### `\{id}`"
  } else {
    "### `\{id}` (`\{tool.name}`)"
  }
  "\{heading}\n\{@codemode.render_tool_sample(tool).trim()}"
}

///|
/// pi's `createCodemodeDescription` restricted to what pi.mbt implements:
/// the intro, the globals summary, then a `Nested tools:` section with one
/// `### \`id\`` entry per callable tool. pi.mbt has no loadout, so the tool
/// list is fixed at definition time and namespaces/deferred/budget do not
/// apply.
fn codemode_description(tools : ArrayView[@tools.ToolDefinition]) -> String {
  let sections : Array[String] = [DESCRIPTION_INTRO, DESCRIBE_GLOBALS]
  let tool_sections : Array[String] = []
  for tool in tools {
    if tool.name == CODEMODE_TOOL_NAME {
      continue
    }
    tool_sections.push(render_tool_section(to_codemode_declaration(tool)))
  }
  if !tool_sections.is_empty() {
    tool_sections.insert(0, "Nested tools:")
    sections.push(tool_sections.join("\n\n"))
  }
  sections.join("\n\n")
}

///|
/// pi's `readCodemodeStore` + `isStoreEntryData`: replay the journal's
/// `codemode-store` custom entries in order into the `load()` snapshot —
/// each entry deletes its keys, then applies its `set` object. Entries whose
/// data is not `{set: object, delete: [strings]}` are skipped.
fn read_codemode_store(
  journal : &@agent_session.SessionJournal,
) -> Map[String, Json] {
  let store : Map[String, Json] = Map([])
  for entry in journal.get_entries() {
    guard entry.content
      is @agent_session.SessionEntryContent::Custom(
        custom_type~,
        data=Some(Object(fields))
      ) &&
      custom_type == "codemode-store" &&
      fields.get("set") is Some(Object(set)) &&
      fields.get("delete") is Some(Array(deleted)) &&
      deleted.iter().all(key => key is String(_)) else {
      continue
    }
    for key in deleted {
      if key is String(key) {
        store.remove(key)
      }
    }
    for key, value in set {
      store[key] = value
    }
  }
  store
}

///|
/// pi's `appendEntry(CODEMODE_STORE_ENTRY_TYPE, ...)`: persist a successful
/// run's `store()` writes as one `codemode-store` custom entry,
/// `{set: {...}, delete: [...]}` like upstream `CodemodeStoreEntryData`.
async fn append_codemode_store(
  journal : &@agent_session.SessionJournal,
  writes : @codemode.CodemodeStoreWrites,
) -> Unit {
  if writes.set.is_empty() && writes.delete.is_empty() {
    return
  }
  ignore(
    journal.append([
      {
        id: journal.generate_id(),
        content: @agent_session.SessionEntryContent::Custom(
          custom_type="codemode-store",
          data=Some(
            Json::object({
              "set": Json::object(writes.set),
              "delete": Json::array(writes.delete.map(key => Json::string(key))),
            }),
          ),
        ),
      },
    ]),
  )
}

///|
struct CodemodeToolInput {
  code : String
} derive(FromJson)

///|
pub extend CodemodeToolInput with @json.FromJson::{from_json}

///|
/// pi's `CodemodeNestedCall`: one `tools.*` call's row in `details.calls`.
priv struct CodemodeNestedCall {
  /// `<codemode tool call id>/<n>`.
  id : String
  name : String
  /// Compact JSON of the arguments, truncated for display.
  args : String
  /// `"running" | "ok" | "error" | "cancelled"`.
  mut status : String
  mut duration_ms : Int32?
  /// Error text, truncated for display.
  mut error : String?
}

///|
/// `{id, name, args, status, durationMs?, error?}` — optional fields only
/// when set, matching pi's `CodemodeNestedCall`.
fn nested_call_json(call : CodemodeNestedCall) -> Json {
  let obj : Map[String, Json] = {
    "id": Json::string(call.id),
    "name": Json::string(call.name),
    "args": Json::string(call.args),
    "status": Json::string(call.status),
  }
  if call.duration_ms is Some(duration_ms) {
    obj["durationMs"] = Json(duration_ms)
  }
  if call.error is Some(error) {
    obj["error"] = Json::string(error)
  }
  Json::object(obj)
}

///|
/// pi's `DEFAULT_MAX_OUTPUT_TOKENS`/`CHARS_PER_TOKEN`:脚本输出的默认 token
/// 预算和字符折算。
const DEFAULT_MAX_OUTPUT_TOKENS : Int64 = 10000

///|
const CHARS_PER_TOKEN : Int64 = 4

///|
/// pi's `ARGS_PREVIEW_CHARS`/`ERROR_PREVIEW_CHARS`:nested call 行上 args 与
/// error 的截断长度。
const ARGS_PREVIEW_CHARS : Int32 = 200

///|
const ERROR_PREVIEW_CHARS : Int32 = 500

///|
/// Run one script end to end: parse the source, run it on a fresh VM with
/// the session's tools as `tools.*`, and fold the outcome into pi's
/// tool-result shape. `on_update` receives the nested-call ledger as the
/// partial result (`{ calls: [...] }`), first before the script starts —
/// pi shows the row as running — then on every call start and finish.
/// External task cancellation propagates after the VM and nested calls clean up.
async fn execute_codemode_tool(
  launcher : async () -> &@codemode.VmChannel,
  tools : ArrayView[@tools.ToolDefinition],
  journal : &@agent_session.SessionJournal?,
  timeout_ms~ : Int32,
  tool_call_id : String,
  input : Json,
  on_update : @agent_loop.ToolExecUpdateCallback,
) -> @agent_loop.ToolResult {
  let params : CodemodeToolInput = @json.from_json(input)
  let started_at = @async.now()
  let parsed = @codemode.parse_codemode_source(params.code) catch {
    error =>
      return {
        content: [
          @agent_loop.InputMessageContent::Text(
            "Script failed\nWall time 0.0 seconds\nOutput:\n",
          ),
          @agent_loop.InputMessageContent::Text(
            "Script error:\n\{error.to_string()}",
          ),
        ],
        details: {},
        is_error: true,
        usage: None,
      }
  }
  let calls : Array[CodemodeNestedCall] = []
  let usage : Ref[@agent_loop.Usage?] = Ref(None)
  let publish = () => {
    on_update([], { "calls": Json::array(calls.map(nested_call_json)) })
  }
  publish()
  let codemode = @codemode.Codemode::Codemode(
    launcher,
    tools=nested_codemode_tools(tools, tool_call_id, calls, publish, usage),
    timeout_ms~,
  )
  let store = match journal {
    Some(journal) => read_codemode_store(journal)
    None => Map([])
  }
  let result = codemode.execute(
    parsed.code,
    store~,
    timeout_ms=parsed.options.timeout_ms,
  )
  if result is Ok(store_writes~, ..) && journal is Some(journal) {
    append_codemode_store(journal, store_writes)
  }
  let wall_ms = @async.now() - started_at
  let tenths = (wall_ms + 50) / 100
  let wall_seconds = "\{tenths / 10}.\{tenths % 10}"
  let (ok, value) = match result {
    Ok(value~, ..) => (true, value)
    Err(..) => (false, None)
  }
  let output = match result {
    Ok(output~, ..) | Err(output~, ..) => output
  }
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
  let items = format_codemode_output(output, value_item~)
  if result is Err(error~, calls=sandbox_calls, ..) {
    items.push(
      @agent_loop.InputMessageContent::Text(
        "Script error:\n\{format_codemode_error(error)}\n\n\{format_call_summary(sandbox_calls)}",
      ),
    )
  }
  let truncated = truncate_codemode_output(
    join_adjacent_text(items),
    parsed.options.max_output_tokens.unwrap_or(DEFAULT_MAX_OUTPUT_TOKENS),
  )
  let output_items = join_adjacent_text(save_codemode_images(truncated.items))
  let content : Array[@agent_loop.InputMessageContent] = [
    @agent_loop.InputMessageContent::Text(
      "\{if ok { "Script completed" } else { "Script failed" }}\nWall time \{wall_seconds} seconds\nOutput:\n",
    ),
  ]
  for item in output_items {
    content.push(item)
  }
  let details : Map[String, Json] = {
    "calls": Json::array(calls.map(nested_call_json)),
  }
  if truncated.full_output_path is Some(path) {
    details["fullOutputPath"] = Json::string(path)
  }
  { content, details: Json::object(details), is_error: !ok, usage: usage.val, }
}

///|
/// pi's `sandboxTools`: every session tool except codemode itself becomes a
/// `tools.<name>` whose `description` (the `ALL_TOOLS` entry) is the tool's
/// `renderToolSample` output. `execute` records a `CodemodeNestedCall` row, republishes
/// the ledger on the nested tool's own partial updates (nested partial
/// content does not merge into the parent result — upstream shows it as a
/// nested row update only), runs the tool in the execution's task group,
/// sums its `usage`, and resolves like `toScriptValue`: the text content,
/// or `details` when the text is empty.
fn nested_codemode_tools(
  tools : ArrayView[@tools.ToolDefinition],
  tool_call_id : String,
  calls : Array[CodemodeNestedCall],
  publish : () -> Unit,
  usage : Ref[@agent_loop.Usage?],
) -> Array[@codemode.CodemodeTool] {
  let nested : Array[@codemode.CodemodeTool] = []
  for tool in tools {
    if tool.name == CODEMODE_TOOL_NAME {
      continue
    }
    let declaration = to_codemode_declaration(tool)
    nested.push({
      name: tool.name,
      js_name: None,
      description: @codemode.render_tool_sample(declaration),
      input_schema: declaration.input_schema,
      output_schema: declaration.output_schema,
      spread: false,
      signature: None,
      execute: async fn(args : Json?) -> Json {
        let record = CodemodeNestedCall::{
          id: "\{tool_call_id}/\{calls.length() + 1}",
          name: tool.name,
          args: preview_nested_args(args),
          status: "running",
          duration_ms: None,
          error: None,
        }
        calls.push(record)
        publish()
        let started_at = @async.now()
        defer (if record.status == "running" {
          record.status = "cancelled"
          record.duration_ms = Some((@async.now() - started_at).to_int())
        })
        let result = (tool.execute)(
          record.id,
          args.unwrap_or(Json::object({})),
          (_, _) => publish(),
        ) catch {
          error if @async.is_being_cancelled() => raise error
          error =>
            @agent_loop.ToolResult::{
              content: [
                @agent_loop.InputMessageContent::Text(error.to_string()),
              ],
              details: {},
              is_error: true,
              usage: None,
            }
        }
        record.duration_ms = Some((@async.now() - started_at).to_int())
        if result.usage is Some(u) {
          usage.val = Some(
            match usage.val {
              Some(total) => combine_usage(total, u)
              None => u
            },
          )
        }
        let text = tool_result_text(result)
        if result.is_error {
          let error_text = if text == "" {
            "Tool \"\{tool.name}\" failed"
          } else {
            text
          }
          record.status = "error"
          record.error = Some(truncate_preview(error_text, ERROR_PREVIEW_CHARS))
          publish()
          fail(error_text)
        }
        record.status = "ok"
        publish()
        if text == "" {
          result.details
        } else {
          Json::string(text)
        }
      },
    })
  }
  nested
}

///|
/// pi's `textOf`: the text blocks of a tool result joined on newlines.
fn tool_result_text(result : @agent_loop.ToolResult) -> String {
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
  text.to_string()
}

///|
/// pi's `previewArgs`: compact JSON of the call arguments, truncated for
/// display; `undefined` arguments preview as the empty string.
fn preview_nested_args(args : Json?) -> String {
  match args {
    None => ""
    Some(args) => truncate_preview(args.stringify(), ARGS_PREVIEW_CHARS)
  }
}

///|
/// pi's `truncateText`: `text[:max-3] + "..."` when over `max_chars`.
fn truncate_preview(text : String, max_chars : Int32) -> String {
  if text.length() > max_chars {
    "\{text[:max_chars - 3]}..."
  } else {
    text
  }
}

///|
/// pi's `combineUsage`: sum two usages, keeping the optional token splits
/// when either side reports them.
fn combine_usage(
  first : @agent_loop.Usage,
  second : @agent_loop.Usage,
) -> @agent_loop.Usage {
  let opt = fn(a : Int32?, b : Int32?) -> Int32? {
    match (a, b) {
      (None, None) => None
      (a, b) => Some(a.unwrap_or(0) + b.unwrap_or(0))
    }
  }
  {
    input: first.input + second.input,
    output: first.output + second.output,
    cache_read: first.cache_read + second.cache_read,
    cache_write: first.cache_write + second.cache_write,
    cache_write_1h: opt(first.cache_write_1h, second.cache_write_1h),
    reasoning: opt(first.reasoning, second.reasoning),
    total_tokens: first.total_tokens + second.total_tokens,
    cost: {
      input: first.cost.input + second.cost.input,
      output: first.cost.output + second.cost.output,
      cache_read: first.cost.cache_read + second.cost.cache_read,
      cache_write: first.cost.cache_write + second.cost.cache_write,
      total: first.cost.total + second.cost.total,
    },
  }
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
/// other kinds get a prefixed message.
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

///|
/// pi's `formatCallSummary`:失败时附带 nested call 台账。
fn format_call_summary(calls : ArrayView[@codemode.CodemodeCall]) -> String {
  if calls.is_empty() {
    return "No tool calls were made."
  }
  let entries : Array[String] = []
  for call in calls {
    entries.push("\{call.name} (\{call.status})")
  }
  "Tool calls made before the failure (they are not undone): \{entries.join(", ")}"
}

///|
/// pi's `joinAdjacentText`:相邻 text 项合成一项,每段从新行开始。分隔判断
/// 看上一个非空段而不是已拼接文本的结尾(读不断变长的拼接串是平方复杂度,
/// pi #10678)。
fn join_adjacent_text(
  items : Array[@agent_loop.InputMessageContent],
) -> Array[@agent_loop.InputMessageContent] {
  let joined : Array[@agent_loop.InputMessageContent] = []
  let parts : Array[String] = []
  let last_part = Ref("")
  let flush = () => {
    if !parts.is_empty() {
      joined.push(@agent_loop.InputMessageContent::Text(parts.join("")))
    }
    parts.clear()
    last_part.val = ""
  }
  for item in items {
    match item {
      @agent_loop.InputMessageContent::Text(text) => {
        if last_part.val != "" && !last_part.val.has_suffix("\n") {
          parts.push("\n")
          last_part.val = "\n"
        }
        parts.push(text)
        if text != "" {
          last_part.val = text
        }
      }
      _ => {
        flush()
        joined.push(item)
      }
    }
  }
  flush()
  joined
}

///|
/// pi's `truncateOutput` 的返回值:`items` 是把文本项折叠后的最终项,
/// `full_output_path` 是全文溢出文件(写成功才有)。
priv struct TruncatedScriptOutput {
  items : Array[@agent_loop.InputMessageContent]
  full_output_path : String?
}

///|
/// pi's `truncateOutput`:合并文本超过 token 预算时,所有文本项折成一项
/// (头尾各保留一半预算),完整文本写到溢出文件;图片项跟在后面。
fn truncate_codemode_output(
  items : Array[@agent_loop.InputMessageContent],
  max_tokens : Int64,
) -> TruncatedScriptOutput {
  let texts : Array[String] = []
  for item in items {
    if item is @agent_loop.InputMessageContent::Text(text) {
      texts.push(text)
    }
  }
  let combined = texts.join("\n")
  let budget = max_tokens * CHARS_PER_TOKEN
  if texts.is_empty() || combined.length().to_int64() <= budget {
    return { items, full_output_path: None, }
  }
  let head_chars = (budget / 2).to_int()
  let tail_chars = (budget - head_chars.to_int64()).to_int()
  let removed = combined.length() - head_chars - tail_chars
  let head = combined[:head_chars]
  let tail = if tail_chars > 0 {
    combined[combined.length() - tail_chars:]
  } else {
    ""[:]
  }
  let original_tokens = (combined.length().to_int64() + CHARS_PER_TOKEN - 1) /
    CHARS_PER_TOKEN
  let removed_tokens = (removed.to_int64() + CHARS_PER_TOKEN - 1) /
    CHARS_PER_TOKEN
  let mut text = "Warning: truncated output (original token count: \{original_tokens})\nTotal output lines: \{combined.split("\n").count()}\n\n\{head}…\{removed_tokens} tokens truncated…\{tail}"
  let spilled : Result[String, String] = Ok(
    write_codemode_output_file(".log", @utf8.encode(combined)),
  ) catch {
    error => Err(error.to_string())
  }
  let full_output_path = match spilled {
    Ok(path) => {
      text = text + "\n\n[Full output: \{path} (read with offset/limit)]"
      Some(path)
    }
    Err(message) => {
      text = text + "\n\n[Could not save the full output: \{message}]"
      None
    }
  }
  let kept : Array[@agent_loop.InputMessageContent] = [
    @agent_loop.InputMessageContent::Text(text),
  ]
  for item in items {
    if item is @agent_loop.InputMessageContent::Image(..) {
      kept.push(item)
    }
  }
  { items: kept, full_output_path, }
}

///|
/// pi's `IMAGE_EXTENSIONS`:`image()` 接受的图片类型对应的文件扩展名。
fn codemode_image_extension(mime_type : String) -> String? {
  match mime_type {
    "image/png" => Some(".png")
    "image/jpeg" => Some(".jpg")
    "image/gif" => Some(".gif")
    "image/webp" => Some(".webp")
    _ => None
  }
}

///|
/// pi's `formatSize`(core/tools/truncate.ts)。
fn format_size(bytes : Int32) -> String {
  if bytes < 1024 {
    "\{bytes}B"
  } else if bytes < 1024 * 1024 {
    let scaled = (bytes * 10 + 512) / 1024
    "\{scaled / 10}.\{scaled % 10}KB"
  } else {
    let scaled = (bytes * 10 + 524288) / 1048576
    "\{scaled / 10}.\{scaled % 10}MB"
  }
}

///|
/// 把脚本产出写到 `<tmpdir>/pi-codemode-<random>/output<extension>`
/// (目录 0700、文件 0600、不覆盖已有文件),返回文件路径。
fn write_codemode_output_file(
  extension : String,
  data : Bytes,
) -> String raise FsError {
  let directory = create_temp_dir("pi-codemode-")
  let path = "\{directory}/output\{extension}"
  let file = create_file(path)
  defer file.close()
  file.write_bytes(data)
  path
}

///|
/// pi's `saveImages`:每个图片项落盘成临时文件,并在图片前插一个 text 项
/// 记录路径。图片在脚本里拿不到字节(脚本不能写文件,`write` 只收文本),
/// 这是模型唯一够得着字节的方式。同一份 data 只保存一次;写失败降级为
/// label 文本而不是丢掉结果。
fn save_codemode_images(
  items : Array[@agent_loop.InputMessageContent],
) -> Array[@agent_loop.InputMessageContent] {
  let labels : Map[String, String] = Map([])
  let result : Array[@agent_loop.InputMessageContent] = []
  for item in items {
    guard item is @agent_loop.InputMessageContent::Image(data~, mime_type~) else {
      result.push(item)
      continue
    }
    let label = match labels.get(data) {
      Some(label) => label
      None => {
        let label = save_codemode_image(data, mime_type)
        labels[data] = label
        label
      }
    }
    result.push(@agent_loop.InputMessageContent::Text(label))
    result.push(item)
  }
  result
}

///|
/// pi's `saveImages` 的单张 label:保存成功是
/// `[Image saved to PATH (mimeType, SIZE)]`,失败是
/// `[Image (mimeType, SIZE) could not be saved: err]`。
fn save_codemode_image(data : String, mime_type : String) -> String {
  let bytes = @base64.decode_lossy(data)
  let kind = "\{mime_type}, \{format_size(bytes.length())}"
  match codemode_image_extension(mime_type) {
    Some(extension) =>
      try {
        let path = write_codemode_output_file(extension, bytes)
        "[Image saved to \{path} (\{kind})]"
      } catch {
        error => "[Image (\{kind}) could not be saved: \{error.to_string()}]"
      }
    None =>
      "[Image (\{kind}) could not be saved: No file extension for image type \{mime_type}]"
  }
}
