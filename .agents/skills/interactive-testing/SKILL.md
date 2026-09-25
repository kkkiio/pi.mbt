---
name: interactive-testing
description: Test and debug pim's interactive mode in a controlled tmux terminal. Use for TUI behavior checks and interactive release smoke tests.
---

# Testing pim Interactive Mode with tmux

Run the TUI in a controlled terminal (from the repo root):

```bash
set -a; source .env.test; set +a # load api key
tmux new-session -d -s pim-test -x 80 -y 24
tmux send-keys -t pim-test "moon run cmd/pim" Enter
sleep 3 && tmux capture-pane -t pim-test -p     # capture after startup
tmux send-keys -t pim-test "your prompt here" Enter
tmux send-keys -t pim-test Escape               # special keys (also C-o for ctrl+o, etc.)
tmux kill-session -t pim-test
```

For release smoke tests, start the tmux session with `-c /tmp` and replace `moon run cmd/pim` with the absolute path to the release binary. Submit a prompt and wait for the model reply; startup alone is not a passing smoke test.
