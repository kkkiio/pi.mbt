///|
/// Encode, snapshot the wire shape, decode, and require the decoded message
/// to re-encode to the same text.
fn[T : @json.ToJson + @json.FromJson] roundtrip(
  value : T,
  expected~ : Json,
) -> Unit raise {
  let json = Json(value)
  @json.json_inspect(json, content=expected)
  let decoded : T = @json.from_json(json)
  assert_eq(Json(decoded).stringify(), json.stringify())
}

///|
test "tool call carries args as a JSON-encoded string" {
  roundtrip(
    @codemode.VmToHostMessage::CallTool(
      id=1,
      name="bash",
      args=Some("{\"command\":\"ls\"}"),
    ),
    expected={
      "type": "call",
      "id": 1,
      "target": "tool",
      "name": "bash",
      "args": "{\"command\":\"ls\"}",
    },
  )
}

///|
test "global call without arguments omits the args key" {
  roundtrip(
    @codemode.VmToHostMessage::CallGlobal(id=2, name="image", args=None),
    expected={ "type": "call", "id": 2, "target": "global", "name": "image" },
  )
}

///|
test "started announces the vm fingerprint" {
  roundtrip(@codemode.VmToHostMessage::Started(fingerprint="fp1"), expected={
    "type": "started",
    "fingerprint": "fp1",
  })
}

///|
test "console output keeps the console flag" {
  roundtrip(
    @codemode.VmToHostMessage::Output(
      item=@codemode.CodemodeOutputItem::Text(text="hi", console=true),
    ),
    expected={
      "type": "output",
      "item": { "type": "text", "text": "hi", "console": true },
    },
  )
}

///|
/// pi types `console` as `console?: true`: `false` means the key is absent,
/// never `"console": false`.
test "plain text output omits the console key" {
  roundtrip(
    @codemode.VmToHostMessage::Output(
      item=@codemode.CodemodeOutputItem::Text(text="hi", console=false),
    ),
    expected={ "type": "output", "item": { "type": "text", "text": "hi" } },
  )
}

///|
test "image output carries base64 data and mimeType" {
  roundtrip(
    @codemode.VmToHostMessage::Output(
      item=@codemode.CodemodeOutputItem::Image(
        data="AAAA",
        mimeType="image/png",
      ),
    ),
    expected={
      "type": "output",
      "item": { "type": "image", "data": "AAAA", "mimeType": "image/png" },
    },
  )
}

///|
/// `value` is the script's return value as a JSON-encoded string; `writes`
/// is a JSON-encoded string of `[key, json]` / `[key]` store entries.
test "done ok carries the return value and store writes" {
  roundtrip(
    @codemode.VmToHostMessage::DoneOk(
      value=Some(Json(42)),
      writes=[
        @codemode.WriteItem::Set(key="k", value=Json(1)),
        @codemode.WriteItem::Delete(key="d"),
      ],
      during=None,
    ),
    expected={
      "type": "done",
      "ok": true,
      "value": "42",
      "writes": "[[\"k\",\"1\"],[\"d\"]]",
    },
  )
}

///|
/// `exit()` or falling off the end produces no `value` key. `during` is the
/// deterministic-mode marker: the result the VM was processing when the
/// script settled, and how many results it had been issued.
test "done ok without a return value carries during" {
  roundtrip(
    @codemode.VmToHostMessage::DoneOk(
      value=None,
      writes=[],
      during=Some({ seq: 3, issued: 2, }),
    ),
    expected={
      "type": "done",
      "ok": true,
      "writes": "[]",
      "during": { "seq": 3, "issued": 2 },
    },
  )
}

///|
test "done err wraps the script error as a JSON-encoded string" {
  roundtrip(
    @codemode.VmToHostMessage::DoneErr(
      error={ "name": "Error", "message": "boom" },
      during=None,
    ),
    expected={
      "type": "done",
      "ok": false,
      "error": "{\"name\":\"Error\",\"message\":\"boom\"}",
    },
  )
}

///|
test "crash reports a vm-side failure" {
  roundtrip(@codemode.VmToHostMessage::Crash(message="trap"), expected={
    "type": "crash",
    "message": "trap",
  })
}

///|
/// In deterministic mode the VM reports which result seq it consumed and how
/// many results it had been issued when it went idle.
test "idle reports deterministic replay progress" {
  roundtrip(@codemode.VmToHostMessage::Idle(seq=1, issued=0), expected={
    "type": "idle",
    "seq": 1,
    "issued": 0,
  })
}

///|
/// `failure` wraps a `CodemodeError` produced outside the VM bridge, for
/// example the remote sandbox's own timeout.
test "failure reports an error outside the vm bridge" {
  roundtrip(
    @codemode.VmToHostMessage::Failure(error={
      kind: @codemode.CodemodeErrorKind::Timeout,
      name: None,
      message: "deadline",
      stack: None,
    }),
    expected={
      "type": "failure",
      "error": { "kind": "timeout", "message": "deadline" },
    },
  )
}

///|
/// `seq` and `now` only exist in deterministic mode, where the host replays
/// recorded results in order.
test "ok result serializes the value as a JSON-encoded string" {
  roundtrip(
    @codemode.HostToVmMessage::CallResult({
      id: 1,
      outcome: @codemode.CallOutcome::Resolve(value=Some({ "x": 1 })),
      seq: Some(3),
      now: Some(1700000000000.0),
    }),
    expected={
      "type": "result",
      "id": 1,
      "ok": true,
      "payload": "{\"x\":1}",
      "seq": 3,
      "now": 1700000000000,
    },
  )
}

///|
/// A tool returning `undefined` produces no `payload` key.
test "ok result without a value omits payload" {
  roundtrip(
    @codemode.HostToVmMessage::CallResult({
      id: 1,
      outcome: @codemode.CallOutcome::Resolve(value=None),
      seq: None,
      now: None,
    }),
    expected={ "type": "result", "id": 1, "ok": true },
  )
}

///|
/// Unlike a successful `payload`, an error's `payload` is the message
/// verbatim — the VM does `new Error(payload)` without parsing it.
/// `properties` (deterministic mode) are copied onto that `Error`.
test "error result sends the message verbatim" {
  roundtrip(
    @codemode.HostToVmMessage::CallResult({
      id: 2,
      outcome: @codemode.CallOutcome::Reject(
        message="boom",
        properties=Some({ "code": "E" }),
      ),
      seq: None,
      now: None,
    }),
    expected={
      "type": "result",
      "id": 2,
      "ok": false,
      "payload": "boom",
      "properties": "{\"code\":\"E\"}",
    },
  )
}

///|
test "start request with all fields" {
  roundtrip(
    @codemode.StartVmRequest::{
      data: {
        code: "1+1",
        tools: [{ name: "bash", js_name: "bash", description: "run", }],
        globals: [{ name: "emit", spread: false, }],
        memory_limit_bytes: Some(1024.0),
        store: { "k": Json::empty_object() },
        deterministic: Some({ started_at: 1700000000000.0, seed: 7, }),
      },
      interrupt_budget: Some(500.0),
    },
    expected={
      "data": {
        "code": "1+1",
        "tools": [{ "name": "bash", "jsName": "bash", "description": "run" }],
        "globals": [{ "name": "emit", "spread": false }],
        "memoryLimitBytes": 1024,
        "store": { "k": "{}" },
        "deterministic": { "startedAt": 1700000000000, "seed": 7 },
      },
      "interruptBudget": 500,
    },
  )
}

///|
test "start request omits absent optional fields" {
  roundtrip(
    @codemode.StartVmRequest::{
      data: {
        code: "x",
        tools: [],
        globals: [],
        memory_limit_bytes: None,
        store: Map([]),
        deterministic: None,
      },
      interrupt_budget: None,
    },
    expected={
      "data": { "code": "x", "tools": [], "globals": [], "store": {} },
    },
  )
}
