///|
pub const CODEMODE_TOOL_NAME = "codemode"

///|
/// Writes `bytes` for a spilled output or image and returns its path.
/// `None` keeps truncated output pathless and images inline.
pub type TempFileWriter = (String, Bytes) -> Result[String, String]

///|
pub fn new_codemode_tool_definition(
  launcher : async () -> &@codemode.VmChannel,
  tools~ : ArrayView[@tools.ToolDefinition],
  journal~ : &@agent_session.SessionJournal? = None,
  timeout_ms~ : Int32 = 0,
  write_temp_file~ : TempFileWriter? = None,
) -> @tools.ToolDefinition {
  {
    name: CODEMODE_TOOL_NAME,
    label: CODEMODE_TOOL_NAME,
    prompt_guidelines: [
      "Use codemode to batch independent tool calls (Promise.allSettled), chain them, or filter large output, instead of many separate calls.",
    ],
    description: codemode_description(tools, write_temp_file~),
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
        write_temp_file~,
        id,
        input,
        on_update,
      )
    },
  }
}

///|
const DESCRIPTION_INTRO : String =
  #|Run JavaScript that calls other tools. The input is raw JavaScript (not JSON, no code fence), run as an async function body in a QuickJS sandbox: top-level `await` and `return` work. No Node, file system, network, or timers.
  #|- `await tools.<name>({ ...args })` resolves to a string and rejects with an Error on failure. Calls still running when the script ends are cancelled.
  #|- Optional first line: `// @options: {"max_output_tokens": 10000, "timeout_ms": 60000}`

///|
fn describe_globals(write_temp_file : TempFileWriter?) -> String {
  let image_note = if write_temp_file is Some(_) {
    "`image()` also saves the image to a temp file and the result names its path."
  } else {
    "`image()` adds the image to the output."
  }
  "Globals:\n- `text(value)`, `image(dataUrlOrImageBlock)`, `console.log(...)`, and top-level `return` add output; `exit()` ends the script. With several text items, each starts with a `==> text N/M <==` line, and `console` lines follow the other output in one `<console_output>` block. \{image_note}\n- `store(key, value)` and `load(key)` keep JSON values across codemode calls.\n- `ALL_TOOLS`: every callable tool's `{ name, description }`, where `description` is the same declaration sample as its `Nested tools:` section."
}

///|
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
fn codemode_description(
  tools : ArrayView[@tools.ToolDefinition],
  write_temp_file~ : TempFileWriter?,
) -> String {
  let sections : Array[String] = [
    DESCRIPTION_INTRO,
    describe_globals(write_temp_file),
  ]
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
priv struct CodemodeNestedCall {
  id : String
  name : String
  args : String
  mut status : String
  mut duration_ms : Int32?
  mut error : String?
}

///|
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
const DEFAULT_MAX_OUTPUT_TOKENS : Int64 = 10000

///|
const CHARS_PER_TOKEN : Int64 = 4

///|
const ARGS_PREVIEW_CHARS : Int32 = 200

///|
const ERROR_PREVIEW_CHARS : Int32 = 500

///|
async fn execute_codemode_tool(
  launcher : async () -> &@codemode.VmChannel,
  tools : ArrayView[@tools.ToolDefinition],
  journal : &@agent_session.SessionJournal?,
  timeout_ms~ : Int32,
  write_temp_file~ : TempFileWriter?,
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
    write_temp_file~,
  )
  let output_items = join_adjacent_text(
    save_codemode_images(truncated.items, write_temp_file~),
  )
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
fn preview_nested_args(args : Json?) -> String {
  match args {
    None => ""
    Some(args) => truncate_preview(args.stringify(), ARGS_PREVIEW_CHARS)
  }
}

///|
fn truncate_preview(text : String, max_chars : Int32) -> String {
  if text.length() > max_chars {
    "\{text[:max_chars - 3]}..."
  } else {
    text
  }
}

///|
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
priv struct TruncatedScriptOutput {
  items : Array[@agent_loop.InputMessageContent]
  full_output_path : String?
}

///|
fn truncate_codemode_output(
  items : Array[@agent_loop.InputMessageContent],
  max_tokens : Int64,
  write_temp_file~ : TempFileWriter?,
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
  let full_output_path = match write_temp_file {
    Some(write) =>
      match write(".log", @utf8.encode(combined)) {
        Ok(path) => {
          text = text + "\n\n[Full output: \{path} (read with offset/limit)]"
          Some(path)
        }
        Err(message) => {
          text = text + "\n\n[Could not save the full output: \{message}]"
          None
        }
      }
    None => None
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
fn save_codemode_images(
  items : Array[@agent_loop.InputMessageContent],
  write_temp_file~ : TempFileWriter?,
) -> Array[@agent_loop.InputMessageContent] {
  let labels : Map[String, String] = Map([])
  let result : Array[@agent_loop.InputMessageContent] = []
  for item in items {
    guard item is @agent_loop.InputMessageContent::Image(data~, mime_type~) else {
      result.push(item)
      continue
    }
    guard write_temp_file is Some(write) else {
      result.push(item)
      continue
    }
    let label = match labels.get(data) {
      Some(label) => label
      None => {
        let label = save_codemode_image(data, mime_type, write)
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
fn save_codemode_image(
  data : String,
  mime_type : String,
  write : TempFileWriter,
) -> String {
  let bytes = @base64.decode_lossy(data)
  let kind = "\{mime_type}, \{format_size(bytes.length())}"
  match codemode_image_extension(mime_type) {
    Some(extension) =>
      match write(extension, bytes) {
        Ok(path) => "[Image saved to \{path} (\{kind})]"
        Err(message) => "[Image (\{kind}) could not be saved: \{message}]"
      }
    None =>
      "[Image (\{kind}) could not be saved: No file extension for image type \{mime_type}]"
  }
}
