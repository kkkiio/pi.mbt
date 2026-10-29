///|
/// `close` 对应上游 `remoteLauncher.stop()`:最后一帧
/// `{ "stream_id", "data": {"type":"stop"} }` 不落盘而直接进 writer 队列 —
/// `try_put` 不挂起,被取消的协程也能把 stop 送到线上。这里用一对内存
/// pipe 证明帧真的到了"线上"。
async test "closing a stream emits a stop frame on the wire" {
  @async.with_task_group(group => {
    let (remote_read, _remote_write) = @io.pipe()
    let (client_read, client_write) = @io.pipe()
    let streams = @coding_agent.NdJsonStreams::new(remote_read, client_write)
    group.spawn_bg(no_wait=true, () => streams.run() catch { _ => () })
    let stream = streams.new_stream()
    stream.close()
    guard client_read.read_until("\n") is Some(line) else {
      fail("no frame reached the wire")
    }
    let frame = @json.parse(line)
    guard frame
      is { "stream_id": Number(1, ..), "data": { "type": "stop", .. }, .. } else {
      fail("unexpected frame \{frame.stringify()}")
    }
  })
}

///|
async test "cancelled streams retain stop frames when all send slots are occupied" {
  @async.with_timeout(3000, () => {
    @async.with_task_group(group => {
      let (remote_read, _remote_write) = @io.pipe()
      let (client_read, client_write) = @io.pipe()
      let streams = @coding_agent.NdJsonStreams::new(remote_read, client_write)
      let stream = streams.new_stream()
      for i in 0..<10 {
        stream.send({ "n": i })
      }
      let entered : @aqueue.Queue[Unit] = @aqueue.Queue(kind=@aqueue.Unbounded)
      let task = group.spawn(() => {
        @async.handle_cancellation(() => {
          defer stream.close()
          entered.put(())
          stream.send({ "n": 10 })
        })
      })
      entered.get()
      task.cancel()
      assert_true(task.wait() is None)
      stream.close()
      group.spawn_bg(no_wait=true, () => streams.run())
      for i in 0..<11 {
        guard client_read.read_until("\n") is Some(line) else {
          fail("missing frame")
        }
        let frame = @json.parse(line)
        if i < 10 {
          assert_true(
            frame is { "data": { "n": Number(n, ..), .. }, .. } &&
            n == i.to_double(),
          )
        } else {
          assert_true(frame is { "data": { "type": "stop", .. }, .. })
        }
      }
      streams.close()
    })
  })
}
