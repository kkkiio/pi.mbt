///|
pub(all) struct StartVmRequest {
  data : VmStartData
  interrupt_budget : Double?
}

///|
/// Message sent from the VM or remote bridge to the host.
pub(all) enum VmToHostMessage {
  Started(fingerprint~ : String)
  /// Raw JSON argument text parsed per call.
  CallTool(id~ : Int32, name~ : String, args~ : String?)
  CallGlobal(id~ : Int32, name~ : String, args~ : String?)
  Output(item~ : CodemodeOutputItem)
  DoneOk(value~ : Json?, writes~ : Array[WriteItem], during~ : CodemodeDuring?)
  DoneErr(error~ : ScriptErrorJson, during~ : CodemodeDuring?)
  Crash(message~ : String)
  Idle(seq~ : Int32, issued~ : Int32)
  Failure(error~ : CodemodeError)
}

///|
pub(all) enum HostToVmMessage {
  CallResult(CallResponse)
}

///|
/// One item of script output (`text()`, `console.*`, or `image()`). `data` is base64-encoded.
pub(all) enum CodemodeOutputItem {
  Text(text~ : String, console~ : Bool)
  Image(data~ : String, mimeType~ : String)
}

///|
pub(all) enum WriteItem {
  Set(key~ : String, value~ : Json)
  Delete(key~ : String)
}

///|
/// Call sequence and issued-call count at the moment the script finished.
#derive(ToJson, FromJson)
pub(all) struct CodemodeDuring {
  seq : Int32
  issued : Int32
}

///|
pub extend CodemodeDuring with @json.ToJson::{to_json}

///|
pub extend CodemodeDuring with @json.FromJson::{from_json}

///|
type ScriptErrorJson = Json

///|
pub(all) enum CodemodeErrorKind {
  /// The script threw or failed to parse.
  Script
  /// The execution deadline or interrupt budget expired.
  Timeout
  /// The remote VM reported an aborted execution.
  Aborted
  /// The VM or transport failed outside the script's control.
  Sandbox
}

///|
pub(all) struct CodemodeError {
  kind : CodemodeErrorKind
  name : String?
  message : String
  stack : String?
}

///|
/// Outcome of a tool or global call: resolves with `value` or rejects with `message` and optional `properties`.
pub(all) enum CallOutcome {
  Resolve(value~ : Json?)
  Reject(message~ : String, properties~ : Map[String, Json]?)
}

///|
/// Result frame for a tool or global call.
pub(all) struct CallResponse {
  id : Int32
  outcome : CallOutcome
  seq : Int32?
  now : Double?
}

///|
/// Initial VM startup payload for running a script.
pub(all) struct VmStartData {
  code : String
  tools : Array[Tool]
  globals : Array[Global]
  memory_limit_bytes : Double?
  /// Initial snapshot for `load()`.
  store : Map[String, Json]
  deterministic : Deterministic?
}

///|
pub(all) struct Tool {
  name : String
  js_name : String
  description : String
}

///|
#derive(ToJson, FromJson)
pub(all) struct Global {
  name : String
  spread : Bool
}

///|
pub extend Global with @json.ToJson::{to_json}

///|
pub extend Global with @json.FromJson::{from_json}

///|
/// Deterministic VM configuration with a virtual clock (`started_at` in ms) and PRNG `seed`.
pub(all) struct Deterministic {
  started_at : Double
  seed : UInt32
}

///|
fn[T] decode_error(
  path : @json.JsonPath,
  message : String,
) -> T raise @json.JsonDecodeError {
  raise @json.JsonDecodeError((path, message))
}

///|
fn parse_json_text(
  text : String,
  path : @json.JsonPath,
) -> Json raise @json.JsonDecodeError {
  @json.parse(text) catch {
    _ => decode_error(path, "invalid JSON payload")
  }
}

///|
pub impl @json.ToJson for StartVmRequest with fn to_json(self) -> Json {
  let obj : Map[String, Json] = Map([])
  obj["data"] = Json(self.data)
  if self.interrupt_budget is Some(budget) {
    obj["interruptBudget"] = Json(budget)
  }
  Json::object(obj)
}

///|
pub extend StartVmRequest with @json.ToJson::{to_json}

///|
pub impl FromJson for StartVmRequest with fn from_json(json, path) {
  guard json is Object(fields) else {
    decode_error(path, "StartVmRequest: expected object")
  }
  guard fields.get("data") is Some(data) else {
    decode_error(path.add_key("data"), "StartVmRequest: missing data")
  }
  let interrupt_budget = match fields.get("interruptBudget") {
    None | Some(Null) => None
    Some(Number(budget, ..)) => Some(budget)
    Some(_) => decode_error(path.add_key("interruptBudget"), "expected number")
  }
  { data: @json.from_json(data, path=path.add_key("data")), interrupt_budget, }
}

///|
pub extend StartVmRequest with @json.FromJson::{from_json}

///|
pub impl @json.ToJson for VmToHostMessage with fn to_json(self) -> Json {
  match self {
    Started(fingerprint~) => { "type": "started", "fingerprint": fingerprint }
    CallTool(id~, name~, args~) => call_message(id, "tool", name, args)
    CallGlobal(id~, name~, args~) => call_message(id, "global", name, args)
    Output(item~) => { "type": "output", "item": Json(item) }
    DoneOk(value~, writes~, during~) => {
      let obj : Map[String, Json] = Map([])
      obj["type"] = Json::string("done")
      obj["ok"] = Json::boolean(true)
      if value is Some(value) {
        obj["value"] = Json::string(value.stringify())
      }
      obj["writes"] = Json::string(Json(writes).stringify())
      if during is Some(during) {
        obj["during"] = Json(during)
      }
      Json::object(obj)
    }
    DoneErr(error~, during~) => {
      let obj : Map[String, Json] = Map([])
      obj["type"] = Json::string("done")
      obj["ok"] = Json::boolean(false)
      obj["error"] = Json::string(error.stringify())
      if during is Some(during) {
        obj["during"] = Json(during)
      }
      Json::object(obj)
    }
    Crash(message~) => { "type": "crash", "message": message }
    Idle(seq~, issued~) => { "type": "idle", "seq": seq, "issued": issued }
    Failure(error~) => { "type": "failure", "error": Json(error) }
  }
}

///|
pub extend VmToHostMessage with @json.ToJson::{to_json}

///|
fn call_message(
  id : Int32,
  target : String,
  name : String,
  args : String?,
) -> Json {
  let obj : Map[String, Json] = Map([])
  obj["type"] = Json::string("call")
  obj["id"] = Json(id)
  obj["target"] = Json::string(target)
  obj["name"] = Json(name)
  if args is Some(args) {
    obj["args"] = Json::string(args)
  }
  Json::object(obj)
}

///|
pub impl FromJson for VmToHostMessage with fn from_json(json, path) {
  guard json is Object(fields) else {
    decode_error(path, "VmToHostMessage: expected object")
  }
  guard fields.get("type") is Some(String(kind)) else {
    decode_error(path.add_key("type"), "VmToHostMessage: missing type")
  }
  let type_path = path.add_key("type")
  match kind {
    "started" =>
      Started(
        fingerprint=match fields.get("fingerprint") {
          Some(String(fingerprint)) => fingerprint
          _ => ""
        },
      )
    "call" => {
      guard fields.get("id") is Some(Number(id, ..)) else {
        decode_error(type_path, "call: missing id")
      }
      guard fields.get("name") is Some(String(name)) else {
        decode_error(type_path, "call: missing name")
      }
      let args = match fields.get("args") {
        Some(String(args)) => Some(args)
        _ => None
      }
      match fields.get("target") {
        Some(String("tool")) => CallTool(id=id.to_int(), name~, args~)
        Some(String("global")) => CallGlobal(id=id.to_int(), name~, args~)
        _ => decode_error(type_path, "call: unknown target")
      }
    }
    "output" =>
      match fields.get("item") {
        Some(item) =>
          Output(item=@json.from_json(item, path=path.add_key("item")))
        None => decode_error(type_path, "output: missing item")
      }
    "done" => {
      let during : CodemodeDuring? = match fields.get("during") {
        Some(during) if during is Object(_) =>
          Some(@json.from_json(during, path=path.add_key("during")))
        _ => None
      }
      match fields.get("ok") {
        Some(True) => {
          let value = match fields.get("value") {
            Some(String(value)) =>
              Some(parse_json_text(value, path.add_key("value")))
            _ => None
          }
          guard fields.get("writes") is Some(String(writes)) else {
            decode_error(type_path, "done: missing writes")
          }
          let parsed_writes = @json.parse(writes) catch {
            _ => decode_error(type_path, "done: writes is not valid JSON")
          }
          DoneOk(
            value~,
            writes=@json.from_json(parsed_writes, path=path.add_key("writes")),
            during~,
          )
        }
        Some(False) =>
          match fields.get("error") {
            Some(String(error)) =>
              DoneErr(
                error=parse_json_text(error, path.add_key("error")),
                during~,
              )
            _ => decode_error(type_path, "done: missing error")
          }
        _ => decode_error(type_path, "done: missing ok")
      }
    }
    "crash" =>
      match fields.get("message") {
        Some(String(message)) => Crash(message~)
        _ => decode_error(type_path, "crash: missing message")
      }
    "idle" =>
      Idle(
        seq=match fields.get("seq") {
          Some(Number(seq, ..)) => seq.to_int()
          _ => 0
        },
        issued=match fields.get("issued") {
          Some(Number(issued, ..)) => issued.to_int()
          _ => 0
        },
      )
    "failure" =>
      match fields.get("error") {
        Some(error) =>
          Failure(error=@json.from_json(error, path=path.add_key("error")))
        None => decode_error(type_path, "failure: missing error")
      }
    _ => decode_error(type_path, "unknown message type \{kind}")
  }
}

///|
pub extend VmToHostMessage with @json.FromJson::{from_json}

///|
pub impl @json.ToJson for HostToVmMessage with fn to_json(self) -> Json {
  match self {
    CallResult(response) => {
      let obj : Map[String, Json] = Map([])
      obj["type"] = Json::string("result")
      for key, value in response.fields() {
        obj[key] = value
      }
      Json::object(obj)
    }
  }
}

///|
pub extend HostToVmMessage with @json.ToJson::{to_json}

///|
pub impl FromJson for HostToVmMessage with fn from_json(json, path) {
  guard json is Object(fields) else {
    decode_error(path, "HostToVmMessage: expected object")
  }
  match fields.get("type") {
    Some(String("result")) => CallResult(@json.from_json(json, path~))
    _ => decode_error(path.add_key("type"), "HostToVmMessage: unknown type")
  }
}

///|
pub extend HostToVmMessage with @json.FromJson::{from_json}

///|
pub impl @json.ToJson for CodemodeOutputItem with fn to_json(self) -> Json {
  match self {
    Text(text~, console~) => {
      let obj : Map[String, Json] = Map([])
      obj["type"] = Json::string("text")
      obj["text"] = Json(text)
      if console {
        obj["console"] = Json::boolean(true)
      }
      Json::object(obj)
    }
    Image(data~, mimeType~) =>
      { "type": "image", "data": data, "mimeType": mimeType }
  }
}

///|
pub extend CodemodeOutputItem with @json.ToJson::{to_json}

///|
pub impl FromJson for CodemodeOutputItem with fn from_json(json, path) {
  guard json is Object(fields) else {
    decode_error(path, "CodemodeOutputItem: expected object")
  }
  match fields.get("type") {
    Some(String("text")) => {
      guard fields.get("text") is Some(String(text)) else {
        decode_error(path.add_key("text"), "text item: missing text")
      }
      Text(text~, console=fields.get("console") is Some(True))
    }
    Some(String("image")) => {
      guard fields.get("data") is Some(String(data)) &&
        fields.get("mimeType") is Some(String(mime_type)) else {
        decode_error(path, "image item: missing data or mimeType")
      }
      Image(data~, mimeType=mime_type)
    }
    _ => decode_error(path.add_key("type"), "unknown output item type")
  }
}

///|
pub extend CodemodeOutputItem with @json.FromJson::{from_json}

///|
pub impl @json.ToJson for WriteItem with fn to_json(self) -> Json {
  match self {
    Set(key~, value~) =>
      Json::array([Json(key), Json::string(value.stringify())])
    Delete(key~) => Json::array([Json(key)])
  }
}

///|
pub extend WriteItem with @json.ToJson::{to_json}

///|
pub impl FromJson for WriteItem with fn from_json(json, path) {
  match json {
    [String(key)] => Delete(key~)
    [String(key), String(value)] =>
      Set(key~, value=parse_json_text(value, path.add_index(1)))
    _ => decode_error(path, "WriteItem: malformed entry")
  }
}

///|
pub extend WriteItem with @json.FromJson::{from_json}

///|
pub impl @json.ToJson for CodemodeErrorKind with fn to_json(self) -> Json {
  Json::string(
    match self {
      Script => "script"
      Timeout => "timeout"
      Aborted => "aborted"
      Sandbox => "sandbox"
    },
  )
}

///|
pub extend CodemodeErrorKind with @json.ToJson::{to_json}

///|
pub impl FromJson for CodemodeErrorKind with fn from_json(json, path) {
  match json {
    String("script") => Script
    String("timeout") => Timeout
    String("aborted") => Aborted
    String("sandbox") => Sandbox
    _ => decode_error(path, "CodemodeErrorKind: unknown kind")
  }
}

///|
pub extend CodemodeErrorKind with @json.FromJson::{from_json}

///|
pub impl @json.ToJson for CodemodeError with fn to_json(self) -> Json {
  let obj : Map[String, Json] = Map([])
  obj["kind"] = Json(self.kind)
  if self.name is Some(name) {
    obj["name"] = Json(name)
  }
  obj["message"] = Json(self.message)
  if self.stack is Some(stack) {
    obj["stack"] = Json(stack)
  }
  Json::object(obj)
}

///|
pub extend CodemodeError with @json.ToJson::{to_json}

///|
pub impl FromJson for CodemodeError with fn from_json(json, path) {
  guard json is Object(fields) else {
    decode_error(path, "CodemodeError: expected object")
  }
  guard fields.get("kind") is Some(kind_json) else {
    decode_error(path.add_key("kind"), "CodemodeError: missing kind")
  }
  guard fields.get("message") is Some(String(message)) else {
    decode_error(path.add_key("message"), "CodemodeError: missing message")
  }
  {
    kind: @json.from_json(kind_json, path=path.add_key("kind")),
    name: match fields.get("name") {
      Some(String(name)) => Some(name)
      _ => None
    },
    message,
    stack: match fields.get("stack") {
      Some(String(stack)) => Some(stack)
      _ => None
    },
  }
}

///|
pub extend CodemodeError with @json.FromJson::{from_json}

///|
pub impl @json.ToJson for CallResponse with fn to_json(self) -> Json {
  Json::object(self.fields())
}

///|
pub extend CallResponse with @json.ToJson::{to_json}

///|
fn CallResponse::fields(self : CallResponse) -> Map[String, Json] {
  let obj : Map[String, Json] = Map([])
  obj["id"] = Json(self.id)
  match self.outcome {
    CallOutcome::Resolve(value~) => {
      obj["ok"] = Json::boolean(true)
      if value is Some(value) {
        obj["payload"] = Json::string(value.stringify())
      }
    }
    CallOutcome::Reject(message~, properties~) => {
      obj["ok"] = Json::boolean(false)
      obj["payload"] = Json::string(message)
      if properties is Some(properties) {
        obj["properties"] = Json::string(Json::object(properties).stringify())
      }
    }
  }
  if self.seq is Some(seq) {
    obj["seq"] = Json(seq)
  }
  if self.now is Some(now) {
    obj["now"] = Json(now)
  }
  obj
}

///|
pub impl FromJson for CallResponse with fn from_json(json, path) {
  guard json is Object(fields) else {
    decode_error(path, "CallResponse: expected object")
  }
  guard fields.get("id") is Some(Number(id, ..)) else {
    decode_error(path.add_key("id"), "CallResponse: missing id")
  }
  let outcome = match fields.get("ok") {
    Some(True) =>
      CallOutcome::Resolve(
        value=match fields.get("payload") {
          Some(String(payload)) =>
            Some(parse_json_text(payload, path.add_key("payload")))
          _ => None
        },
      )
    Some(False) => {
      let message = match fields.get("payload") {
        Some(String(message)) => message
        _ => ""
      }
      let properties = match fields.get("properties") {
        Some(String(properties)) =>
          match parse_json_text(properties, path.add_key("properties")) {
            Object(properties) => Some(properties)
            _ =>
              decode_error(
                path.add_key("properties"),
                "properties must be an object",
              )
          }
        _ => None
      }
      CallOutcome::Reject(message~, properties~)
    }
    _ => decode_error(path.add_key("ok"), "CallResponse: missing ok")
  }
  {
    id: id.to_int(),
    outcome,
    seq: match fields.get("seq") {
      Some(Number(seq, ..)) => Some(seq.to_int())
      _ => None
    },
    now: match fields.get("now") {
      Some(Number(now, ..)) => Some(now)
      _ => None
    },
  }
}

///|
pub extend CallResponse with @json.FromJson::{from_json}

///|
pub impl @json.ToJson for VmStartData with fn to_json(self) -> Json {
  let obj : Map[String, Json] = Map([])
  obj["code"] = Json(self.code)
  obj["tools"] = Json(self.tools)
  obj["globals"] = Json(self.globals)
  if self.memory_limit_bytes is Some(limit) {
    obj["memoryLimitBytes"] = Json(limit)
  }
  let store : Map[String, Json] = Map([])
  for key, value in self.store {
    store[key] = Json::string(value.stringify())
  }
  obj["store"] = Json::object(store)
  if self.deterministic is Some(deterministic) {
    obj["deterministic"] = Json(deterministic)
  }
  Json::object(obj)
}

///|
pub extend VmStartData with @json.ToJson::{to_json}

///|
pub impl FromJson for VmStartData with fn from_json(json, path) {
  guard json is Object(fields) else {
    decode_error(path, "VmStartData: expected object")
  }
  guard fields.get("code") is Some(String(code)) else {
    decode_error(path.add_key("code"), "VmStartData: missing code")
  }
  guard fields.get("tools") is Some(tools) else {
    decode_error(path.add_key("tools"), "VmStartData: missing tools")
  }
  guard fields.get("globals") is Some(globals) else {
    decode_error(path.add_key("globals"), "VmStartData: missing globals")
  }
  guard fields.get("store") is Some(Object(store_fields)) else {
    decode_error(path.add_key("store"), "VmStartData: missing store")
  }
  let store : Map[String, Json] = Map([])
  for key, value in store_fields {
    match value {
      String(text) =>
        store[key] = parse_json_text(text, path.add_key("store").add_key(key))
      _ =>
        decode_error(
          path.add_key("store").add_key(key),
          "store value must be a string",
        )
    }
  }
  {
    code,
    tools: @json.from_json(tools, path=path.add_key("tools")),
    globals: @json.from_json(globals, path=path.add_key("globals")),
    memory_limit_bytes: match fields.get("memoryLimitBytes") {
      Some(Number(limit, ..)) => Some(limit)
      _ => None
    },
    store,
    deterministic: match fields.get("deterministic") {
      Some(deterministic) if deterministic is Object(_) =>
        Some(@json.from_json(deterministic, path=path.add_key("deterministic")))
      _ => None
    },
  }
}

///|
pub extend VmStartData with @json.FromJson::{from_json}

///|
pub impl @json.ToJson for Tool with fn to_json(self) -> Json {
  { "name": self.name, "jsName": self.js_name, "description": self.description }
}

///|
pub extend Tool with @json.ToJson::{to_json}

///|
pub impl FromJson for Tool with fn from_json(json, path) {
  guard json
    is {
      "name": String(name),
      "jsName": String(js_name),
      "description": String(description),
      ..
    } else {
    decode_error(path, "Tool: expected { name, jsName, description }")
  }
  { name, js_name, description, }
}

///|
pub extend Tool with @json.FromJson::{from_json}

///|
pub impl @json.ToJson for Deterministic with fn to_json(self) -> Json {
  { "startedAt": self.started_at, "seed": self.seed }
}

///|
pub extend Deterministic with @json.ToJson::{to_json}

///|
pub impl FromJson for Deterministic with fn from_json(json, path) {
  guard json is Object(fields) else {
    decode_error(path, "Deterministic: expected object")
  }
  guard fields.get("startedAt") is Some(Number(started_at, ..)) else {
    decode_error(path.add_key("startedAt"), "Deterministic: missing startedAt")
  }
  guard fields.get("seed") is Some(seed) else {
    decode_error(path.add_key("seed"), "Deterministic: missing seed")
  }
  { started_at, seed: @json.from_json(seed, path=path.add_key("seed")), }
}

///|
pub extend Deterministic with @json.FromJson::{from_json}
