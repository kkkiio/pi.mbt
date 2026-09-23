# ADR 0002: JavaScript target for `cmd/pim`, and reusing pi-tui for the TUI agent

- Status: Accepted
- Date: 2026-09-23

## Context

The next product surface for pim is an interactive TUI agent, and we want to
build it on [`@earendil-works/pi-tui`](https://github.com/earendil-works/pi)
rather than write a terminal renderer. pi-tui is the rendering framework pi
itself uses: `TuiAltScreen` (differential alt-screen renderer), an injectable
`Terminal` seam, and 18 reusable primitives (`Editor`, `ScrollView`, `VStack`,
`Markdown`, `Text`, `Box`, `TruncatedText`, `Loader`, …).

pi-tui is TypeScript, ESM-only, Node-only (`process.stdin` raw mode,
`node:fs`/`node:path`/`node:module`, optional N-API prebuilds for clipboard and
keyboard modifiers), requires Node ≥ 22.19, and depends only on
`get-east-asian-width` + `marked`. It cannot be consumed from a MoonBit native
binary; reusing it forces a JavaScript runtime.

Today pim is native-only: `preferred_target = "native"` in `moon.mod`, and
`supported_targets = "+native"` on `cmd/pim`, `sdk/providers`, and
`sdk/coding_agent`.

Facts established while evaluating this (verified in scratch probes against
`moonbitlang/async@0.22.2` and a real `@earendil-works/pi-tui` checkout):

- The MoonBit `js` backend emits a self-contained ESM bundle; `async fn main`
  is a real process entry point there (the compiler spawns it and pumps the
  event loop via `run_async_main` / `event_loop.reschedule()`).
- `pim`'s JS side can import npm packages (`#module("…")` emits a plain ESM
  `import`, resolved by Node from the project's `node_modules`). Only
  **function** exports can be imported this way; classes must be reached via
  dynamic `import()` (a named class export imported as a function is emitted
  as a call and throws `Class constructor … cannot be invoked without 'new'`).
- `@js_async.Promise::from_async` turns a MoonBit `async` block into a JS
  Promise and schedules the runtime itself, so a JS host can simply `await` an
  exported async function — no `async fn main` required on either side.
- JS → MoonBit callbacks work in both directions (a MoonBit closure registered
  through FFI is invoked by JS and mutates MoonBit state).
- `moonbitlang/async` on `js` provides: HTTP client via `fetch` (streaming SSE
  works), `@io` readers/writers, timers, retry, task groups and cancellation,
  and `js_async` (Promise/AbortController/ReadableStream). It does **not**
  provide `fs`, `process`, `stdio`, `socket`, `tls` — those packages collapse
  to `pub let unimplemented` on `js`.
- Consequence for this repo: `sdk/agent_loop`, `sdk/agent_session` (5/5 tests),
  `sdk/tools`, and `sdk/providers` (1/1 test) already compile and run under
  `--target js`; `sdk/coding_agent` does not (16 errors: 3 `@async/process`,
  12 `@async/fs`, 1 `@fs.File` type), and `cmd/pim` additionally uses
  `@stdio` and a native `extern "c" exit`.
- `bun build --compile` over the MoonBit JS bundle plus pi-tui produces a
  single ~60 MiB executable that runs unchanged, so a JS build does not cost
  us single-file distribution.
- `moon cram test` only builds native executables and runs transcripts in a
  temp directory; it cannot build or discover JS artifacts by itself.

## Decision

**1. `cmd/pim` targets JavaScript only.**

```moonbit
// cmd/pim/moon.pkg
supported_targets = "js"
pkgtype(kind: "executable")
```

```moonbit
// moon.mod
preferred_target = "js"
```

Rationale: the product is a pi-tui-driven agent, and pi-tui needs a JS runtime,
so a native entry point has no consumer. Keeping both entry points would mean
maintaining two host implementations for no product benefit.

**2. MoonBit stays the program body and entry point.**

`cmd/pim` remains an `async fn main` executable that imports pi-tui across the
FFI boundary. We do not invert this into "a TS host that imports a MoonBit
library": the agent loop, session, journal, and tool pipeline are MoonBit and
stay the driver, and the TUI is a consumer of the agent's event stream.

`async fn main` is supported on the js target, with three verified details
that shape the js host glue:

- It requires an explicit dependency on `moonbitlang/async` (otherwise the
  compiler reports E4037: *cannot use `async fn main`: package
  moonbitlang/async is not imported*). `cmd/pim` already depends on it.
- The js driver differs from native: `run_async_main` reports an unhandled
  error as `eprintln` + `exit(1)` on native but `eprintln` + `panic()` on js,
  so on js it leaves a full JS stack trace on stderr. `fatal` must therefore write its own
  diagnostic and call `process.exit(code)` through FFI — the js counterpart of
  the existing native-gated `proc_exit_ffi` — after restoring the terminal.
- `event_loop.reschedule()` never blocks (it defers with `setTimeout(0)` while
  tasks are ready), so the main coroutine is what keeps the process alive: `-p`
  mode stays alive on the agent's HTTP/SSE awaits, and TUI mode awaits a quit
  promise while pi-tui's `ProcessTerminal` holds stdin open.

A sync `fn main` is also viable on js (`@js_async.Promise::from_async` is a
sync function that schedules the runtime itself, verified to keep the process
alive until the async body completes), but it scatters error handling across
call sites and leaves no single place to restore the terminal. Not chosen.

**3. `sdk/coding_agent` supports native and JS, with platform code kept
in-package (per-file `targets`).**

```moonbit
// sdk/coding_agent/moon.pkg
supported_targets = "+native+js"
options(
  targets: {
    "bash_native.mbt": ["native"],
    "bash_js.mbt": ["js"],
    "…_native.mbt": ["native"],
    "…_js.mbt": ["js"],
  },
)
```

The per-target files export identical signatures, and target-specific types
(`@fs.File`) are hidden behind a package-private handle type so shared files
stay target-agnostic.

**4. The target matrix is explicit per package:**

| `moon.pkg` | `supported_targets` | Requires |
| --- | --- | --- |
| `sdk/agent_loop` | `"+native+js"` | add declaration; compiles on both today |
| `sdk/agent_session` | `"+native+js"` | add declaration; 5/5 tests pass on js today |
| `sdk/tools` | `"+native+js"` | add declaration; compiles on both today |
| `sdk/providers` | `"+native+js"` | replace the current `"+native"`; 1/1 test passes on js today (HTTP is `fetch`-backed) |
| `sdk/coding_agent` | `"+native+js"` | split fs/process call sites into per-target files |
| `cmd/pim` | `"js"` | js host glue: fs, stdout/stderr, exit, TUI |

**5. Distribution: JS bundle for development, bun-compiled single file for
release, npm deferred.**

- Development / debugging: `node _build/js/debug/build/cmd/pim/pim.js …`.
- Release: `moon build --target js` → `bun build --compile` → one binary per
  platform (`--target=bun-linux-x64-musl` covers the musl task images the
  current native build cannot serve).
- Benchmark keeps harbor's "upload the binary" model: `benchmarks/harbor/
  pim_agent.py` continues to take `PIM_BINARY`, now pointing at the
  bun-compiled artifact, so benchmark task images need no Node.

## Alternatives considered

**TS host owns the process; MoonBit is compiled as a JS library
(`pkgtype(kind: "foreign_library")` + `link.js.exports`).**
Keeps the TUI in idiomatic TS, but moves the agent wiring (session lifecycle,
event fan-out, tool updates) into the TUI layer, duplicating logic that
already exists in MoonBit and splitting the pipeline across two languages.
Rejected while the FFI surface stays manageable; revisit if driving pi-tui's
component graph from MoonBit proves disproportionately expensive.

**Port pi-tui (or a subset) to MoonBit.**
`tui-alt-screen.ts` (1745 lines), `tui.ts` (1456), and `terminal.ts` (547)
plus 18 components, markdown rendering, kitty image protocol, and optional
native addons. Rejected: far more work than the FFI boundary, and pi-tui keeps
improving independently.

**Split platform code into separate packages (`sdk/host/native` +
`sdk/host/js` behind a neutral interface).**
Cleaner ownership boundary, but adds an indirection layer and three packages
for ~13 call sites. Rejected in favour of explicit in-package per-file
`targets`, which keeps the target matrix readable from each package's
`moon.pkg` alone.

**Keep `cmd/pim` native and add a second, JS-only TUI executable.**
Preserves the current native `-p` path, but means writing and keeping in sync
two host implementations (fs, process, stdio, exit) for one product.
Rejected: the native path has no consumer once the TUI exists.

**npm as the primary distribution channel.**
npm is how pi ships (`@earendil-works/pi-coding-agent`, `bin` → an esbuild
bundle, `engines.node >= 22.19`) and how harbor's official adapter installs it
(`nvm install 22` + `npm install -g --ignore-scripts` inside the task
environment — which requires `curl` and a glibc distro). It is a good channel
for human installs but the wrong one for benchmarks, where uploading one file
beats installing a runtime per trial. Deferred rather than rejected: if we
want `npm i -g` or harbor's `BaseInstalledAgent` integration, it is an
additive work item that does not change this ADR.

## Consequences

**Gained**

- pi-tui's renderer and primitives are reused as-is; no terminal renderer to
  write or maintain.
- The agent loop, session, journal format, and tool pipeline keep their
  current shape; only the platform-glue call sites change.
- One artifact story for every consumer: the same JS bundle runs under `node`
  in development, inside a single-file binary in release, and in benchmark
  task images.
- The musl coverage gap of the current native binary (built glibc-only on
  Ubuntu runners) is closed by cross-compiling a musl binary.

**Cost / risk**

- Platform code exists twice inside `sdk/coding_agent` (native and js files).
  The compiler only catches a missing or mismatched signature when a shared
  file actually calls it; behavioural divergence between the two
  implementations is not caught at all, so the ported tests are the only
  guard (see below).
- `UInt64` crosses the JS FFI boundary as `bigint`, and `JSON.stringify`
  rejects bigints. Timestamps must keep flowing as numbers through the
  existing `Json::number(timestamp.to_double())` shape; never hand a raw
  `UInt64` to JS.
- Retry classification currently pins native io symptoms
  (`ReaderClosed`, `PipeClosed`, `ConnectionClosed`). JS transport failures
  surface as `fetch`/`JsError`/DOMException shapes, so the session-level
  whitelist needs js entries or js runs will not retry transient failures.
- JS `reschedule()` never blocks: if no task is immediately ready and nothing
  else is pending, Node can exit. The TUI must keep a live handle (stdin or a
  timer), and must restore the alt screen and raw mode from a `defer`/catch —
  `run_async_main` reports an unhandled error by printing it and panicking.
- pi-tui requires Node ≥ 22.19, an ESM host, and a real TTY; its N-API
  prebuilds are best-effort and are not embedded by `bun build --compile`
  (clipboard/modifier features degrade to the JS fallbacks).
- Only function exports are reachable through `#module`; pi-tui's classes
  (`TuiAltScreen`, `ProcessTerminal`, components) therefore need dynamic
  `import()` or a small TS bridge that re-exports factory functions. The
  bridge cannot be a relative path (`#module` rejects them, E4189), so it must
  be a real package resolvable from `node_modules`.

**Verification contract changes**

- `just check` must run both targets, and assert the core packages are
  actually type-checked under each: `moon check --target js` silently drops
  packages that do not support the target, which makes target drift invisible.
- `just cram` becomes `moon build && moon cram test tests/cram`; transcripts
  invoke `node "$TESTDIR/../../_build/js/debug/build/cmd/pim/pim.js"` because
  `moon cram` builds native executables only and runs transcripts in a temp
  directory.
- `tests/live/deepseek.md`'s inline `moon run --target native -e '…'` step
  moves to `--target js`.
- `jsonl_journal_test.mbt` and `output_accumulator_test.mbt` are the only
  consumers of the native fs/process paths once `cmd/pim` is js-only. Porting
  them onto the per-file platform boundary keeps the native branch honest by
  running the same tests under `--target native` and `--target js`.

## Follow-ups

- `docs/targets.md`: if the matrix grows beyond the table above, split it out
  of this ADR as the single source of truth.
- CI gates: (a) `moon check --target native --deny-warn` and
  `moon check --target js --deny-warn` over the same core package set, with an
  assertion that every matrix package was actually type-checked under both
  targets (unsupported packages are filtered silently); (b) a lint that fails
  when a `moon.pkg` imports `moonbitlang/async/{fs,process,stdio}` without the
  package declaring `supported_targets` and listing its platform files under
  `options(targets:)`, so no target-specific API can leak into a shared file.
- js host glue design: `node:fs/promises` and `node:child_process` bindings
  for the `*_js.mbt` files, with `child_process.spawn` streamed output bridged
  through `@io.pipe()` or a callback-based `Promise`.
- TUI bridge: a small TS package exporting factory functions (and, if the FFI
  surface grows, a JSON-string protocol for agent events) consumed via
  `#module`.
- npm packaging, if `npm i -g` becomes a requirement.
