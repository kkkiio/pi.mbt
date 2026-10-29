# ADR 0005: Remote Codemode Sandbox over In-Process C FFI QuickJS

- Status: Accepted
- Date: 2026-10-28

## Context

`pi.mbt` 需要提供对齐上游 [`@earendil-works/pi-codemode`](https://github.com/earendil-works/pi/tree/main/packages/codemode) 的 `codemode` 工具：让大模型编写一段受限的 JavaScript 脚本，在沙箱中组合调用宿主注入的工具（如批量调用、条件过滤、中间结果聚合），仅将最终输出写入模型上下文。

在支持 `js` 与 `native` 双 target 时，我们尝试并对比了两条实现路径：

1. **同进程内嵌方案（In-Process C FFI + Vendored QuickJS）**：
   在 `sdk/codemode` 中内嵌 QuickJS-NG 的 C 源码（约 5 万行），编写 `vm_worker.c`（约 800 行 C 胶水代码），通过 `pthread` + `mutex`/`condvar` 消息队列 + `@pipe.pipe()` 唤醒机制在同进程后台线程驱动 QuickJS；`js` target 则另写一套 FFI 直接调用 Node `worker_threads`。
2. **远程沙箱协议方案（Remote Codemode Sandbox）**：
   `sdk/codemode` 仅使用纯 MoonBit 实现宿主侧状态机与上游 `remote.ts` 的消息协议（`StartVmRequest`、`VmToHostMessage`、`HostToVmMessage`），将底层 VM 抽象为只有 `send` / `recv` / `close` 三个方法的 `VmChannel` trait。VM 自身的运行、Wasm 隔离以及进程/容器生命周期全部交给外部 VM Server（如运行 `serveCodemodeRemote` 的 `scripts/codemode-sidecar.mjs` 或独立容器）。

在原型验证完方案 1 后，我们决定废弃并移除内嵌的 C FFI + QuickJS 实现，优先采用方案 2（Remote Codemode Sandbox）。

## Decision

### 1. `sdk/codemode` 保持为纯 MoonBit 的远程协议宿主包（零 FFI、全 Target 通用）

`sdk/codemode` 不绑定任何 JS 引擎、不内嵌 C 代码、也不管理子进程或网络连接。它只依赖 `moonbitlang/async` 与 `moonbitlang/core/json`，对外暴露 `VmChannel` 传输缝（seam）：

```moonbit
pub(open) trait VmChannel {
  async fn send(Self, Json) -> Unit
  async fn recv(Self) -> Json
  fn close(Self) -> Unit
}
```

每次 `Codemode::execute` 通过 `vm_launcher : async () -> &VmChannel` 获取一条独立流，发送 `StartVmRequest`，在循环中接收 `VmToHostMessage`（或消息批次数组），在宿主协程中并发调度工具调用并回传 `CallResult`，在所有退出路径调用 `vm.close()`。

### 原生取消与执行所有权

取消遵循 [ADR 0003](0003-native-async-cancellation.md) 与 [ADR 0004](0004-layered-event-cancellation.md)。不再定义或透传自定义 `AbortSignal` / `AbortController`；`CodemodeTool.execute` 仅接收调用参数，不保留只为 signal 存在的 context。

一次 `Codemode::execute` 的任务组拥有 VM 启动、截止计时、消息循环以及所有工具和 global 调用。脚本成功或失败后，仍在运行的调用由任务组取消；外部原生取消同样取消整个执行。任务组等待全部子任务及其受保护清理退出后才返回，未完成调用记为 cancelled，已经产生的结果保留。清理期间抛出的普通错误继续传播。

截止时间包含 VM 启动和协议发送。计时任务到期时结束执行任务组，取消消息循环与嵌套调用，保留已有输出和调用记录，并返回 `Timeout`。外部取消直接传播，不合成 `CodemodeResult::Err(Aborted)` 或工具错误结果；session 的正常返回、loop 的 `Operation aborted` 结果和取消终态事件由 main 的取消路径负责。协议中的 `aborted` 仍可表示远端主动报告的结果。

VM 获取成功后立即注册 `defer vm.close()`。`close` 必须同步、幂等、可在取消状态调用，并在传输仍可用时保留停止通知。NDJSON 与 WebSocket 的普通发送维持 10 个排队槽位，close 帧绕过槽位进入同一有序队列；传输关闭时唤醒等待发送和接收的任务。JS AbortController 仅用于 FFI 的可取消等待。

### 2. VM 执行层委托给上游 `@earendil-works/pi-codemode` 的 `serveCodemodeRemote`

真实脚本在独立的 VM Server 中通过 `serveCodemodeRemote` + `quickjs-wasi`（WebAssembly 版 QuickJS）运行。

在 `sdk/coding_agent` 中，宿主通过 `NdJsonStreams` 在单条字节流上以 `{ "stream_id", "data" }` 多路复用多个 `NdJsonStream`（实现 `@codemode.VmChannel`），对接 `scripts/codemode-sidecar.mjs`（支持 stdio 管道与 `--ws <port>` WebSocket 两种传输方式）。

### 3. VM Server 的生命周期与部署形态交由上层宿主决定

`sdk/codemode` 不关心对端是本地子进程还是远程容器：
- **本地 CLI（`cmd/pim` / `sdk/coding_agent`）**：按需惰性拉起常驻的 `node codemode-sidecar.mjs` 子进程，通过 stdio 管道多路复用每次执行。
- **SaaS / 服务端部署**：可将 VM Server 部署为无特权的独立 Sidecar 容器或远程服务，通过 WebSocket / Socket 接入 `NdJsonStreams`。

## Rationale

### 1. 消除 `pi.mbt` 自身的 C 内存安全攻击面与双层隔离缺失

`codemode` 执行的是大模型生成的不可信代码（极易受 Prompt Injection 影响）。在同进程 C FFI 方案中：
- **缺少 Wasm 线性内存边界**：上游 `pi-codemode` 之所以安全，是因为 QuickJS 被编译成了 `quickjs.wasm`，其内部指针全部被限制在 32 位 Wasm 线性内存偏移量内。而在 MoonBit Native 中直接编译 `quickjs.c`，QuickJS 与宿主共享同一个 64 位虚拟地址空间；一旦触发 QuickJS C 引擎的内存破坏漏洞（如堆溢出、UAF），攻击者可直接读取宿主进程内存中的 LLM API Key 或多租户会话数据。
- **手写 C FFI 胶水自身成为高危漏洞面**：`vm_worker.c` 需要手动管理跨线程互斥锁、链表指针、`JSValue` 引用计数、JSON 转义拼接与 `moonbit_bytes_t` 拷贝。代码审计表明，这类胶水极易引入嵌入 `\0` 截断、转义缓冲区计算偏差、32 位长度溢出以及未设限的 C 堆队列 OOM 等隐患。

改为 Remote Sandbox 后，`sdk/codemode` 是 100% 内存安全的纯 MoonBit 代码；不可信代码被隔离在外部进程/容器的 Wasm 实例中，实现了 **“OS 进程/容器边界 + V8 Wasm 线性内存边界 + QuickJS 语义边界”** 的纵深防御。

### 2. 无需管理或强杀进程，即可保留完整的 VM Reset 与 Cancel 能力

将 VM Server 移出 `sdk/codemode` 并不会牺牲控制力：
- **天然的每次执行 Reset**：VM Server 进程虽然常驻（仅缓存编译好的 `WebAssembly.Module`），但 `serveCodemodeRemote` 对每一个 `stream_id`（每次 `execute`）都会实例化一个全新的 QuickJS Wasm 实例，执行结束或收到 `stop` 后立即 `dispose()` 回收线性内存。跨执行状态仅通过协议中的 `store` / `writes` 由宿主显式传递。
- **双保险的 Cancel / Timeout**：
  1. 当宿主超时或取消时，`Codemode::execute` 通过关闭本地流排入 `{"stream_id", "close": true}`，并等待本地调用清理结束，不等待远端停止确认；`codemode-sidecar.mjs` 收到 close 帧后立即向所有挂起的 `exchange` 回调兑现 `{ type: "stop" }`，触发 `serveCodemodeRemote` 销毁 VM。
  2. 对于不调用工具的纯 CPU 死循环（`while (true) {}`），`serveCodemodeRemote` 内置 `interruptBudget`（默认 100,000 次中断轮询），耗尽预算后自动中断 VM 并上报 `Timeout`，无需宿主通过 `SIGKILL` 强杀进程。

### 3. 消除双 Target 重复实现与 ~50,000 行 C 源码维护负担

- 同进程方案要求为 `js` target（`vm_js.mbt`）和 `native` target（`vm_native.mbt` + `vm_worker.c` + `vendor/quickjs/*`）维护两套完全不同的底层桥接，并在两处重复维护 `prelude.js`。
- 远程方案直接复用了上游 `@earendil-works/pi-codemode` 的 `serveCodemodeRemote`（包含经过完整测试的 `prelude.js` 原型冻结、输出批处理缓冲、内存与中断预算封顶、确定性模式支持），`sdk/codemode` 在 `js`、`native`、`wasm` 下共享同一份纯 MoonBit 实现。

## Alternatives Considered

### 1. 同进程 C FFI + 内嵌 `quickjs.c`（已废弃原型）
- **优点**：Native 构建产物为单文件，无需外部 Node 运行时。
- **缺点**：失去 Wasm 线性内存隔离，引入 5 万行第三方 C 代码与近千行手写多线程 C FFI 胶水；若 QuickJS 内部卡在未轮询 interrupt 的长耗时操作中，`pthread_join` 会永久阻塞宿主；且与 `js` target 割裂为两套实现。

### 2. 同进程 C FFI + `wasm2c` / 嵌入式 Wasm 运行时（Wasmtime / WAMR）
- **优点**：在 Native 同进程内恢复 Wasm 线性内存沙箱。
- **缺点**：`wasm2c` 生成的 C 源码体积巨大（数十 MB），显著拖慢编译；链接 `libwasmtime` 则引入数十 MB 的外部动态/静态库跨平台分发难题，且仍需用 C 语言重写 `quickjs-wasi` 的宿主内存读写胶水与 `prelude.js` 同步维护。

### 3. 在 `sdk/codemode` 内部直接通过 `@process.spawn` 管理子进程
- **优点**：对上层隐藏子进程启动细节。
- **缺点**：使 `sdk/codemode` 强耦合特定平台的进程 API（而 `moonbitlang/async/process` 在 `js` target 上不可用）以及 Node 脚本的文件路径分发策略，且无法直接将 VM Server 拆分到独立的 K8s 容器或远程节点。通过 `VmChannel` trait 解耦后，进程管理留在 `sdk/coding_agent` 或应用入口层，职责更清晰。

## Consequences

### Gained
- **极简且安全的宿主核心**：`sdk/codemode` 仅约 1,000 行纯 MoonBit 代码，零 `extern` FFI，零 C 代码，全 target 直接通过编译与黑盒测试（`remote_test.mbt`、`protocol_test.mbt` 可直接用内存 mock `VmChannel` 测试所有边界情况）。
- **与上游 100% 语义对齐**：直接使用 `@earendil-works/pi-codemode` 的 `serveCodemodeRemote`，自动获得上游所有的沙箱加固（`lockdown()`、输出上限、Store 容量限制、Wasm 内存隔离）。
- **灵活的部署拓扑**：同一套 `Codemode` 代码既能在本地通过 stdio 管道连 Node sidecar，也能在生产环境通过 WebSocket / TCP 连独立沙箱容器。

### Cost / Risk
- **运行时依赖**：端到端运行 `codemode` 工具需要存在可连接的 VM Server（本地模式下需 Node ≥ 22.19 及 `scripts/codemode-sidecar.mjs`）。
- **IPC 序列化开销**：每次工具调用与输出批次需经过一次 NDJSON 帧序列化与跨进程/网络传输；但鉴于 LLM 工具调用本身的耗时（毫秒至秒级），微秒级的本地管道 JSON 序列化开销可忽略不计。
