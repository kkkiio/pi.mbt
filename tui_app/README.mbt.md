# tui_app

pim 的全屏 TUI:把 `@agent_session.AgentSession` 的事件流渲染成终端界面。
渲染、布局、滚动、搜索、选择都由 [`@earendil-works/pi-tui`](https://github.com/earendil-works/pi) 负责,
本包只提供**内容型组件**、**应用状态**与**会话接线**。

## 组件树

```
TuiAltScreen                                  pi-tui(TS) · 副屏 + 差分渲染 + 滚轮/搜索/选择
└─ VStack(root)                               chat_viewport.mbt · chat_viewport_new()
   │
   ├─ ScrollView { follow:"end", primary:true }        内容视窗(flex 主区)
   │  │  basis=0, grow=1, shrink=1, minSize=1
   │  └─ Component(transcript)                 transcript.mbt · MoonBit widget
   │        render(width) -> string[]          消息流:user / assistant / thinking / tool
   │
   └─ VStack(dock)                             basis="auto", grow=0, shrink=1, minSize=1
      ├─ Component(pending)                    app.mbt · PendingList(agent 忙时排队的输入)
      ├─ Component(status)                     status.mbt · idle(0 行) / working(⠙ label · 3s)
      ├─ Component(editor)                     prompt_editor.mbt → pi-tui Editor
      │                                        编辑/历史/补全/多行,Enter 触发 onSubmit
      └─ Component(footer)                     footer.mbt · model · thinking · cwd · ↑in ↓out · $cost
```

只有 `ScrollView` 标了 `primary:true`:滚轮、pageUp/pageDown、home/end、
`ctrl+shift+f` 搜索、鼠标选择都作用在它身上 —— 副屏没有回滚缓冲,
"聊天记录可滚动"完全由这个视窗实现。

## 数据流

```
stdin ─▶ ProcessTerminal ─▶ StdinBuffer(分帧/粘贴) ─▶ TuiAltScreen 的输入监听器
                                                        ├─ 自带:滚轮/选择/搜索、tui.altScreen.*
                                                        └─ 本包: TuiApp::on_input
                                                                  └─ ctrl+c / ctrl+d ─▶ request_exit

焦点组件(Editor) ◀──────────────────────── handleInput
      │
      └─ onSubmit ─▶ TuiApp::submit ─▶ 提交队列 ─▶ run.mbt 命令循环
                                                  ├─ "/new"  → SessionHost::new_session + TuiApp::reset
                                                  ├─ "/quit" → TuiApp::request_exit
                                                  └─ 其他     → SessionHost::prompt

AgentSession.subscribe ─▶ SessionHost::on_event ─▶ TuiApp 的 mutator ─▶ request_render()
                                                                      │
                            每帧:pi-tui 调用组件的 render(width) ──────┘
                                  读**当前**状态 → 只重画变化的行

退出:TuiApp::stop ─▶ Terminal::drain_input ─▶ TuiAltScreen.stop
      └─ 离开副屏,并把最终画面倒回主屏(所以退出后 scrollback 里能看到聊天记录)
```

## 分层与归属

| 层 | 文件 | 是否认识 agent |
|---|---|---|
| pi-tui 绑定 | `js_value.mbt`、`pi_tui_js.mbt`、`component.mbt`、`tui.mbt` | 否 |
| 组件 | `transcript.mbt`、`status.mbt`、`footer.mbt`、`prompt_editor.mbt`、`style.mbt` | 仅 `footer.mbt`(取 `@agent_loop.Usage`) |
| 视图层 | `app.mbt`(`TuiApp`:状态 + mutator + 输入/退出) | 仅 `set_usage` |
| 会话层 | `session_host.mbt`(`SessionHost`:provider/journal/多会话 + 事件投影) | 是 |
| 装配 | `run.mbt`(`run()`:建视图、建会话、命令循环、收尾) | 是 |

组件不保存"业务真相":它们是被动读状态画行的对象,
状态由 `TuiApp` 持有,事件由 `SessionHost` 投影进去。
`render(width)` 必须是**同步纯函数**(pi-tui 在布局路径上同步调用它),所以任何异步数据都只能
先落状态、再 `request_render()`。
