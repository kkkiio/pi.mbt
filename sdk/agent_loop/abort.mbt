///|
/// 中断信号:只读令牌。持有者只能查询"本次运行是否已被请求中断"。
///
/// 与 `AbortController` 分离(对应 Web / pi 的 `AbortSignal` / `AbortController`):
/// 只有控制器能置位,消费者(agent loop、provider、将来的工具)只能观察 ——
/// 避免"谁都能把别人的运行中断掉"。
///
/// `flag` 是私有字段,所以包外拿不到它的写入口。含 `mut` 字段的结构体按引用传递,
/// 因此控制器与它发出的信号共享同一个对象(置位立即可见)。
pub struct AbortSignal {
  mut flag : Bool
  /// `on_abort` 登记的回调,`abort()` 触发时清空。
  mut listeners : Array[() -> Unit]
}

///|
/// 永远不会被中断的信号(调用方不关心中断时的默认值)。
pub fn AbortSignal::never() -> AbortSignal {
  AbortSignal::{ flag: false, listeners: [], }
}

///|
pub fn AbortSignal::is_aborted(self : AbortSignal) -> Bool {
  self.flag
}

///|
/// 订阅中断:若已中断,立即同步调用一次 `handler`;否则登记,待 `abort()` 时调用。
///
/// 对应 Web / pi 的 `signal.addEventListener("abort", handler)`。回调是同步的
/// (可能在任意协程、甚至 JS 回调里被触发),需要挂起协程请改用 `wait_abort`。
pub fn AbortSignal::on_abort(self : AbortSignal, handler : () -> Unit) -> Unit {
  if self.flag {
    handler()
  } else {
    self.listeners.push(handler)
  }
}

///|
/// 挂起当前协程直到中断被请求(已中断则立即返回)。事件驱动,不轮询;
/// 当前协程被取消时这次等待一并取消。
pub async fn AbortSignal::wait_abort(self : AbortSignal) -> Unit {
  guard !self.flag else { return }
  let gate = @async.Semaphore::Semaphore(1, initial_value=0)
  self.on_abort(() => gate.release())
  gate.acquire()
}

///|
pub struct AbortController {
  signal : AbortSignal
}

///|
pub fn AbortController::new() -> AbortController {
  AbortController::{ signal: AbortSignal::{ flag: false, listeners: [], }, }
}

///|
/// 交给消费者只读令牌。
pub fn AbortController::signal(self : AbortController) -> AbortSignal {
  self.signal
}

///|
/// 请求中断(幂等):置位后一次性触发所有 `on_abort` 订阅。
pub fn AbortController::abort(self : AbortController) -> Unit {
  if self.signal.flag {
    return
  }
  self.signal.flag = true
  let listeners = self.signal.listeners
  self.signal.listeners = []
  for handler in listeners {
    handler()
  }
}
