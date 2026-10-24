// Only the HTTP transport is scripted. The CLI, @file attachment processing,
// image downgrade and session loop all execute normally; no request reaches
// the network.
import assert from "node:assert/strict";

let calls = 0;
const message = {
  type: "message", id: "msg_offline", role: "assistant", status: "completed",
  content: [{ type: "output_text", text: "image-contract-ok", annotations: [] }],
};

globalThis.fetch = async (url, options) => {
  assert.equal(String(url), "https://api.deepseek.com/v1/responses");
  const body = JSON.parse(new TextDecoder().decode(options.body));
  assert.equal(++calls, 1, "expected exactly one model request");
  assert.equal(body.input.length, 1);
  const content = body.input[0].content;
  // The prompt is a positional message; @pixel.png and @note.txt became <file>
  // references plus one image attachment. DeepSeek has no vision input, so
  // transform_messages downgraded the image block to pi's placeholder text.
  assert.equal(content.length, 2);
  assert.equal(content[0].type, "input_text");
  assert.match(
    content[0].text,
    /^<file name="[^"]*pixel\.png"><\/file>\n<file name="[^"]*note\.txt">\nhello from cram\n\n<\/file>\ndescribe-this$/,
  );
  assert.deepEqual(content[1], {
    type: "input_text",
    text: "(image omitted: model does not support images)",
  });
  const events = [
    ["response.created", { response: { status: "in_progress" } }],
    ["response.output_item.added", { output_index: 0, item: { ...message, content: [], status: "in_progress" } }],
    ["response.output_text.delta", { output_index: 0, delta: "image-contract-ok" }],
    ["response.output_item.done", { output_index: 0, item: message }],
    ["response.completed", { response: {
      status: "completed", output: [message], error: null, incomplete_details: null,
      usage: { input_tokens: 37, output_tokens: 11, total_tokens: 48 },
    } }],
  ];
  const sse = events.map(([type, data]) =>
    `event: ${type}\ndata: ${JSON.stringify({ type, ...data })}\n\n`).join("");
  return new Response(sse, { headers: { "Content-Type": "text/event-stream" } });
};
