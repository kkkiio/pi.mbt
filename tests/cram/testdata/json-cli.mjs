import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";

const result = spawnSync("moon", [
  "run", "--target", "js", "cmd/pim", "--", "--no-session", "--mode", "json", "-p", "offline-json",
], {
  encoding: "utf8",
  env: {
    ...process.env,
    PIM_CONFIG_DIR: "tests/cram/testdata/auth-absent",
    DEEPSEEK_API_KEY: "offline-fixture-key",
    NODE_OPTIONS: `--import=${new URL("./json-fetch.mjs", import.meta.url).href}`,
  },
});
assert.ifError(result.error);
assert.equal(result.status, 0, result.stderr);
assert.ok(result.stdout.endsWith("\n"), "JSONL output must end with a newline");
// Parse every stdout line before selecting stable records for the snapshot:
// diagnostics, embedded newlines or a truncated final record must fail the test.
const events = result.stdout.trimEnd().split("\n").map(line => JSON.parse(line));
assert.equal(events[0].type, "agent_start");
assert.equal(events.at(-1).type, "agent_end");
const replies = events.filter(e => e.type === "message_end" && e.message.role === "assistant");
assert.equal(replies.length, 2);
assert.equal(replies[0].message.stopReason, "toolUse");
assert.equal(replies[1].message.stopReason, "stop");
assert.equal(replies[1].message.content[0].text, 'pim-offline\n"complete"');
for (const event of events) {
  // These complete records contain no clock or random fields. Keep all their
  // fields so new wire fields, snapshots and casing changes are visible in cram.
  if (event.type === "message_update" || event.type.startsWith("tool_execution_")) {
    process.stdout.write(JSON.stringify(event) + "\n");
  }
}
