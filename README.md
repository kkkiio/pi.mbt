# pi.mbt

用 MoonBit 重新实现的 [pi](https://github.com/earendil-works/pi) coding agent 子集。

## Install

```bash
moon install ./cmd/pim
```

## Usage

当前只支持 `-p/--print` 单轮、非交互模式:

```bash
DEEPSEEK_API_KEY=sk-xxx
pim -p "What's the capital of France? Respond with only the city name."
# Paris
```

加上 `--mode json` 可以输出 JSONL 事件流:

```bash
pim -p "What's the capital of France? Respond with only the city name." --mode json
# {"type":"agent_start"}
# {"type":"turn_start"}
# {"type":"message_start","message":{"role":"user","content":[{"type":"text","text":"What's the capital of France? Respond with only the city name."}]}}
# ...
# {"type":"agent_end"}
```
