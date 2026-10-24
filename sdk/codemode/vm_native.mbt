///|
/// native target 的默认启动器:每次执行起一个 pthread 跑内嵌
/// QuickJS-NG(vendor/quickjs,与 js target 的 quickjs-wasi 同为 0.17.0
/// 引擎),同一份 prelude_source。复刻 sqlite3.mbt 的 executor.c 模式:
/// VM→宿主消息进 C 侧 mutex 队列,写 1 字节到 @pipe.pipe() 唤醒读端;
/// 宿主→VM 结果经 condvar 队列;stop() 置 interrupt flag 后 join。
fn default_vm_launcher() -> VmLauncher {
  async fn(data, events) {
    @async.pause()
    let (reader, writer) = @pipe.pipe() catch {
      error =>
        raise CodemodeSandboxError(
          "codemode VM pipe failed: \{error_message(error)}",
        )
    }
    let rescode : Ref[Int32] = Ref(0)
    let memory_limit : Int64 = match data.memory_limit_bytes {
      Some(limit) => limit.to_int64()
      None => -1L
    }
    let vm = vm_spawn(
      @utf8.encode(data.code),
      @utf8.encode(prelude_source),
      @utf8.encode(encode_tools_json(data.tools).stringify()),
      @utf8.encode(encode_globals_json(data.globals).stringify()),
      @utf8.encode(encode_store_json(data.store).stringify()),
      memory_limit,
      writer.fd(),
      rescode,
    )
    if rescode.val != 0 {
      reader.close()
      writer.close()
      raise CodemodeSandboxError(
        "codemode VM spawn failed (code \{rescode.val})",
      )
    }
    NativeVmChannel::{ vm, events, reader, writer, stopped: false, }
  }
}

///|
/// 内嵌 VM 的宿主侧通道。
/// stopped 在 vm 内存释放前置位;pump 每轮读醒后先查它再 drain,
/// 避免把已释放的 ctx 传给 FFI。
priv struct NativeVmChannel {
  vm : NativeVm
  events : &VmEvents
  reader : @pipe.PipeRead
  writer : @pipe.PipeWrite
  mut stopped : Bool
}

///|
impl VmChannel for NativeVmChannel with fn post(self, message) {
  if self.stopped {
    return
  }
  match message {
    Result(id~, ok~, payload~) =>
      match payload {
        Some(payload) => vm_post(self.vm, id, ok, @utf8.encode(payload), true)
        None => vm_post(self.vm, id, ok, b"", false)
      }
  }
}

///|
/// VM→宿主泵:读唤醒字节 → drain C 侧消息队列 → deliver_worker_message。
/// VM 线程退出时关掉 dup 的写端,读端见 EOF 退出;stop() 或执行收尾
/// 关掉两端后阻塞中的 read 报错退出。
impl VmChannel for NativeVmChannel with fn pump(self) {
  let buf = FixedArray::make(64, b'\x00')
  for ;; {
    let n = self.reader.read(buf, max_len=buf.length()) catch { _ => break }
    if n <= 0 || self.stopped {
      break
    }
    for ;; {
      if self.stopped {
        break
      }
      let bytes = vm_next_message(self.vm)
      if bytes.length() == 0 {
        break
      }
      deliver_worker_message(self.events, @utf8.decode_lossy(bytes[:]))
    }
  }
}

///|
/// 对应 pi stop()/channel.stop():置 interrupt flag,broadcast 唤醒
/// cond_wait 中的 VM,pthread_join 后释放 C 侧资源,最后关管道两端。
/// 阻塞时间与 VM 清理速度同阶(脚本已被打断)。
impl VmChannel for NativeVmChannel with fn stop(self) {
  if self.stopped {
    return
  }
  self.stopped = true
  vm_stop(self.vm)
  self.writer.close()
  self.reader.close()
}

///|
#external
priv type NativeVm

///|
/// 创建 VM 线程;code/prelude/tools/globals/store 均为 UTF-8 字节,
/// 线上 JSON 文本与 js target 的 workerData 同形。
/// rescode != 0 表示失败(VM 未启动,vm 不得使用)。
#borrow(code, prelude, tools, globals, store, rescode)
extern "C" fn vm_spawn(
  code : Bytes,
  prelude : Bytes,
  tools : Bytes,
  globals : Bytes,
  store : Bytes,
  memory_limit : Int64,
  wake_fd : @types.Fd,
  rescode : Ref[Int32],
) -> NativeVm = "pim_codemode_vm_spawn"

///|
/// 投递工具结果;payload 是线上 JSON 文本(对应 settle 的 payload)。
#borrow(payload)
extern "C" fn vm_post(
  vm : NativeVm,
  id : Int32,
  ok : Bool,
  payload : Bytes,
  has_payload : Bool,
) -> Unit = "pim_codemode_vm_post"

///|
/// 弹出一条 VM→宿主消息(UTF-8 JSON);队列空返回零长 Bytes。
extern "C" fn vm_next_message(vm : NativeVm) -> Bytes = "pim_codemode_vm_next_message"

///|
/// 停止 VM:interrupt + join + 释放全部 C 侧内存;调用后 vm 不得再进 FFI。
extern "C" fn vm_stop(vm : NativeVm) -> Unit = "pim_codemode_vm_stop"
