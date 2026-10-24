///|
/// 脚本可调用的实体(对应 pi CodemodeTool)。
/// tools[] 成员挂到 `tools.<id>`;globals[] 成员挂到顶层标识符或
/// `ns.member`,行为同 tools 但不计入 result.calls。
pub(all) struct CodemodeTool {
  name : String
  /// 声明渲染中的 doc comment;tools 的 ALL_TOOLS 条目
  description : String
  /// 单参数 schema;None 渲染为 unknown
  input_schema : Json?
  /// resolve 值 schema;None 渲染为 unknown
  output_schema : Json?
  /// globals 专用:true 时 execute 收到全部参数组成的数组而非第一个参数
  spread : Bool
  /// globals 专用:完整 TS 签名串(如 `(type: string): Promise<Model[]>`),
  /// 声明渲染时覆盖 schema 推导
  signature : String?
  /// args 已做 JSON 往返;返回值须可 JSON 序列化(None 即 undefined);
  /// raise 的错误在脚本侧呈现为同名 Error
  execute : async (Json?, CodemodeToolContext) -> Json?
}

///|
/// 便捷构造器:默认值覆盖 pi 的可选字段。
pub fn CodemodeTool::new(
  name~ : String,
  execute~ : async (Json?, CodemodeToolContext) -> Json?,
  description~ : String = "",
  input_schema~ : Json? = None,
  output_schema~ : Json? = None,
  spread~ : Bool = false,
  signature~ : String? = None,
) -> CodemodeTool {
  {
    name,
    description,
    input_schema,
    output_schema,
    spread,
    signature,
    execute,
  }
}

///|
/// 嵌套调用上下文(对应 pi CodemodeToolContext)。
pub(all) struct CodemodeToolContext {
  /// 脚本结束(含未 await 的调用)/超时/宿主 abort/沙箱 close 时置位
  signal : @agent_loop.AbortSignal
}

///|
/// 脚本产出的一个输出项,按产生顺序排列(对应 pi CodemodeOutputItem)。
/// text() 与 return 值产生 Text;console.* 产生 console=true 的 Text;
/// image() 产生 Image。
pub(all) enum CodemodeOutputItem {
  Text(text~ : String, console~ : Bool)
  /// data 为 base64
  Image(data~ : String, mime_type~ : String)
} derive(ToJson)

///|
pub(all) enum CodemodeCallStatus {
  Ok
  Error
  Cancelled
} derive(ToJson)

///|
/// 一次脚本发起的工具调用记录(对应 pi CodemodeCall)。
/// status/duration_ms 由宿主在调用生命周期内更新:创建即 cancelled,
/// 应答后改写为 ok/error 并填耗时。
pub(all) struct CodemodeCall {
  name : String
  mut status : CodemodeCallStatus
  mut duration_ms : Double
} derive(ToJson)

///|
/// 执行失败分类(对应 pi CodemodeErrorKind)。
pub(all) enum CodemodeErrorKind {
  /// 脚本抛错或语法错误;name/stack 来自脚本侧
  Script
  /// 总时限(含工具调用耗时)到期
  Timeout
  /// 调用方 abort 或沙箱 close
  Aborted
  /// VM 或传输层自身故障(非脚本可控,如线程退出、wasm trap)
  Sandbox
} derive(ToJson)

///|
pub(all) struct CodemodeError {
  kind : CodemodeErrorKind
  name : String?
  message : String
  stack : String?
} derive(ToJson)

///|
/// 脚本 store() 的净写入;仅成功执行才上报(对应 pi CodemodeStoreWrites)。
pub(all) struct CodemodeStoreWrites {
  set : Map[String, Json]
  /// store(key, undefined) 记为删除
  delete : Array[String]
} derive(ToJson)

///|
/// 执行结果(对应 pi CodemodeResult 联合类型的两个分支)。
/// 失败分支同样保留截至失败时的 output 与 calls。
pub(all) enum CodemodeResult {
  Ok(
    value~ : Json?,
    output~ : Array[CodemodeOutputItem],
    calls~ : Array[CodemodeCall],
    store_writes~ : CodemodeStoreWrites
  )
  Err(
    error~ : CodemodeError,
    output~ : Array[CodemodeOutputItem],
    calls~ : Array[CodemodeCall]
  )
} derive(ToJson)

///|
pub extend CodemodeOutputItem with ToJson::{to_json}

///|
pub extend CodemodeCallStatus with ToJson::{to_json}

///|
pub extend CodemodeCall with ToJson::{to_json}

///|
pub extend CodemodeErrorKind with ToJson::{to_json}

///|
pub extend CodemodeError with ToJson::{to_json}

///|
pub extend CodemodeStoreWrites with ToJson::{to_json}

///|
pub extend CodemodeResult with ToJson::{to_json}
