///|
/// js target 的默认启动器(对应 pi host.ts 的 workerLauncher):
/// 每个执行起一个 node:worker_threads Worker,加载
/// @earendil-works/pi-codemode 的 worker.js(quickjs-wasi + prelude),
/// SharedArrayBuffer interrupt flag + terminate() 实现停止。
///
/// FFI 全程同步:wasm 以 BufferSource 克隆进 workerData(quickjs-wasi 的
/// resolveModule 接受字节),消息回调同步进 MoonBit;JS 异常不进 MoonBit
/// 错误通道,统一转成 { ok, worker/error } 数据或 on_failure 上报。
fn default_vm_launcher() -> VmLauncher {
  async fn(data, events) {
    @async.pause()
    let wasm = match wasm_bytes.val {
      Some(bytes) => bytes
      None => {
        let path = quickjs_wasm_path()
        let bytes = read_file_sync(path)
        wasm_bytes.val = Some(bytes)
        bytes
      }
    }
    let start_json : Json = {
      "code": Json(data.code),
      "tools": Json(
        data.tools.map(fn(tool) {
          Json::object({
            "name": Json(tool.name),
            "jsName": Json(tool.js_name),
            "description": Json(tool.description),
          })
        }),
      ),
      "globals": Json(
        data.globals.map(fn(g) {
          Json::object({ "name": Json(g.name), "spread": Json(g.spread) })
        }),
      ),
      "store": Json::object(store_json(data.store)),
    }
    let start_obj = match data.memory_limit_bytes {
      Some(limit) => {
        guard start_json is Object(map) else { abort("unreachable") }
        map["memoryLimitBytes"] = Json::number(limit.to_double())
        start_json.stringify()
      }
      None => start_json.stringify()
    }
    let spawned = spawn_codemode_worker(
      worker_ctor(),
      codemode_worker_path(),
      start_obj,
      wasm,
      fn(text) {
        deliver_worker_message(events, text)
        pump_scheduler()
      },
      fn(text) {
        events.failure({
          kind: Sandbox,
          name: None,
          message: text,
          stack: None,
        })
        pump_scheduler()
      },
    )
    guard spawned.is_ok() else { raise CodemodeSandboxError(spawned.error()) }
    JsWorkerChannel::{ worker: spawned.worker(), }
  }
}

///|
/// 快速JS wasm 字节缓存(对应 pi wasm.ts 的 modules Map;字节态,
/// 克隆进每个 workerData,由 worker 侧 resolveModule 编译)。
let wasm_bytes : Ref[Bytes?] = Ref(None)

///|
/// load() 数据源的线上形状:key -> JSON 文本。
fn store_json(store : Map[String, String]) -> Map[String, Json] {
  let map : Map[String, Json] = Map([])
  for key, value in store {
    map[key] = Json(value)
  }
  map
}

///|
/// JS 事件回调里触发的协程工作(spawn 工具任务、唤醒等待的协程)只进
/// 调度器的就绪队列,必须有 reschedule 才会跑——那一步是 internal 的。
/// run_async_main 是 spawn + reschedule,借它泵一轮;空协程零开销。
/// 缺了这步,就绪任务会挨饿到下一次偶发调度(复现:x64 CI 上饿死 300s)。
fn pump_scheduler() -> Unit {
  @async.run_async_main(async fn() { @async.pause() })
}

///|
/// worker -> 宿主消息解码(对应 pi protocol.ts 的 WorkerToHostMessage;
/// started/idle 只在 deterministic 模式出现,忽略)。非法消息/载荷报
/// failure(Sandbox),对应 pi 的 "Sandbox bridge broken"。
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

///|
/// Worker 句柄的宿主侧通道。
priv struct JsWorkerChannel {
  worker : JsWorker
}

///|
impl VmChannel for JsWorkerChannel with fn post(self, message) {
  match message {
    Result(id~, ok~, payload~) =>
      match payload {
        Some(payload) => self.worker.post_result(id, ok, payload, true)
        None => self.worker.post_result(id, ok, "", false)
      }
  }
}

///|
/// 对应 pi stop():先置 interrupt flag(VM 自旋时由 wasm 轮询打断),
/// terminate 不等退出,unref 防悬挂引用拖住进程。
impl VmChannel for JsWorkerChannel with fn stop(self) {
  self.worker.terminate_vm()
}

///|
#external
priv type JsWorker

///|
/// spawn 结果:JS 侧异常不进 MoonBit catch,用 { ok, worker|error } 传递。
#external
priv type JsSpawnResult

///|
#external
priv type JsWorkerCtor

///|
#module("node:fs")
extern "js" fn read_file_sync(path : String) -> Bytes = "readFileSync"

///|
/// 包内资源路径:从 quickjs.wasm 的 require.resolve 位置推导
/// node_modules 根(pi-codemode 未导出 ./worker 的 require 条件,
/// 且 bundle 可能是 CJS,不能用 import.meta.resolve)。
/// process.argv[1] 是正在执行的 bundle,其 node_modules 即依赖根。
extern "js" fn quickjs_wasm_path() -> String =
  #| () => process.getBuiltinModule("node:module")
  #|       .createRequire(process.argv[1])
  #|       .resolve("quickjs-wasi/quickjs.wasm")

///|
extern "js" fn codemode_worker_path() -> String =
  #| () => {
  #|   const path = process.getBuiltinModule("node:path");
  #|   const req = process.getBuiltinModule("node:module").createRequire(process.argv[1]);
  #|   const root = path.dirname(path.dirname(req.resolve("quickjs-wasi/quickjs.wasm")));
  #|   return path.join(root, "@earendil-works/pi-codemode/dist/runtime/worker.js");
  #| }

///|
/// ESM 没有 require;process.getBuiltinModule 同步拿内建模块(Node >= 22)。
extern "js" fn worker_ctor() -> JsWorkerCtor =
  #| () => process.getBuiltinModule("node:worker_threads").Worker

///|
extern "js" fn JsSpawnResult::is_ok(self : JsSpawnResult) -> Bool =
  #| (res) => res.ok

///|
extern "js" fn JsSpawnResult::worker(self : JsSpawnResult) -> JsWorker =
  #| (res) => res.worker

///|
extern "js" fn JsSpawnResult::error(self : JsSpawnResult) -> String =
  #| (res) => res.error

///|
/// 起 worker:workerData 带 wasm 字节 + interrupt SAB(对应 pi
/// workerData = { ...data, wasm, interrupt })。
extern "js" fn spawn_codemode_worker(
  worker_ctor : JsWorkerCtor,
  worker_url : String,
  start_json : String,
  wasm : Bytes,
  on_message : (String) -> Unit,
  on_failure : (String) -> Unit,
) -> JsSpawnResult =
  #| (WorkerCtor, workerUrl, startJson, wasmBytes, onMessage, onFailure) => {
  #|   try {
  #|     const interrupt = new SharedArrayBuffer(4);
  #|     const workerData = { ...JSON.parse(startJson), wasm: wasmBytes, interrupt };
  #|     const worker = new WorkerCtor(workerUrl, { workerData });
  #|     worker.__pimInterrupt = interrupt;
  #|     worker.on("message", (message) => {
  #|       // Node --watch 会向 worker 通道漏依赖报告(nodejs/node#65044)
  #|       if (typeof message === "object" && message !== null &&
  #|           ("watch:import" in message || "watch:require" in message)) return;
  #|       onMessage(JSON.stringify(message));
  #|     });
  #|     worker.on("error", (error) => {
  #|       onFailure(error instanceof Error ? `${error.name}: ${error.message}` : String(error));
  #|     });
  #|     worker.on("exit", (code) => {
  #|       onFailure(`Worker exited with code ${code} before the script settled`);
  #|     });
  #|     return { ok: true, worker };
  #|   } catch (error) {
  #|     return { ok: false, error: error instanceof Error ? `${error.name}: ${error.message}` : String(error) };
  #|   }
  #| }

///|
extern "js" fn JsWorker::post_result(
  self : JsWorker,
  id : Int32,
  ok : Bool,
  payload : String,
  has_payload : Bool,
) -> Unit =
  #| (worker, id, ok, payload, hasPayload) =>
  #| worker.postMessage({ type: "result", id, ok, payload: hasPayload ? payload : undefined })

///|
extern "js" fn JsWorker::terminate_vm(self : JsWorker) -> Unit =
  #| (worker) => {
  #|   Atomics.store(new Int32Array(worker.__pimInterrupt), 0, 1);
  #|   void worker.terminate().catch(() => undefined);
  #|   worker.unref();
  #| }
