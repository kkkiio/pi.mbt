# Benchmark Results

Harness: `benchmarks/harbor/pim_agent.py` + `.github/workflows/terminal-bench.yml`
(harbor 0.21.0, dataset `terminal-bench/terminal-bench-2-1`, model
`deepseek/deepseek-v4-flash`).

## 2026-08-18 — full run (all 89 tasks)

**Pass rate: 64/89 (71.9%)** — DeepSeek's official V4-Flash reference is
82.7% (DeepSeek Harness, max effort; we run `--thinking max` with no sampling
params for comparability).

Dispatched as GHA matrix jobs (one task per runner, `max-parallel: 8`) in 5
waves; aggregated with `benchmarks/aggregate.py`. Tainted trials (see below)
were re-run once fixed; only valid trials are counted.

Failures (25):

| Task | Agent time | Classification |
| --- | --- | --- |
| build-pov-ray | 10min | gave up early (200min budget available) |
| cancel-async-tasks | 9min | capability |
| chess-best-move | 15min | capability |
| circuit-fibsqrt | 60min | timeout |
| db-wal-recovery | 15min | capability |
| dna-assembly | 30min | timeout |
| dna-insert | 2min | capability |
| extract-moves-from-video | 30min | timeout |
| filter-js-from-html | 8min | capability (XSS filter incomplete) |
| fix-ocaml-gc | 60min | timeout |
| gcode-to-text | 15min | capability |
| gpt2-codegolf | 15min | capability |
| install-windows-3.11 | 60min | timeout (QEMU 5.2.0 source compile eats the budget) |
| largest-eigenval | 15min | capability |
| mailman | 30min | timeout |
| make-doom-for-mips | 15min | capability |
| mcmc-sampling-stan | 30min | timeout |
| path-tracing-reverse | 30min | timeout |
| pytorch-model-cli | 3min | capability |
| qemu-alpine-ssh | 15min | capability (interactive serial-console ssh) |
| raman-fitting | 15min | capability |
| regex-chess | 60min | timeout |
| sam-cell-seg | 8min | capability |
| torch-tensor-parallelism | 13min | capability |
| video-processing | 19min | capability |

### Infra bugs found and fixed during this run

- **DeepSeek API balance exhaustion** (402) killed `make-doom-for-mips` and
  `make-mips-interpreter` mid-run. 402 is correctly non-retryable; both were
  re-run after recharge (one PASS, one genuine FAIL). Signature:
  `"stopReason":"error"` + `errorMessage` with `402` in the journal.
- **MoonBit async error names were not retryable** (`retry_policy.mbt` ported
  pi's Node-tuned regexes verbatim): `ReaderClosed` killed overfull-hbox
  without auto-retry. Added `readerclosed|pipeclosed|connectionclosed|
  resolvehostname|econnreset|epipe|etimedout`; re-run PASSed.
- **glibc one-way compat**: pim was built on the ubuntu-24.04 runner (glibc
  2.39) but qemu-startup/qemu-alpine-ssh images are debian:bullseye (glibc
  2.31) → `GLIBC_2.32 not found`, 0min FAILs. The workflow now builds pim in
  a bullseye container (`-lpthread -ldl` needed: glibc < 2.34 keeps
  pthread/dl symbols out of libc); the binary now requires only GLIBC_2.29.
  Re-runs: qemu-startup PASS, qemu-alpine-ssh genuine FAIL.
- **`--print` with dash-leading instruction**: pytorch-model-recovery's
  instruction starts with `-`, which argparse read as a new flag. Adapter now
  uses `--print=<value>`. Re-run PASSed.

## 2026-08-17 — first validation (12 unique tasks)

Selection criteria for this round: lightweight (< 15 min agent budget),
glibc-based images (pim binary is dynamically linked), non-interactive
solutions.

| Task | Result | Notes |
| --- | --- | --- |
| openssl-selfsigned-cert | ✅ 1.0 | |
| regex-log | ✅ 1.0 | needed ca-certificates in env (adapter fix) |
| fix-git | ✅ 1.0 | |
| pypi-server | ✅ 1.0 | |
| vulnerable-secret | ✅ 1.0 | |
| configure-git-webserver | ✅ 1.0 | |
| break-filter-js-from-html | ✅ 1.0 | |
| count-dataset-tokens | ✅ 1.0 | |
| query-optimize | ✅ 1.0 | timed out on first attempt, passed after retry fix |
| filter-js-from-html | ❌ 0.0 | XSS filter incomplete (capability) |
| sanitize-git-repo | ❌ 0.0 | verification failed (capability) |
| extract-elf | ❌ 0.0 | agent process died silently after ~65 tool calls (suspected OOM/stack overflow); wrong output format in an earlier attempt |

**Pass rate: 9/12 (75%)**

### Infra bugs found and fixed along the way

- Workflow `-i` filters must match registry names (`terminal-bench/<name>`) —
  include patterns are wrapped as `*<pattern>` suffix globs (#9).
- Adapter `chmod` command executed pim when `default_user` was unset (#10).
- Task images without `ca-certificates` broke pim's TLS (`STORE routines:
  unregistered scheme`); adapter now installs it (#10).
- Transient provider failures (TCP reset mid-stream, SSE idle timeout)
  crashed runs permanently; `retry_transient` with backoff + `loop.mbt`
  stream-restart handling landed in #11.

### Known issues

- **extract-elf silent crash**: long sessions (~65 tool calls, large context)
  end with the process dying without any stderr. Suspected OOM or stack
  overflow in native code. Needs a repro with memory profiling.
- `*<pattern>` suffix globs can over-match: `filter-js-from-html` also
  matches `break-filter-js-from-html`.

### How to reproduce

```bash
gh workflow run terminal-bench.yml \
  -f tasks_json='["openssl-selfsigned-cert","regex-log","fix-git"]'
gh run download <run-id> -D /tmp/tb-results -p 'tb-result-*'
uv run benchmarks/aggregate.py /tmp/tb-results
```

Artifacts include per-trial session journals (pi v4 JSONL).
