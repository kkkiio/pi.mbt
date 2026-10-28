///|
/// Multiplexed `{ "stream_id", "data" }` JSON frames over one WebSocket
/// connection — pim's own wire shape for a codemode remote. `run` pumps
/// the connection; `new_stream` allocates a `WsStream`, a transparent
/// `@codemode.VmServer` for `Codemode::execute`: `data` payloads pass through
/// untouched — a VM message, an array batch, or `{ "type": "exit" }`
/// ending the stream.
pub struct WsStreams {
  priv ws : @websocket.Conn
  priv mut next_id : Int32
  priv send_queue : @aqueue.Queue[Json]
  priv recv_queue_map : Map[Int32, @aqueue.Queue[Json]]
  priv mut closed : Bool
}

///|
/// Connect to a codemode-remote WebSocket endpoint at `url` (for example
/// `ws://host:port/`). `run` must be called to pump frames, usually in a
/// background task; `with_ws_streams` composes connect + pump + close.
pub async fn WsStreams::connect(url~ : String) -> WsStreams {
  {
    ws: @websocket.Conn::connect(url),
    next_id: 1,
    send_queue: @aqueue.Queue(kind=@aqueue.Blocking(10)),
    recv_queue_map: Map([]),
    closed: false,
  }
}

///|
/// Connect to `url`, pump frames in a background task, and call `f` with
/// the demultiplexer. Returns `f`'s result. The connection is closed when
/// `f` returns or raises; a pump failure or `f`'s error propagates.
pub async fn[X] with_ws_streams(url~ : String, f : async (WsStreams) -> X) -> X {
  let streams = WsStreams::connect(url~)
  @async.with_task_group(tg => {
    tg.spawn_bg(() => streams.run())
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
        let msg = self.send_queue.get() catch {
          @aqueue.QueueAlreadyClosed => break
          err => raise err
        }
        self.ws.send_text(msg.stringify()) catch {
          _ => break
        }
      }
    })
    while true {
      // Any recv failure — a close frame surfacing as `ConnectionClosed`,
      // or the transport dropping — ends every stream the same way.
      let message = self.ws.recv() catch { _ => break }
      guard message.kind is Text else {
        fail("ws streams: unexpected binary message")
      }
      let text = message.read_all().text() catch { _ => break }
      let frame = @json.parse(text)
      guard frame is { "stream_id": Number(stream_id, ..), "data": data, .. } else {
        fail("ws streams: invalid frame \{frame.stringify()}")
      }
      if self.recv_queue_map.get(stream_id.to_int()) is Some(queue) {
        // A concurrently closed stream drops the frame.
        queue.put(data) catch {
          @aqueue.QueueAlreadyClosed => ()
          err => raise err
        }
      }
    }
    self.closed = true
    for _, queue in self.recv_queue_map {
      queue.close()
    }
    self.send_queue.close()
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
    recv_queue,
    recv_queue_map: self.recv_queue_map,
  }
}

///|
/// Close the websocket, ending `run` and every pending `recv`.
pub fn WsStreams::close(self : WsStreams) -> Unit {
  self.ws.close()
}

///|
/// One stream of a `WsStreams` connection, transparent as a `@codemode.VmServer`:
/// `send` wraps `data` in a `{ "stream_id", "data" }` frame; `recv` returns
/// each `data` payload as-is — a VM message or an array batch — and raises
/// once the remote ends the execution (`exit` frame, connection close, or
/// `close` running).
pub struct WsStream {
  priv id : Int32
  priv send_queue : @aqueue.Queue[Json]
  priv recv_queue : @aqueue.Queue[Json]
  priv recv_queue_map : Map[Int32, @aqueue.Queue[Json]]
}

///|
pub impl @codemode.VmServer for WsStream with fn send(self, data : Json) -> Unit {
  self.send_queue.put({ "stream_id": self.id, "data": data })
}

///|
pub impl @codemode.VmServer for WsStream with fn recv(self) -> Json {
  let data = self.recv_queue.get()
  if data is { "type": "exit", .. } {
    fail("ws stream: remote ended the execution")
  }
  data
}

///|
pub impl @codemode.VmServer for WsStream with fn close(self) {
  self.recv_queue_map.remove(self.id)
  self.recv_queue.close()
}

///|
pub extend WsStream with @codemode.VmServer::{send, recv, close}
