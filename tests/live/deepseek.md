# Live DeepSeek CLI Documentation

Unlike [`tests/cram/cli.md`](../cram/cli.md), the examples here make **real**
DeepSeek API calls — there is no mocking. They live in a separate directory so
the offline suite can run in CI without credentials, while these are opt-in:

```bash
export DEEPSEEK_API_KEY=sk-...   # a real DeepSeek provider API key
moon cram test tests/live
```

## Smoke: A Real Round Trip That Answers

The upstream pi smoke eval
(`packages/evals/src/smoke.eval.ts`) runs the same prompt through a real
provider and asserts the final reply is exactly `Paris`. `pim` mirrors that:
`-p` prints the agent's final reply text to stdout, and the assertion is the
full stdout content.

```mooncram
$ pim.exe -p "What's the capital of France? Respond with only the city name."
Paris
```

Without `DEEPSEEK_API_KEY` the run fails at provider construction instead of
reaching the API, so this transcript only passes when a real key is exported.

## Watching The Agent Use Bash

`--mode json` streams one event per line, so we can verify the agent really
*acts*: the task forces the `bash` tool, and the `tool_execution_start` /
`tool_execution_end` records join the stream. We match the events together
with the tool name, and use a regex on the command and the returned content
to confirm the command ran and its output flowed back. We also assert the
user `message_start` carries a numeric `timestamp`, pinning the wire shape
of pi-aligned user messages.

```mooncram
$ pim.exe --mode json -p "Use the bash tool to run exactly: echo pim-cram. Then respond with only the command output." 2>/dev/null \
>   | moon run --target native -e 'import {
>   "bobzhang/jsonl@0.2.0",
>   "moonbitlang/async",
> }
> 
> async fn main {
>   let mut used_bash = false
>   let mut bash_output_seen = false
>   let mut user_timestamp_seen = false
>   for value in @jsonl.read_stdin() {
>     if value is { "type": String("message_start"), "message": { "role": String("user"), "timestamp": Number(_), .. }, .. } {
>       user_timestamp_seen = true
>     }
>     if value is { "type": String("tool_execution_start"), "toolName": String("bash"), "args": Object(args), .. } {
>       if args.get("command") is Some(String(cmd)) && cmd =~ re"echo pim-cram" {
>         used_bash = true
>       }
>     }
>     if value is { "type": String("tool_execution_end"), "toolName": String("bash"), "content": Array(parts), .. } {
>       for part in parts {
>         if part is { "type": String("text"), "text": String(text), .. } && text =~ re"pim-cram" {
>           bash_output_seen = true
>         }
>       }
>     }
>   }
>   println("used_bash=\{used_bash}")
>   println("bash_output_seen=\{bash_output_seen}")
>   println("user_timestamp_seen=\{user_timestamp_seen}")
> }' 2>/dev/null \
>   | grep '='
used_bash=true
bash_output_seen=true
user_timestamp_seen=true
```
