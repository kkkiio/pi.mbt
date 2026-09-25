# pim CLI 契约测试

这些示例被 `moon cram test` 使用，所有命令都是离线的。

## 顶层 Help

`pim --help` 把用法输出到 stdout 并以 0 退出:

```mooncram
$ moon run cmd/pim -- --help
Usage: pim [options]

Options:
  -h, --help                   Show help information.
  -p, --print <print>          prompt text
  --session-dir <session_dir>  directory to store session JSONL files [env: PIM_SESSION_DIR]
  --mode <mode>                output mode: text or json (default text)
  --thinking <thinking>        thinking effort level: low, high (default), or max
```

## 非终端且没有 -p

没有 `-p` 时:stdin/stdout 都是终端才进全屏 TUI,否则(这里是 cram 的非终端环境)
按 print 模式处理,而 print 模式必须有提示词 —— 诊断写入 stderr,退出码为 1:

```mooncram {output_stream: stderr}
$ moon run cmd/pim --
Error: no prompt (pass -p <prompt>, or run in a terminal for the TUI)
[1]
```

## 未实现的 --mode rpc

`--mode` 只支持 text/json(与 pi 一致,rpc 未实现),错误同样是单行诊断:

```mooncram {output_stream: stderr}
$ moon run cmd/pim -- --mode rpc -p hi
Error: mode 'rpc' is not supported yet
[1]
```

## 选项缺值

`-p` 缺省值由 argparse 拒绝;诊断写入 stderr(丢弃 usage 块),退出码为 1:

```mooncram {output_stream: stderr}
$ moon run cmd/pim -- -p
Error: a value is required for '-p' but none was supplied
[1]
```

## 未知选项

```mooncram {output_stream: stderr}
$ moon run cmd/pim -- --bogus
Error: unexpected argument '--bogus' found
[1]
```

## 非法 --mode 取值

`--mode` 只接受 `text` 或 `json`;非法取值在接触 provider 之前被拒绝,
诊断写入 stderr,退出码为 1:

```mooncram {output_stream: stderr}
$ moon run cmd/pim -- --mode yaml -p hi
Error: invalid mode 'yaml' (expected text or json)
[1]
```

## 缺少 API key 时 -p 失败

没有 `DEEPSEEK_API_KEY` 时,`-p` 在 provider 构造阶段失败,退出码为 1;失败报告
目前由 async runtime 输出到 stdout:

```mooncram {output_stream: stderr}
$ (unset DEEPSEEK_API_KEY; moon run cmd/pim -- -p hi)
Error: miss DEEPSEEK_API_KEY
[1]
```

`--mode json` 的事件流契约(`tool_execution_start` /
`tool_execution_end` 等)由 `tests/live/deepseek.md` 用真实 provider 覆盖。
