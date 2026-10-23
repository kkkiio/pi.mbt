///|
/// native target 的默认启动器(占位):
/// 计划实现是 C pthread 工作线程里跑内嵌 quickjs.c(复刻 sqlite3.mbt 的
/// executor.c 模式),桥消息经 @pipe.pipe() 唤醒 MoonBit 主线程的异步 read;
/// interrupt flag 用 C 侧 atomic_int,stop() 置位后 cond_signal 唤醒线程退出。
/// 当前先以明确的沙箱错误报错:宿主状态机与协议层在 native 可编译可测。
fn default_vm_launcher() -> VmLauncher {
  async fn(_data, _events) {
    @async.pause()
    raise CodemodeSandboxError(
      "codemode VM is not available on the native backend yet",
    )
  }
}
