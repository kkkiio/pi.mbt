# Benchmarks

## Terminal-Bench 2.1 via harbor

`harbor/pim_agent.py` is a harbor agent adapter that runs pim inside task
environments. pim is a single-file executable (js bundle + bun runtime), so the
adapter uploads the CI-built binary (`PIM_BINARY`) instead of installing a
package, and injects `DEEPSEEK_API_KEY` into the agent process env only. Task
images need no node: the bun runtime is embedded in the binary.

Session journals land in `/logs/agent/pim/sessions` inside the environment and
are collected via `--agent-include-logs "pim/**"`, so every trial artifact
includes the pi-v4 JSONL journal for analysis.

### Cloud (GitHub Actions)

`.github/workflows/terminal-bench.yml` runs one matrix job per task: GitHub
Actions dispatches, and each job's `harbor run` sees a single task on a clean
`ubuntu-latest` runner. Dispatch inputs:

- `tasks_json`: JSON array of task names, e.g. `["fix-git","regex-log"]`
- `max_parallel`: max concurrent jobs (default 8, DeepSeek rate-limit headroom)
- `agent_timeout_multiplier`: fraction of the official agent time budget

Each job uploads `tb-result-<task>` (harbor jobs-dir tree, including the
trial's `result.json` and the pim journal). Aggregate a run locally:

```bash
gh run download <run-id> -D /tmp/tb-results -p 'tb-result-*'
uv run benchmarks/aggregate.py /tmp/tb-results
```

Requires the `DEEPSEEK_API_KEY` repository secret.

### Local

```bash
moon build --target js --release
bun build --compile --outfile /tmp/pim _build/js/release/build/cmd/pim/pim.js
PYTHONPATH=. harbor run \
  -d terminal-bench/terminal-bench-2-1 \
  -a benchmarks.harbor.pim_agent:Pim \
  -m deepseek/deepseek-v4-flash \
  --ae PIM_BINARY=/tmp/pim \
  --ae DEEPSEEK_API_KEY="$DEEPSEEK_API_KEY" \
  -i "hello-world" -n 1
```

Known limitation: CI builds the glibc variant (`--target=bun-linux-x64`), so
musl-based task images (alpine) cannot run it. Build with
`--target=bun-linux-x64-musl` for those, and note that alpine also needs
`apk add libstdc++`. Terminal-Bench 2.1 task images are glibc-based, so this
does not affect the benchmark suite.
