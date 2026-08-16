///|
/// Reads a Responses SSE stream inline, delivering each streaming delta to
/// `sink` and returning the terminal `AssistantMessage` as the function's
/// result. There is no background task: the caller's task drives the whole
/// stream, and closing the reader cancels it.
pub async fn[R : @io.Reader] read_responses_sse_stream(
  reader : R,
  sink~ : async (@agent_loop.GenerationEvent) -> Unit,
  custom_tool_input_properties? : Map[String, String] = Map([]),
) -> @agent_loop.AssistantMessage raise {
  let idle_timeout_ms : Int = 120_000
  let data_lines : Array[StringView] = []
  let acc : Array[@agent_loop.AssistantMessageContent] = []
  let slots : Map[Int, ResponsesOutputSlot] = Map([])
  let mut final_message : @agent_loop.AssistantMessage? = None
  for ;; {
    let reason = match
      (@async.with_timeout_opt(idle_timeout_ms) <| () => {
        reader.read_until("\n")
      }) {
      Some(Some(raw)) => {
        let trimmed = raw.trim()
        if trimmed.is_empty() {
          let flushed = flush_sse_event(
            data_lines,
            sink~,
            acc,
            slots,
            custom_tool_input_properties,
          )
          if flushed is Some(message) {
            final_message = Some(message)
            break
          }
        } else {
          data_lines.push(trimmed)
        }
        continue
      }
      Some(None) => "Responses stream ended before a terminal event"
      None => "Responses stream idle for \{idle_timeout_ms}ms"
    }
    let flushed = flush_sse_event(
      data_lines,
      sink~,
      acc,
      slots,
      custom_tool_input_properties,
    )
    if flushed is Some(message) {
      final_message = Some(message)
      break
    }
    fail(reason)
  }
  final_message.unwrap()
}

///|
priv enum ResponsesOutputSlot {
  Thinking(Int)
  Text(Int)
  FunctionCall(Int, String)
  CustomToolCall(Int, String, String)
  HostedToolCall(Int)
}

///|
fn encode_responses_input(context : @agent_loop.Context) -> Array[Json] raise {
  let input : Array[Json] = []
  let custom_call_ids : Map[String, Bool] = Map([])
  for message in context.messages {
    match message {
      User(contents) =>
        input.push({
          "role": "user",
          "content": [
            for content in contents => {
              match content {
                Text(text) => ({ "type": "input_text", "text": text } : Json)
                Image(_) => (fail("image input not supported") : Json)
              }
            }
          ],
        })
      Assistant(blocks) =>
        for content in blocks {
          match content {
            Text(text, signature~) => {
              guard signature
                is { "type": String(signature_type), "id": String(item_id), .. } else {
                fail("Responses text signature is missing type or id")
              }
              guard signature_type == "message" else {
                fail("Responses text signature must describe a message")
              }
              let item : Json = match signature {
                { "phase": String(phase), .. } =>
                  {
                    "type": "message",
                    "id": item_id,
                    "role": "assistant",
                    "status": "completed",
                    "phase": phase,
                    "content": [
                      { "type": "output_text", "text": text, "annotations": [] },
                    ],
                  }
                _ =>
                  {
                    "type": "message",
                    "id": item_id,
                    "role": "assistant",
                    "status": "completed",
                    "content": [
                      { "type": "output_text", "text": text, "annotations": [] },
                    ],
                  }
              }
              input.push(item)
            }
            Thinking(_, signature~) => input.push(signature)
            HostedToolCall(_, signature~) => input.push(signature)
            ToolCall(call, signature~) => {
              guard signature
                is { "type": String(signature_type), "id": String(item_id), .. } else {
                fail("Responses tool-call signature is missing type or id")
              }
              if signature_type == "function_call" {
                input.push({
                  "type": "function_call",
                  "id": item_id,
                  "call_id": call.id,
                  "name": call.name,
                  "arguments": call.arguments.stringify(),
                })
              } else if signature_type == "custom_tool_call" {
                guard signature
                  is { "input_property": String(input_property), .. } else {
                  fail(
                    "Responses custom tool-call signature is missing input_property",
                  )
                }
                guard call.arguments is Json::Object(arguments) else {
                  fail("Responses custom tool call requires object arguments")
                }
                guard arguments.get(input_property)
                  is Some(String(custom_input)) else {
                  fail("Responses custom tool call is missing string input")
                }
                custom_call_ids[call.id] = true
                input.push({
                  "type": "custom_tool_call",
                  "id": item_id,
                  "call_id": call.id,
                  "name": call.name,
                  "input": custom_input,
                })
              } else {
                fail(
                  "Unsupported Responses tool-call signature: \{signature_type}",
                )
              }
            }
          }
        }
      ToolResult(result) => {
        let is_custom = custom_call_ids.get(result.tool_call_id) == Some(true)
        input.push({
          "type": if is_custom {
            "custom_tool_call_output"
          } else {
            "function_call_output"
          },
          "call_id": result.tool_call_id,
          "output": [
            for content in result.content => {
              match content {
                Text(text) => ({ "type": "input_text", "text": text } : Json)
                Image(_) => (fail("image input not supported") : Json)
              }
            }
          ],
        })
      }
    }
  }
  input
}

///|
async fn flush_sse_event(
  data_lines : Array[StringView],
  sink~ : async (@agent_loop.GenerationEvent) -> Unit,
  acc : Array[@agent_loop.AssistantMessageContent],
  slots : Map[Int, ResponsesOutputSlot],
  custom_tool_input_properties : Map[String, String],
) -> @agent_loop.AssistantMessage? {
  if data_lines.length() == 0 {
    return None
  }
  let mut event : StringView? = None
  let data = StringBuilder()
  for line in data_lines {
    if line.strip_prefix("event:") is Some(value) {
      event = Some(value.trim())
    } else if line.strip_prefix("data:") is Some(value) {
      if !data.is_empty() {
        data.write_char('\n')
      }
      data.write_stringview(value.trim())
    }
  }
  data_lines.clear()
  guard (event, data.is_empty()) is (Some(event), false) else {
    fail("Malformed Responses SSE event")
  }
  guard parse_sse_event(
      event,
      data.to_string(),
      acc,
      slots,
      custom_tool_input_properties~,
    )
    is Some(outcome) else {
    return None
  }
  // Streaming deltas go to the sink; the terminal AssistantMessage is the
  // caller's return value, not a callback event.
  match outcome {
    SseOutcome::Delta(evt) => {
      sink(evt)
      None
    }
    SseOutcome::Terminal(message) => Some(message)
  }
}

///|
/// Parsed outcome of one Responses SSE event: either a streaming delta for
/// the sink, or the terminal `AssistantMessage` that ends the turn.
priv enum SseOutcome {
  Delta(@agent_loop.GenerationEvent)
  Terminal(@agent_loop.AssistantMessage)
}

///|
fn sse_delta(evt : @agent_loop.GenerationEvent) -> SseOutcome? {
  Some(SseOutcome::Delta(evt))
}

///|
fn parse_sse_event(
  event : StringView,
  data : StringView,
  acc : Array[@agent_loop.AssistantMessageContent],
  slots : Map[Int, ResponsesOutputSlot],
  custom_tool_input_properties? : Map[String, String] = Map([]),
) -> SseOutcome? raise {
  let json = @json.parse(data)
  let partial = () => @agent_loop.PartialAssistantMessage::{ content: acc }
  return match event {
    "response.created" => sse_delta(@agent_loop.GenerationEvent::Start)
    "response.in_progress"
    | "response.content_part.added"
    | "response.content_part.done"
    | "response.reasoning_text.done"
    | "response.reasoning_summary_text.done"
    | "response.output_text.done"
    | "response.function_call_arguments.done"
    | "response.custom_tool_call_input.done"
    | "response.web_search_call.in_progress"
    | "response.web_search_call.searching"
    | "response.web_search_call.completed" => None
    "response.output_item.added" => {
      guard json
        is {
          "output_index": Number(output_index, ..),
          "item": { "type": String(item_type), .. } as item_json,
          ..
        } else {
        fail("Malformed response item")
      }
      let output_index = output_index.to_int()
      let content_index = acc.length()
      match item_type {
        "reasoning" => {
          let item : ResponseReasoningItem = @json.from_json(item_json)
          acc.push(
            @agent_loop.AssistantMessageContent::Thinking(
              (if item.content is Some(parts) { parts } else { item.summary })
              .iter()
              .map(p => p.text)
              .join(""),
              signature=item_json,
            ),
          )
          slots[output_index] = Thinking(content_index)
          sse_delta(@agent_loop.ThinkingStart(content_index, partial()))
        }
        "message" => {
          let item : ResponseOutputMessage = @json.from_json(item_json)
          let text = StringBuilder()
          for part in item.content {
            if part.text is Some(value) {
              text.write_string(value)
            } else if part.refusal is Some(value) {
              text.write_string(value)
            }
          }
          let signature : Json = match item.phase {
            Some(phase) => { "type": "message", "id": item.id, "phase": phase }
            None => { "type": "message", "id": item.id }
          }
          acc.push(
            @agent_loop.AssistantMessageContent::Text(
              text.to_string(),
              signature~,
            ),
          )
          slots[output_index] = Text(content_index)
          sse_delta(@agent_loop.TextStart(content_index, partial()))
        }
        "function_call" => {
          let item : ResponseFunctionToolCall = @json.from_json(item_json)
          acc.push(
            @agent_loop.AssistantMessageContent::ToolCall(
              {
                id: item.call_id,
                name: item.name,
                arguments: Json::empty_object(),
              },
              signature={ "type": "function_call", "id": item.id },
            ),
          )
          slots[output_index] = FunctionCall(content_index, item.arguments)
          sse_delta(@agent_loop.ToolCallStart(content_index, partial()))
        }
        "custom_tool_call" => {
          let item : ResponseCustomToolCall = @json.from_json(item_json)
          let input_property = custom_tool_input_properties
            .get(item.name)
            .unwrap_or("input")
          let arguments : Map[String, String] = Map([])
          arguments[input_property] = item.input
          acc.push(
            @agent_loop.AssistantMessageContent::ToolCall(
              {
                id: item.call_id,
                name: item.name,
                arguments: @json.to_json(arguments),
              },
              signature={
                "type": "custom_tool_call",
                "id": item.id,
                "input_property": input_property,
              },
            ),
          )
          slots[output_index] = CustomToolCall(
            content_index,
            item.input,
            input_property,
          )
          sse_delta(@agent_loop.ToolCallStart(content_index, partial()))
        }
        "web_search_call" => {
          acc.push(
            @agent_loop.AssistantMessageContent::HostedToolCall(
              @agent_loop.HostedTool::WebSearch,
              signature=item_json,
            ),
          )
          slots[output_index] = HostedToolCall(content_index)
          None
        }
        _ => None
      }
    }
    "response.reasoning_text.delta" | "response.reasoning_summary_text.delta" => {
      let payload : ResponseDeltaEvent = @json.from_json(json)
      let output_index = payload.output_index
      let delta = payload.delta
      guard slots.get(output_index) is Some(Thinking(content_index)) else {
        return None
      }
      guard acc[content_index]
        is @agent_loop.AssistantMessageContent::Thinking(current, signature~) else {
        return None
      }
      acc[content_index] = @agent_loop.AssistantMessageContent::Thinking(
        current + delta,
        signature~,
      )
      sse_delta(@agent_loop.ThinkingDelta(content_index, delta, partial()))
    }
    "response.reasoning_summary_part.done" => {
      let payload : ResponseOutputIndexEvent = @json.from_json(json)
      let output_index = payload.output_index
      guard slots.get(output_index) is Some(Thinking(content_index)) else {
        return None
      }
      guard acc[content_index]
        is @agent_loop.AssistantMessageContent::Thinking(current, signature~) else {
        return None
      }
      acc[content_index] = @agent_loop.AssistantMessageContent::Thinking(
        current + "\n\n",
        signature~,
      )
      sse_delta(@agent_loop.ThinkingDelta(content_index, "\n\n", partial()))
    }
    "response.output_text.delta" | "response.refusal.delta" => {
      let payload : ResponseDeltaEvent = @json.from_json(json)
      let output_index = payload.output_index
      let delta = payload.delta
      guard slots.get(output_index) is Some(Text(content_index)) else {
        return None
      }
      guard acc[content_index]
        is @agent_loop.AssistantMessageContent::Text(current, signature~) else {
        return None
      }
      acc[content_index] = @agent_loop.AssistantMessageContent::Text(
        current + delta,
        signature~,
      )
      sse_delta(@agent_loop.TextDelta(content_index, delta, partial()))
    }
    "response.function_call_arguments.delta" => {
      let payload : ResponseDeltaEvent = @json.from_json(json)
      let output_index = payload.output_index
      let delta = payload.delta
      guard slots.get(output_index)
        is Some(FunctionCall(content_index, current)) else {
        return None
      }
      slots[output_index] = FunctionCall(content_index, current + delta)
      sse_delta(@agent_loop.ToolCallDelta(content_index, delta, partial()))
    }
    "response.custom_tool_call_input.delta" => {
      let payload : ResponseDeltaEvent = @json.from_json(json)
      let output_index = payload.output_index
      let delta = payload.delta
      guard slots.get(output_index)
        is Some(CustomToolCall(content_index, current, input_property)) else {
        return None
      }
      guard acc[content_index]
        is @agent_loop.AssistantMessageContent::ToolCall(tool_call, signature~) else {
        return None
      }
      let input = current + delta
      slots[output_index] = CustomToolCall(content_index, input, input_property)
      let arguments : Map[String, String] = Map([])
      arguments[input_property] = input
      acc[content_index] = @agent_loop.AssistantMessageContent::ToolCall(
        {
          id: tool_call.id,
          name: tool_call.name,
          arguments: @json.to_json(arguments),
        },
        signature~,
      )
      sse_delta(@agent_loop.ToolCallDelta(content_index, delta, partial()))
    }
    "response.output_item.done" => {
      guard json
        is {
          "output_index": Number(output_index, ..),
          "item": { "type": String(item_type), .. } as item_json,
          ..
        } else {
        fail("Malformed completed response item")
      }
      let output_index = output_index.to_int()
      match (item_type, slots.get(output_index)) {
        ("reasoning", Some(Thinking(content_index))) => {
          let item : ResponseReasoningItem = @json.from_json(item_json)
          let text = StringBuilder()
          let parts = match item.summary {
            [_, ..] as summary => summary
            _ => item.content.unwrap_or([])
          }
          for part in parts {
            if !text.is_empty() {
              text.write_string("\n\n")
            }
            text.write_string(part.text)
          }
          let final_text = if text.is_empty() {
            match acc[content_index] {
              @agent_loop.AssistantMessageContent::Thinking(value, ..) => value
              _ => ""
            }
          } else {
            text.to_string()
          }
          acc[content_index] = @agent_loop.AssistantMessageContent::Thinking(
            final_text,
            signature=item_json,
          )
          slots.remove(output_index)
          sse_delta(@agent_loop.ThinkingEnd(content_index, final_text, partial()))
        }
        ("message", Some(Text(content_index))) => {
          let item : ResponseOutputMessage = @json.from_json(item_json)
          let text = StringBuilder()
          for part in item.content {
            if part.text is Some(value) {
              text.write_string(value)
            } else if part.refusal is Some(value) {
              text.write_string(value)
            }
          }
          let final_text = if text.is_empty() {
            match acc[content_index] {
              @agent_loop.AssistantMessageContent::Text(value, ..) => value
              _ => ""
            }
          } else {
            text.to_string()
          }
          let signature : Json = match item.phase {
            Some(phase) => { "type": "message", "id": item.id, "phase": phase }
            None => { "type": "message", "id": item.id }
          }
          acc[content_index] = @agent_loop.AssistantMessageContent::Text(
            final_text,
            signature~,
          )
          slots.remove(output_index)
          sse_delta(@agent_loop.TextEnd(content_index, final_text, partial()))
        }
        ("function_call", Some(FunctionCall(content_index, _))) => {
          let item : ResponseFunctionToolCall = @json.from_json(item_json)
          guard acc[content_index]
            is @agent_loop.AssistantMessageContent::ToolCall(tool_call, ..) else {
            fail("Function call output slot has invalid content")
          }
          let arguments = item.arguments
          let parsed_arguments = if arguments.is_empty() {
            Json::empty_object()
          } else {
            @json.parse(arguments)
          }
          let final_tool_call : @agent_loop.ToolCall = {
            id: tool_call.id,
            name: tool_call.name,
            arguments: parsed_arguments,
          }
          acc[content_index] = @agent_loop.AssistantMessageContent::ToolCall(
            final_tool_call,
            signature={ "type": "function_call", "id": item.id },
          )
          slots.remove(output_index)
          sse_delta(
            @agent_loop.ToolCallEnd(content_index, final_tool_call, partial()),
          )
        }
        (
          "custom_tool_call",
          Some(CustomToolCall(content_index, _, input_property)),
        ) => {
          let item : ResponseCustomToolCall = @json.from_json(item_json)
          guard acc[content_index]
            is @agent_loop.AssistantMessageContent::ToolCall(tool_call, ..) else {
            fail("Custom tool call output slot has invalid content")
          }
          let arguments : Map[String, String] = Map([])
          arguments[input_property] = item.input
          let final_tool_call : @agent_loop.ToolCall = {
            id: tool_call.id,
            name: tool_call.name,
            arguments: @json.to_json(arguments),
          }
          acc[content_index] = @agent_loop.AssistantMessageContent::ToolCall(
            final_tool_call,
            signature={
              "type": "custom_tool_call",
              "id": item.id,
              "input_property": input_property,
            },
          )
          slots.remove(output_index)
          sse_delta(
            @agent_loop.ToolCallEnd(content_index, final_tool_call, partial()),
          )
        }
        ("web_search_call", Some(HostedToolCall(content_index))) => {
          guard acc[content_index]
            is @agent_loop.AssistantMessageContent::HostedToolCall(name, ..) else {
            fail("Web search output slot has invalid content")
          }
          acc[content_index] = @agent_loop.AssistantMessageContent::HostedToolCall(
            name,
            signature=item_json,
          )
          slots.remove(output_index)
          None
        }
        _ => None
      }
    }
    "response.completed" | "response.incomplete" | "response.failed" => {
      let payload : ResponseTerminalEvent = @json.from_json(json)
      let terminal = payload.response
      for terminal_item in terminal.output.unwrap_or([]) {
        guard terminal_item
          is { "type": String(item_type), "id": String(terminal_id), .. } else {
          continue
        }
        if item_type != "reasoning" && item_type != "web_search_call" {
          continue
        }
        for index, content in acc {
          match content {
            @agent_loop.AssistantMessageContent::Thinking(text, signature~) => {
              guard signature is { "id": String(signature_id), .. } else {
                continue
              }
              if item_type == "reasoning" && terminal_id == signature_id {
                acc[index] = @agent_loop.AssistantMessageContent::Thinking(
                  text,
                  signature=terminal_item,
                )
                break
              }
            }
            @agent_loop.AssistantMessageContent::HostedToolCall(name, signature~) => {
              guard signature is { "id": String(signature_id), .. } else {
                continue
              }
              if item_type == "web_search_call" && terminal_id == signature_id {
                acc[index] = @agent_loop.AssistantMessageContent::HostedToolCall(
                  name,
                  signature=terminal_item,
                )
                break
              }
            }
            _ => ()
          }
        }
      }
      let usage = match terminal.usage {
        None => None
        Some(usage) => {
          let cached = match usage.input_tokens_details {
            Some(details) => details.cached_tokens.unwrap_or(0)
            None => 0
          }
          let cache_write = match usage.input_tokens_details {
            Some(details) => details.cache_write_tokens.unwrap_or(0)
            None => 0
          }
          let uncached_input = usage.input_tokens - cached - cache_write
          let reasoning = match usage.output_tokens_details {
            Some(details) => details.reasoning_tokens
            None => None
          }
          Some(@agent_loop.Usage::{
            input: if uncached_input > 0 {
              uncached_input
            } else {
              0
            },
            output: usage.output_tokens,
            cache_read: cached,
            cache_write,
            cache_write_1h: None,
            reasoning,
            total_tokens: usage.total_tokens,
            cost: {
              input: 0.0,
              output: 0.0,
              cache_read: 0.0,
              cache_write: 0.0,
              total: 0.0,
            },
          })
        }
      }
      let status = terminal.status.unwrap_or_else(() => {
        if event == "response.completed" {
          "completed"
        } else if event == "response.incomplete" {
          "incomplete"
        } else {
          "failed"
        }
      })
      let incomplete_reason = match terminal.incomplete_details {
        Some(details) => details.reason
        None => None
      }
      let has_tool_call = acc.any(content => {
        content is @agent_loop.AssistantMessageContent::ToolCall(_, ..)
      })
      if status == "completed" {
        let stop_reason = if has_tool_call {
          @agent_loop.StopReason::ToolUse
        } else {
          @agent_loop.StopReason::Stop
        }
        Some(
          SseOutcome::Terminal({
            content: acc,
            stop_reason,
            error_message: None,
            usage,
          }),
        )
      } else if status == "incomplete" &&
        incomplete_reason == Some("max_output_tokens") {
        Some(
          SseOutcome::Terminal({
            content: acc,
            stop_reason: @agent_loop.StopReason::Length,
            error_message: None,
            usage,
          }),
        )
      } else {
        Some(
          SseOutcome::Terminal({
            content: acc,
            stop_reason: @agent_loop.StopReason::Error,
            error_message: incomplete_reason,
            usage,
          }),
        )
      }
    }
    "error" => {
      let error_message = match json {
        { "error": Object(fields), .. } =>
          match fields.get("message") {
            Some(String(message)) => Some(message)
            _ => None
          }
        _ => None
      }
      Some(
        SseOutcome::Terminal({
          content: acc,
          stop_reason: @agent_loop.StopReason::Error,
          error_message,
          usage: None,
        }),
      )
    }
    _ => None
  }
}

///|
/// OpenAPI `ResponseReasoningItem`: reasoning emitted by a reasoning model.
/// The complete item must be replayed when context is managed statelessly.
#warnings("-unused_field")
priv struct ResponseReasoningItem {
  /// Unique identifier of the reasoning item.
  id : String
  /// Reasoning summaries intended for presentation.
  summary : Array[ResponseTextPart]
  /// Detailed reasoning content, when the provider exposes it.
  content : Array[ResponseTextPart]?
  /// Encrypted reasoning required for stateless multi-turn replay.
  encrypted_content : String?
  /// Item lifecycle status: in_progress, completed, or incomplete.
  status : String?
} derive(FromJson)

///|
/// OpenAPI `ResponseOutputMessage`: an assistant message generated by the model.
#warnings("-unused_field")
priv struct ResponseOutputMessage {
  /// Unique identifier of the output message.
  id : String
  /// Text or refusal parts in this message.
  content : Array[ResponseOutputContent]
  /// Always assistant in the OpenAPI schema.
  role : String
  /// Item lifecycle status: in_progress, completed, or incomplete.
  status : String
  /// Optional commentary or final-answer phase label.
  phase : String?
} derive(FromJson)

///|
/// The text-bearing subset shared by reasoning summary and reasoning content.
priv struct ResponseTextPart {
  text : String
} derive(FromJson)

///|
/// OpenAPI message content is a union of `ResponseOutputText` and
/// `ResponseOutputRefusal`; only one field is populated for each variant.
priv struct ResponseOutputContent {
  text : String?
  refusal : String?
} derive(FromJson)

///|
/// OpenAPI `ResponseFunctionToolCall`: a client-executed function invocation.
#warnings("-unused_field")
priv struct ResponseFunctionToolCall {
  /// JSON-encoded arguments passed to the function.
  arguments : String
  /// Identifier used to associate the later function_call_output.
  call_id : String
  /// Name of the function to execute.
  name : String
  /// Unique provider item identifier.
  id : String
  /// Item lifecycle status when returned as an output item.
  status : String?
} derive(FromJson)

///|
/// OpenAPI `ResponseCustomToolCall`: a client-executed free-form tool call.
#warnings("-unused_field")
priv struct ResponseCustomToolCall {
  /// Identifier used to associate the later custom_tool_call_output.
  call_id : String
  /// Free-form input generated for the tool.
  input : String
  /// Name of the custom tool to execute.
  name : String
  /// Unique provider item identifier.
  id : String
  /// Item lifecycle status when returned as an output item.
  status : String?
} derive(FromJson)

///|
/// Fields consumed from text, reasoning, function, and custom-tool delta events.
priv struct ResponseDeltaEvent {
  /// Incremental text or tool input.
  delta : String
  /// Index of the output item receiving the delta.
  output_index : Int
} derive(FromJson)

///|
/// Fields consumed from events that delimit an output item's nested part.
priv struct ResponseOutputIndexEvent {
  /// Index of the affected output item.
  output_index : Int
} derive(FromJson)

///|
/// OpenAPI terminal event payload shared by response.completed,
/// response.incomplete, and response.failed.
priv struct ResponseTerminalEvent {
  response : ResponseTerminal
} derive(FromJson)

///|
/// Terminal subset of the OpenAPI `Response` resource used by stream processing.
priv struct ResponseTerminal {
  /// Final response status.
  status : String?
  /// Reason why an incomplete response stopped.
  incomplete_details : ResponseIncompleteDetails?
  /// Token usage reported by the provider.
  usage : ResponseUsage?
  /// Ordered output items. Their discriminant is inspected only when terminal
  /// data can add replay state that was absent from output_item.done.
  output : Array[Json]?
}

///|
/// Wire representation used to normalize OpenAPI's explicit nullable fields.
priv struct ResponseTerminalWire {
  status : String?
  incomplete_details : Json?
  usage : Json?
  output : Array[Json]?
} derive(FromJson)

///|
/// OpenAPI `Response.IncompleteDetails`.
priv struct ResponseIncompleteDetails {
  /// Usually max_output_tokens or content_filter.
  reason : String?
} derive(FromJson)

///|
/// OpenAPI `ResponseUsage` token accounting.
priv struct ResponseUsage {
  input_tokens : Int
  output_tokens : Int
  total_tokens : Int
  input_tokens_details : ResponseUsageDetails?
  output_tokens_details : ResponseUsageDetails?
} derive(FromJson)

///|
/// Token detail fields used by OpenAI-compatible Responses providers.
priv struct ResponseUsageDetails {
  cached_tokens : Int?
  cache_write_tokens : Int?
  reasoning_tokens : Int?
} derive(FromJson)

///|
impl @json.FromJson for ResponseTerminal with fn from_json(json, path) {
  let wire : ResponseTerminalWire = @json.from_json(json, path~)
  let incomplete_details = match wire.incomplete_details {
    None | Some(Json::Null) => None
    Some(value) =>
      Some(@json.from_json(value, path=path.add_key("incomplete_details")))
  }
  let usage = match wire.usage {
    None | Some(Json::Null) => None
    Some(value) => Some(@json.from_json(value, path=path.add_key("usage")))
  }
  { status: wire.status, incomplete_details, usage, output: wire.output }
}
