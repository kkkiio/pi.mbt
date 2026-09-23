///|
/// JavaScript (Node.js) implementation of the bash tool's executor.
///
/// `bash.mbt` owns the tool definition, the JSON schema, the output
/// accumulator and the result formatting; this file replaces the two things
/// that were `@async/process` and `@async.sleep` on native: `local_bash_exec`
/// and the timer behind the throttled UI update.
///
/// Output arrives from Node as `data` events, and the handler on the MoonBit
/// side (`BashExecParams.on_data`) is a plain function on purpose: an `async`
/// MoonBit closure cannot be entered from a JS callback, because a JS event
/// callback has no coroutine context (`@coroutine.current_coroutine` would
/// unwrap `None` and panic). Everything the handler touches therefore stays
/// synchronous — including `OutputAccumulator::append`, the temp-file spill
/// and the update timer.
///
/// Parity with the native implementation and with pi's TypeScript executor:
///
/// - stdout and stderr are merged into a single stream in arrival order;
/// - `params.timeout` kills the process and raises `TimedOut(seconds)`, whose
///   text is exactly `timeout:{seconds}`;
/// - a spawn failure (bad `cwd`, missing `/bin/bash`) fails with Node's
///   message, which then propagates like the native fs error did;
/// - cancellation aborts the exit wait and `defer` kills the child, raising
///   `Aborted`, whose text is exactly `aborted`.
///
/// The two texts are pinned because `execute_bash_tool` switches on them
/// (`"aborted"`, `[.. "timeout:", ..]`). They are raised as a typed suberror
/// with an explicit `Show` rather than via `fail(...)`: a `Failure` stringifies
/// with a source location and `FAILED: ` prefix, which would never match.

///|
/// Failure mode of one bash execution, named so the caller's `catch` can
/// switch on the error instead of parsing a message.
pub(all) suberror BashExecError {
  TimedOut(Int)
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
/// Opaque handles for values that only exist inside JavaScript: the running
/// child, Node's spawn options object, the terminal record, and the timer
/// handle `setTimeout` returns.
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
/// The exit code, or `-1` when the process died from a signal.
extern "js" fn JsBashEnd::code(self : JsBashEnd) -> Int =
  #| (end) => end.code ?? -1

///|
extern "js" fn JsBashEnd::timed_out(self : JsBashEnd) -> Bool =
  #| (end) => end.timedOut === true

///|
/// Node's spawn-failure message, or `""` when the process ran.
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
/// Spawn `/bin/bash -c <command>`, forward stdout and stderr to `on_data` as
/// they arrive, and expose the terminal record as a promise.
///
/// `env_json` is a JSON object of extra environment variables; it is merged
/// over `process.env` when `inherit_env` is true. `timeout_ms` of 0 disables
/// the timeout.
extern "js" fn spawn_bash_ffi(
  spawn : (String, FixedArray[String], JsSpawnOptions) -> JsChild,
  on_data : (Bytes) -> Unit,
  command : String,
  cwd : String,
  env_json : String,
  inherit_env : Bool,
  timeout_ms : Int,
) -> JsBashProc =
  #| function(spawn, onData, command, cwd, envJson, inheritEnv, timeoutMs) {
  #|   const extra = JSON.parse(envJson);
  #|   const env = inheritEnv ? Object.assign({}, process.env, extra) : extra;
  #|   const child = spawn("/bin/bash", ["-c", command], {
  #|     cwd,
  #|     env,
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
  #|   if (timeoutMs > 0) {
  #|     timer = setTimeout(() => {
  #|       timedOut = true;
  #|       child.kill("SIGKILL");
  #|     }, timeoutMs);
  #|   }
  #|   return {
  #|     exited: () => exited,
  #|     kill: () => {
  #|       if (child.exitCode === null && child.signalCode === null) {
  #|         child.kill("SIGKILL");
  #|       }
  #|     },
  #|   };
  #| }

///|
/// Schedule `callback` after `ms` milliseconds. The callback runs outside the
/// MoonBit coroutine, so it must be synchronous.
extern "js" fn set_timeout(callback : () -> Unit, ms : Int) -> JsTimer =
  #| (callback, ms) => setTimeout(callback, ms)

///|
extern "js" fn clear_timeout(timer : JsTimer) -> Unit =
  #| (timer) => clearTimeout(timer)

///|
fn encode_override_envs(envs : Map[String, String]) -> String {
  let fields : Map[String, Json] = Map([])
  for key, value in envs {
    fields[key] = value.to_json()
  }
  Json::object(fields).stringify()
}

///|
/// Bridge the optional handler to the non-optional JS callback. `Bytes` widens
/// to `BytesView` at the call, so the accumulator sees the same view type as
/// before.
fn data_callback(callback : ((BytesView) -> Unit)?) -> (Bytes) -> Unit {
  match callback {
    Some(callback) => fn(data) { callback(data) }
    None => fn(_data) { () }
  }
}

///|
async fn local_bash_exec(params : BashExecParams) -> Int {
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
  // An abort controller keeps the wait cancellable: without one the runtime
  // defers cancellation until the promise resolves, so an aborted bash call
  // would run to completion.
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
