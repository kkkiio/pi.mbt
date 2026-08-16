# pi.mbt

用 MoonBit 重新实现的 [pi](https://github.com/earendil-works/pi) coding agent 子集。

## Usage

构建 native 可执行文件:

```bash
moon build --target native
```

源码构建产物名为 `pim.exe`。当前只支持 `-p/--print` 非交互模式,把 agent 的最终
回复写到 stdout:

```bash
pim -p "Explain the codebase in one paragraph"
```

运行全部测试(`moon test` + CLI 契约测试):

```bash
just test
```

CLI 契约的离线测试转录见 `tests/cram/cli.md`,由 `moon cram test tests/cram`
执行。真实 provider 的 smoke 测试见 `tests/live/deepseek.md`,需要
`DEEPSEEK_API_KEY`,用 `just eval` 运行。
