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
