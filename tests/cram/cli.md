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
Usage: pim [options] [args...]

Arguments:
  args...  prompt texts and @file attachments

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

## @file 附件

位置参数里以 `@` 开头的条目是文件附件(pi `fileArgs`):图片文件按魔数
嗅探后 base64 内联成 image 块,文本文件展开为 `<file name="abs">` 文本块;
两者都只挂在首条消息上。不存在的路径是单行错误:

```mooncram {output_stream: stderr}
$ PIM_CONFIG_DIR=tests/cram/testdata/auth-absent DEEPSEEK_API_KEY=sk-fake moon run cmd/pim -- --no-session -p hi @missing.png
Error: File not found: */missing.png (glob)
[1]
```

下面的离线桩断言整条约路:位置参数 `describe-this` 是提示词,
`@pixel.png` 内联成 image 块并在请求编码前被降级成 pi 的占位文本
(DeepSeek 无视觉输入),`@note.txt` 展开成 `<file>` 文本块:

```mooncram
$ node tests/cram/testdata/image-cli.mjs
image-contract-ok
```

## 离线 JSONL 事件流

通过 Node preload 替换 HTTP fetch,实际执行 `pim --no-session --mode json`:
第一轮产生 bash 工具调用并执行 `echo pim-offline`,第二轮返回两段文本增量。
fixture 禁止联网,并检查第二轮请求确实携带工具结果;配置目录和凭证都隔离。

检查器验证子进程成功退出、stdout 每行都能解析为 JSON、最终回复和生命周期,
然后保留完整的 `message_update` / `tool_execution_*` 行作为快照。
换行与引号故意放在文本 delta 中,覆盖 JSONL 转义;不把时间戳纳入快照。
真实 provider 的补充覆盖仍在 `tests/live/deepseek.md`。

```mooncram
$ node tests/cram/testdata/json-cli.mjs
{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"toolcall_start","contentIndex":0,"id":"call_offline","toolName":"bash"}}
{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"toolcall_delta","contentIndex":0,"delta":"{\"command\":"}}
{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"toolcall_delta","contentIndex":0,"delta":"\"echo pim-offline\"}"}}
{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"toolcall_end","contentIndex":0,"toolCall":{"type":"toolCall","id":"call_offline","name":"bash","arguments":{"command":"echo pim-offline"}}}}
{"type":"tool_execution_start","toolName":"bash","args":{"command":"echo pim-offline"}}
{"type":"tool_execution_end","toolName":"bash","content":[{"type":"text","text":"pim-offline\n"}],"isError":false}
{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"text_start","contentIndex":0}}
{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"pim-offline"}}
{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"\n\"complete\""}}
{"type":"message_update","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"text_end","contentIndex":0,"content":"pim-offline\n\"complete\""}}
```
