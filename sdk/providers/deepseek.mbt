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
const RETRY_ATTEMPTS : Int32 = 3

///|
/// Base exponential-backoff delay in milliseconds (doubling per retry, capped
/// at `MAX_BACKOFF_MS`).
const RETRY_BACKOFF_MS : Int32 = 500

///|
/// Ceiling on a single backoff sleep, so a generous budget cannot accumulate
/// minutes-long sleeps between attempts.
const MAX_BACKOFF_MS : Int32 = 60_000

///|
/// A response status worth retrying: rate limiting or a server-side failure.
/// Other 4xx are caller errors (bad key, malformed request) that a retry
/// cannot fix.
fn retryable_status(code : Int32) -> Bool {
  code == 429 || (code >= 500 && code < 600)
}

///|
///
/// The key is injected by the caller instead of being read from the
/// environment here, so credential resolution lives in `cmd/pim` (and, later,
/// wherever `auth.json` is read). Temporary shape: once the stream-facing auth
/// seam exists this field likely moves to per-request options.
struct DeepSeekProvider {
  api_key : String
}

///|
pub fn DeepSeekProvider::DeepSeekProvider(
  api_key~ : String,
) -> DeepSeekProvider {
  { api_key, }
}

///|
pub impl LLMProvider for DeepSeekProvider with fn new_llm(
  self,
  model_id,
  thinking~ : String = "high",
) {
  let model = DeepSeekModel::of(model_id)
  DeepSeekResponsesAPILLM(
    self.api_key,
    model_id~,
    thinking~,
    supports_images=model.supports_images(),
  )
}

///|
pub extend DeepSeekProvider with LLMProvider::{new_llm}

///|
/// DeepSeek 模型能力表,按 API model id 查;未识别的 model id 回退 `Unknown`
/// (按无视觉输入处理 —— image 块在编码前降级为占位文本)。
priv enum DeepSeekModel {
  /// deepseek-v4.1-flash(API id `deepseek-v4-flash`):支持图片输入。
  V4Flash
  Unknown
}

///|
fn DeepSeekModel::of(model_id : String) -> DeepSeekModel {
  match model_id {
    "deepseek-v4-flash" => V4Flash
    _ => Unknown
  }
}

///|
fn DeepSeekModel::supports_images(self : DeepSeekModel) -> Bool {
  match self {
    V4Flash => true
    Unknown => false
  }
}

///|
struct DeepSeekResponsesAPILLM {
  api_key : String
  model_id : String
  /// DeepSeek thinking effort: low / high / max.
  thinking : String
  /// Whether the model accepts image input; for text-input models the
  /// transcript's image blocks are downgraded to placeholder text before
  /// encoding (see `transform_messages`).
  supports_images : Bool
}

///|
pub fn DeepSeekResponsesAPILLM::DeepSeekResponsesAPILLM(
  api_key : String,
  model_id~ : String = "deepseek-v4-flash",
  thinking~ : String = "high",
  supports_images~ : Bool = false,
) -> DeepSeekResponsesAPILLM {
  { api_key, model_id, thinking, supports_images, }
}

///|
pub extend DeepSeekResponsesAPILLM with @agent_loop.LLM::{generate}

///|
pub impl @agent_loop.LLM for DeepSeekResponsesAPILLM with fn generate(
  self : DeepSeekResponsesAPILLM,
  context : @agent_loop.Context,
  sink~ : async (@agent_loop.GenerationEvent) -> Unit,
) -> @agent_loop.AssistantMessage {
  let input = encode_responses_input(
    context,
    supports_images=self.supports_images,
  )
  let custom_tool_input_properties = Map([])
  let tools : Array[Json] = []
  for tool in context.tools {
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
  let body : Json = {
    "model": self.model_id,
    "instructions": context.system_prompt,
    "stream": true,
    "reasoning": { "effort": self.thinking },
    "tools": tools,
    "tool_choice": "auto",
    "input": input,
  }
  @async.pause()
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
    // Transport-shaped errors and `RetryableApiError` are retried within
    // the budget; anything else is a final verdict that must not be
    // replayed: plain failures (4xx, malformed payloads, truncated
    // streams) or an attempt that already produced output. Cancellation is
    // a control-flow signal rather than an error, so `retry` propagates it
    // on its own and it never reaches this predicate.
    fatal_error=error => produced || error is Failure::Failure(_),
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
