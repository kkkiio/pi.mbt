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
}

///|
/// 永远不会被中断的信号(调用方不关心中断时的默认值)。
pub fn AbortSignal::never() -> AbortSignal {
  AbortSignal::{ flag: false, }
}

///|
pub fn AbortSignal::is_aborted(self : AbortSignal) -> Bool {
  self.flag
}

///|
/// 中断控制器:唯一能触发中断的对象(对应 pi 里每次 prompt 前 `new AbortController()`)。
pub struct AbortController {
  signal : AbortSignal
}

///|
pub fn AbortController::new() -> AbortController {
  AbortController::{ signal: AbortSignal::{ flag: false, }, }
}

///|
/// 交给消费者只读令牌。
pub fn AbortController::signal(self : AbortController) -> AbortSignal {
  self.signal
}

///|
/// 请求中断(幂等)。
pub fn AbortController::abort(self : AbortController) -> Unit {
  self.signal.flag = true
}
