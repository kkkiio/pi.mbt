# tui_app 与 pi agent TUI 对齐清单

对照对象：pi monorepo `packages/coding-agent` 的 interactive 模式（v1.3.0）。

组织方式：**每一行是一个用户能感知到的功能**。

本文件只记录差异与决策，不复述已对齐的实现细节。

## 状态

| 标记 | 含义 |
| --- | --- |
| ✅ | 已对齐 |
| 🟡 | 有实现，覆盖范围或行为仍有缺口（缺口写在单元格里） |
| ⬜ | 未实现（未讨论过要不要做） |
| ❌ | 明确不做（决策见 §7） |
| ❓ | 未验证，或依赖 pi-tui 默认行为 |

## 1. 会话与生命周期

| 功能 | pi 功能说明 | pim 状态 |
| --- | --- | --- |
| 新建会话 | `/new`、`app.session.new` | ✅ `/new`（`tui_app/run.mbt:52`） |
| 恢复会话 | `/resume`、`app.session.resume` | ✅ `/resume`、`/resume <前缀>`（`run.mbt:59`） |
| 退出 | `/quit`、`ctrl+d` | ✅ `/quit`、`/exit`、`ctrl+d`、双击 `ctrl+c` |
| 中断当前回合 | `escape` | ✅（`app.mbt:193`） |
| 自动重试提示 | 状态提示 | ✅ `push_note` + 状态行（`app.mbt:341`） |
| 会话树 / 分支切换 | `/tree`、`app.session.tree` | ⬜ |
| 分支（fork / clone） | `/fork`、`/clone` | ⬜ |
| 会话命名 | `/name`、`app.session.rename` | ⬜ 只显示 journal 里的名字（`app.mbt:163`） |
| 会话导入 / 导出 | `/import`、`/export` | ⬜ |
| 会话分享 | `/share` | ⬜ |
| 手动压缩上下文 | `/compact` | ⬜ 后端有 `compaction.mbt`，TUI 未接 |
| 重载资源 | `/reload` | ⬜ `/skill:` 每次提交重新发现技能，补全列表只在启动时算一次（`app.mbt:152`） |
| 挂起进程 | `app.suspend`（`ctrl+z`） | ⬜ |

## 2. 输入与编辑

| 功能 | pi 功能说明 | pim 状态 |
| --- | --- | --- |
| 编辑器基础（多行、历史、粘贴、kill-ring、undo） | pi-tui `Editor` | ✅（`prompt_editor.mbt` 包装 `Editor`） |
| 运行状态行（spinner + 阶段） | 有 | ✅（`status.mbt`，嵌在输入框上边框） |
| slash 命令名补全 | 内置命令 + 模板 + 扩展 + 技能 | 🟡 缺模板与扩展命令（`app.mbt:171`） |
| 命令参数补全 | `argumentHint` / `getArgumentCompletions` | ⬜ 桥接层只映射 name/description |
| `@文件` 补全 | 需要 `fd` | ⬜ 未接 `fd`，`@` 无结果（`component.mbt:384`） |
| 路径补全 | 有 | ✅ 不依赖 `fd` |
| 外部编辑器 | `ctrl+g` | ⬜ |
| 图片 / 文件粘贴 | `ctrl+v` | ⬜ |
| 复制消息 | `ctrl+x` | ⬜ |
| 手动 follow-up 队列 | `alt+enter` | ⬜ |
| 取回排队消息编辑 | `alt+up` | ⬜ 排队消息回合结束后自动发送（`app.mbt:435`） |

## 3. slash 命令

未识别的 `/xxx` 目前当作普通用户文本发给模型（`run.mbt:63`）；pi 会走命令分发。

| 功能 | pi 功能说明 | pim 状态 |
| --- | --- | --- |
| `/skill:<name> [args]` | 显式加载技能，忽略 `disable-model-invocation` | ✅ TUI 提交时展开为 `<skill>` 块，显示与 journal 一致 |
| `/new`、`/resume`、`/quit` | 会话生命周期 | ✅ |
| `/help`、`/hotkeys` | 帮助与快捷键清单 | ⬜ |
| `/model`、`/scoped-models` | 模型选择与 Ctrl+P 循环范围 | ⬜ |
| `/thinking` | 设置 thinking 级别 | ⬜ |
| `/settings`、`/trust`、`/login`、`/logout` | 设置、项目信任、凭证 | ⬜ |
| `/session`、`/name` | 会话信息与重命名 | ⬜ |
| `/tree`、`/fork`、`/clone` | 会话树与分支操作 | ⬜ |
| `/compact`、`/reload` | 压缩上下文、重载资源 | ⬜ |
| `/copy`、`/export`、`/import`、`/share` | 复制与导入导出分享 | ⬜ |
| `/bug`、`/changelog` | 报告问题、查看更新 | ⬜ |
| prompt templates（`/template`） | 从文件加载的提示模板 | ⬜ 无模板子系统 |
| 扩展注册的命令 | extension 提供的命令 | ⬜ 无扩展子系统 |

## 4. 转录渲染

| 功能 | pi 功能说明 | pim 状态 |
| --- | --- | --- |
| Markdown 渲染 + 缓存 | 全部文本 | ✅ |
| 工具调用块与结果 | 有 | ✅ |
| `ctrl+o` 全局折叠/展开 | 工具输出、skill 正文、自定义消息、压缩/分支摘要 | 🟡 覆盖工具输出与 skill 正文；自定义消息、压缩/分支摘要无对应子系统 |
| 点击单条折叠/展开 | 同 `ctrl+o` 的全部块类型 | ❌ 不实现（§7） |
| `ctrl+t` 显示/隐藏思考块 | 思考块 | ✅（`app.mbt:237`） |
| 自定义消息块 | extension / custom 消息 | ⬜ |
| 压缩摘要块、分支摘要块 | 有 | ⬜ |
| 图片渲染 | 终端图片协议 | ⬜ |
| 滚动、鼠标、点击 | 有 | ✅（`chat_viewport.mbt`、`component.mbt:61`） |
| 全屏备用屏幕 + 搜索 | `TuiAltScreen` + `ctrl+shift+f` | ❓ `TuiAltScreen` 已用（`tui.mbt:110`），搜索未验证 |

## 5. 状态栏

| 功能 | pi 功能说明 | pim 状态 |
| --- | --- | --- |
| 模型 / thinking / cwd / git 分支 / 会话名 | 有 | ✅（`footer.mbt`） |
| token 用量、缓存读写、缓存命中率、费用 | 有 | ✅ |
| 上下文窗口占用 | 依赖模型元数据 | ⬜ 无元数据时不显示（`footer.mbt:7`） |

## 6. 配置与资源

| 功能 | pi 功能说明 | pim 状态 |
| --- | --- | --- |
| 主题切换 | `/settings`、主题包 | ⬜ 只有内置 `light`（`theme/light.json`） |
| 键位自定义 | keybindings 配置 | ⬜ 硬编码 |
| skills（`SKILL.md`、`disable-model-invocation`、`/skill:`） | 有 | ✅ |
| 用户级 skill 目录 | `~/.agents/skills` | ⬜ 只扫 `<cwd>/.agents/skills` |
| AGENTS.md 热重载 | `/reload` | ⬜ 首次提示时读取并随系统提示缓存 |

## 7. 明确不做（决策记录）

| 项 | 决策 | 原因 |
| --- | --- | --- |
| 点击单条折叠/展开 | ❌ 不实现 | 折叠/展开只做全局开关（`ctrl+o`） |
| print 模式（`pim -p`）展开 `/skill:` | ❌ 暂不支持 | 本轮范围限定 TUI，展开只在 `TuiApp::submit` 做 |
