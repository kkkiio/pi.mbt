///|
pub fn new_bash_tool_definition(
  cwd? : String = @env.current_dir().unwrap(),
  exec? : async (BashExecParams) -> Int = local_bash_exec,
) -> @tools.ToolDefinition {
  {
    name: "bash",
    label: "bash",
    prompt_guidelines: ["Use bash for file operations like ls, rg, find"],
    callable_definition: {
      description: "Execute a bash command in the current working directory. Returns stdout and stderr. Output is truncated to last \{DEFAULT_MAX_LINES} lines or \{DEFAULT_MAX_BYTES / 1024}KB (whichever is hit first). If truncated, full output is saved to a temp file. Optionally provide a timeout in seconds.",
      parameters: {
        "type": "object",
        "properties": {
          "command": {
            "type": "string",
            "description": "The bash command to execute",
          },
          "timeout": {
            "type": "integer",
            "description": "Optional timeout in seconds",
            "minimum": 1,
          },
        },
        "required": ["command"],
        "additionalProperties": false,
      },
      constrained_sampling: @agent_loop.ConstrainedSampling::JsonSchema(
        strict=true,
      ),
      execute: (_, input, on_update) => {
        execute_bash_tool(cwd, input, on_update~, exec~)
      },
    }
    |> Some,
  }
}

///|
pub(all) struct BashExecParams {
  command : String
  cwd : String
  timeout : Int?
  /// Called from the JS `data` handler for stdout and stderr, so it has no
  /// coroutine context: it must stay synchronous. The throttled UI update is
  /// scheduled with a JS timer for the same reason.
  on_data : ((BytesView) -> Unit)?
  override_envs : Map[String, String]
  inherit_env : Bool
}

///|
struct BashToolInput {
  command : String
  timeout : Int?
} derive(FromJson)

///|
pub extend BashToolInput with @json.FromJson::{from_json}

///|
async fn execute_bash_tool(
  cwd : String,
  input : Json,
  on_update? : @agent_loop.ToolExecUpdateCallback,
  exec~ : async (BashExecParams) -> Int,
) -> @agent_loop.ToolResult {
  let params : BashToolInput = @json.from_json(input)
  let command = params.command
  if command.length() <= 0 {
    fail("command should not be empty")
  }
  if params.timeout is Some(timeout) && timeout <= 0 {
    fail("timeout should be greater than zero")
  }
  let override_envs : Map[String, String] = Map([])
  let output = OutputAccumulator(
    max_lines=DEFAULT_MAX_LINES,
    max_bytes=DEFAULT_MAX_BYTES,
    temp_file_prefix="pim-bash",
  )
  let mut acceptingOutput = true
  let mut updateTimer : JsTimer? = None
  let mut updateDirty = false
  let mut lastUpdateAt : UInt64 = 0

  // Data-path failures cannot cross the JS callback boundary (`on_data` is
  // called from Node's `data` handler, which has no way to carry a MoonBit
  // error), so the first one is recorded here and surfaced once the child has
  // exited.
  let mut dataError : String? = None

  let emitOutputUpdate = () => {
    guard on_update is Some(onUpdate) && updateDirty is true else { return }
    updateDirty = false
    lastUpdateAt = @env.now()
    let snapshot = output.snapshot(persist_if_truncated=true) catch {
      // A throttled UI refresh is best effort: a failure here is reported by
      // the terminal snapshot in `finish_output`.
      _ => return
    }
    onUpdate([@agent_loop.InputMessageContent::Text(snapshot.content)], {
      "truncation": if snapshot.truncation.truncated {
        snapshot.truncation
      } else {
        null
      },
      "fullOutputPath": match snapshot.full_output_path {
        Some(value) => value.to_json()
        None => null
      },
    })
  }

  let clearUpdateTimer = () => {
    if updateTimer is Some(t) {
      clear_timeout(t)
      updateTimer = None
    }
  }

  let scheduleOutputUpdate = () => {
    guard on_update is Some(_) else { return }
    updateDirty = true
    let now = @env.now()
    if now >= lastUpdateAt + BASH_UPDATE_THROTTLE_MS.to_uint64() {
      clearUpdateTimer()
      emitOutputUpdate()
      return
    }
    if updateTimer is None {
      let delay = lastUpdateAt + BASH_UPDATE_THROTTLE_MS.to_uint64() - now
      updateTimer = Some(
        set_timeout(
          () => {
            updateTimer = None
            emitOutputUpdate()
          },
          delay.to_int(),
        ),
      )
    }
  }

  if on_update is Some(onUpdate) {
    onUpdate([], {})
  }

  let handleData = fn(data : BytesView) {
    if !acceptingOutput || dataError is Some(_) {
      return
    }
    output.append(data) catch {
      err => dataError = Some(err.to_string())
    }
    if dataError is None {
      scheduleOutputUpdate()
    }
  }

  let finish_output = fn() raise {
    acceptingOutput = false
    output.finish()
    clearUpdateTimer()
    emitOutputUpdate()
    let snapshot = output.snapshot(persist_if_truncated=true)
    output.close_temp_file()
    return snapshot
  }

  fn formatOutput(
    snapshot : OutputSnapshot,
    emptyText : String,
  ) -> (String, Json) {
    let truncation = snapshot.truncation
    let text = StringBuilder()
    text.write_string() <| (match snapshot.content {
      "" => emptyText
      c => c
    })
    let details = if truncation.truncated {
      let startLine = truncation.total_lines - truncation.output_lines + 1
      let endLine = truncation.total_lines
      let fullOutputPath = snapshot.full_output_path.unwrap_or("")
      if truncation.last_line_partial {
        let lastLineSize = output.get_last_line_bytes()
        text <+
          "\n\n[Showing last \{truncation.output_bytes} bytes of line \{endLine} (line is \{lastLineSize} bytes). Full output: \{fullOutputPath}]"
      } else if truncation.truncated_by is Some("lines") {
        text <+
          "\n\n[Showing lines \{startLine}-\{endLine} of \{truncation.total_lines}. Full output: \{fullOutputPath}]"
      } else {
        text <+
          "\n\n[Showing lines \{startLine}-\{endLine} of \{truncation.total_lines} (\{DEFAULT_MAX_BYTES} byte limit). Full output: \{fullOutputPath}]"
      }
      BashToolDetails::{
        truncation: Some(truncation),
        full_output_path: snapshot.full_output_path,
      }
    } else {
      BashToolDetails::{ truncation: None, full_output_path: None, }
    }
    return (text.to_string(), @json.to_json(details))
  }

  fn appendStatus(text : String, status : String) -> String {
    match text {
      "" => status
      text =>
        (
          $|\{text}
          $|
          $|\{status}
        )
    }
  }

  defer clearUpdateTimer()
  let exitCode = try {
    let exitCode = exec({
      command,
      cwd,
      timeout: params.timeout,
      on_data: Some(handleData),
      override_envs,
      inherit_env: true,
    })
    exitCode
  } catch {
    err => {
      let snapshot = finish_output()
      let (text, _) = formatOutput(snapshot, "")
      match err.to_string() {
        "aborted" => fail(appendStatus(text, "Command aborted"))
        [.. "timeout:", .. timeoutSecs] =>
          fail(
            appendStatus(text, "Command timed out after \{timeoutSecs} seconds"),
          )
        _ => raise err
      }
    }
  }

  match dataError {
    Some(message) => fail("failed to persist command output: \{message}")
    None => ()
  }

  let snapshot = finish_output()
  let (outputText, details) = formatOutput(snapshot, "(no output)")
  if exitCode != 0 {
    fail(appendStatus(outputText, "Command exited with code \{exitCode}"))
  }
  {
    content: [@agent_loop.InputMessageContent::Text(outputText)],
    details,
    is_error: false,
    terminate: false,
    usage: None,
  }
}

///|
struct BashToolDetails {
  truncation : TruncationResult?
  full_output_path : String?
}

///|
/// pi's `BashToolDetails` is `{ truncation?, fullOutputPath? }` with camelCase
/// keys, so this is written by hand rather than derived.
pub impl ToJson for BashToolDetails with fn to_json(self : BashToolDetails) -> Json {
  {
    "truncation": match self.truncation {
      Some(value) => value.to_json()
      None => null
    },
    "fullOutputPath": match self.full_output_path {
      Some(value) => value.to_json()
      None => null
    },
  }
}

///|
pub extend BashToolDetails with ToJson::{to_json}

///|
const DEFAULT_MAX_LINES : Int = 2000

///|
const DEFAULT_MAX_BYTES : Int = 50 * 1024

///|
const BASH_UPDATE_THROTTLE_MS = 100
