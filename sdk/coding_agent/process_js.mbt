///|
#external
priv type JsSidecarChild

///|
#external
priv type JsSidecarSpawnOptions

///|
extern "js" fn node_spawn(
  args : FixedArray[String],
  options : JsSidecarSpawnOptions,
) -> JsSidecarChild =
  #| (args, options) => process.getBuiltinModule("node:child_process")
  #|   .spawn(process.execPath, args, options)

///|
extern "js" fn sidecar_spawn_options() -> JsSidecarSpawnOptions =
  #| () => ({ stdio: ["pipe", "pipe", "inherit"] })

///|
extern "js" fn JsSidecarChild::stdout_to_web(
  self : JsSidecarChild,
) -> @js_async.JsReadableStream =
  #| (child) => process.getBuiltinModule("node:stream")
  #|   .Readable.toWeb(child.stdout)

///|
extern "js" fn JsSidecarChild::on_stdin_error(
  self : JsSidecarChild,
  on_error : () -> Unit,
) -> Unit =
  #| (child, onError) => child.stdin.on("error", () => onError())

///|
extern "js" fn JsSidecarChild::stdin_write(
  self : JsSidecarChild,
  data : Bytes,
  offset : Int32,
  len : Int32,
) -> Unit =
  #| (child, data, offset, len) => {
  #|   child.stdin.write(data.subarray(offset, offset + len));
  #| }

///|
extern "js" fn JsSidecarChild::kill(self : JsSidecarChild) -> Unit =
  #| (child) => { child.kill(); }

///|
struct SidecarProcess {
  child : JsSidecarChild
  stdout : @js_async.ReadableStream
  stdin : SidecarStdin
}

///|
/// Spawn `node <script>`. The process keeps running until `kill` or until it
/// exits on its own; either way `stdout` reads EOF.
///
/// `stdout` goes through `@js_async.ReadableStream`, whose reads suspend on
/// `Promise::wait` — settling a JS promise is what re-arms the coroutine
/// scheduler on this backend. A raw `stdout.on("data", ...)` callback would
/// only enqueue the waiting coroutine without rescheduling it, stalling the
/// stream whenever the scheduler's task chain has gone idle.
pub fn SidecarProcess::spawn(script : String) -> SidecarProcess {
  let child = node_spawn([script], sidecar_spawn_options())
  let stdout = @js_async.ReadableStream::from_js(child.stdout_to_web())
  // `stdin.write` can raise EPIPE asynchronously when the sidecar dies;
  // surface it as the end of stdout so the pump unwinds like a normal exit.
  child.on_stdin_error(() => stdout.close())
  { child, stdout, stdin: SidecarStdin::{ child, }, }
}

///|
/// Signal the child to exit. Idempotent on the Node side.
pub fn SidecarProcess::kill(self : SidecarProcess) -> Unit {
  self.child.kill()
}

///|
struct SidecarStdin {
  child : JsSidecarChild
}

///|
pub impl @io.Writer for SidecarStdin with fn write_once(
  self,
  buf,
  offset~,
  len~,
) {
  self.child.stdin_write(buf, offset, len)
  len
}

///|
#deprecated
#doc(hidden)
pub extend SidecarStdin with @io.Writer::{write_once, write, write_reader}
