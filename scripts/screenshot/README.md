# README TUI screenshot

在仓库根目录运行：

```bash
npm ci
just screenshot
# 没有 just 时：python3 scripts/screenshot/capture.py
```

依赖：MoonBit、Node.js（版本见根目录 package.json）、Python 3（仅标准库）、tmux 和 [Freeze 0.2.2](https://github.com/charmbracelet/freeze/releases/tag/v0.2.2)。例如 macOS 可以用 `brew install tmux charmbracelet/tap/freeze`，Linux 可安装 tmux 并下载对应架构的 Freeze release。Freeze 使用自带的 JetBrains Mono 字体；无需安装 Python 图像库。

脚本先构建 npm 产物，再在独立 tmux server 的 **100×32** 终端运行 `dist/pim.js`，恢复本目录的 `session.jsonl`。配置、工作目录和可写 journal 副本均在临时目录中；退出时清理。CLI 使用占位凭证满足启动检查，只回放日志并输入未提交的提示，不调用 provider，也不执行 fixture 中的 bash 命令。fixture 中的回复、测试数量和费用是固定的演示数据，不代表当前测试运行结果。

脚本等待恢复状态和编辑器输入实际出现，捕获带 ANSI 颜色的画面，把临时目录显示替换为 `~/projects/pi.mbt`，使用固定的 `freeze.json` 生成 `docs/assets/tui-session.png`。重生成后检查图片和 Git diff，再提交。更换示例内容时修改 `session.jsonl`；渲染外观由 `freeze.json` 控制。截图流程参考 [pi-workmap](https://github.com/kkkiio/pi-workmap/tree/main/test/visual)。

`TMUX_BIN` 和 `FREEZE_BIN` 可指定工具路径。不同 tmux/Freeze 版本可能影响像素；需稳定输出时保持上述版本和终端尺寸。
