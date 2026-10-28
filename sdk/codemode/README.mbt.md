# CodeMode

A tool for running js code in a sandboxed environment.
The protocol is inspired by [pi's codemode-remote](https://github.com/earendil-works/pi/blob/main/packages/codemode/src/runtime/remote.ts).

## Remote VM Server

The Host and VM Server communicate through a stream of messages.
For example, the following js code:

```js
const [a, b] = await Promise.all([tools.read("a"), tools.read("b")]);
return await tools.write(a + b);
```

Would be executed as:

```mermaid
sequenceDiagram
    participant H as Host
    participant V as VM Server

    H->>V: StartVm(code)
    V->>H: VmStarted
    V->>H: CallTool(read, id=1)
    V->>H: CallTool(read, id=2)
    V->>H: Idle(seq=0)
    H->>V: CallResult(id=2, seq=1)
    V->>H: Idle(seq=1)
    H->>V: CallResult(id=1, seq=2)
    V->>H: Idle(seq=2)
    V->>H: CallTool(write, id=3)
    V->>H: Idle(seq=3)
    H->>V: CallResult(id=3, seq=4)
    V->>H: Done(seq=3)
```

The VM is expected to be isolated from the host and other VMs, both CPU and memory wise.
