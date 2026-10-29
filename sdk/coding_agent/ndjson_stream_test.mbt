///|
/// `close` 把 `{ "stream_id", "close": true }` 直接放进 writer 队列 —
/// `try_put` 不挂起,被取消的协程也能把帧送到线上。
async test "closing a stream emits a close frame on the wire" {
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
    guard frame is { "stream_id": Number(1, ..), "close": True, .. } else {
      fail("unexpected frame \{frame.stringify()}")
    }
  })
}

///|
async test "cancelled streams retain close frames when all send slots are occupied" {
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
          assert_true(frame is { "close": True, .. })
        }
      }
      streams.close()
    })
  })
}

///|
async test "closing the demultiplexer unblocks the pump" {
  @async.with_timeout(3000, () => {
    let (remote_read, _remote_write) = @io.pipe()
    let (_client_read, client_write) = @io.pipe()
    let streams = @coding_agent.NdJsonStreams::new(remote_read, client_write)
    @async.with_task_group(group => {
      let task = group.spawn(() => streams.run())
      @async.sleep(50)
      streams.close()
      ignore(task.wait() catch { _ => () })
    })
  })
}
