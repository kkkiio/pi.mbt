///|
fn encode_responses_input(context : @agent_loop.Context) -> Array[Json] raise {
  let input : Array[Json] = []
  let custom_call_ids : Set[String] = Set([])
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
      Assistant(message) =>
        for content in message.content {
          match content {
            Text(text, signature~) => {
              guard signature is { "id": String(item_id), .. } else {
                fail("Responses text signature is missing type or id")
              }
              let item : Map[String, Json] = {
                "type": "message",
                "id": item_id,
                "role": "assistant",
                "status": "completed",
                "content": [
                  { "type": "output_text", "text": text, "annotations": [] },
                ],
              }
              if signature is { "phase": String(phase), .. } {
                item["phase"] = phase.to_json()
              }
              input.push(item.to_json())
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
                custom_call_ids.add(call.id)
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
      ToolResult(result) =>
        input.push({
          "type": if custom_call_ids.contains(result.tool_call_id) {
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
  input
}

///|
/// Reads a Responses SSE stream inline, delivering each streaming delta to
/// `sink` and returning the terminal `AssistantMessage` as the function's
/// result. There is no background task: the caller's task drives the whole
/// stream, and closing the reader cancels it.
pub async fn[R : @io.Reader] read_responses_sse_stream(
  reader : R,
  sink~ : async (@agent_loop.GenerationEvent) -> Unit,
  api~ : String,
  provider~ : String,
  model~ : String,
  custom_tool_input_properties? : Map[String, String] = Map([]),
  now? : () -> UInt64 = @env.now,
) -> @agent_loop.AssistantMessage {
  let idle_timeout_ms : Int = 120_000
  let started_at = now()
  let data_lines : Array[StringView] = []
  let acc : Array[@agent_loop.AssistantMessageContent] = []
  let slots : Map[Int, ResponsesOutputSlot] = Map([])
  let final_message : @agent_loop.AssistantMessage = for ;; {
    let idle_reason : String? = match
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
            api~,
            provider~,
            model~,
            started_at,
          )
          if flushed is Some(message) {
            break message
          }
        } else {
          data_lines.push(trimmed)
        }
        continue
      }
      Some(None) => None
      // Wording matters: the session-level retry policy matches "timed out"
      // (pi's phrasing), so a stall past the provider's retry window still
      // reads as a transient condition there.
      None => Some("Responses stream timed out (idle for \{idle_timeout_ms}ms)")
    }
    let flushed = flush_sse_event(
      data_lines,
      sink~,
      acc,
      slots,
      custom_tool_input_properties,
      api~,
      provider~,
      model~,
      started_at,
    )
    if flushed is Some(message) {
      break message
    }
    match idle_reason {
      // A silent stall is a transient provider/network condition: it is
      // retried (within the caller's retry window, i.e. while no event has
      // streamed) instead of failing the run.
      Some(reason) => raise RetryableApiError(reason)
      None => fail("Responses stream ended before a terminal event")
    }
  }
  final_message
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
async fn flush_sse_event(
  data_lines : Array[StringView],
  sink~ : async (@agent_loop.GenerationEvent) -> Unit,
  acc : Array[@agent_loop.AssistantMessageContent],
  slots : Map[Int, ResponsesOutputSlot],
  custom_tool_input_properties : Map[String, String],
  api~ : String,
  provider~ : String,
  model~ : String,
  started_at : UInt64,
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
      api~,
      provider~,
      model~,
      started_at,
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
  api~ : String,
  provider~ : String,
  model~ : String,
  started_at : UInt64,
) -> SseOutcome? raise {
  let json = @json.parse(data)
  // The in-flight message carried by streaming events: metadata known at
  // stream start is already set; `stop_reason` stays `Pending` and `usage`
  // stays `None` until the terminal event. `content` aliases `acc`, matching
  // pi's model where the partial message grows as deltas arrive.
  let in_flight = () => @agent_loop.AssistantMessage::{
    content: acc,
    api,
    provider,
    model,
    stop_reason: @agent_loop.StopReason::Pending,
    error_message: None,
    usage: None,
    timestamp: started_at,
  }
  return match event {
    "response.created" =>
      sse_delta(@agent_loop.GenerationEvent::Start(in_flight()))
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
          sse_delta(@agent_loop.ThinkingStart(content_index, in_flight()))
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
          sse_delta(@agent_loop.TextStart(content_index, in_flight()))
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
          sse_delta(@agent_loop.ToolCallStart(content_index, in_flight()))
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
          sse_delta(@agent_loop.ToolCallStart(content_index, in_flight()))
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
      sse_delta(@agent_loop.ThinkingDelta(content_index, delta, in_flight()))
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
      sse_delta(@agent_loop.ThinkingDelta(content_index, "\n\n", in_flight()))
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
      sse_delta(@agent_loop.TextDelta(content_index, delta, in_flight()))
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
      sse_delta(@agent_loop.ToolCallDelta(content_index, delta, in_flight()))
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
      sse_delta(@agent_loop.ToolCallDelta(content_index, delta, in_flight()))
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
          sse_delta(
            @agent_loop.ThinkingEnd(content_index, final_text, in_flight()),
          )
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
          sse_delta(@agent_loop.TextEnd(content_index, final_text, in_flight()))
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
            @agent_loop.ToolCallEnd(content_index, final_tool_call, in_flight()),
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
            @agent_loop.ToolCallEnd(content_index, final_tool_call, in_flight()),
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
      for terminal_item in terminal.output {
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
            @agent_loop.AssistantMessageContent::HostedToolCall(
              name,
              signature~
            ) => {
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
            api,
            provider,
            model,
            stop_reason,
            error_message: None,
            usage,
            timestamp: started_at,
          }),
        )
      } else if status == "incomplete" &&
        incomplete_reason == Some("max_output_tokens") {
        Some(
          SseOutcome::Terminal({
            content: acc,
            api,
            provider,
            model,
            stop_reason: @agent_loop.StopReason::Length,
            error_message: None,
            usage,
            timestamp: started_at,
          }),
        )
      } else {
        let error_message = match terminal.error {
          Some(error) =>
            match error.message {
              Some(message) => Some(message)
              None => incomplete_reason
            }
          None => incomplete_reason
        }
        Some(
          SseOutcome::Terminal({
            content: acc,
            api,
            provider,
            model,
            stop_reason: @agent_loop.StopReason::Error,
            error_message,
            usage,
            timestamp: started_at,
          }),
        )
      }
    }
    "error" => {
      // Standard Responses API `error` events carry `message` at the top
      // level; keep the nested `error.message` fallback for compatible
      // providers.
      let error_message = match json {
        { "message": String(message), .. } => Some(message)
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
          api,
          provider,
          model,
          stop_reason: @agent_loop.StopReason::Error,
          error_message,
          usage: None,
          timestamp: started_at,
        }),
      )
    }
    _ => None
  }
}
