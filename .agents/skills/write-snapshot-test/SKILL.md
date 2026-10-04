---
name: write-snapshot-test
description: 为 pi.mbt 编写或修改 MoonBit 快照测试。适用于 JSONL journal、会话 entries、诊断消息、CLI 输出契约等结构化输出。
---

# Write Snapshot Test

Use this skill when adding or updating MoonBit snapshot tests in pi.mbt.

## 决策：用哪种断言

核心原则：提高可读性，让用户在 review 时能理解用例和代码行为。

| 场景                                                      | 用                                                                   | 原因                                                |
| --------------------------------------------------------- | -------------------------------------------------------------------- | --------------------------------------------------- |
| 完整 JSONL 文本输出                                       | `inspect(value)`                                                     | 文本形状就是契约                                    |
| `Json` 或实现 `ToJson` 的结构化对象（events,messages 等） | `json_inspect(value)`                                                | 可读性强，手工构造的预期值容易过时                  |
| 实现 `Show` 的标量                                        | `inspect(value)`                                                     | 比 `debug_inspect` 可读。                           |
| 单个可独立推导的不变量（计数、id 相等）                   | `assert_eq(a, b)`                                                    | 有明确预期就不必看快照                              |
| 布尔谓词（`is_retryable(...)` 这类分类/判定函数）         | `assert_true(f(x))` / `assert_false(f(x))`                           | `debug_inspect(..., content="true")` 是无信息快照。 |
| **不可**                                                  | 把 `contains` / `length` / `starts_with` 结果包进 `inspect` 或 tuple | 既丢可读性，又丢定位能力。                          |

用 `moon test --update` 生成 baseline，不要手写预期数组或字符串。

## 确定性规则

快照测试只有在每次输入产出相同输出时才有意义。

- **随机 id**：传入固定种子，如 `rand=@random.Rand::chacha8()`。
- **时间戳**：传入固定 `now`，如 `now=1786903823973`。
- **当前工作目录**：传入固定 `cwd`，如 `cwd="/workspaces/pi.mbt"`。

## JSONL / 文本契约

- 快照完整行，不做 `contains` 或正则断言。
- 不要为同一行输出同时写完整 snapshot 和子串断言；snapshot 已经覆盖。

## 内存对象契约

- 优先 `json_inspect(value)`，利用 `ToJson` 得到稳定的 JSON 表示。
- 如果类型没有 `ToJson`，可以补 `derive(ToJson)`，或用 `debug_inspect`。

## 反模式

### 布尔谓词包进 snapshot tuple（坏）

```moonbit
debug_inspect(
  (text.contains("session"), text.contains("model_change")),
  content=((true, true)),
)
// review 看不到实际输出，失败时也不知道哪个 true 变了。
```

### 源码/文本片段断言（坏）

```moonbit
assert_eq(text.contains("model_change"), true)
```

子串断言不能替代完整 snapshot，也无法证明输出可解析或语义正确。

### 手写预期数组（坏）

```moonbit
assert_eq(
  entries.map(e => e.id),
  ["e1", "e2"],
)
// 新增字段或顺序调整后必须手工同步。
```

正确做法：

```moonbit
json_inspect(entries, content=[...])
```

## 更新 baseline

1. 先运行测试看 diff。
2. 仅当变化符合预期时更新：
   ```bash
   moon test --update
   ```
3. 用 `git diff` 逐项审查 snapshot 变化。
4. 把 snapshot 更新与行为变更放在同一个 commit。

## 与现有测试政策的边界

- CLI 输出契约用 `moon cram` 快照，不用 `inspect` snapshot。
