---
defaults:
  environment:
    DEEPSEEK_API_KEY: ""
---

# pim CLI 契约测试

这些示例被 `moon cram test` 使用，所有命令都是离线的。

## 顶层 Help

`pim --help` 把用法输出到 stdout 并以 0 退出:

```mooncram
$ moon run cmd/pim -- --help
Usage: pim [options]

Options:
  -h, --help                   Show help information.
  -c, --continue               continue the most recent session
  --no-session                 don't save the session (ephemeral)
  -p, --print <print>          prompt text
  -r, --resume <resume>        continue the session whose name starts with this prefix
  --session-dir <session_dir>  directory to store session JSONL files (default: <config>/sessions/<cwd>) [env: PIM_SESSION_DIR]
  --mode <mode>                output mode: text or json (default text)
  --thinking <thinking>        thinking effort level: low, high (default), or max
```

## 会话参数

会话默认落盘到 `<config>/sessions/--<cwd 转义>--/`,`--no-session` 关闭落盘,
`-c` 续写最新会话、`-r <前缀>` 按名字前缀续写。

两个参数互斥,这一条在参数阶段就被拒绝 —— 不读凭证、不碰网络:

```mooncram {output_stream: stderr}
$ moon run cmd/pim -- --no-session -c -p hi
Error: --no-session cannot be combined with --continue/--resume
[1]
```

`-c` 与 `-r` 同理互斥 —— 隐式让其中一个优先会无声忽略用户指定的选择器:

```mooncram {output_stream: stderr}
$ moon run cmd/pim -- -c -r xyz -p hi
Error: --continue cannot be combined with --resume
[1]
```

`-r` 找不到会话同样是错误。这里把 `PIM_CONFIG_DIR` 指向空的配置目录,默认会话
目录下自然一个会话都没有,所以**不需要新增任何 fixture**:

```mooncram {output_stream: stderr}
$ PIM_CONFIG_DIR=tests/cram/testdata/auth-absent DEEPSEEK_API_KEY=sk-fake moon run cmd/pim -- -r xyz -p hi
Error: no session matches 'xyz'
[1]
```

真正「落盘 / 续写」的路径要跑完一轮模型才能观察,因此归 `tests/live/`。

## 没有 -p

print 模式必须有提示词 —— 诊断写入 stderr,退出码为 1:

```mooncram {output_stream: stderr}
$ moon run cmd/pim --
Error: only '-p' support for now
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

## 凭证来源与顺序

凭证按 `auth.json` → 环境变量的顺序解析: pi 的顺序是 `--api-key` → `auth.json` → env,pim 还 没有 `--api-key`。
配置目录由 `PIM_CONFIG_DIR` 覆盖,默认 `~/.pim`。

目录存在但没有 `auth.json`、`DEEPSEEK_API_KEY` 也没配时失败,退出码 1:

```mooncram {output_stream: stderr}
$ PIM_CONFIG_DIR=tests/cram/testdata/auth-absent moon run cmd/pim -- -p hi
Error: no DeepSeek API key (set DEEPSEEK_API_KEY, or add a "deepseek" entry to tests/cram/testdata/auth-absent/auth.json)
[1]
```

`auth.json` 存在但 JSON 损坏时明确报错(不静默降级到环境变量):

```mooncram {output_stream: stderr}
$ PIM_CONFIG_DIR=tests/cram/testdata/auth-invalid-json moon run cmd/pim -- -p hi
Error: tests/cram/testdata/auth-invalid-json/auth.json is not valid JSON: Invalid character 'n' at line 1, column 2
[1]
```

`deepseek` 条目存在但不是 api_key 形状时同样报错 —— 拼错的条目如果被环境变量
悄悄兜住,用户很难解释“为什么换了 key 没生效”:

```mooncram {output_stream: stderr}
$ PIM_CONFIG_DIR=tests/cram/testdata/auth-oauth-credential moon run cmd/pim -- -p hi
Error: tests/cram/testdata/auth-oauth-credential/auth.json: "deepseek" is not an api_key credential (expected {"type": "api_key", "key": "sk-..."})
[1]
```

`key` 为空同样不算凭证:

```mooncram {output_stream: stderr}
$ PIM_CONFIG_DIR=tests/cram/testdata/auth-empty-key moon run cmd/pim -- -p hi
Error: tests/cram/testdata/auth-empty-key/auth.json: "deepseek" is not an api_key credential (expected {"type": "api_key", "key": "sk-..."})
[1]
```

`--mode json` 的事件流契约(`tool_execution_start` /
`tool_execution_end` 等)由 `tests/live/deepseek.md` 用真实 provider 覆盖。
