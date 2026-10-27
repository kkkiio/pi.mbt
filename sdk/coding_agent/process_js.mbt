///|
/// Spawn a Node child process whose stdin/stdout are usable as
/// `@io.Writer`/`@io.Reader` — the byte channel `NdJsonStreams` multiplexes
/// frames over.
///
/// Like `bash_js.mbt`, stdout `data` reaches MoonBit through a plain (not
/// async) callback because a JS event handler has no coroutine context. The
/// callback therefore only does `try_put` on an unbounded queue — never
/// blocking, so backpressure is delegated to the child pipe: the sidecar
/// protocol is low-volume and each frame is bounded by `MAX_FRAME_SIZE`.
/// Child stderr is inherited so sidecar diagnostics reach pim's stderr.

///|
#external
priv type JsSidecarChild

///|
#external
priv type JsSidecarSpawnOptions

///|
/// Spawn `node <script>` with the *running* Node executable
/// (`process.execPath`), not whatever `node` resolves to on PATH — an
/// installed `pim` package can rely on its own runtime.
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
/// `on_data` runs in a JS `data` handler: it must stay synchronous. An empty
/// chunk would read as EOF downstream, so it is filtered out here.
extern "js" fn JsSidecarChild::on_stdout_data(
  self : JsSidecarChild,
  on_data : (Bytes) -> Unit,
) -> Unit =
  #| (child, onData) => child.stdout.on("data", (buf) => {
  #|   if (buf.byteLength > 0) onData(new Uint8Array(buf));
  #| })

///|
/// `on_end` runs when the stdout byte stream is over: `end` for a clean EOF,
/// `close` for process death (including a spawn failure, which emits `error`
/// then `close`). It may fire more than once; the consumer must tolerate that.
extern "js" fn JsSidecarChild::on_stdout_end(
  self : JsSidecarChild,
  on_end : () -> Unit,
) -> Unit =
  #| (child, onEnd) => {
  #|   child.stdout.on("end", onEnd);
  #|   child.on("close", onEnd);
  #| }

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
/// A spawned `node` child, exposed as a `@io.Reader`/`@io.Writer` pair for
/// `NdJsonStreams`.
struct SidecarProcess {
  child : JsSidecarChild
  stdout : SidecarStdout
  stdin : SidecarStdin
}

///|
/// Spawn `node <script>`. The process keeps running until `kill` or until it
/// exits on its own; either way `stdout` reads EOF.
#warnings("-alert_internal")
pub fn SidecarProcess::spawn(script : String) -> SidecarProcess {
  let chunks = @aqueue.Queue(kind=@aqueue.Unbounded)
  let child = node_spawn([script], sidecar_spawn_options())
  child.on_stdout_data(chunk => {
    ignore(chunks.try_put(chunk) catch { _ => false })
  })
  child.on_stdout_end(() => chunks.close())
  {
    child,
    stdout: {
      chunks,
      read_buf: @io.ReaderBuffer::new(),
      leftover: b"",
      leftover_offset: 0,
    },
    stdin: { child, },
  }
}

///|
/// Signal the child to exit. Idempotent on the Node side.
pub fn SidecarProcess::kill(self : SidecarProcess) -> Unit {
  self.child.kill()
}

///|
/// The child's stdout as a `@io.Reader`: JS `data` events are queued without
/// blocking and EOF is reported once the queue is closed and drained.
#warnings("-alert_internal")
struct SidecarStdout {
  chunks : @aqueue.Queue[Bytes]
  read_buf : @io.ReaderBuffer
  mut leftover : Bytes
  mut leftover_offset : Int32
}

///|
pub impl @io.Reader for SidecarStdout with fn _get_internal_buffer(self) {
  self.read_buf
}

///|
#deprecated
#doc(hidden)
pub extend SidecarStdout with @io.Reader::{_direct_read, _get_internal_buffer}

///|
pub impl @io.Reader for SidecarStdout with fn _direct_read(
  self,
  dst,
  offset~,
  max_len~,
) {
  if self.leftover_offset >= self.leftover.length() {
    let chunk = self.chunks.get() catch { _ => return 0 }
    self.leftover = chunk
    self.leftover_offset = 0
  }
  let n = @cmp.minimum(max_len, self.leftover.length() - self.leftover_offset)
  dst.blit_from_bytes(offset, self.leftover, self.leftover_offset, n)
  self.leftover_offset += n
  n
}

///|
pub extend SidecarStdout with @io.Reader::{
  read,
  read_some,
  drop,
  read_all,
  read_until,
  read_exactly,
}

///|
/// The child's stdin as a `@io.Writer`. Node buffers writes internally, so
/// `write_once` always reports the whole chunk accepted.
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
