///|
/// 构建 codemode ToolDefinition(对应 pi createCodemodeToolDefinition +
/// executeCodemode;去掉 models.* / 发现系 globals / worker 准入,namespace
/// 与 inline budget 暂不移植——本包 ToolDefinition 没有这些概念)。
///
/// - callable_tools:每次执行时求值的脚本可调用工具集,实现需剔除
///   codemode 自身(本函数会再过滤一次)。用 getter 而非快照,因为
///   active tools 可变;description 的工具目录在构建时取一次快照。
/// - run_tool:嵌套调用入口,传 session 的工具管线(与 Agent 的
///   tool_executor 同形),校验/权限等行为与直接调用一致。
/// - load_store:load() 的数据源,装配层从 journal 的 codemode-store
///   条目回放得到。
/// - on_store_writes:脚本成功后的 store 净写入回调,装配层把它持久化为
///   codemode-store custom entry;默认丢弃。
/// - spill_output:输出超 max_output_tokens 预算时完整文本落盘,返回给
///   模型看的 "[Full output: ...]" 提示;None 表示落盘失败,默认丢弃。
/// - launch:VM 启动器;默认用平台实现(js=pi worker,native=内嵌
///   QuickJS),测试注入脚本化 faux VM。
///
/// 产出固定:name="codemode"、parameters=codemode_parameters、
/// constrained_sampling=Grammar(Lark, CODEMODE_SOURCE_GRAMMAR, "code")。
pub fn new_codemode_tool_definition(
  callable_tools~ : () -> ArrayView[@tools.ToolDefinition],
  run_tool~ : async (@agent_loop.ToolCall, @agent_loop.ToolExecUpdateCallback) -> @agent_loop.ToolResult,
  load_store~ : () -> Map[String, Json] = fn() { Map([]) },
  on_store_writes~ : async (CodemodeStoreWrites) -> Unit = _ => (),
  spill_output~ : async (String) -> String? = _ => None,
  launch~ : VmLauncher? = None,
) -> @tools.ToolDefinition {
  @tools.ToolDefinition::{
    name: CODEMODE_TOOL_NAME,
    label: "Codemode",
    prompt_guidelines: [
      "Use codemode to batch independent tool calls (Promise.allSettled), chain them, or filter large output, instead of many separate calls.",
    ],
    description: codemode_description(callable_tools()),
    parameters: codemode_parameters,
    constrained_sampling: @agent_loop.ConstrainedSampling::Grammar(
      format=@agent_loop.Lark,
      definition=CODEMODE_SOURCE_GRAMMAR,
      input_property="code",
    ),
    execute: async fn(
      tool_call_id : String,
      arguments : Json,
      on_update : @agent_loop.ToolExecUpdateCallback,
    ) -> @agent_loop.ToolResult {
      let started_at = @async.now()
      let calls : Array[CodemodeNestedCall] = []
      let publish = fn(details : CodemodeToolDetails) {
        on_update([], details.to_json())
      }
      publish({ calls, full_output_path: None, })
      // code 参数提取 + @options 行解析;失败即错误结果(脚本未启动)。
      guard arguments is Object(fields) &&
        fields.get("code") is Some(String(code)) else {
        return script_error_result(
          calls, started_at, "Invalid codemode input: expected { \"code\": <javascript source> }",
        )
      }
      let parsed = parse_codemode_source(code) catch {
        CodemodeSourceError(message) =>
          return script_error_result(calls, started_at, message)
      }
      // 嵌套调用记录与工具桥(对应 pi sandboxTools 的 execute 闭包)。
      let call_seq = Ref(0)
      let sandbox_tools : Array[CodemodeTool] = []
      for tool in callable_tools() {
        if tool.name == CODEMODE_TOOL_NAME {
          continue
        }
        sandbox_tools.push(
          CodemodeTool::new(
            name=tool.name,
            description=sample_of(tool),
            input_schema=Some(tool.parameters),
            output_schema=Some(text_output_schema),
            execute=async fn(args, ctx) {
              call_seq.val = call_seq.val + 1
              let record : CodemodeNestedCall = {
                id: "\{tool_call_id}/\{call_seq.val}",
                name: tool.name,
                args: preview_args(args),
                status: Running,
                duration_ms: None,
                error: None,
              }
              calls.push(record)
              publish({ calls, full_output_path: None, })
              let call_started = @async.now()
              let result = run_tool(
                {
                  id: record.id,
                  name: tool.name,
                  arguments: args.unwrap_or(Json::null()),
                },
                fn(_content, _detail) {
                  publish({ calls, full_output_path: None, })
                },
              )
              record.duration_ms = Some(
                (@async.now() - call_started).to_double(),
              )
              let text = result_text(result)
              if result.is_error {
                record.status = if ctx.signal.is_aborted() {
                  Cancelled
                } else {
                  Error
                }
                record.error = Some(truncate_text(text, ERROR_PREVIEW_CHARS))
                publish({ calls, full_output_path: None, })
                raise Failure::Failure(
                  if text == "" {
                    "Tool \"\{tool.name}\" failed"
                  } else {
                    text
                  },
                )
              }
              record.status = Ok
              publish({ calls, full_output_path: None, })
              Some(Json(text))
            },
          ),
        )
      }
      // 每次执行一个新沙箱(对应 pi);宿主协程取消经 execute 的 errdefer
      // 收尾为 Aborted 后再向上传播,与 tool_executor 取消语义一致。
      let launcher = launch.unwrap_or_else(fn() { default_vm_launcher() })
      let sandbox = CodemodeSandbox::with_launcher(
        launch=launcher,
        tools=sandbox_tools,
      ) catch {
        error =>
          return script_error_result(calls, started_at, error_message(error))
      }
      let result = sandbox.execute(
        parsed.code,
        timeout_ms=parsed.options.timeout_ms,
        store=load_store(),
      ) catch {
        error =>
          CodemodeResult::Err(
            error={
              kind: Sandbox,
              name: None,
              message: error_message(error),
              stack: None,
            },
            output=[],
            calls=[],
          )
      }
      // 脚本结束时仍在 running 的嵌套调用记为 cancelled。
      for call in calls {
        if call.status is Running {
          call.status = Cancelled
        }
      }
      // 输出装配:脚本产出 + 成功的 return 值 / 失败的 error 段
      // (对应 pi scriptOutput + formatOutput + Script error 追加)。
      let ok = result is CodemodeResult::Ok(..)
      let items : Array[@agent_loop.InputMessageContent] = []
      let output = match result {
        Ok(output~, ..) => output
        Err(output~, ..) => output
      }
      for item in output {
        match item {
          CodemodeOutputItem::Text(text~, console~) =>
            items.push(
              @agent_loop.InputMessageContent::Text(
                if console {
                  "<console>\{text}"
                } else {
                  text
                },
              ),
            )
          CodemodeOutputItem::Image(data~, mime_type~) => {
            let decoded : Bytes? = Some(@base64.decode(data)) catch {
              _ => None
            }
            match decoded {
              Some(bytes) =>
                items.push(@agent_loop.InputMessageContent::Image(bytes))
              None =>
                items.push(
                  @agent_loop.InputMessageContent::Text(
                    "[Image (\{mime_type}) could not be decoded]",
                  ),
                )
            }
          }
        }
      }
      match result {
        Ok(value~, store_writes~, ..) => {
          if value is Some(value) {
            items.push(@agent_loop.InputMessageContent::Text(value_text(value)))
          }
          if !store_writes.set.is_empty() || !store_writes.delete.is_empty() {
            on_store_writes(store_writes)
          }
        }
        Err(error~, ..) =>
          items.push(
            @agent_loop.InputMessageContent::Text(
              "Script error:\n\{format_error(error, calls)}",
            ),
          )
      }
      // 截断:文本合并按 token 预算留头尾,图片不受影响;全文经
      // spill_output 落盘(对应 pi truncateOutput)。
      let mut full_output_path : String? = None
      let budget_chars = parsed.options.max_output_tokens
        .unwrap_or(DEFAULT_MAX_OUTPUT_TOKENS)
        .to_int64() *
        4
      let texts = items
        .iter()
        .filter_map(fn(item) {
          if item is @agent_loop.InputMessageContent::Text(t) {
            Some(t)
          } else {
            None
          }
        })
        .collect()
      let combined = texts.join("\n")
      let status_word = if ok { "Script completed" } else { "Script failed" }
      let final_items = if combined.length().to_int64() <= budget_chars {
        items
      } else {
        let budget = budget_chars.to_int()
        let head_chars = budget / 2
        let tail_chars = budget - head_chars
        let head = combined[:head_chars].to_owned()
        let tail = if tail_chars > 0 {
          combined[combined.length() - tail_chars:].to_owned()
        } else {
          ""
        }
        let removed_tokens = (combined.length() - head_chars - tail_chars + 3) /
          4
        let mut text =
          $|Warning: truncated output (original token count: \{(combined.length() + 3) / 4})
          $|Total output lines: \{combined.split("\n").count()}
          $|
          $|\{head}…\{removed_tokens} tokens truncated…\{tail}
        let spilled : String? = spill_output(combined) catch { _ => None }
        match spilled {
          Some(path) => {
            full_output_path = Some(path)
            text = text + "\n\n[Full output: \{path} (read with offset/limit)]"
          }
          None => text = text + "\n\n[Could not save the full output]"
        }
        let truncated : Array[@agent_loop.InputMessageContent] = [
          @agent_loop.InputMessageContent::Text(text),
        ]
        for item in items {
          if item is @agent_loop.InputMessageContent::Image(_) {
            truncated.push(item)
          }
        }
        truncated
      }
      {
        content: [
          @agent_loop.InputMessageContent::Text(
            "\{status_word}\nWall time \{wall_seconds(started_at)} seconds\nOutput:\n",
          ),
          ..final_items,
        ],
        details: { calls, full_output_path, }.to_json(),
        is_error: !ok,
        usage: None,
      }
    },
  }
}

///|
/// 嵌套调用的结果文本:文本块按行拼接(对应 pi textOf + toScriptValue 的
/// "无 outputSchema 走文本"分支;本包 ToolResult 无 structuredContent 概念)。
fn result_text(result : @agent_loop.ToolResult) -> String {
  result.content
  .iter()
  .filter_map(fn(item) {
    if item is @agent_loop.InputMessageContent::Text(t) {
      Some(t)
    } else {
      None
    }
  })
  .collect()
  .join("\n")
}

///|
/// 脚本未启动的错误结果(对应 pi executeCodemode 的 admission 失败分支)。
fn script_error_result(
  calls : Array[CodemodeNestedCall],
  started_at : Int64,
  message : String,
) -> @agent_loop.ToolResult {
  @agent_loop.ToolResult::{
    content: [
      @agent_loop.InputMessageContent::Text(
        "Script failed\nWall time \{wall_seconds(started_at)} seconds\nOutput:\n",
      ),
      @agent_loop.InputMessageContent::Text(
        "Script error:\n\{message}\n\nThe script did not start.",
      ),
    ],
    details: { calls, full_output_path: None, }.to_json(),
    is_error: true,
    usage: None,
  }
}

///|
/// 距 started_at 的秒数,一位小数(对应 pi (…/1000).toFixed(1))。
fn wall_seconds(started_at : Int64) -> String {
  let tenths = (@async.now() - started_at + 50) / 100
  "\{tenths / 10}.\{tenths % 10}"
}

///|
/// "Script error:" 正文(对应 pi formatError + formatCallSummary)。
fn format_error(
  error : CodemodeError,
  calls : Array[CodemodeNestedCall],
) -> String {
  let head = match error.kind {
    Script =>
      error.stack.unwrap_or(
        "\{error.name.unwrap_or("Error")}: \{error.message}",
      )
    Timeout => "Script timed out: \{error.message}"
    Aborted => "Script aborted: \{error.message}"
    Sandbox => "Script sandbox failed: \{error.message}"
  }
  let summary = if calls.is_empty() {
    "No tool calls were made."
  } else {
    "Tool calls made before the failure (they are not undone): " +
    calls.map(fn(call) { "\{call.name} (\{call.status})" }).join(", ")
  }
  "\{head}\n\n\{summary}"
}

///|
fn preview_args(args : Json?) -> String {
  match args {
    None => ""
    Some(args) => truncate_text(args.stringify(), ARGS_PREVIEW_CHARS)
  }
}

///|
fn truncate_text(text : String, max_chars : Int32) -> String {
  if text.length() > max_chars {
    "\{text[:max_chars - 3]}..."
  } else {
    text
  }
}

///|
/// return 值追加为文本(对应 pi valueText)。
fn value_text(value : Json) -> String {
  match value {
    String(text) => text
    _ => value.stringify(indent=2)
  }
}

///|
/// 无 outputSchema 工具的脚本侧 resolve 类型(对应 pi TEXT_OUTPUT_SCHEMA)。
let text_output_schema : Json = { "type": "string" }

///|
const ARGS_PREVIEW_CHARS : Int32 = 200

///|
const ERROR_PREVIEW_CHARS : Int32 = 500

///|
/// 输出 token 预算默认值(对应 pi DEFAULT_MAX_OUTPUT_TOKENS)。
const DEFAULT_MAX_OUTPUT_TOKENS : Int32 = 50_000

///|
/// ALL_TOOLS 条目/脚本侧描述:工具描述 + 声明样例 + guideline 要点
/// (对应 pi renderToolSample(toCodemodeDeclaration(tool, guidelines)))。
fn sample_of(tool : @tools.ToolDefinition) -> String {
  let bullets = tool.prompt_guidelines
    .iter()
    .filter_map(fn(line) {
      let trimmed = line.trim().to_owned()
      if trimmed == "" {
        None
      } else {
        Some("- \{trimmed}")
      }
    })
    .collect()
  let description = if bullets.is_empty() {
    tool.description
  } else {
    "\{tool.description.trim()}\n\n\{bullets.join("\n")}"
  }
  render_tool_sample(
    CodemodeTool::new(
      name=tool.name,
      description~,
      input_schema=Some(tool.parameters),
      output_schema=Some(text_output_schema),
      execute=async fn(_, _) {
        @async.pause()
        None
      },
    ),
  )
}

///|
/// 模型可见 description(对应 pi createCodemodeDescription 的无 namespace/
/// 无 deferred/无 inline budget 版本)。
fn codemode_description(tools : ArrayView[@tools.ToolDefinition]) -> String {
  let sections : Array[String] = [
    DESCRIPTION_INTRO,
    (
      $|Globals:
      $|- `text(value)`, `image(dataUrlOrImageBlock)`, `console.log(...)`, and top-level `return` add output; `exit()` ends the script.
      $|- `store(key, value)` and `load(key)` keep JSON values across codemode calls.
    ),
  ]
  let tool_sections : Array[String] = []
  for tool in tools {
    if tool.name == CODEMODE_TOOL_NAME {
      continue
    }
    let id = to_codemode_identifier(tool.name)
    let heading = if id == tool.name {
      "### `\{id}`"
    } else {
      "### `\{id}` (`\{tool.name}`)"
    }
    tool_sections.push("\{heading}\n\{sample_of(tool)}")
  }
  if !tool_sections.is_empty() {
    sections.push("Nested tools:\n\n" + tool_sections.join("\n\n"))
  }
  sections.join("\n\n")
}

///|
const DESCRIPTION_INTRO : String =
  #|Run JavaScript that calls other tools. The input is raw JavaScript (not JSON, no code fence), run as an async function body in a QuickJS sandbox: top-level `await` and `return` work. No Node, file system, network, or timers.
  #|- `await tools.<name>({ ...args })` resolves to a string, or an object if the tool's declaration says so, and rejects with an Error on failure. Calls still running when the script ends are cancelled.
  #|- Optional first line: `// @options: {"max_output_tokens": 10000, "timeout_ms": 60000}`

///|
pub const CODEMODE_TOOL_NAME : String = "codemode"

///|
/// store() 净写入持久化用的 session custom entry type(对应 pi CODEMODE_STORE_ENTRY_TYPE)。
pub const CODEMODE_STORE_ENTRY_TYPE : String = "codemode-store"

///|
/// 脚本参数 schema:`{ code: string }`(对应 pi codemodeSchema)。
pub let codemode_parameters : Json = {
  "type": "object",
  "properties": {
    "code": { "type": "string", "description": "Raw JavaScript source." },
  },
  "required": ["code"],
  "additionalProperties": false,
}

///|
/// codemode-store custom entry 的数据(对应 pi CodemodeStoreEntryData)。
pub(all) struct CodemodeStoreEntryData {
  set : Map[String, Json]
  delete : Array[String]
} derive(ToJson, FromJson)

///|
pub extend CodemodeStoreEntryData with ToJson::{to_json}

///|
pub extend CodemodeStoreEntryData with @json.FromJson::{from_json}

///|
pub(all) enum CodemodeNestedCallStatus {
  Running
  Ok
  Error
  Cancelled
}

///|
/// 一次嵌套调用的展示记录,进 result.details(对应 pi CodemodeNestedCall)。
pub(all) struct CodemodeNestedCall {
  /// "<codemode call id>/<n>"
  id : String
  name : String
  /// 紧凑 JSON 参数预览,截断展示
  args : String
  mut status : CodemodeNestedCallStatus
  mut duration_ms : Double?
  mut error : String?
}

///|
/// codemode 工具的 result.details(对应 pi CodemodeToolDetails)。
pub(all) struct CodemodeToolDetails {
  calls : Array[CodemodeNestedCall]
  /// 输出被截断时完整文本的落盘路径
  full_output_path : String?
}

///|
/// details JSON 用 pi 的 camelCase 形状(status 为小写串,None 字段省略)。
pub impl ToJson for CodemodeNestedCallStatus with fn to_json(
  self : CodemodeNestedCallStatus,
) -> Json {
  Json(
    match self {
      Running => "running"
      Ok => "ok"
      Error => "error"
      Cancelled => "cancelled"
    },
  )
}

///|
pub extend CodemodeNestedCallStatus with ToJson::{to_json}

///|
pub impl Show for CodemodeNestedCallStatus with fn output(
  self : CodemodeNestedCallStatus,
  logger : &Logger,
) -> Unit {
  logger.write_string(
    match self {
      Running => "running"
      Ok => "ok"
      Error => "error"
      Cancelled => "cancelled"
    },
  )
}

///|
pub extend CodemodeNestedCallStatus with Show::{output, to_string}

///|
pub impl ToJson for CodemodeNestedCall with fn to_json(
  self : CodemodeNestedCall,
) -> Json {
  let fields : Map[String, Json] = {
    "id": Json(self.id),
    "name": Json(self.name),
    "args": Json(self.args),
    "status": self.status.to_json(),
  }
  if self.duration_ms is Some(duration) {
    fields["durationMs"] = Json(duration)
  }
  if self.error is Some(error) {
    fields["error"] = Json(error)
  }
  Json::object(fields)
}

///|
pub extend CodemodeNestedCall with ToJson::{to_json}

///|
pub impl ToJson for CodemodeToolDetails with fn to_json(
  self : CodemodeToolDetails,
) -> Json {
  let fields : Map[String, Json] = { "calls": Json(self.calls) }
  if self.full_output_path is Some(path) {
    fields["fullOutputPath"] = Json(path)
  }
  Json::object(fields)
}

///|
pub extend CodemodeToolDetails with ToJson::{to_json}
