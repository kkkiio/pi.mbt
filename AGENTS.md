# AGENTS.md

## Project Structure Guide

### Repo Structure & Important Files

```text
.
├── AGENTS.md
├── README.md
├── justfile
├── moon.mod
├── package.json
├── dist/                     # gitignore;npm 交付物
├── scripts/
│   └── pack-npm.sh           # 生成 dist/pim.js(npm 包根 = 仓库根)
├── cmd/
│   └── pim/                  # pim 可执行入口:print 模式 + 全屏 TUI(moon 包,无 npm manifest)
│       ├── main.mbt
│       └── config.mbt        # 用户配置目录与凭证读取(PIM_CONFIG_DIR / auth.json)
├── tui_app/                  # 全屏 TUI(pi-tui 绑定 + 组件 + 会话接线)
│   ├── README.mbt.md         # 组件树与数据流
│   ├── app.mbt               # TuiApp:视图状态 / mutator / 输入与退出
│   ├── session_host.mbt      # 会话所有权:journal、多会话、事件 → 视图
│   ├── run.mbt               # 装配 + 斜杠命令循环 + 收尾
│   ├── app_test.mbt
│   ├── transcript_test.mbt
│   ├── theme/light.json
│   └── theme_builtin_gen.mbt # 由 `moon tool embed` 生成
├── sdk/                      # 库代码(agent 组装与 provider 集成)
│   ├── agent_loop/           # agent 事件循环与消息类型
│   ├── agent_session/        # 会话、journal、listener、tool registry
│   ├── coding_agent/         # agent 组装、system prompt、bash 工具、@file 附件、输出累加
│   ├── providers/            # LLM provider
│   │   └── faux/             # 脚本化假 provider(测试基建)
│   └── tools/                # 工具定义
└── tests/
    ├── cram/                 # CLI 契约离线测试转录(由 moon cram test 执行)
    │   ├── cli.md
    │   └── testdata/         # 入库的只读 fixture(PIM_CONFIG_DIR 用的隔离配置目录)
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

## Policies & Mandatory Rules

### Black-Box Test Policy

只写黑盒测试:通过公共 API 或 CLI 行为验证,不添加 `_for_test` 公开符号、不暴露私有类型、不扩大 facade 只为可测性。

### CLI Contract Test Policy

CLI 契约由 `tests/cram/` 下的 `mooncram` 转录持续验证。

- 在对应的转录文件(`tests/cram/cli.md` 等)中同步行为。
- 涉及凭证的用例必须把 `PIM_CONFIG_DIR` 指向隔离目录,避免开发机的 `~/.pim/auth.json` 影响结果。

### Live Provider Test Policy

真实 provider 测试放在 `tests/live/`,与离线套件分离。
可以只断言稳定契约(如最终回复恰好为 `Paris`)，避免测试太脆弱。

### Github Issues Tracking Policy

创建 `enhancement` 时，只描述需求，不写方案。

### API Comment Policy

在 public API 上写 Doc 注释。
防御性注释写到 `*_test.mbt` 文件里。

## Operation Guide

日常迭代流程:

```bash
just check
just fmt
just test
just build
```

跑真实 provider 的 live 测试(需要 `DEEPSEEK_API_KEY`):

```bash
# 若本地存在 `.env.test` 会自动加载
just eval
# 或者手动设置 key
DEEPSEEK_API_KEY=sk-... moon cram test --work-directory . tests/live
```

### PR Review

Github PR 配置了 codex review (on pr).
新提交的 PR 可以 watch [codex review check](.github/workflows/codex-review-check.yml) 来等待 review 结果.
如果有 review 意见, 可以根据意见修复, 推送后 `@codex review` 重新 review.
如果 review 超过 3 次仍未通过, 可能是 PR 方向有误, 或者是 codex 理解不对, 停下并联系项目维护者沟通.