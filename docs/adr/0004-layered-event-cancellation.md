# ADR 0004: 分层的事件扩展与 listener 原生取消

- Status: Accepted
- Date: 2026-10-29
- Refines: [ADR 0003](0003-native-async-cancellation.md) 的事件扩展与取消保护范围

## 背景

ADR 0003 让 loop 在取消收尾时保护整个 event_sink，以完成消息封口、工具结果补齐和 journal 提交。session 的 listeners 也在这层保护中执行，因此无法通过 async.is_being_cancelled 感知原生取消，普通异步等待也不会因取消而结束。

sink 面向组装 agent 的宿主，需要承担可靠收尾；listener 面向应用扩展，应默认响应原生取消，并自行决定哪些工作必须完成。将两者放在同一个取消边界中，会迫使所有扩展遵循宿主级的收尾契约。

## 决策

### Loop 的 sink 是宿主扩展点

loop 的 sink 改为 `async (AgentEvent, EventContext) -> Unit`。EventContext 是只读值，包含 `is_cancelling : Bool`，表示本次通知是否由取消收尾派发。正常通知为 false，取消收尾为 true，覆盖补齐输入、assistant、工具结果、TurnEnd 和 AgentEnd。

上下文报告派发阶段，不代表事件自身的业务结果，也不提供触发或等待取消的能力。正常通知期间仍可能收到取消请求；是否正在取消收尾由 loop 的控制流决定，不能从 stop_reason 或当前协程是否受保护推断。

取消收尾仍由 loop 的 protect_from_cancel 保护整个 sink。Agent.run 透传上下文；session 的 sink 先完成受保护的 journal 追加，再派发 listeners。直接接入 loop 的宿主可以在受保护环境中异步完成必要工作，sink 抛错仍立即终止派发。

### Session 的 listener 是应用扩展点

listener 保持 `async (AgentSessionEvent) -> Unit`。正常派发按注册顺序直接等待各 listener，保留背压和错误传播。

取消收尾时，FanOutListener 为每个 listener 创建独立的子任务，并在进入 listener 前建立不可撤销的原生取消状态。listener 在入口调用 async.is_being_cancelled 得到 true；普通可取消异步操作立即响应取消，必要工作由 listener 自己使用 protect_from_cancel 保护。

一个 listener 因原生取消退出后，继续派发下一个 listener。每个 listener 都有进入其回调的机会；这不保证每个回调都完成。必须等待当前 listener 及其受保护工作退出后，才能调用下一个。

普通错误不属于可忽略的取消。listener 抛出普通错误时停止剩余派发，并向调用方传播；不合成失败回合、不隔离错误、不重放事件。同步死循环、不可取消 FFI 和主动保护的等待仍由扩展负责。

### 取消入口不依赖调度顺序

spawn 与取消之间必须有明确的同步边界。子任务先等待一个不可获得的信号量，局部 handle_cancellation 消费该等待的取消通知，再进入 listener；任务的取消状态仍然保留。task group 请求立即结束并取消子任务，等待其退出。

因此无论子任务在 spawn 返回前还是之后开始执行，都只能在收到原生取消后进入 listener。handle_cancellation 只包住入口等待，不包住 listener 的普通错误。

### Session 自身的事件遵循同一规则

AutoRetryStart 和正常路径的 AutoRetryEnd 采用正常派发。退避取消后的 AutoRetryEnd，以及取消收尾中交付的待发送重试终态，都采用逐个 listener 的取消派发。

AutoRetryEnd 的 success 保持既有判定时机。已经结算为成功的重试终态可能在取消收尾中交付，因此不能根据 success 或 final_error 推断派发上下文。

## Alternatives considered

**继续让所有 listener 继承 sink 的取消保护。**

能够等待每个 listener 完整执行，但普通异步工作也可能拖住整个取消收尾。选择由宿主保护 sink，由应用扩展显式保护自己的必要工作。

**仅把取消布尔值传给 listener，继续在受保护协程里调用。**

便于查询状态，但每个扩展仍需手动检查并中止普通异步工作，无法复用 MoonBit 的原生取消机制。选择只在 sink 层传递派发上下文，listener 通过当前协程感知取消。

**将整个 fanout 放入一个已取消任务。**

任务边界更少，但第一个 listener 的可取消等待会展开整个 fanout，后续 listener 可能完全没有进入回调的机会。选择逐个建立边界，同时保留顺序等待。

**spawn listener 后立即取消，不设置入口同步。**

代码更短，但公开 API 不保证子任务何时开始执行，无法承诺 listener 入口已经处于取消状态。选择通过入口等待保证时序。

## 影响

loop 的 event_sink 和 Agent.run 的 on_event 增加 EventContext 参数，属于 SDK 接口变化。session.subscribe 的 listener 签名、事件序列化和 journal 格式保持不变。

应用扩展在取消收尾期间需要显式保护必要的异步清理；普通异步工作默认终止。低层 sink 继续获得完整收尾所需的保护，session 则在持久化之后适配扩展的取消语义。取消派发会增加每个 listener 的任务与同步开销，正常派发不增加任务。
