///|
/// Multiplexed `{ "stream_id", "data" }` JSON frames over one WebSocket
/// connection — pim's own wire shape for a codemode remote. `run` pumps
/// the connection; `new_stream` allocates a `WsStream`, a transparent
/// `@codemode.VmChannel` for `Codemode::execute`: `data` payloads pass through
/// untouched; `{ "stream_id", "close": true }` ends a stream.
pub struct WsStreams {
  priv ws : @websocket.Conn
  priv mut next_id : Int32
  priv send_queue : @aqueue.Queue[(Json, Bool)]
  priv send_slots : @aqueue.Queue[Unit]
  priv recv_queue_map : Map[Int32, @aqueue.Queue[Json]]
  priv mut closed : Bool
}

///|
/// Wrap an already connected WebSocket for multiplexed codemode streams.
/// `run` must be called to pump frames, usually in a background task.
///
/// The ownership of `ws` will be transferred to this function.
/// So caller must not use the connection anymore, nor close it.
pub fn WsStreams::WsStreams(ws : @websocket.Conn) -> WsStreams {
  let send_slots : @aqueue.Queue[Unit] = @aqueue.Queue(kind=@aqueue.Unbounded)
  for _ in 0..<10 {
    ignore(send_slots.try_put(()) catch { _ => false })
  }
  {
    ws,
    next_id: 1,
    send_queue: @aqueue.Queue(kind=@aqueue.Unbounded),
    send_slots,
    recv_queue_map: Map([]),
    closed: false,
  }
}

///|
/// Connect to a codemode-remote WebSocket endpoint at `url` (for example
/// `ws://host:port/`). `run` must be called to pump frames, usually in a
/// background task; `with_ws_streams` composes connect + pump + close.
///
/// The returned `WsStreams` owns the connection; `close` releases it.
pub async fn WsStreams::connect(url~ : String) -> WsStreams {
  WsStreams::WsStreams(@websocket.Conn::connect(url))
}

///|
/// Connect to `url`, pump frames in a background task, and call `f` with
/// the demultiplexer. Returns `f`'s result. The connection is closed when
/// `f` returns or raises; a pump failure or `f`'s error propagates.
pub async fn[X] with_ws_streams(url~ : String, f : async (WsStreams) -> X) -> X {
  let streams = WsStreams::connect(url~)
  @async.with_task_group(tg => {
    // `no_wait`: teardown cancels the pump instead of waiting on a socket
    // close to wake `recv`, which a transport close does not guarantee.
    tg.spawn_bg(no_wait=true, () => streams.run())
    defer streams.close()
    f(streams)
  })
}

///|
/// Pump frames until the peer closes the connection: a writer task
/// serializes `send` calls onto the socket (the single writer, so frames
/// never interleave) while the reader puts each `{ "stream_id", "data" }`
/// frame's `data` into that stream's queue, dropping unknown stream ids.
/// On close — a close frame surfacing as `ConnectionClosed` — every
/// stream queue is closed so pending `recv` raises, then returns
/// normally. A binary message or malformed frame fails.
pub async fn WsStreams::run(self : WsStreams) -> Unit {
  @async.with_task_group(tg => {
    tg.spawn_bg(() => {
      while true {
        let (msg, reserved) = self.send_queue.get() catch {
          @aqueue.QueueAlreadyClosed => break
          err => raise err
        }
        if reserved {
          ignore(self.send_slots.try_put(()) catch { _ => false })
        }
        self.ws.send_text(msg.stringify()) catch {
          _ => break
        }
      }
    })
    defer {
      self.closed = true
      for _, queue in self.recv_queue_map {
        queue.close()
      }
      self.send_queue.close()
      self.send_slots.close()
    }
    while true {
      // Any recv failure — a close frame surfacing as `ConnectionClosed`,
      // or the transport dropping — ends every stream the same way.
      let message = self.ws.recv() catch { _ => break }
      guard message.kind is Text else {
        fail("ws streams: unexpected binary message")
      }
      let text = message.read_all().text() catch { _ => break }
      let frame = @json.parse(text)
      guard frame is { "stream_id": Number(stream_id, ..), .. } else {
        fail("ws streams: invalid frame \{frame.stringify()}")
      }
      let id = stream_id.to_int()
      if frame is { "close": True, .. } {
        if self.recv_queue_map.remove_and_get(id) is Some(queue) {
          queue.close()
        }
        continue
      }
      guard frame is { "data": data, .. } else {
        fail("ws streams: invalid frame \{frame.stringify()}")
      }
      if self.recv_queue_map.get(id) is Some(queue) {
        queue.put(data) catch {
          @aqueue.QueueAlreadyClosed => ()
          err => raise err
        }
      }
    }
  })
}

///|
/// Allocate a stream id and its receive queue. Streams created after the
/// connection ended come back already closed.
pub fn WsStreams::new_stream(self : WsStreams) -> WsStream {
  let id = self.next_id
  self.next_id += 1
  let recv_queue = @aqueue.Queue(kind=@aqueue.Blocking(10))
  if self.closed {
    recv_queue.close()
  } else {
    self.recv_queue_map.set(id, recv_queue)
  }
  WsStream::{
    id,
    send_queue: self.send_queue,
    send_slots: self.send_slots,
    closed: false,
    recv_queue,
    recv_queue_map: self.recv_queue_map,
  }
}

///|
/// Close the websocket, ending `run` and every pending `recv`.
pub fn WsStreams::close(self : WsStreams) -> Unit {
  self.closed = true
  for _, queue in self.recv_queue_map {
    queue.close()
  }
  self.send_queue.close()
  self.send_slots.close()
  self.ws.close()
}

///|
/// One stream of a `WsStreams` connection, transparent as a `@codemode.VmChannel`:
/// `send` wraps `data` in a `{ "stream_id", "data" }` frame; `recv` returns
/// each `data` payload as-is and raises once the stream closes.
pub struct WsStream {
  priv id : Int32
  priv send_queue : @aqueue.Queue[(Json, Bool)]
  priv send_slots : @aqueue.Queue[Unit]
  priv recv_queue : @aqueue.Queue[Json]
  priv recv_queue_map : Map[Int32, @aqueue.Queue[Json]]
  priv mut closed : Bool
}

///|
pub impl @codemode.VmChannel for WsStream with fn send(self, data : Json) -> Unit {
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
pub impl @codemode.VmChannel for WsStream with fn recv(self) -> Json {
  self.recv_queue.get()
}

///|
/// Queue a `{ "stream_id", "close": true }` frame and release the stream.
pub impl @codemode.VmChannel for WsStream with fn close(self) {
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
pub extend WsStream with @codemode.VmChannel::{send, recv, close}
