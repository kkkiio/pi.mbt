# tui_app

pim 的全屏 TUI:把 `AgentSession` 的事件流渲染成终端界面。
渲染、布局、滚动、搜索、选择由 [`@earendil-works/pi-tui`](https://github.com/earendil-works/pi) 负责,
本包只提供内容型组件、应用状态、主题与会话接线。界面与行为对齐 pi coding-agent 的 interactive 模式,
主题取自 pi 内置 `light`。

图内一律纯 ASCII(`+ - |`),字符数等于列数,任何等宽字体下都对齐。
真实界面里的 `⠋`(spinner)、`▌`(光标)、`↑↓`(用量)在图中以 `*`、`>`、`^v` 代替。

## 组件树

关键组件:

- **ScrollView(transcript)** — 消息流。dock 之外的全部内容,唯一可滚动 / 可搜索的视窗
- **PendingList** — agent 忙时排队的输入,每行 `Follow-up: <text>`
- **Editor** — 输入框。上边框兼任运行状态(spinner + 标签)
- **Footer** — 两行。行1 cwd / branch / session,行2 用量 / 模型
- **Toast** — 右上角反显小条,~1s 自动消失
- **补全菜单** — 输入框下方的 slash 命令建议
- **TranscriptItem** — 消息流里的一项:user / note / error / assistant / tool

它们的嵌套关系:

```
TuiAltScreen                                      pi-tui: alt screen + diff render + wheel/search/select
|
+-- VStack(root)                                   chat_viewport.mbt
|   |
|   +-- ScrollView { follow:"end", primary:true }   the only scrollable viewport, grow=1
|   |   \-- Component(transcript)                   transcript.mbt: message stream
|   |
|   \-- VStack(dock)                                basis=auto, pinned to the bottom
|       +-- Component(pending)                      app.mbt: queued input, "Follow-up: <text>"
|       +-- Component(editor)                       prompt_editor.mbt: top/bottom border
|       |   \-- top border = StatusLine::render_border   status.mbt: a plain rule when idle
|       \-- Component(footer)                       footer.mbt: two lines
```

dock 里没有独立的 status 组件:运行状态由输入框上边框渲染。

## 分层与归属

从整屏往下逐级放大:整屏 → 输入框 → 单条消息 → 临时层。图中出现的区域:

- **content** — 消息流。唯一可滚动 / 可搜索的视窗
- **dock** — 排队消息、输入框、footer。固定不动,输入框上边框兼任运行状态
- **transient** — toast、slash 补全菜单。自动消失(~1s)或依附输入框
- **background** — 终端自身。pim 不刷全局背景

**整屏:**

```
+- whole screen (alt-screen) ----------------------------------------------+
| content  ScrollView (follow:end, primary)   the only scrollable area     |
|      startup help / user message / Thinking / assistant / tool block     |
|      ...                                                                 |
+--------------------------------------------------------------------------+
| dock     fixed, never scrolls                                            |
|      Follow-up: queued input                                             |
|   +- editor -------------------------------------------------+           |
|   | -- * thinking (Esc to interrupt) ----------------------- |           |
|   | >                                                        |           |
|   | -------------------------------------------------------- |           |
|   +----------------------------------------------------------+           |
|      ~/projects/pi.mbt (main) / parser-fix                               |
|      ^12.4k v3.1k R88k CH72.3% $0.042     claude-sonnet-4.5 / high       |
+--------------------------------------------------------------------------+
```

**放大 ① · 输入框**(dock 中,焦点所在):

```
working:
+- working --------------------------------------------------+
| -- * thinking (Esc to interrupt) --------------------------|   <- top border carries the run status
| >                                                          |   <- text + cursor
| -----------------------------------------------------------|   <- bottom border
+------------------------------------------------------------+

idle:
+- idle -----------------------------------------------------+
| -----------------------------------------------------------|
| >                                                          |
| -----------------------------------------------------------|
+------------------------------------------------------------+
```

**放大 ② · 内容层里的一条消息**:

```
+- user message -----------------------------+
|                                            |
+--------------------------------------------+
            whole block gets userMessageBg, no ">" prefix
            |
            v
The user asks about recursion depth.            thinking: shown by default, italic gray markdown
Let me trace parseTemplate() and check          ctrl+t collapses it to the label "Thinking..."
whether the stack is bounded.
            |
            v
assistant text                                  markdown: fenced code + inline `code` / bold
            |
            v
+- tool block -------------------------------+
| bg = pending / success / error             |
| ... (N more lines, ctrl+o to expand)       |
+--------------------------------------------+
```

**放大 ③ · 临时层**(覆盖在内容之上,不占布局):

```
+- transient layer (no layout space) ------------------------------------+
|                                                        [ new session ] |
|                                                                        |
| -- * thinking (Esc to interrupt) ----------------------------          |
| >                                                                      |
| -------------------------------------------------------------          |
|   /model      Switch model                                             |
|   /settings   Open settings                                            |
+------------------------------------------------------------------------+
```

**交互:**

- **焦点** — 唯一焦点是输入框;Esc 两级,先关补全菜单,再中断当前回合
- **视线** — 新内容从内容层底部出现,状态就在输入框上边框,眼睛不必离开输入处
- **反馈** — 结果直接改写工具块背景色与尾部提示,不弹额外面板
- **时限** — 预计 1s 内消失的进 transient;否则进 dock(常驻)或 content(历史)

**状态与视觉反馈:**

- **空闲** — 上边框是纯横线;footer 保留上次用量
- **工作中** — 上边框换成 `-- * thinking (Esc to interrupt) --`;终端进度指示(OSC 9;4)开启
- **工具执行** — 工具块背景 pending -> success / error
- **完成** — 回落空闲;footer 用量刷新
- **中断** — Esc 后上边框立即回落;assistant 追加 "Operation aborted"

## 消息渲染

```
TranscriptItem
+-- User(text)          whole block gets userMessageBg, one padding row above/below, no ">" prefix
+-- Note(text)          dim: startup help, retry notices, "... earlier messages omitted"
+-- Error(text)         error color
+-- Assistant(text, thinking, stop_reason, error_message)
|   +-- thinking        expanded by default: italic gray markdown; ctrl+t collapses to the label
|   \-- text            simplified markdown: fenced code + inline `code` / bold
\-- Tool(name, args, result, is_error)
    +-- bash            green frame + "$ command" + last 20 lines + "... (N more lines, ctrl+o to expand)"
    +-- read            "read <path>"; result hidden while collapsed (same as pi)
    \-- other           bold name + arg summary; 10-line preview, ctrl+o expands
```

## 会话与命令

TUI 内:

- `/new` — 开一个新会话。
- `/resume [前缀]` — 载入当前目录下已有的会话并回放历史。不带前缀取最新的一个;
  前缀命中多个时列出候选,无命中则只提示。会话文件以创建时刻(epoch 毫秒)开头。
- `/quit`、`/exit` — 即时中断当前生成或工具并退出,不进入提交队列。

`TuiApp` 统一维护提交队列与排队展示,消费一条提交时撤掉对应展示行;
`run` 只负责顺序执行提示词和会话切换。工具结果在渲染时按内容列宽换行后截取
预览,bash 显示最后 20 个可见行,其余工具显示前 10 个;展开后保留全部输出。
