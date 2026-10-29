///|
struct Codemode {
  vm_launcher : async () -> &VmChannel
  tools : Map[String, CodemodeTool]
  globals : Map[String, CodemodeTool]
  timeout_ms : Int32
  memory_limit_bytes : Double?
}

///|
/// Create a new codemode instance.
pub fn Codemode::Codemode(
  vm_launcher : async () -> &VmChannel,
  tools~ : Array[CodemodeTool] = [],
  globals~ : Array[CodemodeTool] = [],
  timeout_ms~ : Int32 = 300000,
  memory_limit_bytes~ : Double? = Some(256.0 * 1024 * 1024),
) -> Codemode {
  Codemode::{
    vm_launcher,
    tools: tools.iter().map(tool => (tool.name, tool)) |> Map::from_iter,
    globals: globals.iter().map(global => (global.name, global))
    |> Map::from_iter,
    timeout_ms,
    memory_limit_bytes,
  }
}

///|
/// Run `code` to completion on a fresh VM, answering the script's tool and
/// global calls from `tools`/`globals` and accumulating its output. `store`
/// is the `load()` snapshot; writes are reported in the result for the
/// caller to apply.
///
/// The deadline includes VM launch and returns a `Timeout` error after cancelling
/// in-flight calls and waiting for their cleanup. Nonpositive deadlines disable it.
/// External task cancellation propagates after cleanup without producing a result.
/// Every acquired VM is closed on exit; closing must stop the remote execution.
/// A stream ending before a terminal frame produces a `Sandbox` error.
pub async fn Codemode::execute(
  self : Codemode,
  code : String,
  store~ : Map[String, Json] = Map([]),
  timeout_ms~ : Int32? = None,
) -> CodemodeResult {
  let deadline_ms = timeout_ms.unwrap_or(self.timeout_ms)
  let output : Array[CodemodeOutputItem] = []
  let calls : Array[CodemodeCall] = []
  let pending : Map[Int32, PendingCall] = Map([])
  let sandbox = fn(message : String) -> CodemodeResult {
    CodemodeResult::Err(
      error={
        kind: CodemodeErrorKind::Sandbox,
        name: None,
        message,
        stack: None,
      },
      output~,
      calls~,
      during=None,
    )
  }
  let bridge = fn(message : String) -> CodemodeResult {
    sandbox(
      "Sandbox bridge broken: \{message}. The script may have modified built-ins such as a prototype's toJSON.",
    )
  }
  @async.with_task_group(tg => {
    if deadline_ms > 0 {
      tg.spawn_bg(no_wait=true, () => {
        @async.sleep(deadline_ms)
        tg.return_immediately(
          CodemodeResult::Err(
            error={
              kind: CodemodeErrorKind::Timeout,
              name: None,
              message: "Execution timed out after \{deadline_ms} ms",
              stack: None,
            },
            output~,
            calls~,
            during=None,
          ),
        )
      })
    }
    let vm = (self.vm_launcher)()
    defer {
      vm.close()
      let finished_at = @async.now()
      for call in pending.values() {
        if call.record is Some(record) {
          record.duration_ms = (finished_at - call.started_at).to_int()
        }
      }
      pending.clear()
    }
    vm.send(
      Json(StartVmRequest::{
        data: VmStartData::{
          code,
          tools: self.tools
          .values()
          .map(tool => Tool::{
            name: tool.name,
            js_name: tool.js_name.unwrap_or(to_codemode_identifier(tool.name)),
            description: tool.description,
          })
          .collect(),
          globals: self.globals
          .values()
          .map(global => Global::{ name: global.name, spread: global.spread, })
          .collect(),
          memory_limit_bytes: self.memory_limit_bytes,
          store,
          deterministic: None,
        },
        interrupt_budget: None,
      }),
    ) catch {
      error => return sandbox("Sandbox start failed: \{error.to_string()}")
    }
    let batch : Array[Json] = []
    let result = while true {
      @async.pause()
      if batch.is_empty() {
        let frame = vm.recv() catch {
          _ => break sandbox("Sandbox stream ended before the script settled")
        }
        if frame is Array(messages) {
          for message in messages {
            batch.push(message)
          }
        } else {
          batch.push(frame)
        }
      }
      let message : VmToHostMessage = @json.from_json(batch.remove(0)) catch {
        _ =>
          break sandbox(
            "Sandbox bridge broken: the frame is not a valid VM message. The script may have modified built-ins such as a prototype's toJSON.",
          )
      }
      match message {
        Started(_) => () // TODO: deterministic mode
        CallTool(id~, name~, args~) => {
          if pending.contains(id) {
            break bridge("duplicate call id \{id}")
          }
          self.dispatch_call(
            tg,
            vm,
            pending,
            calls,
            is_tool=true,
            id~,
            name~,
            args_text=args,
          )
        }
        CallGlobal(id~, name~, args~) => {
          if pending.contains(id) {
            break bridge("duplicate call id \{id}")
          }
          self.dispatch_call(
            tg,
            vm,
            pending,
            calls,
            is_tool=false,
            id~,
            name~,
            args_text=args,
          )
        }
        Output(item~) => output.push(item)
        DoneOk(value~, writes~, during~) => {
          let store_writes = CodemodeStoreWrites::{ set: {}, delete: [], }
          for write in writes {
            match write {
              WriteItem::Set(key~, value~) => store_writes.set[key] = value
              WriteItem::Delete(key~) => store_writes.delete.push(key)
            }
          }
          break CodemodeResult::Ok(
            value~,
            output~,
            calls~,
            store_writes~,
            during~,
          )
        }
        DoneErr(error~, during~) =>
          match error {
            Object(fields) =>
              match fields.get("message") {
                Some(String(err_message)) =>
                  break CodemodeResult::Err(
                    error={
                      kind: CodemodeErrorKind::Script,
                      name: match fields.get("name") {
                        Some(String(name)) => Some(name)
                        _ => None
                      },
                      message: err_message,
                      stack: match fields.get("stack") {
                        Some(String(stack)) => Some(stack)
                        _ => None
                      },
                    },
                    output~,
                    calls~,
                    during~,
                  )
                _ => break bridge("script error is malformed")
              }
            _ => break bridge("script error is not an object")
          }
        Crash(message~) => break sandbox(message)
        Idle(_) => () // TODO: deterministic mode
        Failure(error~) =>
          break CodemodeResult::Err(error~, output~, calls~, during=None)
      }
    } nobreak {
      fail("unreachable: the loop only ends through `break`")
    }
    result
  })
}

///|
pub(open) trait VmChannel {
  /// Send one whole JSON message to the peer.
  async fn send(Self, Json) -> Unit
  /// Receive the next whole JSON message.
  async fn recv(Self) -> Json
  /// Stop the remote execution and release the stream.
  fn close(Self) -> Unit
}

///|
priv struct PendingCall {
  record : CodemodeCall?
  started_at : Int64
}

///|
/// Record the call and answer it. A missing tool/global gets an immediate
/// error result; a found one runs in a background task so concurrent script
/// calls stay concurrent. `pending` tracks in-flight calls, and finishing
/// the execution clears it so a late reply sends nothing.
async fn Codemode::dispatch_call(
  self : Codemode,
  tg : @async.TaskGroup[CodemodeResult],
  vm : &VmChannel,
  pending : Map[Int32, PendingCall],
  calls : Array[CodemodeCall],
  is_tool~ : Bool,
  id~ : Int32,
  name~ : String,
  args_text~ : String?,
) -> Unit {
  let record : CodemodeCall? = if is_tool {
    let record = CodemodeCall::{ name, status: "cancelled", duration_ms: 0, }
    calls.push(record)
    Some(record)
  } else {
    None
  }
  pending[id] = PendingCall::{ record, started_at: @async.now(), }
  let reject = async fn(message : String) {
    pending.remove(id)
    if record is Some(record) {
      record.status = "error"
    }
    ignore(
      vm.send(
        Json(
          HostToVmMessage::CallResult({
            id,
            outcome: CallOutcome::Reject(message~, properties=None),
            seq: None,
            now: None,
          }),
        ),
      ) catch {
        _ => ()
      },
    )
  }
  let table = if is_tool { self.tools } else { self.globals }
  guard table.get(name) is Some(tool) else {
    reject("Unknown \{if is_tool { "tool" } else { "global" }} \"\{name}\"")
    return
  }
  let args : Json? = match args_text {
    Some(text) =>
      (@json.parse(text) catch {
        _ => {
          reject("call arguments are not valid JSON")
          return
        }
      })
      |> Some
    None => None
  }
  tg.spawn_bg(no_wait=true, () => {
    let outcome = CallOutcome::Resolve(value=Some((tool.execute)(args))) catch {
      error if @async.is_being_cancelled() => raise error
      Failure::Failure(message) =>
        CallOutcome::Reject(message~, properties=None)
      error => CallOutcome::Reject(message=error.to_string(), properties=None)
    }
    if pending.remove_and_get(id) is Some(call) {
      if call.record is Some(record) {
        record.status = match outcome {
          CallOutcome::Resolve(_) => "ok"
          CallOutcome::Reject(_) => "error"
        }
        record.duration_ms = (@async.now() - call.started_at).to_int()
      }
      ignore(
        vm.send(
          Json(
            HostToVmMessage::CallResult({ id, outcome, seq: None, now: None, }),
          ),
        ) catch {
          _ => ()
        },
      )
    }
  })
}

///|
/// A `tools.<name>` or global the script can call. `execute` receives the
/// call's first argument after a JSON round trip — `None` for `undefined`,
/// `Some(Null)` for explicit `null` — or the whole arguments array when
/// `spread`. Its return value is serialized
/// back to the script; raising rejects the script's promise with the error
/// message.
pub(all) struct CodemodeTool {
  name : String
  /// The identifier the script uses; `to_codemode_identifier(name)` when unset.
  js_name : String?
  /// Listed in `ALL_TOOLS` for tools.
  description : String
  /// Schema of the single argument, for declaration rendering.
  input_schema : Json?
  /// Schema of the resolved value, for declaration rendering.
  output_schema : Json?
  /// Globals only: `execute` receives all call arguments as an array.
  spread : Bool
  /// Globals only: TypeScript parameter list and return type for
  /// `render_declarations`, replacing the rendering from the schemas.
  signature : String?
  execute : async (Json?) -> Json
}

///|
/// pi's `CodemodeResult`. `output` is kept for failed executions too, up to
/// the failure. `during` is the result the VM was processing when a
/// script-ended run finished.
pub(all) enum CodemodeResult {
  Ok(
    value~ : Json?,
    output~ : Array[CodemodeOutputItem],
    calls~ : Array[CodemodeCall],
    store_writes~ : CodemodeStoreWrites,
    during~ : CodemodeDuring?
  )
  Err(
    error~ : CodemodeError,
    output~ : Array[CodemodeOutputItem],
    calls~ : Array[CodemodeCall],
    during~ : CodemodeDuring?
  )
}

///|
/// pi's `CodemodeCall`: one `tools.*` call's entry in the `calls` ledger,
/// `status` is `"ok"`, `"error"`, or `"cancelled"` (still in flight when the
/// execution ended).
pub(all) struct CodemodeCall {
  name : String
  mut status : String
  mut duration_ms : Int32
}

///|
/// Keys the script changed with `store()`. Only successful executions report writes.
pub(all) struct CodemodeStoreWrites {
  set : Map[String, Json]
  delete : Array[String]
}
