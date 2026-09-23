# AGENTS.md

## Project Structure Guide

### Repo Structure & Important Files

```text
.
├── AGENTS.md                 # Root — 全局规则
├── README.md                 # 用户文档与使用说明
├── justfile                  # check / build / test / cram 命令
├── moon.mod                  # MoonBit 模块元数据(依赖 moonbitlang/async)
├── cmd/
│   └── pim/                  # pim 可执行入口;当前仅 -p/--print 非交互模式
│       └── main.mbt
├── sdk/                      # 库代码(agent 组装与 provider 集成)
│   ├── agent_loop/           # agent 事件循环与消息类型
│   ├── agent_session/        # 会话、journal、listener、tool registry
│   ├── coding_agent/         # agent 组装、system prompt、bash 工具、输出累加
│   ├── providers/            # LLM provider(当前: DeepSeek responses API)
│   └── tools/                # 工具定义
└── tests/
    ├── cram/                 # CLI 契约离线测试转录(由 moon cram test 执行)
    │   └── cli.md
    └── live/                 # 真实 provider 测试转录(opt-in,需 DEEPSEEK_API_KEY)
        └── deepseek.md
```

### 参考项目

- [Pi](https://github.com/earendil-works/pi)
- [openseek](https://github.com/moonbitlang/openseek)

## Domain Language

- **pi** — 上游 TypeScript coding agent(https://github.com/earendil-works/pi),pim 的行为对齐目标。
- **pim** — 本项目的 CLI 可执行文件产物。
- **mooncram** — 测试转录中的可执行终端会话块(` ```mooncram `),由 `moon cram test` 校验命令输出与退出状态。
- **-p / --print** — pi 的非交互模式:处理 prompt 后打印回复并退出;`pim` 当前唯一支持的选项。

## Policies & Mandatory Rules

### Black-Box Test Policy

只写黑盒测试:通过公共 API 或 CLI 行为验证,不添加 `_for_test` 公开符号、不暴露私有类型、不扩大 facade 只为可测性。

### CLI Contract Test Policy

CLI 契约由 `tests/cram/` 下的 `mooncram` 转录持续验证。

- 在对应的转录文件(`tests/cram/cli.md` 等)中同步行为。
- 所有 cram 用例必须离线确定。

### Live Provider Test Policy

真实 provider 测试放在 `tests/live/`,与离线套件分离。

- 运行方式:`just eval`(若本地存在 `.env.test` 会自动加载);或显式
  `DEEPSEEK_API_KEY=sk-... moon cram test tests/live`。本地 key 放在
  git-ignored 的 `.env*` 文件里,跑 live 测试前先检查是否存在。
- 没有 key(且没有 `.env.test`)时用例会失败,这是预期行为——live 测试是
  opt-in,不假装离线可过。
- 转录只断言稳定契约(如最终回复恰好为 `Paris`),不复现模型输出细节。

## Operation Guide

检查(警告即错误):

```bash
moon check --deny-warn
```

构建 CLI 产物:

```bash
moon build
```

运行全部测试(`moon test` + cram):

```bash
just test
```

只跑 CLI 契约测试:

```bash
moon cram test tests/cram
```

跑真实 provider 的 live 测试(需要 `DEEPSEEK_API_KEY`):

```bash
moon cram test tests/live
```

新增或改动 `mooncram` 转录时,单独跑受影响的文件:

```bash
moon cram test tests/cram/cli.md
```
