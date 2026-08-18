# Benchmark Results

Harness: `benchmarks/harbor/pim_agent.py` + `.github/workflows/terminal-bench.yml`
(harbor 0.21.0, dataset `terminal-bench/terminal-bench-2-1`, model
`deepseek/deepseek-v4-flash`).

## 2026-08-18 — full run (all 89 tasks)

**Pass rate: 64/89 (71.9%)** — DeepSeek's official V4-Flash reference is
82.7% (DeepSeek Harness, max effort; we run `--thinking max` with no sampling
params for comparability).

Dispatched as GHA matrix jobs (one task per runner, `max-parallel: 8`) in 5
waves; aggregated with `benchmarks/aggregate.py`. A few trials tainted by
infra issues (API balance, old-glibc images, adapter quoting) were re-run
after fixes; only valid trials are counted.

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

## How to reproduce

```bash
gh workflow run terminal-bench.yml \
  -f tasks_json='["openssl-selfsigned-cert","regex-log","fix-git"]'
gh run download <run-id> -D /tmp/tb-results -p 'tb-result-*'
uv run benchmarks/aggregate.py /tmp/tb-results
```

Artifacts include per-trial session journals (pi v4 JSONL).
