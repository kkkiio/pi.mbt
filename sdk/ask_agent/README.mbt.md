# Ask Agent

Provides the agent with light-weight codemode sandbox instead of filesystem, OS or network capabilities.

## Remote codemode over WebSocket (native only)

`WsStreams` 在一条 WebSocket 上复用多条 `{ "stream_id", "data" }` 逻辑流——这是 pim 自己的
wire 形状,远端(例如 `scripts/codemode-sidecar.mjs --ws <port>` 或单独部署的 sandbox 容器)在其后
面跑 pi-codemode 的 `serveCodemodeRemote`。每个沙箱执行对应一条流;`new_stream()` 返回的
`WsStream` 是透明的 `@codemode.Vm`(`data` 原样透传:VM 消息、消息数组批、`{type:"exit"}` 终流帧),
交给 `@codemode.Codemode::execute` 使用。

```mbt nocheck
@ask_agent.with_ws_streams(url="ws://sandbox-host:9000/", streams => {
  let codemode = @codemode.Codemode::Codemode(
    fn() -> &@codemode.Vm { streams.new_stream() },
    tools=my_tools,
  )
  codemode.execute(code)
})
```

`with_ws_streams` 负责连接、在后台跑收发泵、退出时关闭连接;一次连接上可多次 `execute`
(每次 `vm_launcher` 分配新的 stream)。手动组合时依次调用 `WsStreams::connect`、
`WsStreams::run`(后台任务)、`new_stream`、`close`。
