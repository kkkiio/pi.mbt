# ADR 0003: 使用原生 async 取消并保留 event_sink 的执行控制权

- Status: Accepted
- Date: 2026-10-29

## 背景

此前的 AbortController / AbortSignal 在 session、loop 与 provider 间透传，最终仍通过 task group 取消 HTTP 请求和工具任务。moonbitlang/async 0.22.5 已提供不可被普通 catch 捕获的原生取消、defer / errdefer 和 protect_from_cancel，可以直接承担任务取消与资源释放。

`event_sink : async (AgentEvent) -> Unit` 同时提供顺序通知、背压与失败传播。它属于执行链：应用可以等待扩展完成，或通过抛错终止执行。核心不能回滚扩展已经产生的副作用，也不能通过重放事件保证所有 listener 恰好处理一次。

## 决策

删除自定义 AbortController / AbortSignal 及跨层参数。provider 和工具只负责正常结果与资源清理；loop 负责原生取消后的消息封口和终态事件。JS AbortController 只保留在 FFI 边界。

### 运行所有权

session 在首次挂起前占用运行位置，记录尚未发布任务句柄时收到的取消请求。整个生成、工具执行和自动重试窗口运行在独立子任务内。abort() 同步请求取消，重复调用幂等；prompt() 等待子任务及资源清理结束后释放占用。

子任务最外层使用 handle_cancellation 将真实取消变为返回值。普通错误不会因为类型类似取消错误而被吞掉；宿主本身的外部取消继续传播。

### 三种结束方式

| 结束方式 | 契约 |
| --- | --- |
| 正常完成，包括 provider Error 消息 | 按正常事件顺序结束；session 保留 provider 自动重试策略 |
| 用户取消 | 保护取消收尾，prompt() 正常返回 |
| sink、hook、journal 抛错 | 停止派发，清理资源，向调用方抛错 |

扩展自行处理可恢复错误；向外抛出的错误终止整个组合。核心不再通过同一个 sink 合成错误消息或补发失败事件。已经观察到的普通错误优先于同时存在的取消请求。

finish-turn hook 删除 signal 参数，仅参与正常回合结束决策。取消时跳过 hook，不再保留 pi 在取消后仍调用 hook 的行为。provider Error 消息仍经过正常回合路径。

### 状态与事件

loop 显式记录当前输入、assistant、工具批次、已产生结果及生命周期事件的派发进度。消息和工具执行事实先更新，再通知 sink。工具返回的结果必须在等待 update 队列排空前保存。

生命周期事件进入 sink 前标记为已经尝试派发。取消时不重发这次通知，部分 listener 可以漏收事件；调用方须将 agent 与扩展视为同一个执行组合。

生成中取消保留 partial 并封口为 Aborted；尚未生成则补空 Aborted 消息。已接受输入补齐尚未尝试的生命周期事件。assistant 已经终结则不改写 stop_reason；工具取消只为尚无结果的调用补 `Operation aborted`，保留真实结果，不重复工具 start/end。

取消收尾等待工具与 update drainer 退出后，补发尚未尝试的终态事件，直至 TurnEnd、AgentEnd。事件派发本身抛错则立即停止，不保证事件流完整。

### 保护范围

正常执行不保护整个 sink。journal 属于 session：session 在其 sink 内保护一次追加及关联记账，再调用可取消的 listeners。保护仅防任务取消，不吞存储错误，不提供任意 I/O 失败的事务回滚。

取消收尾由 loop 的 protect_from_cancel 保护，包含收尾期间调用的整个 sink。因此此时 listeners 也不可被外部任务取消，但仍可抛错。扩展自行设置等待期限；核心不增加收尾超时配置。

使用公开的 async.pause 在工作边界提供调度与取消检查点，不能将同步计算视为可抢占执行。

### 重试与应用

仅正常返回的 provider Error 消息参与自动重试。退避取消停止新 attempt，并尝试一次 AutoRetryEnd(false, "Retry cancelled")。重试结果在通知前结算，未尝试的终态通知保存至取消收尾，已经尝试的通知不重发。

TUI 和 CLI 必须通过 prompt() 的返回或错误结束本次调用，不能依赖错误路径必有 AgentEnd。不增加事件重放、失败 listener 隔离或通知后台队列。

## Alternatives considered

**保留 AbortController / AbortSignal，继续桥接原生任务取消。**

能够维持现有 SDK 签名，并允许代码独立查询中断状态。但每层仍需透传 signal，provider 和工具仍需维护 watcher 与竞速边界，也无法自动中断未检查 signal 的扩展。选择直接使用原生取消，将 JS signal 限制在 FFI 内部。

**正常执行和取消收尾都保护整个 event_sink。**

可以避免取消截断一次通知的 listener 调用链，简化事件派发进度管理。但正常执行中的慢 listener 也会阻止中断，而且防取消不能回滚抛错前已经完成的副作用。选择正常执行只保护 session 的 journal 追加，取消收尾才保护整个 sink，并接受部分 listener 漏收通知。

**将 event_sink 改为后台观察者，隔离 listener 失败。**

可以让 loop 独立推进，并将通知失败交给队列消费者处理。但会移除扩展通过等待和抛错控制后续执行的能力，还需定义队列容量、积压、排空与失败报告。应用需要将 agent 和扩展视为同一个执行组合，因此保留按序等待的 sink，扩展抛错终止该组合。

**在扩展抛错后，通过同一个 sink 合成 Error 消息并补发终态事件。**

能够延续此前的恢复行为，让部分调用错误表现为完整的失败回合。但出错的 sink 可能再次拒绝收尾，先前的通知也可能已经部分生效；核心无法可靠恢复这个扩展组合。选择释放资源后直接传播错误，由调用方处理截断的事件流，provider Error 消息仍按正常协议处理。

**取消后仍调用 finish-turn hook，保持 pi 的行为。**

可以保留 hook 的副作用，但此时已经没有继续执行的决策空间，受保护调用还可能延迟取消完成。选择取消时跳过 hook：资源清理由 defer 承担，取消通知通过 event_sink 交付。需要取消通知的应用应订阅事件，而非依赖 hook 的副作用。

**由核心为取消收尾设置统一超时。**

能够限制等待扩展的时间，但超时会截断收尾，还需处理超时取消与受保护 journal 追加的边界。不同扩展的合理等待期限取决于各自的外部操作。选择由扩展自行设置超时并抛错，核心等待受保护收尾完成，不增加全局超时策略。

## 影响

公共 SDK 接口发生破坏性变化：LLM.generate、loop 和 Agent.run 删除 signal 参数，finish-turn hook 改为两个参数，Agent.run 返回 Unit。取消的可观察结果仍通过 loop 事件和消息表达；直接调用 provider 被取消时不会返回 Aborted 消息。

原生取消减少了跨层竞速代码，保留扩展对执行顺序的控制。代价是应用需要处理扩展失败造成的事件截断，并对受保护收尾中可能长期等待的扩展负责。
