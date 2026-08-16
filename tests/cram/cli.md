# pim CLI 契约测试

这些示例由 `moon cram test tests/cram` 执行。Moon 先构建 `cmd/pim` 的 native 包,
再把可执行文件以 `pim.exe` 暴露到 PATH 上。

这里的所有命令都是离线的:要么打印 help,要么在 agent 接触 DeepSeek 之前就完成
参数校验失败,因此整个套件不需要 API key、不发网络请求。

## 顶层 Help

`pim --help` 把用法输出到 stdout 并以 0 退出:

```mooncram
$ pim.exe --help
Usage: pim [options]

Options:
  -h, --help           Show help information.
  -p, --print <print>  
```

## 缺少 -p

不带任何参数是使用错误;诊断写入 stderr,退出码为 1:

```mooncram {output_stream: stderr}
$ pim.exe
Error: only '-p' support for now
[1]
```

## 选项缺值

`-p` 缺省值由 argparse 拒绝;诊断写入 stderr(丢弃 usage 块),退出码为 1:

```mooncram {output_stream: stderr}
$ pim.exe -p
Error: a value is required for '-p' but none was supplied
[1]
```

## 未知选项

```mooncram {output_stream: stderr}
$ pim.exe --bogus
Error: unexpected argument '--bogus' found
[1]
```

## 缺少 API key 时 -p 失败

没有 `DEEPSEEK_API_KEY` 时,`-p` 在 provider 构造阶段失败,退出码为 1;失败报告
目前由 async runtime 输出到 stdout:

```mooncram
$ (unset DEEPSEEK_API_KEY; pim.exe -p hi)
Failure(sdk/providers/deepseek.mbt:17:5-17:34@KKKIIO/pi FAILED: miss DEEPSEEK_API_KEY)
[1]
```
