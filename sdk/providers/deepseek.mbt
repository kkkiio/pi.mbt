///|
/// https://api-docs.deepseek.com/guides/responses_api/
const BASE_URL = "https://api.deepseek.com"

///|
/// Marks an attempt failure the retry loop may absorb: the SSE idle timeout
/// and retryable HTTP statuses (429, 5xx). Carries the already-formatted
/// public failure message so an exhausted budget re-raises the same text a
/// non-retrying call would have produced; the type never escapes.
priv suberror RetryableApiError {
  RetryableApiError(String)
}

///|
/// Total attempts for the provider-level retry window (connection through the
/// first SSE event): 1 initial attempt + 2 retries.
const RETRY_ATTEMPTS : Int = 3

///|
/// Base exponential-backoff delay in milliseconds (doubling per retry, capped
/// at `MAX_BACKOFF_MS`).
const RETRY_BACKOFF_MS : Int = 500

///|
/// Ceiling on a single backoff sleep, so a generous budget cannot accumulate
/// minutes-long sleeps between attempts.
const MAX_BACKOFF_MS : Int = 60_000

///|
/// A response status worth retrying: rate limiting or a server-side failure.
/// Other 4xx are caller errors (bad key, malformed request) that a retry
/// cannot fix.
fn retryable_status(code : Int) -> Bool {
  code == 429 || (code >= 500 && code < 600)
}

///|
struct DeepSeekProvider {}

///|
pub fn DeepSeekProvider::DeepSeekProvider() -> DeepSeekProvider {
  DeepSeekProvider::{  }
}

///|
pub impl LLMProvider for DeepSeekProvider with fn new_llm(
  self,
  model_id,
  thinking? : String = "high",
) {
  ignore(self)
  guard @env.get_env_var("DEEPSEEK_API_KEY") is Some(api_key) else {
    fail("miss DEEPSEEK_API_KEY")
  }
  DeepSeekResponsesAPILLM(api_key, model_id~, thinking~)
}

///|
struct DeepSeekResponsesAPILLM {
  api_key : String
  model_id : String
  /// DeepSeek thinking effort: low / high / max.
  thinking : String
}

///|
pub fn DeepSeekResponsesAPILLM::DeepSeekResponsesAPILLM(
  api_key : String,
  model_id? : String = "deepseek-v4-flash",
  thinking? : String = "high",
) -> DeepSeekResponsesAPILLM {
  { api_key, model_id, thinking }
}

///|
pub impl @agent_loop.LLM for DeepSeekResponsesAPILLM with fn generate(
  self : DeepSeekResponsesAPILLM,
  context : @agent_loop.Context,
  sink~ : async (@agent_loop.GenerationEvent) -> Unit,
) -> @agent_loop.AssistantMessage {
  let input = encode_responses_input(context)
  let custom_tool_input_properties = Map([])
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
    "reasoning": { "effort": self.thinking },
    "tools": tools,
    "tool_choice": "auto",
    "input": input,
  }
  // `bail` semantics: the retry window covers connection through the first
  // SSE event. Once any event has streamed, the completion is live and billed;
  // a retry would duplicate content downstream, so failures past that point
  // propagate to the caller instead. Failed attempts emit nothing, keeping the
  // retry invisible to the sink and downstream consumers.
  let mut produced = false
  let attempt_sink = (event : @agent_loop.GenerationEvent) => {
    produced = true
    sink(event)
  }
  @async.retry(
    @async.ExponentialDelay(
      initial=RETRY_BACKOFF_MS,
      factor=2.0,
      maximum=MAX_BACKOFF_MS,
    ),
    max_retry=RETRY_ATTEMPTS - 1,
    fatal_error=error => {
      // Transport-shaped errors and `RetryableApiError` are retried within
      // the budget; anything else is a final verdict that must not be
      // replayed: cancellation, plain failures (4xx, malformed payloads,
      // truncated streams), or an attempt that already produced output.
      produced ||
      @async.is_cancellation_error(error) ||
      error is Failure::Failure(_)
    },
    () => {
      // Each attempt is a fresh request and a fresh SSE stream.
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
        let message = "DeepSeek API error \{resp.code}: \{detail}"
        if retryable_status(resp.code) {
          raise RetryableApiError(message)
        }
        fail(message)
      }
      read_responses_sse_stream(
        client,
        sink=attempt_sink,
        api="openai-responses",
        provider="deepseek",
        model=self.model_id,
        custom_tool_input_properties~,
      )
    },
  ) catch {
    // Budget exhausted (or bailed): surface the same message a non-retrying
    // call would have produced, via plain failure so the marker never escapes.
    RetryableApiError(message) => fail(message)
    error => raise error
  }
}
