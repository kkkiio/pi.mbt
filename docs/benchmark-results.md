# Benchmark Results

Harness: `benchmarks/harbor/pim_agent.py` + `.github/workflows/terminal-bench.yml`
(harbor 0.21.0, dataset `terminal-bench/terminal-bench-2-1`, model
`deepseek/deepseek-v4-flash`).

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
  -f include="openssl-selfsigned-cert,regex-log,fix-git" \
  -f n_tasks=0 -f n_concurrent=3
gh run download <run-id>   # artifacts include per-trial session journals (pi v4 JSONL)
```
