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
