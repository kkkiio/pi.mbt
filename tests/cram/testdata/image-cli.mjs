// Drives `pim describe-this @pixel.png @note.txt` against image-fetch.mjs and
// prints the final reply. The fetch stub carries the request-shape assertions:
// <file> text references, the image attachment downgraded to placeholder text.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";

const result = spawnSync("moon", [
  "run", "--target", "js", "cmd/pim", "--", "--no-session",
  "describe-this",
  "@tests/cram/testdata/pixel.png",
  "@tests/cram/testdata/note.txt",
], {
  encoding: "utf8",
  env: {
    ...process.env,
    PIM_CONFIG_DIR: "tests/cram/testdata/auth-absent",
    DEEPSEEK_API_KEY: "offline-fixture-key",
    NODE_OPTIONS: `--import=${new URL("./image-fetch.mjs", import.meta.url).href}`,
  },
});
assert.ifError(result.error);
assert.equal(result.status, 0, result.stderr);
process.stdout.write(result.stdout);
