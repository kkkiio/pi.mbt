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
- **pim** — 本项目的 native CLI 可执行文件产物(由 `cmd/pim` 构建为 `pim.exe`)。
- **mooncram** — 测试转录中的可执行终端会话块(` ```mooncram `),由 `moon cram test` 校验命令输出与退出状态。
- **-p / --print** — pi 的非交互模式:处理 prompt 后打印回复并退出;`pim` 当前唯一支持的选项。

## Policies & Mandatory Rules

### Black-Box Test Policy

只写黑盒测试:通过公共 API 或 CLI 行为验证,不添加 `_for_test` 公开符号、不暴露私有类型、不扩大 facade 只为可测性。

### CLI Contract Test Policy

CLI 契约由 `tests/cram/` 下的 `mooncram` 转录持续验证。变更 CLI 参数、stdout/stderr、退出状态或用户工作流时:

- 在对应的转录文件(`tests/cram/cli.md` 等)中同步更新,转录直接调用产物名 `pim.exe`。
- 所有 cram 用例必须离线确定:不依赖 API key、不发网络请求;prompt 路径用
  缺 key 失败或参数校验失败覆盖,不包含时间戳、随机值、绝对临时路径或环境相关颜色。
- 未实现的命令保留红色规格(failing transcript)作为实现目标;不要改写期望输出来掩盖实现缺口。

### Live Provider Test Policy

真实 provider 测试放在 `tests/live/`,与离线套件分离:`just test` 和 CI 不跑它们。

- 运行方式:`just eval`(若本地存在 `.env.test` 会自动加载);或显式
  `DEEPSEEK_API_KEY=sk-... moon cram test tests/live`。本地 key 放在
  git-ignored 的 `.env*` 文件里,跑 live 测试前先检查是否存在。
- 没有 key(且没有 `.env.test`)时用例会失败,这是预期行为——live 测试是
  opt-in,不假装离线可过。
- 转录只断言稳定契约(如最终回复恰好为 `Paris`),不复现模型输出细节。

### Output Stream Contract

对齐 pi 的输出流约定:成功结果与 `--help` 输出到 stdout;诊断与参数错误输出到 stderr,
参数错误按 pi 风格格式化为单行 `Error: <detail>`(不附带 usage 块)。`pim` 不得让未
捕获的参数解析错误泄漏到 stdout(`cmd/pim/main.mbt` 已 catch `@argparse.parse` 的
raise,取首行改写后写入 stderr)。

## Operation Guide

检查(警告即错误):

```bash
moon check --deny-warn
```

构建 native 可执行文件:

```bash
moon build --target native
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
