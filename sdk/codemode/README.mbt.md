# CodeMode

A tool for running js code in a sandboxed environment.

## VM Communication

The Host and VM communicate through a stream of messages.
For example, the following js code:

```js
const [a, b] = await Promise.all([tools.read("a"), tools.read("b")]);
return await tools.write(a + b);
```

Would be executed as:

```mermaid
sequenceDiagram
    participant H as Host
    participant V as VM

    H->>V: StartVm(code)
    V->>H: VmStarted
    V->>H: CallTool(id=1, name="read")
    V->>H: CallTool(id=2, name="read")
    V->>H: Idle(seq=0)
    H->>V: CallResult(id=2, seq=1)
    V->>H: Idle(seq=1)
    H->>V: CallResult(id=1, seq=2)
    V->>H: Idle(seq=2)
    V->>H: CallTool(id=3, name="write")
    V->>H: Idle(seq=3)
    H->>V: CallResult(id=3, seq=4)
    V->>H: Done(seq=3)
```
