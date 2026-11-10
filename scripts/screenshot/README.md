# README TUI screenshot

Run from the repository root:

```bash
npm ci
npx --no-install playwright-core install chromium
just screenshot
```

Dependencies: MoonBit, Node.js (see root `package.json`), Python 3, `just`, `tmux`, and Chromium. `npm ci` installs the locked `xterm.js`, Playwright, and JetBrains Mono packages; the Playwright command installs the bundled Chromium browser. On Linux, install missing system libraries with `npx --no-install playwright-core install-deps chromium`.

The script builds the npm bundle, runs `dist/pim.js` in an isolated **100×32** tmux session resuming `session.jsonl`, captures the ANSI screen, renders it through `xterm.js` (`terminal.html`), and writes `docs/assets/tui-session.png`.

Set `TMUX_BIN` or `CHROMIUM_BIN` to override the `tmux` or Chromium binary paths.
