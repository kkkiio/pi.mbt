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
