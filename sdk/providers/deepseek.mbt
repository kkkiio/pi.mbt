///|
/// https://api-docs.deepseek.com/guides/responses_api/
const BASE_URL = "https://api.deepseek.com"

///|
/// Max attempts for the bounded retry around a whole generate call.
const MAX_STREAM_ATTEMPTS : Int = 3

///|
/// Base exponential-backoff delay in milliseconds: attempts wait 1s, 2s, 4s.
const STREAM_BACKOFF_BASE_MS : Int = 1000

///|
/// Raised by the provider when the API responds with a transient HTTP status
/// (429 or 5xx). `retry_transient` retries these; when attempts are exhausted
/// the final error still carries the original HTTP detail for diagnostics.
pub(all) suberror RetryableHttpError {
  RetryableHttpError(Int, String)
}

///|
pub impl Show for RetryableHttpError with fn output(self, logger) {
  let RetryableHttpError(code, detail) = self
  logger <+ "DeepSeek API error \{code}: \{detail} [retryable]"
}

///|
/// Retry policy for the DeepSeek provider: transient conditions only. A
/// socket-level error (e.g. a TCP reset mid-SSE-stream), the SSE idle timeout,
/// or a retryable HTTP status (429/5xx, signalled via `RetryableHttpError`)
/// may be retried. Anything else — including cancellation — fails immediately.
pub fn is_transient_provider_error(err : Error) -> Bool {
  if @async.is_cancellation_error(err) {
    // A cancelled (aborted) request must never be retried.
    return false
  }
  let message = "\{err}"
  message.has_prefix("OSError(") ||
  message.contains(SSE_STREAM_IDLE_FAILURE_PREFIX) ||
  message.contains("[retryable]")
}

///|
struct DeepSeekProvider {}

///|
pub fn DeepSeekProvider::DeepSeekProvider() -> DeepSeekProvider {
  DeepSeekProvider::{  }
}

///|
pub impl LLMProvider for DeepSeekProvider with fn new_llm(self, model_id) {
  ignore(self)
  guard @env.get_env_var("DEEPSEEK_API_KEY") is Some(api_key) else {
    fail("miss DEEPSEEK_API_KEY")
  }
  DeepSeekResponsesAPILLM(api_key, model_id~)
}

///|
struct DeepSeekResponsesAPILLM {
  api_key : String
  model_id : String
}

///|
pub fn DeepSeekResponsesAPILLM::DeepSeekResponsesAPILLM(
  api_key : String,
  model_id? : String = "deepseek-v4-flash",
) -> DeepSeekResponsesAPILLM {
  { api_key, model_id }
}

///|
pub impl @agent_loop.LLM for DeepSeekResponsesAPILLM with fn generate(
  self : DeepSeekResponsesAPILLM,
  context : @agent_loop.Context,
  sink~ : async (@agent_loop.GenerationEvent) -> Unit,
) -> @agent_loop.AssistantMessage {
  let (body, custom_tool_input_properties) = self.encode_responses_body(context)
  retry_transient(
    max_attempts=MAX_STREAM_ATTEMPTS,
    base_backoff_ms=STREAM_BACKOFF_BASE_MS,
    is_transient=is_transient_provider_error,
    attempt=() => {
      // Each attempt is a fresh request and a fresh SSE stream; transient
      // failures (TCP reset, idle timeout, HTTP 429/5xx) restart from scratch
      // and re-emit a fresh Start/.../ event sequence to the sink.
      let client = @http.post_stream("\{BASE_URL}/v1/responses", headers={
        "Content-Type": "application/json",
        "Authorization": "Bearer \{self.api_key}",
        "Accept-Encoding": "identity", // disable gzip for streaming
      })
      defer client.close()
      client.write(body)
      let resp = client.end_request()
      guard resp.code >= 200 && resp.code < 300 else {
        let detail = client.read_all().text()
        if resp.code == 429 || resp.code >= 500 {
          raise RetryableHttpError(resp.code, detail)
        }
        fail("DeepSeek API error \{resp.code}: \{detail}")
      }
      read_responses_sse_stream(
        client,
        sink~,
        api="openai-responses",
        provider="deepseek",
        model=self.model_id,
        custom_tool_input_properties~,
      )
    },
  )
}

///|
/// Encodes the request body for one Responses API call plus the tool input
/// property map needed to decode custom tool calls. Building is pure: the same
/// body is replayed verbatim on every retry attempt.
fn DeepSeekResponsesAPILLM::encode_responses_body(
  self : DeepSeekResponsesAPILLM,
  context : @agent_loop.Context,
) -> (String, Map[String, String]) raise {
  let input = encode_responses_input(context)
  let custom_tool_input_properties : Map[String, String] = Map([])
  let tools : Array[Json] = []
  for definition in context.tools {
    match definition {
      @agent_loop.ToolDefinition::Hosted(WebSearch) =>
        tools.push({ "type": "web_search" })
      @agent_loop.ToolDefinition::Function(tool) =>
        match tool.constrained_sampling {
          JsonSchema(strict~) =>
            tools.push({
              "type": "function",
              "name": tool.name,
              "description": tool.description,
              "parameters": tool.parameters,
              "strict": strict,
            })
          Grammar(format~, definition=grammar_definition, input_property~) => {
            custom_tool_input_properties[tool.name] = input_property
            tools.push({
              "type": "custom",
              "name": tool.name,
              "description": tool.description,
              "format": {
                "type": "grammar",
                "syntax": match format {
                  Lark => "lark"
                  Regex => "regex"
                },
                "definition": grammar_definition,
              },
            })
          }
        }
    }
  }
  let body : Json = {
    "model": self.model_id,
    "instructions": context.system_prompt,
    "stream": true,
    "reasoning": { "effort": "high" },
    "tools": tools,
    "tool_choice": "auto",
    "input": input,
  }
  (body.stringify(), custom_tool_input_properties)
}
