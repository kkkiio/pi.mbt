#!/usr/bin/env node
import { serveCodemodeRemote, loadQuickJSWasm } from "@earendil-works/pi-codemode";

const wasm = loadQuickJSWasm();

function errorMessage(error) {
  return error instanceof Error ? error.message : String(error);
}

function startExecution(link, streamId, request) {
  const state = {
    nextExchange: 1,
    pending: new Map(),
    calls: new Map(),
    settled: false,
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
  state.stopAll = stopAll;

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
    if (failure !== undefined) {
      sendFailure(failure);
    } else if (!state.settled && !state.stopped) {
      sendFailure("Remote sandbox returned before the script settled");
    }
    link.send({ stream_id: streamId, close: true });
    for (const exchangeId of [...state.pending.keys()]) resolveExchange(exchangeId, null);
    link.streams.delete(streamId);
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
    if (data.type === "result" && typeof data.id === "number") {
      const exchangeId = state.calls.get(data.id);
      if (exchangeId !== undefined) resolveExchange(exchangeId, data);
    }
  };
}

function handleFrame(link, frame) {
  const { stream_id: streamId, data } = frame;
  if (typeof streamId !== "number") return;
  const state = link.streams.get(streamId);
  if (state) {
    if (frame.close === true) {
      state.stopAll();
      return;
    }
    if (data !== null && typeof data === "object" && state.answer) state.answer(data);
    return;
  }
  if (data === null || typeof data !== "object" || data.data === null || typeof data.data !== "object") return;
  startExecution(link, streamId, data);
}

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
    send: (frame) => process.stdout.write(JSON.stringify(frame) + "\n"),
  };
  let pending = "";
  process.stdin.setEncoding("utf8");
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
    process.exit(0);
  });
  process.stdin.resume();
}

runStdio();
