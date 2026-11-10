///|
/// Failure mode of a bash execution (`TimedOut` or `Aborted`).
pub(all) suberror BashExecError {
  TimedOut(Int32)
  Aborted
}

///|
pub impl Show for BashExecError with fn output(self, logger) {
  match self {
    TimedOut(seconds) => logger.write_string("timeout:\{seconds}")
    Aborted => logger.write_string("aborted")
  }
}

///|
pub extend BashExecError with Show::{to_string, output}

///|
#external
priv type JsBashProc

///|
#external
priv type JsBashEnd

///|
#external
priv type JsChild

///|
#external
priv type JsSpawnOptions

///|
#external
priv type JsTimer

///|
extern "js" fn JsBashEnd::code(self : JsBashEnd) -> Int32 =
  #| (end) => end.code ?? -1

///|
extern "js" fn JsBashEnd::timed_out(self : JsBashEnd) -> Bool =
  #| (end) => end.timedOut === true

///|
extern "js" fn JsBashEnd::error_message(self : JsBashEnd) -> String =
  #| (end) => end.error ?? ""

///|
extern "js" fn JsBashProc::exited(
  self : JsBashProc,
) -> @js_async.Promise[JsBashEnd] =
  #| (proc) => proc.exited()

///|
extern "js" fn JsBashProc::kill(self : JsBashProc) -> Unit =
  #| (proc) => proc.kill()

///|
#module("node:child_process")
extern "js" fn spawn_sync(
  command : String,
  args : FixedArray[String],
  options : JsSpawnOptions,
) -> JsChild = "spawn"

///|
extern "js" fn spawn_bash_ffi(
  spawn : (String, FixedArray[String], JsSpawnOptions) -> JsChild,
  on_data : (Bytes) -> Unit,
  command : String,
  cwd : String,
  env_json : String,
  inherit_env : Bool,
  timeout_ms : Int32,
) -> JsBashProc =
  #| function(spawn, onData, command, cwd, envJson, inheritEnv, timeoutMs) {
  #|   const extra = JSON.parse(envJson);
  #|   const env = inheritEnv ? Object.assign({}, process.env, extra) : extra;
  #|   const detached = process.platform !== "win32";
  #|   const child = spawn("/bin/bash", ["-c", command], {
  #|     cwd,
  #|     env,
  #|     detached,
  #|     stdio: ["ignore", "pipe", "pipe"],
  #|   });
  #|   let settled = false;
  #|   let timedOut = false;
  #|   let error = "";
  #|   let timer = null;
  #|   let resolveExit = null;
  #|   const exited = new Promise((resolve) => {
  #|     resolveExit = resolve;
  #|   });
  #|   const forward = (buf) => onData(new Uint8Array(buf));
  #|   const finish = () => {
  #|     if (settled) {
  #|       return;
  #|     }
  #|     settled = true;
  #|     if (timer !== null) {
  #|       clearTimeout(timer);
  #|     }
  #|     resolveExit({ code: child.exitCode, timedOut, error });
  #|   };
  #|   child.stdout.on("data", forward);
  #|   child.stderr.on("data", forward);
  #|   child.on("error", (err) => {
  #|     error = String((err && err.message) || err);
  #|     finish();
  #|   });
  #|   child.on("close", (code) => {
  #|     if (code !== null) {
  #|       child.exitCode = code;
  #|     }
  #|     finish();
  #|   });
  #|   const killTree = () => {
  #|     if (child.exitCode !== null || child.signalCode !== null) {
  #|       return;
  #|     }
  #|     if (detached && typeof child.pid === "number") {
  #|       try {
  #|         process.kill(-child.pid, "SIGKILL");
  #|         return;
  #|       } catch {}
  #|     }
  #|     try {
  #|       child.kill("SIGKILL");
  #|     } catch {}
  #|   };
  #|   if (timeoutMs > 0) {
  #|     timer = setTimeout(() => {
  #|       timedOut = true;
  #|       killTree();
  #|     }, timeoutMs);
  #|   }
  #|   return {
  #|     exited: () => exited,
  #|     kill: killTree,
  #|   };
  #| }

///|
extern "js" fn set_timeout(callback : () -> Unit, ms : Int32) -> JsTimer =
  #| (callback, ms) => setTimeout(callback, ms)

///|
extern "js" fn clear_timeout(timer : JsTimer) -> Unit =
  #| (timer) => clearTimeout(timer)

///|
fn encode_override_envs(envs : Map[String, String]) -> String {
  let fields : Map[String, Json] = Map([])
  for key, value in envs {
    fields[key] = Json(value)
  }
  Json::object(fields).stringify()
}

///|
fn data_callback(callback : ((BytesView) -> Unit)?) -> (Bytes) -> Unit {
  match callback {
    Some(callback) => fn(data) { callback(data) }
    None => fn(_data) { () }
  }
}

///|
async fn local_bash_exec(params : BashExecParams) -> Int32 {
  let timeout_ms = params.timeout.map_or(0, seconds => seconds * 1000)
  let proc = spawn_bash_ffi(
    spawn_sync,
    data_callback(params.on_data),
    params.command,
    params.cwd,
    encode_override_envs(params.override_envs),
    params.inherit_env,
    timeout_ms,
  )
  defer proc.kill()
  let controller = @js_async.AbortController::new()
  let end = proc.exited().wait(abort_controller=controller) catch {
      _ => raise Aborted
    }
  if end.timed_out() {
    raise TimedOut(params.timeout.unwrap_or(0))
  }
  let message = end.error_message()
  if message != "" {
    fail(message)
  }
  end.code()
}
