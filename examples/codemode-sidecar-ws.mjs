#!/usr/bin/env node
import { Worker } from "node:worker_threads";
import { WebSocketServer } from "ws";
import { loadQuickJSWasm } from "@earendil-works/pi-codemode";

const port = Number.parseInt(process.argv[2] ?? "", 10);
if (!Number.isInteger(port)) {
  process.stderr.write("usage: codemode-sidecar-ws.mjs <port>\n");
  process.exit(2);
}

const workerUrl = new URL(import.meta.resolve("@earendil-works/pi-codemode/worker"));
const wasm = await loadQuickJSWasm();
const server = new WebSocketServer({ port });

server.on("connection", (socket) => {
  const streams = new Map();

  const send = (frame) => {
    try {
      socket.send(JSON.stringify(frame));
    } catch {}
  };

  const finish = (streamId, state) => {
    if (streams.get(streamId) !== state) return;
    streams.delete(streamId);
    Atomics.store(new Int32Array(state.interrupt), 0, 1);
    void state.worker.terminate();
    send({ stream_id: streamId, close: true });
  };

  const start = (streamId, request) => {
    const interrupt = new SharedArrayBuffer(4);
    const worker = new Worker(workerUrl, {
      workerData: { ...request.data, wasm, interrupt },
    });
    const state = { worker, interrupt };
    streams.set(streamId, state);
    worker.on("message", (message) => {
      send({ stream_id: streamId, data: message });
      if (message?.type === "done" || message?.type === "crash") finish(streamId, state);
    });
    worker.on("error", (error) => {
      if (streams.get(streamId) !== state) return;
      send({
        stream_id: streamId,
        data: { type: "failure", error: { kind: "sandbox", message: error.message } },
      });
      finish(streamId, state);
    });
    worker.on("exit", (code) => {
      if (streams.get(streamId) !== state) return;
      send({
        stream_id: streamId,
        data: { type: "failure", error: { kind: "sandbox", message: `worker exited with code ${code}` } },
      });
      finish(streamId, state);
    });
  };

  socket.on("message", (text) => {
    for (const line of text.toString().split("\n")) {
      if (line.trim() === "") continue;
      let frame;
      try {
        frame = JSON.parse(line);
      } catch {
        continue;
      }
      if (typeof frame.stream_id !== "number") continue;
      const streamId = frame.stream_id;
      const state = streams.get(streamId);
      if (frame.close === true) {
        if (state) finish(streamId, state);
      } else if (state) {
        if (frame.data?.type === "result") state.worker.postMessage(frame.data);
      } else if (typeof frame.data?.data === "object" && frame.data.data !== null) {
        start(streamId, frame.data);
      }
    }
  });

  socket.on("close", () => {
    for (const [streamId, state] of streams) finish(streamId, state);
  });
});

server.on("listening", () => {
  process.stderr.write(`codemode-sidecar-ws listening on ws://127.0.0.1:${port}\n`);
});
