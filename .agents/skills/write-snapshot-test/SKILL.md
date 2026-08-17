---
name: write-snapshot-test
description: 为 pi.mbt 编写或修改 MoonBit 快照测试。适用于 JSONL journal、会话 entries、诊断消息、CLI 输出契约等结构化输出。
---

# Write Snapshot Test

Use this skill when adding or updating MoonBit snapshot tests in pi.mbt.

## 决策：用哪种断言

| 场景 | 用 | 原因 |
| --- | --- | --- |
| 完整 JSONL 文本输出 | `inspect(value, content=(#|...#))` | 文本形状就是契约。 |
| 实现 `ToJson` 的结构化领域对象（`SessionEntry`、messages 等） | `json_inspect(value)` | snapshot 即 JSON 契约，`--update` 自动维护。 |
| 实现 `Show` 的标量 | `inspect(value)` | 比 `debug_inspect` 可读。 |
| 单个可独立推导的不变量（计数、id 相等） | `assert_eq(a, b)` | 失败定位精确，不必看 snapshot。 |
| 布尔谓词（`is_retryable(...)` 这类分类/判定函数） | `assert_true(f(x))` / `assert_false(f(x))` | 谓词测试的本质就是真假，`debug_inspect(..., content="true")` 是无信息快照。 |
| **不可** | 把 `contains` / `length` / `starts_with` 结果包进 `inspect` 或 tuple | 既丢可读性，又丢定位能力。 |

**核心原则：让 `moon test --update` 生成 baseline，不要手写预期数组或字符串。**

JSONL / JSON 文本形状的快照由 formatter/序列化器决定，agent 或人手工构造的预期值容易过时。

## 确定性规则

快照测试只有在每次输入产出相同输出时才有意义。

### 必须固定

- **随机 id**：传入固定种子，如 `rand=@random.Rand::chacha8()`。
- **时间戳**：传入固定 `now`，如 `now=1786903823973`。
- **当前工作目录**：传入固定 `cwd`，如 `cwd="/workspaces/pi.mbt"`。
- **Map/Set 迭代顺序**：必要时先排序再快照。

### 禁止快照

- 未受控的当前时间、进程 ID、临时路径。
- 模型生成的自由文本。
- 平台相关的颜色、换行、文件分隔符。
- 绝对临时目录。

## JSONL / 文本契约

- 快照完整行，不做 `contains` 或正则断言。
- 如果文本包含不稳定字段，要么通过依赖注入固定它们，要么把稳定部分拆出来单独断言。
- 不要为同一行输出同时写完整 snapshot 和子串断言；snapshot 已经覆盖。

## 内存对象契约

- 优先 `json_inspect(value)`，利用 `ToJson` 得到稳定的 JSON 表示。
- 不要为了让 `inspect` 编译而去 unwrap `Option` 或拆散公开结构。
- 如果类型没有 `ToJson`，先评估是否真的需要快照；可以补 `derive(ToJson)`，或用 `debug_inspect`。

## 一个测试一个场景

单个快照测试应覆盖一个完整场景，把多种输入放在一起断言，而不是拆成多个只测一行的小测试。

示例：一个测试同时 persist `ModelChanage`、`User` message 和 `Compaction`，然后 snapshot `get_entries()` 和 writer 文本。

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
4. 拒绝包含未固定的时间戳、随机值、绝对路径的 baseline。
5. 把 snapshot 更新与行为变更放在同一个 commit。

## 与现有测试政策的边界

- 默认仍遵循黑盒测试政策：通过公开 API 驱动，不为测试扩大 facade。
- CLI 输出契约用 `moon cram` 转录，不用 `inspect` snapshot。
- 真实 provider 的 live 测试放在 `tests/live/`，不参与默认 `moon test`。
