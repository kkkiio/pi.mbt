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
        @async.with_task_group() <| group => {
          execute_bash_tool(group, cwd, input, on_update~, exec~)
        }
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
  on_data : (async (BytesView) -> Unit)?
  override_envs : Map[String, String]
  inherit_env : Bool
}

///|
struct BashToolInput {
  command : String
  timeout : Int?
} derive(FromJson)

///|
async fn execute_bash_tool(
  group : @async.TaskGroup[@agent_loop.ToolResult],
  cwd : String,
  input : Json,
  on_update? : @agent_loop.ToolExecUpdateSink,
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
    temp_file_prefix="pi-bash",
  )
  let mut acceptingOutput = true
  let mut updateTimer : @async.Task[Unit]? = None
  let mut updateDirty = false
  let mut lastUpdateAt : UInt64 = 0

  let emitOutputUpdate = () => {
    guard on_update is Some(onUpdate) && updateDirty is true else { return }
    updateDirty = false
    lastUpdateAt = @env.now()
    let snapshot = output.snapshot(persist_if_truncated=true)
    onUpdate([@agent_loop.InputMessageContent::Text(snapshot.content)], {
      "truncation": if snapshot.truncation.truncated {
        snapshot.truncation
      } else {
        null
      },
      "fullOutputPath": snapshot.full_output_path,
    })
  }

  let clearUpdateTimer = () => {
    if updateTimer is Some(t) {
      t.cancel()
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
        group.spawn(no_wait=true) <| () => {
          @async.sleep(delay.to_int())
          updateTimer = None
          emitOutputUpdate()
        },
      )
    }
  }

  if on_update is Some(onUpdate) {
    onUpdate([], {})
  }

  let handleData = async fn(data : BytesView) {
    if !acceptingOutput {
      return
    }
    output.append(data)
    scheduleOutputUpdate()
  }

  let finishOutput = () => {
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
      BashToolDetails::{ truncation: None, full_output_path: None }
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
      let snapshot = finishOutput()
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

  let snapshot = finishOutput()
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
} derive(ToJson)

///|
const DEFAULT_MAX_LINES : Int = 2000

///|
const DEFAULT_MAX_BYTES : Int = 50 * 1024

///|
const BASH_UPDATE_THROTTLE_MS = 100

///|
async fn local_bash_exec(params : BashExecParams) -> Int {
  let timeout_ms = params.timeout.map_or(0, seconds => seconds * 1000)
  let run = async fn() -> Int {
    let (reader, writer) = @process.read_from_process()
    @async.with_task_group() <| group => {
      let process = @process.spawn(
        group,
        "/bin/bash",
        ["-c", params.command],
        stdout=writer,
        stderr=writer,
        cwd=params.cwd.view(),
        extra_env=params.override_envs,
        inherit_env=params.inherit_env,
        cancel_handler=@process.hard_cancel(),
        no_wait=true,
      )
      defer reader.close()
      try {
        for ;; {
          match reader.read_some(max_len=4096) {
            None => break
            Some(chunk) => {
              if params.on_data is Some(callback) {
                callback(chunk)
              }
            }
          }
        }
        process.wait()
      } catch {
        err => {
          process.cancel()
          raise err
        }
      }
    }
  }
  if timeout_ms > 0 {
    match @async.with_timeout_opt(timeout_ms, run) {
      Some(code) => code
      None => fail("timeout:\{params.timeout.unwrap_or(0)}")
    }
  } else {
    run()
  }
}
