#!/usr/bin/env python3
"""Capture the packaged pim CLI replaying an offline README fixture."""

import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
TMUX = os.environ.get("TMUX_BIN", "tmux")
FREEZE = os.environ.get("FREEZE_BIN", "freeze")


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def main():
    for executable in (TMUX, FREEZE, "node", "moon"):
        if not shutil.which(executable):
            raise SystemExit(f"Missing {executable}; see scripts/screenshot/README.md")
    run("bash", str(ROOT / "scripts/pack-npm.sh"), cwd=ROOT)
    with tempfile.TemporaryDirectory(prefix="pim-screenshot-") as temporary:
        base = Path(temporary)
        cwd = base / "demo"
        config = base / "config"
        sessions = base / "sessions"
        for directory in (cwd, config, sessions):
            directory.mkdir()
        (sessions / "readme.jsonl").write_text(
            (HERE / "session.jsonl").read_text().replace("/tmp/pim-demo", str(cwd))
        )
        # A private tmux server avoids inherited user config and terminal sizing.
        tmux = [TMUX, "-f", "/dev/null", "-S", str(base / "tmux.sock")]
        command = shlex.join([
            "env", f"PIM_CONFIG_DIR={config}", "DEEPSEEK_API_KEY=screenshot-only",
            "COLORTERM=truecolor", "TERM=xterm-256color",
            "node", str(ROOT / "dist/pim.js"),
            "--session-dir", str(sessions), "--resume", "readme",
        ])
        try:
            run(*tmux, "new-session", "-d", "-s", "capture", "-x", "100", "-y", "32",
                "-c", str(cwd), command)
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                pane = run(*tmux, "capture-pane", "-t", "capture", "-p",
                           capture_output=True).stdout
                if "Resumed session" in pane and "Project tour" in pane:
                    break
                time.sleep(0.1)
            else:
                raise RuntimeError(f"TUI replay did not become ready:\n{pane}")
            # Type into the real editor without Enter: no model request is sent.
            prompt = "Show me how session resume works"
            run(*tmux, "send-keys", "-t", "capture", "-l", prompt)
            while time.monotonic() < deadline:
                pane = run(*tmux, "capture-pane", "-t", "capture", "-p",
                           capture_output=True).stdout
                if prompt in pane:
                    break
                time.sleep(0.1)
            else:
                raise RuntimeError("Editor input did not render")
            ansi = run(*tmux, "capture-pane", "-t", "capture", "-p", "-e", "-N",
                       capture_output=True).stdout
            ansi = ansi.replace(str(cwd), "~/projects/pi.mbt")
            output = ROOT / "docs/assets/tui-session.png"
            run(FREEZE, "--config", str(HERE / "freeze.json"), "--language", "ansi",
                "--output", str(output), "-", input=ansi)
            print(f"Generated {output.relative_to(ROOT)}")
        finally:
            subprocess.run([*tmux, "kill-server"], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
