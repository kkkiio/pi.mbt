///|
/// 每次执行的宿主侧状态机(对应 pi execution.ts 的 Execution 类,去掉
/// deterministic start/deliver 分支)。
///
/// 生命周期:
/// 1. 创建时武装 deadline 定时器与 abort watcher,随后请求启动器给 channel。
/// 2. VM 消息经 VmEvents.message 进来;工具调用在这里执行,结果经
///    VmChannel.post 回 VM。channel 未到位前先排队(unsent)。
/// 3. 首个终态胜:done/crash/启动器 failure/deadline/abort。finish() 取消
///    pending 工具调用;run() 随后请求 channel.stop()。之后的消息全部忽略。
///
/// 真正停 VM 是启动器的职责:worker 被 terminate,内嵌 VM 被 interrupt。
const DEFAULT_TIMEOUT_MS : Int32 = 300_000

///|
/// VM 启动器:为一次执行创建一个 VM(对应 pi VmLauncher)。
/// data 是启动所需的一切;events 由启动器回调上报 VM 消息与桥外故障。
/// 实现方:vm_js.mbt(JS FFI)、vm_native.mbt(pthread + 内嵌 quickjs.c)。
pub type VmLauncher = async (VmStartData, &VmEvents) -> &VmChannel

///|
/// VM 侧事件上报(对应 pi VmEvents)。
pub(open) trait VmEvents {
  /// VM 发来一条消息;消息本身的合法性由宿主校验,载荷解码在启动器侧
  fn message(Self, VmToHostMessage) -> Unit
  /// VM 或传输层在桥协议外失败(worker 退出、管道断开、载荷解码失败等)
  fn failure(Self, CodemodeError) -> Unit
}

///|
/// 宿主持有的运行中 VM 句柄(对应 pi VmChannel)。
pub(open) trait VmChannel {
  /// 向 VM 投递一条宿主消息(目前是工具结果应答)
  fn post(Self, HostToVmMessage) -> Unit
  /// 请求 VM 停止;每次执行只调一次,可在 VM 真正退出前返回
  async fn stop(Self) -> Unit
}

// 平台默认启动器 default_vm_launcher() 在各 target 文件定义:
// vm_js.mbt(pi worker.js)、vm_native.mbt(pthread + 内嵌 quickjs.c)。

///|
/// 持有工具表与默认值;每次 execute 起一个新 VM(对应 pi CodemodeSandboxBase)。
///
/// 脚本可见面:tools.<id>(args)、ALL_TOOLS、text()/image()/exit()、
/// console.*、store()/load() 及配置的 globals;无定时器/fetch/fs/require/模块。
/// 沙箱自身只保存工具表与默认值;close() 中断在跑执行。
pub struct CodemodeSandbox {
  tools_by_name : Map[String, CodemodeTool]
  globals_by_name : Map[String, CodemodeTool]
  timeout_ms : Int32
  memory_limit_bytes : Int32?
  launch : VmLauncher
  running : Array[Execution]
  done_notify : @aqueue.Queue[Unit]
  mut closed : Bool
}

///|
/// 平台默认 VM 的沙箱(对应 pi CodemodeSandbox)。
/// globals 重名/撞保留字/命名空间冲突时报错(对应 pi checkGlobals)。
pub fn CodemodeSandbox::new(
  tools~ : Array[CodemodeTool] = [],
  globals~ : Array[CodemodeTool] = [],
  timeout_ms~ : Int32 = DEFAULT_TIMEOUT_MS,
  memory_limit_bytes~ : Int32? = None,
) -> CodemodeSandbox raise {
  CodemodeSandbox::with_launcher(
    launch=default_vm_launcher(),
    tools~,
    globals~,
    timeout_ms~,
    memory_limit_bytes~,
  )
}

///|
/// 指定启动器的沙箱(对应 pi 给 CodemodeSandboxBase 传 VmLauncher)。
/// 也是宿主状态机的单测注入缝:可接脚本化 faux VM。
pub fn CodemodeSandbox::with_launcher(
  launch~ : VmLauncher,
  tools~ : Array[CodemodeTool] = [],
  globals~ : Array[CodemodeTool] = [],
  timeout_ms~ : Int32 = DEFAULT_TIMEOUT_MS,
  memory_limit_bytes~ : Int32? = None,
) -> CodemodeSandbox raise {
  let tools_by_name : Map[String, CodemodeTool] = Map([])
  for tool in tools {
    if tools_by_name.contains(tool.name) {
      raise CodemodeSandboxError("Tool \"\{tool.name}\" is already registered")
    }
    tools_by_name[tool.name] = tool
  }
  check_globals(globals)
  let globals_by_name : Map[String, CodemodeTool] = Map([])
  for g in globals {
    globals_by_name[g.name] = g
  }
  {
    tools_by_name,
    globals_by_name,
    timeout_ms,
    memory_limit_bytes,
    launch,
    running: [],
    done_notify: @aqueue.Queue(kind=@aqueue.Unbounded),
    closed: false,
  }
}

///|
/// 执行一段脚本;code 是 async 函数体,顶层 await/return 可用
/// (对应 pi CodemodeSandboxBase.execute)。
///
/// 脚本失败不 raise,由 CodemodeResult::Err 报告;abort 信号按
/// Err(kind=Aborted) 收尾,宿主协程取消则照常向上传播(先把执行收尾为
/// Aborted 再传)。timeout_ms=None 用沙箱默认。store 是 load() 数据源;
/// 脚本的 store() 经 result.store_writes 返回,是否持久化由调用方决定。
/// 沙箱已 close 时 raise。
pub async fn CodemodeSandbox::execute(
  self : Self,
  code : String,
  timeout_ms~ : Int32? = None,
  store~ : Map[String, Json] = Map([]),
  abort~ : @agent_loop.AbortSignal = @agent_loop.AbortSignal::never(),
) -> CodemodeResult {
  if self.closed {
    raise CodemodeSandboxError("Sandbox is closed")
  }
  let tools : Map[String, CodemodeTool] = Map([])
  for name, tool in self.tools_by_name {
    tools[name] = tool
  }
  let globals : Map[String, CodemodeTool] = Map([])
  for name, g in self.globals_by_name {
    globals[name] = g
  }
  let execution = Execution::{
    code,
    tools,
    globals,
    timeout_ms: timeout_ms.unwrap_or(self.timeout_ms),
    abort,
    memory_limit_bytes: self.memory_limit_bytes,
    store: serialize_store(store),
    launch: self.launch,
    group: Ref(None),
    result: @aqueue.Queue(kind=@aqueue.Unbounded),
    channel: Ref(None),
    unsent: [],
    calls: [],
    output: [],
    pending: Map([]),
    finished: Ref(false),
  }
  self.running.push(execution)
  defer {
    self.running.retain(fn(e) { !physical_equal(e, execution) })
    ignore(self.done_notify.try_put(()) catch { _ => false })
  }
  execution.run()
}

///|
/// 注册工具;重名报错(对应 pi registerTool)。
pub fn CodemodeSandbox::register_tool(
  self : Self,
  tool : CodemodeTool,
) -> Unit raise {
  if self.tools_by_name.contains(tool.name) {
    raise CodemodeSandboxError("Tool \"\{tool.name}\" is already registered")
  }
  self.tools_by_name[tool.name] = tool
}

///|
pub fn CodemodeSandbox::unregister_tool(self : Self, name : String) -> Bool {
  self.tools_by_name.remove_and_get(name) is Some(_)
}

///|
pub fn CodemodeSandbox::tools(self : Self) -> Array[CodemodeTool] {
  self.tools_by_name.values().collect()
}

///|
pub fn CodemodeSandbox::globals(self : Self) -> Array[CodemodeTool] {
  self.globals_by_name.values().collect()
}

///|
/// 中断在跑执行(结果 Err kind=Aborted)并拒绝新的 execute(对应 pi close)。
/// 等所有在跑执行收尾(含 channel.stop)后返回。
pub async fn CodemodeSandbox::close(self : Self) -> Unit {
  self.closed = true
  let pending = self.running.length()
  for execution in self.running {
    execution.finish(Some(aborted_error()))
  }
  for _ in 0..<pending {
    self.done_notify.get()
  }
}

///|

///|
/// pending 工具调用记录;pub 只因 Execution 字段可见性规则,对外无构造面。
pub struct PendingCall {
  record : CodemodeCall?
  started_at : Int64
  controller : @agent_loop.AbortController
  task : @async.Task[Unit]
}

///|
/// 一次脚本执行;字段全部私有,经 VmEvents 回调驱动。
/// 类型公开(沙箱 running 字段引用),但对外无可见字段与构造面。
pub struct Execution {
  code : String
  tools : Map[String, CodemodeTool]
  globals : Map[String, CodemodeTool]
  timeout_ms : Int32
  abort : @agent_loop.AbortSignal
  memory_limit_bytes : Int32?
  store : Map[String, String]
  launch : VmLauncher
  group : Ref[@async.TaskGroup[CodemodeResult]?]
  result : @aqueue.Queue[CodemodeResult]
  channel : Ref[&VmChannel?]
  /// channel 未到位前排队的应答
  unsent : Array[HostToVmMessage]
  calls : Array[CodemodeCall]
  output : Array[CodemodeOutputItem]
  pending : Map[Int32, PendingCall]
  finished : Ref[Bool]
}

///|
async fn Execution::run(self : Execution) -> CodemodeResult {
  @async.with_task_group(async fn(group) {
    self.group.val = Some(group)
    let data : VmStartData = {
      code: self.code,
      tools: self.tools
      .values()
      .map(fn(tool) {
        {
          name: tool.name,
          js_name: to_codemode_identifier(tool.name),
          description: tool.description,
        }
      })
      .collect(),
      globals: self.globals
      .values()
      .map(fn(g) { { name: g.name, spread: g.spread, } })
      .collect(),
      memory_limit_bytes: self.memory_limit_bytes,
      store: self.store,
    }
    // 启动器可能抛错(VM 起不来)=> Sandbox 错误;channel 晚于 finish
    // 到达时要立即 stop(对应 pi 的 .then 分支)。
    // 全部侧任务 no_wait:task group 的等待计数归零时才取消剩余子任务,
    // wait 子任务(如睡满 timeout 的定时器)会把 execute 拖到自然结束。
    group.spawn_bg(no_wait=true, async fn() {
      let channel = (self.launch)(data, self) catch {
        error => {
          self.finish(
            Some({
              kind: Sandbox,
              name: None,
              message: error_message(error),
              stack: None,
            }),
          )
          return
        }
      }
      if self.finished.val {
        channel.stop() catch {
          _ => ()
        }
        return
      }
      self.channel.val = Some(channel)
      for message in self.unsent {
        channel.post(message)
      }
      self.unsent.clear()
    })
    // deadline 定时器与 abort watcher(对应 pi setTimeout + signal 监听)。
    group.spawn_bg(no_wait=true, async fn() {
      @async.sleep(self.timeout_ms)
      self.finish(
        Some({
          kind: Timeout,
          name: None,
          message: "Execution timed out after \{self.timeout_ms} ms",
          stack: None,
        }),
      )
    })
    group.spawn_bg(no_wait=true, async fn() {
      self.abort.wait_abort()
      self.finish(Some(aborted_error()))
    })
    // 主等待:终态结果;宿主协程取消转成 Aborted 收尾后再传播。
    // errdefer 覆盖取消:catch 将来不再捕获 async cancellation。
    errdefer {
      self.finish(Some(aborted_error()))
      self.stop_channel()
    }
    let result = self.result.get()
    self.stop_channel()
    result
  })
}

///|
/// 请求 channel 停 VM;阻塞直到 VM 收到停止请求(对应 pi finish() 里
/// 的 channel.stop().then(resolve) 顺序)。取消状态下照常执行。
async fn Execution::stop_channel(self : Execution) -> Unit {
  if self.channel.val is Some(channel) {
    @async.protect_from_cancel(async fn() { channel.stop() }) catch {
      _ => ()
    }
  }
}

///|
/// 首个终态胜(对应 pi finish())。
fn Execution::finish(
  self : Execution,
  error : CodemodeError?,
  value~ : Json? = None,
  writes~ : CodemodeStoreWrites? = None,
) -> Unit {
  if self.finished.val {
    return
  }
  self.finished.val = true
  let now = @async.now()
  for _id, pending in self.pending {
    if pending.record is Some(record) {
      record.duration_ms = (now - pending.started_at).to_double()
    }
    pending.controller.abort()
    pending.task.cancel()
  }
  self.pending.clear()
  self.unsent.clear()
  let result = match error {
    Some(error) =>
      CodemodeResult::Err(error~, output=self.output, calls=self.calls)
    None =>
      CodemodeResult::Ok(
        value~,
        output=self.output,
        calls=self.calls,
        store_writes=writes.unwrap_or({ set: Map([]), delete: [], }),
      )
  }
  ignore(self.result.try_put(result) catch { _ => false })
}

///|
/// VmEvents.message:VM 上报一条消息。
impl VmEvents for Execution with fn message(self, message) {
  if self.finished.val {
    return
  }
  self.handle_message(message) catch {
    error =>
      self.finish(
        Some({
          kind: Sandbox,
          name: None,
          message: "Sandbox host failed: \{error_message(error)}",
          stack: None,
        }),
      )
  }
}

///|
/// VmEvents.failure:VM/传输层在桥协议外失败。
impl VmEvents for Execution with fn failure(self, error) {
  self.finish(Some(error))
}

///|
fn Execution::handle_message(
  self : Execution,
  message : VmToHostMessage,
) -> Unit raise {
  match message {
    Output(item) => self.output.push(item)
    Call(id~, target~, name~, args~) => {
      if self.pending.contains(id) {
        raise CodemodeSandboxError("duplicate call id \{id}")
      }
      self.start_call(id, target, name, args)
    }
    Done(value~, store_writes~) =>
      self.finish(None, value~, writes=Some(store_writes))
    ScriptError(error~) => self.finish(Some(error))
    Crash(message~) =>
      self.finish(Some({ kind: Sandbox, name: None, message, stack: None, }))
  }
}

///|
/// 把一条 call 消息变成异步工具调用(对应 pi handleCall)。
/// 应答前 finish() 已发生:pending 移除为空,记录保持 cancelled,不再应答。
fn Execution::start_call(
  self : Execution,
  id : Int32,
  target : CodemodeCallTarget,
  name : String,
  args : Json?,
) -> Unit {
  let is_tool = target is Tool
  let record : CodemodeCall? = if is_tool {
    let record : CodemodeCall = { name, status: Cancelled, duration_ms: 0.0, }
    self.calls.push(record)
    Some(record)
  } else {
    None
  }
  let controller = @agent_loop.AbortController::new()
  let started_at = @async.now()
  guard self.group.val is Some(group) else { return }
  let task = group.spawn(
    async fn() {
      let mut status = CodemodeCallStatus::Error
      let reply = try {
        let executors = if is_tool { self.tools } else { self.globals }
        guard executors.get(name) is Some(tool) else {
          let kind = if is_tool { "tool" } else { "global" }
          raise CodemodeSandboxError("Unknown \{kind} \"\{name}\"")
        }
        let value = (tool.execute)(args, { signal: controller.signal, })
        status = Ok
        HostToVmMessage::Result(
          id~,
          ok=true,
          payload=value.map(fn(value) { value.stringify() }),
        )
      } catch {
        error =>
          HostToVmMessage::Result(
            id~,
            ok=false,
            payload=Some(error_message(error)),
          )
      }
      if self.pending.remove_and_get(id) is None {
        return
      }
      if record is Some(record) {
        record.status = status
        record.duration_ms = (@async.now() - started_at).to_double()
      }
      self.post(reply)
    },
    no_wait=true,
    allow_failure=true,
  )
  self.pending[id] = { record, started_at, controller, task, }
}

///|
/// 经 channel 回 VM;channel 未到位先排队(对应 pi postReply/unsent)。
fn Execution::post(self : Execution, message : HostToVmMessage) -> Unit {
  match self.channel.val {
    Some(channel) => channel.post(message)
    None => self.unsent.push(message)
  }
}

///|
/// 沙箱宿主侧的使用错误:已关闭、重复注册、非法 global 名等。
/// 不经 VM 协议,直接抛给调用方(对应 pi 的 Error 校验失败)。
pub suberror CodemodeSandboxError {
  CodemodeSandboxError(String)
}

///|
/// 取净错误消息(对应 pi errorMessage);fail() 的位置前缀一并剥掉。
fn error_message(error : Error) -> String {
  match error {
    CodemodeSandboxError(message) => message
    Failure::Failure(message) =>
      match message.find(" FAILED: ") {
        Some(i) => message[i + 9:].to_owned()
        None => message
      }
    _ => error.to_string()
  }
}

///|
fn aborted_error() -> CodemodeError {
  { kind: Aborted, name: None, message: "Execution aborted", stack: None, }
}

///|
/// load() 快照:值序列化为 JSON 文本(对应 pi serializeStore)。
fn serialize_store(store : Map[String, Json]) -> Map[String, String] {
  let serialized : Map[String, String] = Map([])
  for key, value in store {
    serialized[key] = value.stringify()
  }
  serialized
}

///|
/// 校验 global 名:标识符或 `ns.member`,不撞保留字/彼此/命名空间
/// (对应 pi checkGlobals)。
fn check_globals(globals : Array[CodemodeTool]) -> Unit raise {
  let names : Map[String, Bool] = Map([])
  let namespaces : Map[String, Bool] = Map([])
  for g in globals {
    let parts = g.name.split(".").map(fn(p) { p.to_owned() }).collect()
    if parts.length() > 2 ||
      parts.iter().any(fn(part) { !is_identifier(part) }) ||
      reserved_globals.contains(parts[0]) {
      raise CodemodeSandboxError("Invalid global name \"\{g.name}\"")
    }
    if names.contains(g.name) {
      raise CodemodeSandboxError("Global \"\{g.name}\" is already registered")
    }
    if parts.length() == 2 {
      namespaces[parts[0]] = true
    }
    names[g.name] = true
  }
  for ns, _ in namespaces {
    if names.contains(ns) {
      raise CodemodeSandboxError(
        "Global \"\{ns}\" conflicts with the namespace \"\{ns}\"",
      )
    }
  }
}

///|
let reserved_globals : Array[String] = [
  "tools", "ALL_TOOLS", "console", "text", "image", "exit", "globalThis", "store",
  "load",
]
