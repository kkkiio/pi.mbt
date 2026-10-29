# Ask Agent

Provides the agent with light-weight codemode sandbox instead of filesystem, OS or network capabilities.

## Remote codemode over WebSocket (native only)

`WsStreams` 在一条 WebSocket 上复用多条 `{ "stream_id", "data" }` 逻辑流——这是 pim 自己的
wire 形状,远端(例如 `examples/codemode-sidecar-ws.mjs` 或单独部署的 sandbox 容器)在其后
面跑 pi-codemode 的 QuickJS VM。每个沙箱执行对应一条流;`new_stream()` 返回的
`WsStream` 是透明的 `@codemode.VmChannel`(`data` 原样透传:VM 消息、消息数组批;close 帧结束一条流),
由 `new_codemode_tool_definition` 包成 agent 的 `codemode` 工具。

```mbt nocheck
@ask_agent.with_ws_streams(url="ws://sandbox-host:9000/", streams => {
  let session = @ask_agent.new_ask_agent_session(
    llm,
    streams,
    system_prompt_contributes=[_ => "You are a codemode agent."],
    tools=my_tools,
    active_tools=[@ask_agent.CODEMODE_TOOL_NAME],
  )
  // 会话运行期间 codemode 复用这条连接,每次执行分配一条新流。
})
```

`with_ws_streams` 负责连接、在后台跑收发泵、退出时关闭连接;一次连接上可多次执行 codemode
(每次由 launcher 分配新的 stream)。手动组合时依次调用 `WsStreams::connect`、
`WsStreams::run`(后台任务)、`new_stream`、`close`。
