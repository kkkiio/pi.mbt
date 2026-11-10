# Transcript

Renders agent conversations (`@agent_loop.AgentMessage`) and session journals (`@agent_session.SessionEntry`) into a deterministic, human-readable YAML format. Designed for **snapshot testing** and **LLM trajectory demonstrations**.

## Why `@transcript`?

Raw session journals and message structs contain volatile or noisy fields—timestamps, random entry/call IDs, provider replay signatures, token usage records, and base64 image blobs—and escape multi-line strings as JSON. `@transcript` projects only the semantic trajectory:

- **Deterministic**: Omits timestamps, IDs, signatures, and usage metadata so snapshots stay stable across runs.
- **Readable multi-line blocks**: Renders markdown replies, `thinking` traces, `codemode` JavaScript source (`code: |-`), and tool outputs as literal YAML blocks (`|-`) instead of escaped JSON strings.
- **Codemode-aware**: Extracts `codemode` `{ "code": "..." }` arguments into a `code` block and summarizes nested sandbox tool calls (`name(args) -> status`) under `calls:`.
- **Journal-aware**: `from_entries` automatically applies `ContextEdit` omissions (such as discarded auto-retry turns) before rendering.
- **Compact**: Collapses plain single-block assistant replies to `- assistant: ...` and replaces inline image payloads with `![image](<mime_type>)`.

## API

- `from_entries(entries : ArrayView[@agent_session.SessionEntry]) -> String`
  Projects active messages from session journal entries (applying `ContextEdit` omissions) and formats them as YAML. Returns `"[]\n"` when no messages remain.
- `from_messages(messages : ArrayView[@agent_loop.AgentMessage]) -> String`
  Formats a slice of `AgentMessage` (`User`, `Assistant`, `ToolResult`) directly into YAML. Returns `"[]\n"` when `messages` is empty.

## Usage

### 1. Snapshot Testing

Pair `@transcript` with MoonBit's `inspect` to assert multi-turn agent behavior, tool invocations, and error recovery in black-box tests:

```mbt nocheck
///|
test "agent trajectory snapshot" {
  let journal = @agent_session.InMemorySessionJournal()
  // ... run session against FauxLLM or a scripted tool ...
  inspect(
    @transcript.from_entries(journal.get_entries()),
    content=(
      #|- user: run command
      #|
      #|- assistant:
      #|    - tool_call: bash
      #|      args: {"command":"exit 2"}
      #|
      #|- tool_result: bash
      #|  is_error: true
      #|  output: Command exited with code 2
      #|
      #|- assistant: Command failed with exit code 2.
      #|
    ),
  )
}
```

### 2. LLM Trajectory Demos

Print the full trajectory of an example or benchmark run (see [`examples/github_issues_codemode`](../../examples/github_issues_codemode/main.mbt)):

```mbt nocheck
let journal = @agent_session.InMemorySessionJournal()
let session = @coding_agent.new_coding_session(llm, cwd~, journal~)
session.prompt([
  {
    content: [@agent_loop.InputMessageContent::Text("Count open issues by label")],
    timestamp: @env.now(),
  },
])
println(@transcript.from_entries(journal.get_entries()))
```

Sample output:

```yaml
- user: Count open issues by label

- assistant:
    - thinking: Use codemode to paginate issues and aggregate counts in JS.
    - text: I will run a script to fetch and group the issues.
    - tool_call: codemode
      code: |-
        const issues = await tools.list_issues({ page: 1 });
        console.log(issues.length);
        return { bug: 3, enhancement: 5 };

- tool_result: codemode
  calls:
    - list_issues({"page":1}) -> ok
  output: |-
    Script completed
    Wall time 1.4 seconds
    Output:
    {"bug":3,"enhancement":5}
    <console_output>
    8
    </console_output>

- assistant: |-
    Here is the summary:

    - **enhancement**: 5
    - **bug**: 3
```
