# Benchmarks

## Terminal-Bench 2.1 via harbor

`harbor/pim_agent.py` is a harbor agent adapter that runs pim inside task
environments. pim is a native binary, so the adapter uploads the CI-built
binary (`PIM_BINARY`) instead of installing a package, and injects
`DEEPSEEK_API_KEY` into the agent process env only.

Session journals land in `/logs/agent/pim/sessions` inside the environment and
are collected via `--agent-include-logs "pim/**"`, so every trial artifact
includes the pi-v4 JSONL journal for analysis.

### Cloud (GitHub Actions)

`.github/workflows/terminal-bench.yml` builds pim on `ubuntu-latest` and runs
`harbor run -d terminal-bench/terminal-bench-2-1`. Dispatch inputs:

- `include`: task name glob (empty = all tasks)
- `n_tasks`: cap after filters (default 3 for smoke runs; 0 = all)
- `n_concurrent`: concurrent trials
- `agent_timeout_multiplier`: fraction of the official agent time budget

Requires the `DEEPSEEK_API_KEY` repository secret.

### Local

```bash
moon build --target native --release
PYTHONPATH=. harbor run \
  -d terminal-bench/terminal-bench-2-1 \
  -a benchmarks.harbor.pim_agent:Pim \
  -m deepseek/deepseek-v4-flash \
  --ae PIM_BINARY="$PWD/_build/native/release/build/cmd/pim/pim.exe" \
  --ae DEEPSEEK_API_KEY="$DEEPSEEK_API_KEY" \
  -i "hello-world" -n 1
```

Known limitation: the binary is glibc-linked (built on ubuntu runners), so
musl-based task environments (alpine) cannot run it.
