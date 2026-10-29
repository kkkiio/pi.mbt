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

`-p/--print` 单轮、非交互模式:

```bash
DEEPSEEK_API_KEY=sk-xxx
pim -p "What's the capital of France? Respond with only the city name."
# Paris
```

使用 `--mode json` 启动, 可以输出 JSONL 事件流:

```bash
pim -p "What's the capital of France? Respond with only the city name." --mode json
# {"type":"agent_start"}
# {"type":"turn_start"}
# {"type":"message_start","message":{"role":"user","content":[{"type":"text","text":"What's the capital of France? Respond with only the city name."}],"timestamp":1786903823973}}
# ...
# {"type":"agent_end"}
```

## Configuration

| 变量              | 作用                                                 |
| ----------------- | ---------------------------------------------------- |
| `PIM_CONFIG_DIR`  | 配置目录,默认 `~/.pim`                               |
| `PIM_SESSION_DIR` | 会话 JSONL 目录(等价于 `--session-dir`) |
| `PIM_TOOLS`       | 启用的工具列表(逗号分隔,等价于 `--tools`) |

配置目录, 默认是 `~/.pim`.

会话默认会持久化, 保存到 `~/.pim/sessions/` 下(同时创建会话目录)。

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
