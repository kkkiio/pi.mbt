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

///|
/// VmStartData 里工具声明的线上 JSON(对应 workerData.tools)。
fn encode_tools_json(tools : Array[CodemodeToolDecl]) -> Json {
  Json::array(
    tools.map(fn(tool) {
      Json::object({
        "name": Json(tool.name),
        "jsName": Json(tool.js_name),
        "description": Json(tool.description),
      })
    }),
  )
}

///|
/// global 声明的线上 JSON(对应 workerData.globals)。
fn encode_globals_json(globals : Array[CodemodeGlobalDecl]) -> Json {
  Json::array(
    globals.map(fn(g) {
      Json::object({ "name": Json(g.name), "spread": Json(g.spread) })
    }),
  )
}

///|
/// load() 数据源的线上形状:key -> JSON 文本。
fn encode_store_json(store : Map[String, String]) -> Json {
  let map : Map[String, Json] = Map([])
  for key, value in store {
    map[key] = Json(value)
  }
  Json::object(map)
}

///|
/// VM -> 宿主消息解码(对应 pi protocol.ts 的 WorkerToHostMessage;
/// started/idle 只在 deterministic 模式出现,忽略)。text 是线上 JSON;
/// 非法消息/载荷报 failure(Sandbox),对应 pi 的 "Sandbox bridge broken"。
/// js 与 native 两个启动器产出同一种线上格式,共用此解码。
fn deliver_worker_message(events : &VmEvents, text : String) -> Unit {
  let message = match try_parse(text) {
    Some(Object(map)) => map
    _ => {
      events.failure({
        kind: Sandbox,
        name: None,
        message: "Sandbox bridge broken: worker message is not an object",
        stack: None,
      })
      return
    }
  }
  match message.get("type") {
    Some(String("call")) =>
      match (message.get("id"), message.get("target"), message.get("name")) {
        (Some(Number(id, ..)), Some(String(target)), Some(String(name))) => {
          let args = match message.get("args") {
            Some(String(args)) =>
              match try_parse(args) {
                Some(args) => Some(args)
                None => {
                  events.failure(bridge_broken("call args is not valid JSON"))
                  return
                }
              }
            _ => None
          }
          events.message(
            Call(
              id=id.to_int(),
              target=if target == "global" { Global } else { Tool },
              name~,
              args~,
            ),
          )
        }
        _ => events.failure(bridge_broken("malformed call message"))
      }
    Some(String("output")) =>
      match message.get("item") {
        Some(
          Object(
            {
              "type": String("image"),
              "data": String(data),
              "mimeType": String(mime_type),
              ..
            }
          )
        ) => events.message(Output(Image(data~, mime_type~)))
        Some(Object({ "type": String("text"), "text": String(text), .. })) =>
          events.message(
            Output(
              Text(
                text~,
                console=match message.get("item") {
                  Some(Object({ "console": True, .. })) => true
                  _ => false
                },
              ),
            ),
          )
        _ => events.failure(bridge_broken("malformed output message"))
      }
    Some(String("done")) =>
      match message.get("ok") {
        Some(True) => {
          let value = match message.get("value") {
            Some(String(value)) =>
              match try_parse(value) {
                Some(value) => Some(value)
                None => {
                  events.failure(bridge_broken("done value is not valid JSON"))
                  return
                }
              }
            _ => None
          }
          match decode_store_writes(message.get("writes")) {
            Ok(store_writes) => events.message(Done(value~, store_writes~))
            Err(reason) => events.failure(bridge_broken(reason))
          }
        }
        Some(False) =>
          match decode_script_error(message.get("error")) {
            Ok(error) => events.message(ScriptError(error~))
            Err(reason) => events.failure(bridge_broken(reason))
          }
        _ => events.failure(bridge_broken("malformed done message"))
      }
    Some(String("crash")) =>
      events.message(
        Crash(
          message=match message.get("message") {
            Some(String(message)) => message
            _ => "Worker crashed"
          },
        ),
      )
    // deterministic 模式的握手消息,非 deterministic 运行不会出现
    Some(String("started")) | Some(String("idle")) => ()
    _ => events.failure(bridge_broken("unknown worker message type"))
  }
}

///|
/// JSON 解析为 Option;桥解码失败统一走 bridge_broken。
fn try_parse(text : String) -> Json? {
  Some(@json.parse(text)) catch {
    _ => None
  }
}

///|
fn bridge_broken(reason : String) -> CodemodeError {
  {
    kind: Sandbox,
    name: None,
    message: "Sandbox bridge broken: \{reason}",
    stack: None,
  }
}

///|
/// writesJson: `[[key],[key,valueJson],...]`(对应 pi parseStoreWrites)。
fn decode_store_writes(field : Json?) -> Result[CodemodeStoreWrites, String] {
  guard field is Some(String(json)) else {
    // exit()/无写入时 prelude 也发 writes;缺省按空写入处理
    return Ok({ set: Map([]), delete: [], })
  }
  guard try_parse(json) is Some(Array(entries)) else {
    return Err("store writes are not an array")
  }
  let set : Map[String, Json] = Map([])
  let delete : Array[String] = []
  for entry in entries {
    guard entry is Array([String(key), .. rest]) && rest.length() <= 1 else {
      return Err("store writes contain a malformed entry")
    }
    match rest {
      [String(value)] =>
        match try_parse(value) {
          Some(value) => set[key] = value
          None => return Err("store value for \{key} is not valid JSON")
        }
      [] => delete.push(key)
      _ => return Err("store writes contain a malformed entry")
    }
  }
  Ok({ set, delete, })
}

///|
/// errorJson: `{name?, message, stack?}`(对应 pi parseScriptError,
/// kind 固定 Script)。
fn decode_script_error(field : Json?) -> Result[CodemodeError, String] {
  guard field is Some(String(json)) else {
    return Err("script error is missing")
  }
  guard try_parse(json) is Some(Object(map)) else {
    return Err("script error is not an object")
  }
  guard map.get("message") is Some(String(message)) else {
    return Err("script error is malformed")
  }
  Ok({
    kind: Script,
    name: match map.get("name") {
      Some(String(name)) => Some(name)
      _ => None
    },
    message,
    stack: match map.get("stack") {
      Some(String(stack)) => Some(stack)
      _ => None
    },
  })
}
