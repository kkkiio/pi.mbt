///|
/// VM 启动参数,每次 execute 一份(对应 pi VmStartData,去掉 deterministic 字段)。
pub(all) struct VmStartData {
  /// 已移除 @options 行的脚本(async 函数体)
  code : String
  tools : Array[CodemodeToolDecl]
  globals : Array[CodemodeGlobalDecl]
  /// QuickJS 堆上限;超限在脚本内抛 InternalError: out of memory
  memory_limit_bytes : Int32?
  /// load() 数据源;键到 JSON 文本,宿主侧已序列化
  store : Map[String, String]
}

///|
/// 脚本侧看到的工具声明(对应 pi CodemodeDeclaredTool)。
pub(all) struct CodemodeToolDecl {
  name : String
  /// tools.<js_name>;构造时默认 to_codemode_identifier(name)
  js_name : String
  description : String
}

///|
/// 脚本侧看到的 global(对应 pi CodemodeDeclaredGlobal)。
pub(all) struct CodemodeGlobalDecl {
  /// 标识符或 `ns.member`(member 归入冻结的命名空间对象)
  name : String
  spread : Bool
}

///|
pub(all) enum CodemodeCallTarget {
  Tool
  Global
}

///|
/// VM -> host(对应 pi WorkerToHostMessage;去掉 started/idle/during 回放字段)。
pub(all) enum VmToHostMessage {
  /// text()/image()/console.* 产出
  Output(CodemodeOutputItem)
  /// 脚本发起调用;args 已 JSON 往返
  Call(id~ : Int32, target~ : CodemodeCallTarget, name~ : String, args~ : Json?)
  /// 脚本完成(含 exit());携带 return 值与 store 净写入
  Done(value~ : Json?, store_writes~ : CodemodeStoreWrites)
  /// 脚本侧错误(kind=Script)
  ScriptError(error~ : CodemodeError)
  /// VM 自身崩溃(kind=Sandbox)
  Crash(message~ : String)
}

///|
/// host -> VM(对应 pi HostToWorkerMessage;去掉 seq/now/properties)。
/// 目前只有工具结果应答;停止 VM 走 VmChannel::stop。
pub(all) enum HostToVmMessage {
  /// 应答 call id;payload 是线上文本:ok=true 为结果的 JSON 文本,
  /// ok=false 为裸错误消息(对应 pi 的 settle(id, ok, payload))
  Result(id~ : Int32, ok~ : Bool, payload~ : String?)
} derive(ToJson)

///|
pub extend HostToVmMessage with ToJson::{to_json}
