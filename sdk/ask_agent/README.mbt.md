# Ask Agent

Provides the agent with a lightweight codemode sandbox instead of filesystem, OS, or network capabilities.

## Remote codemode over WebSocket (native only)

`WsStreams` multiplexes logical `{ "stream_id", "data" }` streams over a single WebSocket connection to a remote QuickJS VM server (such as `examples/codemode-sidecar-ws.mjs` or a standalone sandbox container). Each sandbox execution uses one stream; `new_stream()` returns a `WsStream` implementing `@codemode.VmChannel`, which `new_codemode_tool_definition` wraps into the agent's `codemode` tool.

```mbt nocheck
@ask_agent.with_ws_streams(url="ws://sandbox-host:9000/", streams => {
  let session = @ask_agent.new_ask_agent_session(
    llm,
    streams,
    system_prompt_contributes=[_ => "You are a codemode agent."],
    tools=my_tools,
    active_tools=[@ask_agent.CODEMODE_TOOL_NAME],
  )
  // Codemode reuses this connection across executions, allocating a fresh stream per run.
})
```

`with_ws_streams` connects, runs the frame pump in the background, and closes the connection on exit. For manual lifecycle management, call `WsStreams::connect`, `WsStreams::run`, `new_stream`, and `close`.
