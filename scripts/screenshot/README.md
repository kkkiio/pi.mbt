# README TUI screenshot

在仓库根目录运行：

```bash
npm ci
npx --no-install playwright-core install chromium
just screenshot
```

依赖：MoonBit、Node.js（版本见根目录 package.json）、Python 3（仅标准库）、just、tmux 和 Chromium。`npm ci` 安装 lockfile 固定的 xterm.js、Playwright 和 JetBrains Mono 字体包；上面的 Playwright 命令安装配套 Chromium，仅首次使用或升级 Playwright 时需要运行。Linux 缺少浏览器系统库时，用 `npx --no-install playwright-core install-deps chromium` 安装，可能需要 sudo。

字体通过页面的 `@font-face` 从 `node_modules` 加载，包括普通、粗体和斜体；不提交字体文件，不安装系统字体，也不依赖字体 CDN。安装依赖和浏览器后，截图流程无需网络。Freeze 不再是依赖。

脚本先构建 npm 产物，再在独立 tmux server 的 **100×32** 终端运行 `dist/pim.js`，恢复本目录的 `session.jsonl`。配置、工作目录和可写 journal 副本均在临时目录中；退出时清理。CLI 使用占位凭证满足启动检查，只回放日志并输入未提交的提示，不调用 provider，也不执行 fixture 中的 bash 命令。fixture 中的回复、测试数量和费用是固定的演示数据，不代表当前测试运行结果。

脚本等待恢复状态和编辑器输入实际出现，捕获带 ANSI 颜色的画面，把临时目录显示替换为 `~/projects/pi.mbt`，交给 xterm.js 渲染。Playwright 等待字体、终端解析和绘制完成，再生成 `docs/assets/tui-session.png`。重生成后检查图片和 Git diff，再提交。更换示例内容时修改 `session.jsonl`；字体、窗口装饰和终端配置在 `terminal.html` 中。截图流程参考 [pi-workmap](https://github.com/kkkiio/pi-workmap/tree/main/test/visual)。

捕获的 SGR 样式直接交给 xterm.js，不做颜色兼容补丁。仅去掉 capture 最后的换行，避免屏幕滚动，并开启 `convertEol` 将 LF 分隔的屏幕行放到各行行首。隐藏 xterm.js 自己的光标，保留 pim 绘制的反色编辑器光标。

`TMUX_BIN` 可指定 tmux 路径；`CHROMIUM_BIN` 可指定已有 Chromium，但默认使用 Playwright 配套版本。npm 依赖、字体和配套浏览器版本由依赖锁定；操作系统、tmux 版本及字体栅格化仍可能造成少量像素差异。示例会话使用英文；增加当前字体不覆盖的字符（例如中文）时，需要为页面补充对应的固定字体依赖。
