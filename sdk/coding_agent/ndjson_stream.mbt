///|
/// Multiplexer for `{ "stream_id", "data" }` NDJSON frames over a byte stream.
pub struct NdJsonStreams[R, W] {
  priv reader : R
  priv writer : W
  priv mut next_id : Int32
  priv send_queue : @aqueue.Queue[(Json, Bool)]
  priv send_slots : @aqueue.Queue[Unit]
  priv recv_queue_map : Map[Int32, @aqueue.Queue[Json]]
  priv mut closed : Bool
  priv mut cancel_reader : (() -> Unit)?
}

///|
/// Creates an NDJSON stream multiplexer over `reader` and `writer`.
pub fn[R, W] NdJsonStreams::new(reader : R, writer : W) -> NdJsonStreams[R, W] {
  let send_slots : @aqueue.Queue[Unit] = @aqueue.Queue(kind=@aqueue.Unbounded)
  for _ in 0..<10 {
    ignore(send_slots.try_put(()) catch { _ => false })
  }
  NdJsonStreams::{
    reader,
    writer,
    next_id: 1,
    send_queue: @aqueue.Queue(kind=@aqueue.Unbounded),
    send_slots,
    recv_queue_map: Map([]),
    closed: false,
    cancel_reader: None,
  }
}

///|
const MAX_FRAME_SIZE : Int32 = 16 * 1024 * 1024

///|
/// Pumps incoming and outgoing NDJSON frames until `reader` reaches EOF or `close` is called.
/// Raises if an incoming frame exceeds `MAX_FRAME_SIZE`, is truncated at EOF, or contains invalid JSON.
pub async fn[R : @io.Reader, W : @io.Writer] NdJsonStreams::run(
  self : NdJsonStreams[R, W],
) -> Unit {
  defer {
    self.closed = true
    self.cancel_reader = None
    for _, queue in self.recv_queue_map {
      queue.close()
    }
    self.send_queue.close()
    self.send_slots.close()
  }
  guard !self.closed else { return }
  @async.with_task_group(tg => {
    let reader = tg.spawn(() => self.pump_reader(), no_wait=true)
    self.cancel_reader = Some(() => reader.cancel())
    tg.spawn_bg(() => {
      while true {
        let (msg, reserved) = self.send_queue.get() catch {
          @aqueue.QueueAlreadyClosed => break
          err => raise err
        }
        if reserved {
          ignore(self.send_slots.try_put(()) catch { _ => false })
        }
        self.writer.write(@utf8.encode(msg.stringify() + "\n")) catch {
          _ => {
            self.close()
            break
          }
        }
      }
    })
    reader.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      err => raise err
    }
  })
}

///|
async fn[R : @io.Reader, W] NdJsonStreams::pump_reader(
  self : NdJsonStreams[R, W],
) -> Unit {
  let pending : Array[Byte] = []
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
  while read_frame() is Some(line) {
    let frame = @json.parse(@utf8.decode_lossy(line[:]))
    guard frame is { "stream_id": Number(stream_id, ..), .. } else { continue }
    let id = stream_id.to_int()
    if frame is { "close": True, .. } {
      if self.recv_queue_map.remove_and_get(id) is Some(queue) {
        queue.close()
      }
      continue
    }
    guard frame is { "data": data, .. } else { continue }
    if self.recv_queue_map.get(id) is Some(queue) {
      queue.put(data) catch {
        @aqueue.QueueAlreadyClosed => ()
        err => raise err
      }
    }
  }
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
    send_slots: self.send_slots,
    closed: false,
    recv_queue,
    recv_queue_map: self.recv_queue_map,
  }
}

///|
/// Close every stream queue and the send queue, ending `run` and every
/// pending `recv`.
pub fn[R, W] NdJsonStreams::close(self : NdJsonStreams[R, W]) -> Unit {
  self.closed = true
  match self.cancel_reader {
    Some(cancel) => cancel()
    None => ()
  }
  for _, queue in self.recv_queue_map {
    queue.close()
  }
  self.send_queue.close()
  self.send_slots.close()
}

///|
/// One stream of an `NdJsonStreams` pump — a transparent `@codemode.VmChannel`:
/// `send` wraps `data` in a `{ "stream_id", "data" }` frame; `recv` returns
/// each `data` payload as-is and raises once the remote closes the stream.
pub struct NdJsonStream {
  priv id : Int32
  priv send_queue : @aqueue.Queue[(Json, Bool)]
  priv send_slots : @aqueue.Queue[Unit]
  priv recv_queue : @aqueue.Queue[Json]
  priv recv_queue_map : Map[Int32, @aqueue.Queue[Json]]
  priv mut closed : Bool
}

///|
pub impl @codemode.VmChannel for NdJsonStream with fn send(self, data : Json) -> Unit {
  guard !self.closed else { fail("codemode stream is closed") }
  self.send_slots.get()
  if self.closed {
    ignore(self.send_slots.try_put(()) catch { _ => false })
    fail("codemode stream is closed")
  }
  errdefer ignore(self.send_slots.try_put(()) catch { _ => false })
  ignore(
    self.send_queue.try_put(({ "stream_id": self.id, "data": data }, true)),
  )
}

///|
pub impl @codemode.VmChannel for NdJsonStream with fn recv(self) -> Json {
  self.recv_queue.get()
}

///|
/// Queue a `{ "stream_id", "close": true }` frame and release the stream.
pub impl @codemode.VmChannel for NdJsonStream with fn close(self) {
  if self.closed {
    return
  }
  self.closed = true
  ignore(
    self.send_queue.try_put(({ "stream_id": self.id, "close": true }, false)) catch {
      _ => false
    },
  )
  self.recv_queue_map.remove(self.id)
  self.recv_queue.close()
}

///|
pub extend NdJsonStream with @codemode.VmChannel::{send, recv, close}
