# pi.mbt

[![Coverage Status](https://coveralls.io/repos/github/kkkiio/pi.mbt/badge.svg?branch=main)](https://coveralls.io/github/kkkiio/pi.mbt?branch=main)

用 MoonBit 重新实现的 [pi](https://github.com/earendil-works/pi) coding agent 子集。

![pim 全屏 TUI：示例对话、思考过程、bash 工具输出与输入框](docs/assets/tui-session.png)

## Install

```bash
just package          # 构建 npm dist
npm install -g .      # symlink 到全局
```

## Usage

在终端中直接运行 `pim` 进入全屏 TUI:

```bash
pim
```

`Ctrl+O` 展开工具输出,`Ctrl+T` 切换思考显示,`Esc` 中断当前回合。

`-p/--print` 单轮、非交互模式:

```bash
DEEPSEEK_API_KEY=sk-xxx
pim -p "What's the capital of France? Respond with only the city name."
# Paris
```

位置参数也是提示词;`@path` 形式的参数会把文件附进首条消息 —— 图片按
魔数嗅探后内联(模型无视觉输入时降级为占位文本),文本文件展开为
`<file name="...">` 引用:

```bash
pim "describe this screenshot" @shot.png @notes.txt
```

加上 `--mode json` 可以输出 JSONL 事件流:

```bash
pim -p "What's the capital of France? Respond with only the city name." --mode json
# {"type":"agent_start"}
# {"type":"turn_start"}
# {"type":"message_start","message":{"role":"user","content":[{"type":"text","text":"What's the capital of France? Respond with only the city name."}],"timestamp":1786903823973}}
# ...
# {"type":"agent_end"}
```

## Configuration

### 工具发现

默认只启用 `bash`。`--tools` 接受逗号分隔的初始工具列表;
`--tools tool_search` 只向模型声明搜索工具,让它按需搜索并加载 `bash`。
`--tools bash,tool_search` 同时启用两者,空字符串禁用初始工具。
恢复会话时以该分支 journal 中最后记录的工具集为准。

SDK 可向 `new_coding_session(..., tool_registry=registry)` 传入注册表,
用 `register_tool(..., exposure=Deferred)` 注册额外工具。
注册与声明分离:只有 `active_tools` 中的工具进入模型请求。
每个 coding session 通过 registry overlay 保存自己的内置 `bash` 实现,
共享注册表上的后续注册仍会被发现,不会相互覆盖工作目录。
`tool_search` 在当前未声明的可调用工具中按 BM25 检索(默认最多 8 个),
返回名称和描述,并将命中的工具追加到下一次模型请求的声明中。
检索包括工具名、描述、参数属性及描述、namespace 描述和指引;
完整工具名及 `__` 后的名称后缀优先,同分按注册顺序排列。
分词与 pi 一致,支持英文大小写、camelCase、缩写和简单复数归一化。
声明同时携带工具的 `prompt_guidelines`,使动态加载的工具也能收到使用指引,
并保持缓存的 system prompt 稳定。

工具集变更存为 `customType: "pi.tools"` 的 session 条目,
`data.activeTools` 保存完整名称列表(含空列表)。
首轮消息会先记录初始工具集;没有工具记录的旧 journal 使用调用方提供的初始值。
`AgentSession.set_active_tools` 现在是异步 API:先写 journal 再更新状态。
`/resume`、`--continue`、选中分支回放及复制历史形成的 fork 都会恢复工具集;
压缩模型上下文不会丢弃工具状态。
恢复 SDK 会话时,调用方仍须注册被保存的工具实现。

`sdk/tools` 提供共用的 `all_tools`、`search_tools`、`describe_tool`、
`describe_namespace` API。用 `register_namespace` 按工具名前缀分组,
搜索时可通过 `ns` 过滤。`ModelOnly` 工具不参与脚本发现或加载。
`sdk/codemode.new_discovery_globals(registry)` 为 JavaScript 宿主提供
`ALL_TOOLS`、异步 `searchTools(query, { limit?, namespace? })`、
`describeTool(name)` 和 `describeNamespace(name)`。
描述包含 TypeScript 调用声明;未知名称返回 `undefined`。
这些只读操作不会加载工具,每次读取都会反映最新注册表。
当前提供的是 discovery globals,脚本宿主仍需负责执行隔离和 `tools` 调用对象;
仓库尚未提供完整 codemode 执行器或 MCP 连接管理。

### 环境变量

| 变量              | 作用                                                 |
| ----------------- | ---------------------------------------------------- |
| `PIM_CONFIG_DIR`  | 配置目录,默认 `~/.pim`                               |
| `PIM_SESSION_DIR` | 会话 JSONL 目录(等价于 `--session-dir`) |

会话默认落盘:不设 `PIM_SESSION_DIR`/`--session-dir` 时,提示词与工具输出会
持久化到 `~/.pim/sessions/` 下(同时创建会话目录)。不想落盘(如敏感内容、
一次性调试)请传 `--no-session`。多轮会话用 `--continue`(接着最近一次)或
`--resume <前缀>`。

### 认证配置

认证优先使用文件配置 `~/.pim/auth.json`:

```json
{
  "deepseek": { "type": "api_key", "key": "sk-xxx" }
}
```

也支持环境变量:

```bash
DEEPSEEK_API_KEY=sk-xxx pim -p "hi"
```
