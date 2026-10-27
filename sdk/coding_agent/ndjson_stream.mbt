///|
/// Multiplexed `{ "stream_id", "data" }` NDJSON frames over a byte stream —
/// pim's own wire shape for a codemode remote such as
/// `scripts/codemode-sidecar.mjs`. `run` pumps the stream; `new_stream`
/// allocates a `NdJsonStream`, a transparent `@codemode.Vm` for
/// `Codemode::execute`: `data` payloads pass through untouched — a VM
/// message, an array batch, or `{ "type": "exit" }` ending the stream.
pub struct NdJsonStreams[R, W] {
  reader : R
  writer : W
  mut next_id : Int32
  send_queue : @aqueue.Queue[Json]
  recv_queue_map : Map[Int32, @aqueue.Queue[Json]]
  mut closed : Bool
}

///|
/// Create a demultiplexer over `reader`/`writer`. `run` must be called to
/// pump frames, usually in a background task.
pub fn[R, W] NdJsonStreams::new(reader : R, writer : W) -> NdJsonStreams[R, W] {
  NdJsonStreams::{
    reader,
    writer,
    next_id: 1,
    send_queue: @aqueue.Queue(kind=@aqueue.Blocking(10)),
    recv_queue_map: Map([]),
    closed: false,
  }
}

///|
const MAX_FRAME_SIZE : Int32 = 16 * 1024 * 1024 // 16MB

///|
/// Pump frames until the reader ends: a writer task serializes `send` calls
/// onto the stream (the single writer, so frames never interleave) while the
/// reader splits input on newlines and puts each `{ "stream_id", "data" }`
/// frame's `data` into that stream's queue, dropping frames for unknown or
/// closed stream ids. On EOF or error every stream queue is closed so
/// pending `recv` raises, and `send_queue` is closed so the writer exits.
pub async fn[R : @io.Reader, W : @io.Writer] NdJsonStreams::run(
  self : NdJsonStreams[R, W],
) -> Unit {
  @async.with_task_group(tg => {
    tg.spawn_bg(() => {
      while true {
        let msg = self.send_queue.get() catch {
          @aqueue.QueueAlreadyClosed => break
          err => raise err
        }
        self.writer.write(@utf8.encode(msg.stringify() + "\n")) catch {
          _ => break
        }
      }
    })
    let pending : Array[Byte] = []
    // Read one LF-terminated line, buffering partial reads. Returns the line
    // bytes without the terminator; `None` at EOF before more data.
    let read_frame = () => {
      while true {
        for i, b in pending {
          if b == b'\n' {
            let line = pending.drain(0, i + 1)
            return Some(Bytes::from_iter(line[:i].iter()))
          }
        }
        if pending.length() > MAX_FRAME_SIZE {
          fail("ndjson streams: frame larger than \{MAX_FRAME_SIZE} bytes")
        }
        match self.reader.read_some(max_len=65536) {
          Some(chunk) => pending.push_iter(chunk.iter())
          None => {
            guard pending.is_empty() else {
              fail("ndjson streams: truncated final frame")
            }
            return None
          }
        }
      } nobreak {
        fail("unreachable")
      }
    }
    defer {
      self.closed = true
      for _, queue in self.recv_queue_map {
        queue.close()
      }
      self.send_queue.close()
    }
    while read_frame() is Some(line) {
      let frame = @json.parse(@utf8.decode_lossy(line[:]))
      guard frame is { "stream_id": Number(stream_id, ..), "data": data, .. } else {
        fail("ndjson streams: invalid frame \{frame.stringify()}")
      }
      if self.recv_queue_map.get(stream_id.to_int()) is Some(queue) {
        queue.put(data) catch {
          // The stream was closed between routing and enqueue; the frame
          // is stale and safe to drop.
          @aqueue.QueueAlreadyClosed => ()
          err => raise err
        }
      }
    }
  })
}

///|
/// Allocate a stream id and its receive queue. Streams created after `run`
/// ended come back already closed.
pub fn[R, W] NdJsonStreams::new_stream(
  self : NdJsonStreams[R, W],
) -> NdJsonStream {
  let id = self.next_id
  self.next_id += 1
  let recv_queue = @aqueue.Queue(kind=@aqueue.Blocking(10))
  if self.closed {
    recv_queue.close()
  } else {
    self.recv_queue_map.set(id, recv_queue)
  }
  NdJsonStream::{
    id,
    send_queue: self.send_queue,
    recv_queue,
    recv_queue_map: self.recv_queue_map,
  }
}

///|
/// Close every stream queue and the send queue, ending `run` and every
/// pending `recv`.
pub fn[R, W] NdJsonStreams::close(self : NdJsonStreams[R, W]) -> Unit {
  self.closed = true
  for _, queue in self.recv_queue_map {
    queue.close()
  }
  self.send_queue.close()
}

///|
/// One stream of an `NdJsonStreams` pump, transparent as a `@codemode.Vm`:
/// `send` wraps `data` in a `{ "stream_id", "data" }` frame; `recv` returns
/// each `data` payload as-is — a VM message or an array batch — and raises
/// once the remote ends the execution (`exit` frame), the pump ends, or
/// `close` runs.
pub struct NdJsonStream {
  id : Int32
  send_queue : @aqueue.Queue[Json]
  recv_queue : @aqueue.Queue[Json]
  recv_queue_map : Map[Int32, @aqueue.Queue[Json]]
}

///|
pub impl @codemode.Vm for NdJsonStream with fn send(self, data : Json) -> Unit {
  self.send_queue.put({ "stream_id": self.id, "data": data })
}

///|
pub impl @codemode.Vm for NdJsonStream with fn recv(self) -> Json {
  let data = self.recv_queue.get()
  if data is { "type": "exit", .. } {
    fail("ndjson stream: remote ended the execution")
  }
  data
}

///|
pub impl @codemode.Vm for NdJsonStream with fn close(self) {
  self.recv_queue_map.remove(self.id)
  self.recv_queue.close()
}

///|
pub extend NdJsonStream with @codemode.Vm::{send, recv, close}
