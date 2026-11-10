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
/// Spawns `node <script>` with piped stdin/stdout and returns its `SidecarProcess` handle.
pub fn SidecarProcess::spawn(script : String) -> SidecarProcess {
  let child = node_spawn([script], sidecar_spawn_options())
  let stdout = @js_async.ReadableStream::from_js(child.stdout_to_web())
  child.on_stdin_error(() => stdout.close())
  { child, stdout, stdin: SidecarStdin::{ child, }, }
}

///|
/// Signals the sidecar process to terminate.
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
