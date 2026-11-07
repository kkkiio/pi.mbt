///|
test "from_messages formats user, markdown assistant, and codemode tool calls" {
  let messages : Array[@agent_loop.AgentMessage] = [
    @agent_loop.AgentMessage::User({
      content: [
        @agent_loop.InputMessageContent::Text("Count open issues by label"),
      ],
      timestamp: 1000,
    }),
    @agent_loop.AgentMessage::Assistant({
      content: [
        @agent_loop.AssistantMessageContent::Thinking(
          "Use codemode to paginate issues and aggregate counts in JS.",
          signature={},
        ),
        @agent_loop.AssistantMessageContent::Text(
          "I will run a script to fetch and group the issues.",
          signature={},
        ),
        @agent_loop.AssistantMessageContent::ToolCall(
          {
            id: "call_1",
            name: "codemode",
            arguments: {
              "code": "const issues = await tools.list_issues({ page: 1 });\nconsole.log(issues.length);\nreturn { bug: 3, enhancement: 5 };",
            },
          },
          signature={},
        ),
      ],
      api: "openai-responses",
      provider: "deepseek",
      model: "deepseek-v4-flash",
      stop_reason: @agent_loop.StopReason::ToolUse,
      error_message: None,
      usage: None,
      timestamp: 1001,
    }),
    @agent_loop.AgentMessage::ToolResult({
      tool_call_id: "call_1",
      tool_name: "codemode",
      content: [
        @agent_loop.InputMessageContent::Text(
          "Script completed\nWall time 1.4 seconds\nOutput:\n{\"bug\":3,\"enhancement\":5}\n<console_output>\n8\n</console_output>",
        ),
      ],
      details: Some({
        "calls": [
          {
            "id": "call_1/1",
            "name": "list_issues",
            "args": "{\"page\":1}",
            "status": "ok",
            "durationMs": 320,
          },
        ],
      }),
      usage: None,
      is_error: false,
      timestamp: 1002,
    }),
    @agent_loop.AgentMessage::Assistant({
      content: [
        @agent_loop.AssistantMessageContent::Text(
          "Here is the summary:\n\n- **enhancement**: 5\n- **bug**: 3",
          signature={},
        ),
      ],
      api: "openai-responses",
      provider: "deepseek",
      model: "deepseek-v4-flash",
      stop_reason: @agent_loop.StopReason::Stop,
      error_message: None,
      usage: None,
      timestamp: 1003,
    }),
  ]
  inspect(
    @transcript.from_messages(messages),
    content=(
      #|- user: Count open issues by label
      #|
      #|- assistant:
      #|    - thinking: Use codemode to paginate issues and aggregate counts in JS.
      #|    - text: I will run a script to fetch and group the issues.
      #|    - tool_call: codemode
      #|      code: |-
      #|        const issues = await tools.list_issues({ page: 1 });
      #|        console.log(issues.length);
      #|        return { bug: 3, enhancement: 5 };
      #|
      #|- tool_result: codemode
      #|  calls:
      #|    - list_issues({"page":1}) -> ok
      #|  output: |-
      #|    Script completed
      #|    Wall time 1.4 seconds
      #|    Output:
      #|    {"bug":3,"enhancement":5}
      #|    <console_output>
      #|    8
      #|    </console_output>
      #|
      #|- assistant: |-
      #|    Here is the summary:
      #|
      #|    - **enhancement**: 5
      #|    - **bug**: 3
      #|
    ),
  )
}

///|
test "from_entries respects context_edit and surfaces tool_result is_error and assistant errors" {
  let entries : Array[@agent_session.SessionEntry] = [
    {
      id: "e1",
      parent_id: None,
      timestamp: 1000,
      content: @agent_session.SessionEntryContent::Message(
        @agent_loop.AgentMessage::User({
          content: [@agent_loop.InputMessageContent::Text("run command")],
          timestamp: 1000,
        }),
      ),
    },
    {
      id: "e2",
      parent_id: Some("e1"),
      timestamp: 1001,
      content: @agent_session.SessionEntryContent::Message(
        @agent_loop.AgentMessage::Assistant({
          content: [],
          api: "openai-responses",
          provider: "deepseek",
          model: "deepseek-v4-flash",
          stop_reason: @agent_loop.StopReason::Error,
          error_message: Some("503 overloaded"),
          usage: None,
          timestamp: 1001,
        }),
      ),
    },
    {
      id: "e3",
      parent_id: Some("e2"),
      timestamp: 1002,
      content: @agent_session.SessionEntryContent::ContextEdit(target_id="e2"),
    },
    {
      id: "e4",
      parent_id: Some("e3"),
      timestamp: 1003,
      content: @agent_session.SessionEntryContent::Message(
        @agent_loop.AgentMessage::Assistant({
          content: [
            @agent_loop.AssistantMessageContent::ToolCall(
              {
                id: "call_bash",
                name: "bash",
                arguments: { "command": "exit 2" },
              },
              signature={},
            ),
          ],
          api: "openai-responses",
          provider: "deepseek",
          model: "deepseek-v4-flash",
          stop_reason: @agent_loop.StopReason::ToolUse,
          error_message: None,
          usage: None,
          timestamp: 1003,
        }),
      ),
    },
    {
      id: "e5",
      parent_id: Some("e4"),
      timestamp: 1004,
      content: @agent_session.SessionEntryContent::Message(
        @agent_loop.AgentMessage::ToolResult({
          tool_call_id: "call_bash",
          tool_name: "bash",
          content: [
            @agent_loop.InputMessageContent::Text("Command exited with code 2"),
          ],
          details: None,
          usage: None,
          is_error: true,
          timestamp: 1004,
        }),
      ),
    },
    {
      id: "e6",
      parent_id: Some("e5"),
      timestamp: 1005,
      content: @agent_session.SessionEntryContent::Message(
        @agent_loop.AgentMessage::Assistant({
          content: [],
          api: "openai-responses",
          provider: "deepseek",
          model: "deepseek-v4-flash",
          stop_reason: @agent_loop.StopReason::Error,
          error_message: Some("401 unauthorized"),
          usage: None,
          timestamp: 1005,
        }),
      ),
    },
  ]
  inspect(
    @transcript.from_entries(entries),
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
      #|- assistant:
      #|    - stop_reason: error
      #|      error_message: 401 unauthorized
      #|
    ),
  )
}
