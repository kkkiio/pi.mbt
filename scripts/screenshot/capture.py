#!/usr/bin/env python3
"""Capture the packaged pim CLI replaying an offline README fixture."""

import os
from pathlib import Path
import re
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


def freeze_ansi(capture):
    """Freeze drops styles at newlines and ignores selective resets like SGR 49.

    Resolve tmux's persistent SGR state into complete styles for each text run.
    """
    foreground, background = [38, 2, 31, 35, 40], None
    attributes = set()
    rows = []
    for line in capture.splitlines():
        rendered = []
        for token in re.split(r"(\x1b\[[0-9;]*m)", line):
            if token.startswith("\x1b["):
                codes = [int(value or "0") for value in token[2:-1].split(";")]
                index = 0
                while index < len(codes):
                    code = codes[index]
                    if code == 0:
                        foreground, background = [38, 2, 31, 35, 40], None
                        attributes.clear()
                    elif code in (1, 3, 4, 7, 9):
                        attributes.add(code)
                    elif code in (22, 23, 24, 27, 29):
                        attributes.discard({22: 1, 23: 3, 24: 4, 27: 7, 29: 9}[code])
                    elif code == 39:
                        foreground = [38, 2, 31, 35, 40]
                    elif code == 49:
                        background = None
                    elif code in (38, 48):
                        count = 5 if codes[index + 1] == 2 else 3
                        color = codes[index:index + count]
                        if code == 38:
                            foreground = color
                        else:
                            background = color
                        index += count - 1
                    else:
                        raise ValueError(f"Unsupported captured SGR: {token!r}")
                    index += 1
            elif token:
                fg, bg = foreground, background
                if 7 in attributes:
                    fg = [38, *(bg or [48, 2, 255, 255, 255])[1:]]
                    bg = [48, *foreground[1:]]
                style = sorted(attributes - {7}) + fg + (bg or [])
                rendered.append("\x1b[0m\x1b[" + ";".join(map(str, style)) + "m" + token)
        rows.append("".join(rendered) + "\x1b[0m")
    return "\n".join(rows) + "\n"


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
                "--output", str(output), "-", input=freeze_ansi(ansi))
            print(f"Generated {output.relative_to(ROOT)}")
        finally:
            subprocess.run([*tmux, "kill-server"], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
