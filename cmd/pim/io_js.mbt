///|
/// JavaScript (Node.js) output layer for `pim`, mirroring pi's
/// `core/output-guard.ts`.
///
/// Writes are queued on an ordered promise chain and awaited per chunk inside
/// the JS side (the `process.stdout.write` callback), which makes them
/// backpressure-aware. The `ENOBUFS` / `EAGAIN` / `EWOULDBLOCK` errors that a
/// non-blocking pipe can report are retried, and anything else exits the
/// process — the same policy pi applies.
///
/// Callers `flush_output()` before returning and before `process.exit`, so a
/// buffered write can never be truncated by the exit. `--mode json` also
/// flushes after each event, mirroring pi's subscriber that awaits its
/// backpressure barrier between events.

///|
#external
priv type JsOut

///|
extern "js" fn out_new() -> JsOut =
  #| () => {
  #|   let tail = Promise.resolve();
  #|   const writeChunk = (text, fd) =>
  #|     new Promise((resolve) => {
  #|       const stream = fd === 1 ? process.stdout : process.stderr;
  #|       const attempt = () => {
  #|         try {
  #|           stream.write(text, (error) => {
  #|             if (error == null) {
  #|               resolve();
  #|               return;
  #|             }
  #|             const code = error.code;
  #|             if (code === "ENOBUFS" || code === "EAGAIN" || code === "EWOULDBLOCK") {
  #|               setTimeout(attempt, 10);
  #|             } else {
  #|               process.exit(1);
  #|             }
  #|           });
  #|         } catch (error) {
  #|           process.exit(1);
  #|         }
  #|       };
  #|       attempt();
  #|     });
  #|   return {
  #|     write: (text, fd) => {
  #|       tail = tail.then(() => writeChunk(text, fd));
  #|     },
  #|     flush: () => tail,
  #|   };
  #| }

///|
let output : JsOut = out_new()

///|
extern "js" fn JsOut::enqueue(self : JsOut, text : String, fd : Int) -> Unit =
  #| (out, text, fd) => out.write(text, fd)

///|
extern "js" fn JsOut::drain(self : JsOut) -> @js_async.Promise[Unit] =
  #| (out) => out.flush()

///|
/// Queue `message` (plus the trailing newline pi's print mode writes) for
/// stdout. Returns immediately: ordering is the queue's job.
pub fn write_stdout(message : String) -> Unit {
  output.enqueue("\{message}\n", 1)
}

///|
/// Queue a diagnostic line for stderr on the same ordered chain, so it cannot
/// overtake stdout output that was queued earlier.
pub fn write_stderr(message : String) -> Unit {
  output.enqueue("\{message}\n", 2)
}

///|
/// Wait for everything queued so far to reach the OS: pi's
/// `waitForRawStdoutBackpressure`.
pub async fn flush_output() -> Unit {
  output.drain().wait()
}

///|
/// `process.exit`. Never returns, so every queued write must be flushed first.
extern "js" fn proc_exit_ffi(code : Int) -> Unit =
  #| (code) => process.exit(code)
