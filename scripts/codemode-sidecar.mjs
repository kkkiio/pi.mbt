#!/usr/bin/env node
// Codemode remote-VM sidecar for pim.
//
// Bridges `{ "stream_id": N, "data": <env> }` NDJSON frames to
// `serveCodemodeRemote` from @earendil-works/pi-codemode. One `stream_id` is
// one execution: its first frame's `data` is the `CodemodeRemoteRequest`.
// For every `exchange(messages)` call the sidecar emits
// `{ "stream_id", "data": <messages> }` — the batch itself, which the
// client's message loop flattens — and, once `serveCodemodeRemote`'s
// promise settles, `{ "stream_id", "data": { "type": "exit" } }`.
//
// Replies from the client come back as bare `data` frames, upstream
// `remoteLauncher` style: `{ "type": "result", "id": <call id>, ... }`
// answers the exchange that carried `call` `<call id>`, and
// `{ "type": "stop" }` answers every pending exchange with `stop`.
// An exchange that carries no `call` resolves `null` at once, like upstream.
// A request that cannot even start, or a remote that ends before a terminal
// `done`/`crash`/`failure`, reports a `failure` batch with
// `{ kind: "sandbox" }` before `exit`.
//
// Transports:
//   node codemode-sidecar.mjs               stdin/stdout, one frame per line
//   node codemode-sidecar.mjs --ws <port>   WebSocket; each message is one or
//                                           more newline-separated frames
//
// Requires node >= 22.19 (pi-codemode's engine floor).
import { serveCodemodeRemote, loadQuickJSWasm } from "@earendil-works/pi-codemode";

const wasm = loadQuickJSWasm();

function errorMessage(error) {
  return error instanceof Error ? error.message : String(error);
}

// Run one execution for `request` (a CodemodeRemoteRequest) on `streamId` of
// `link`. `link.send` writes one whole frame.
function startExecution(link, streamId, request) {
  const state = {
    nextExchange: 1,
    // exchange id -> { resolve, callId }; the reply the client owes us.
    pending: new Map(),
    // call id -> exchange id, for bare `result` replies.
    calls: new Map(),
    // a terminal `done`/`crash`/`failure` message was delivered.
    settled: false,
    // the client asked to stop; ending then is normal, not a failure.
    stopped: false,
  };
  link.streams.set(streamId, state);

  const resolveExchange = (exchangeId, reply) => {
    const entry = state.pending.get(exchangeId);
    if (!entry) return;
    state.pending.delete(exchangeId);
    if (entry.callId !== null) state.calls.delete(entry.callId);
    entry.resolve(reply);
  };
  const stopAll = () => {
    state.stopped = true;
    for (const exchangeId of [...state.pending.keys()]) {
      resolveExchange(exchangeId, { type: "stop" });
    }
  };

  const exchange = (messages) =>
    new Promise((resolve) => {
      const id = state.nextExchange++;
      const call = messages.find((m) => m?.type === "call");
      const callId = call ? call.id : null;
      state.pending.set(id, { resolve, callId });
      if (callId !== null) state.calls.set(callId, id);
      if (messages.some((m) => m?.type === "done" || m?.type === "crash" || m?.type === "failure")) {
        state.settled = true;
      }
      link.send({ stream_id: streamId, data: messages });
      if (callId === null) resolveExchange(id, null);
    });

  const sendFailure = (message) => {
    link.send({
      stream_id: streamId,
      data: [{ type: "failure", error: { kind: "sandbox", message } }],
    });
  };

  const settle = (failure) => {
    // A request that cannot even start reports as a batch carrying a
    // sandbox failure, then exits: the client's message loop sees a terminal
    // `failure` message either way. Like `remoteLauncher`, a remote that
    // returns before the script settled also reports a sandbox failure.
    if (failure !== undefined) {
      sendFailure(failure);
    } else if (!state.settled && !state.stopped) {
      sendFailure("Remote sandbox returned before the script settled");
    }
    link.send({ stream_id: streamId, data: { type: "exit" } });
    for (const exchangeId of [...state.pending.keys()]) resolveExchange(exchangeId, null);
    link.streams.delete(streamId);
    if (link.eof && link.streams.size === 0) process.exit(0);
  };

  let done;
  try {
    done = Promise.resolve(serveCodemodeRemote(request, exchange, { wasm }));
  } catch (error) {
    settle(errorMessage(error));
    return;
  }
  done.then(
    () => settle(),
    (error) => settle(`Remote sandbox failed: ${errorMessage(error)}`),
  );

  state.answer = (data) => {
    // Bare VM-bridge frames: `result` answers the exchange that carried the
    // call, `stop` answers every pending exchange with `stop`.
    if (data.type === "stop") {
      stopAll();
      return;
    }
    if (data.type === "result" && typeof data.id === "number") {
      const exchangeId = state.calls.get(data.id);
      if (exchangeId !== undefined) resolveExchange(exchangeId, data);
    }
  };
}

// `frame` is `{ stream_id, data }`: `data` is a CodemodeRemoteRequest to
// start, or a VM-bridge frame (`{type:"result",id}` / `{type:"stop"}`) for a
// running stream.
function handleFrame(link, frame) {
  const { stream_id: streamId, data } = frame;
  if (typeof streamId !== "number") return;
  const state = link.streams.get(streamId);
  if (state) {
    if (data !== null && typeof data === "object" && state.answer) state.answer(data);
    return;
  }
  startExecution(link, streamId, data);
}

// Feed `text` (possibly several newline-separated frames) to `link`.
function feedLines(link, text) {
  for (const line of text.split("\n")) {
    const trimmed = line.trim();
    if (trimmed === "") continue;
    let frame;
    try {
      frame = JSON.parse(trimmed);
    } catch {
      continue; // not JSON; drop the line
    }
    handleFrame(link, frame);
  }
}

function runStdio() {
  const link = {
    streams: new Map(),
    eof: false,
    send: (frame) => process.stdout.write(JSON.stringify(frame) + "\n"),
  };
  let pending = "";
  process.stdin.on("data", (chunk) => {
    pending += chunk;
    let index = pending.indexOf("\n");
    while (index >= 0) {
      feedLines(link, pending.slice(0, index));
      pending = pending.slice(index + 1);
      index = pending.indexOf("\n");
    }
  });
  process.stdin.on("end", () => {
    feedLines(link, pending);
    pending = "";
    // stdin gone means the host is done; exit once in-flight streams settle
    // so the sidecar does not linger as an orphan.
    link.eof = true;
    if (link.streams.size === 0) process.exit(0);
  });
  process.stdin.resume();
}

async function runWebSocket(port) {
  const { WebSocketServer } = await import("ws");
  const wss = new WebSocketServer({ port });
  wss.on("connection", (socket) => {
    const link = {
      streams: new Map(),
      eof: false,
      send: (frame) => socket.send(JSON.stringify(frame)),
    };
    socket.on("message", (data) => feedLines(link, data.toString()));
    socket.on("close", () => {
      link.eof = true;
    });
  });
  wss.on("listening", () => {
    process.stderr.write(`codemode-sidecar listening on ws://127.0.0.1:${port}\n`);
  });
}

const args = process.argv.slice(2);
if (args[0] === "--ws") {
  const port = Number.parseInt(args[1] ?? "", 10);
  if (!Number.isInteger(port)) {
    process.stderr.write("usage: codemode-sidecar.mjs [--ws <port>]\n");
    process.exit(2);
  }
  runWebSocket(port).catch((error) => {
    process.stderr.write(`codemode-sidecar: ${errorMessage(error)}\n`);
    process.exit(1);
  });
} else {
  runStdio();
}
