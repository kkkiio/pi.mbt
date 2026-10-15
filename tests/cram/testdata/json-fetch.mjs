// Only the HTTP transport is scripted. The CLI, SSE decoder, session loop,
// JSON subscriber and bash tool all execute normally; no request reaches the network.
import assert from "node:assert/strict";

let calls = 0;
const tool = {
  type: "function_call", id: "fc_offline", call_id: "call_offline",
  name: "bash", arguments: '{"command":"echo pim-offline"}', status: "completed",
};
const message = {
  type: "message", id: "msg_offline", role: "assistant", status: "completed",
  content: [{ type: "output_text", text: 'pim-offline\n"complete"', annotations: [] }],
};

globalThis.fetch = async (url, options) => {
  assert.equal(String(url), "https://api.deepseek.com/v1/responses");
  assert.equal(options.method, "POST");
  const body = JSON.parse(new TextDecoder().decode(options.body));
  assert.equal(body.stream, true);
  assert.equal(body.input[0].role, "user");
  assert.deepEqual(body.input[0].content, [{ type: "input_text", text: "offline-json" }]);
  const events = [["response.created", { response: { status: "in_progress" } }]];
  let output;
  if (++calls === 1) {
    assert.equal(body.input.length, 1);
    events.push(
      ["response.output_item.added", { output_index: 0, item: { ...tool, arguments: "", status: "in_progress" } }],
      ["response.function_call_arguments.delta", { output_index: 0, delta: '{"command":' }],
      ["response.function_call_arguments.delta", { output_index: 0, delta: '"echo pim-offline"}' }],
    );
    output = tool;
  } else {
    assert.equal(calls, 2, "unexpected extra model request");
    // This requires a real tool execution, not just a serialized tool call.
    assert.deepEqual(body.input.at(-1), {
      type: "function_call_output", call_id: "call_offline",
      output: [{ type: "input_text", text: "pim-offline\n" }],
    });
    events.push(
      ["response.output_item.added", { output_index: 0, item: { ...message, content: [], status: "in_progress" } }],
      ["response.output_text.delta", { output_index: 0, delta: "pim-offline" }],
      ["response.output_text.delta", { output_index: 0, delta: '\n"complete"' }],
    );
    output = message;
  }
  events.push(
    ["response.output_item.done", { output_index: 0, item: output }],
    ["response.completed", { response: {
      status: "completed", output: [output], error: null, incomplete_details: null,
      usage: { input_tokens: 37, output_tokens: 11, total_tokens: 48 },
    } }],
  );
  const sse = events.map(([type, data]) =>
    `event: ${type}\ndata: ${JSON.stringify({ type, ...data })}\n\n`).join("");
  return new Response(sse, { headers: { "Content-Type": "text/event-stream" } });
};

process.on("exit", () => {
  if (calls !== 2) {
    process.stderr.write(`expected 2 offline requests, got ${calls}\n`);
    process.exitCode = 1;
  }
});
