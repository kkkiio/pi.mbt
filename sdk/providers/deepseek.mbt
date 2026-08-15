///|
/// https://api-docs.deepseek.com/guides/responses_api/
const BASE_URL = "https://api.deepseek.com"

///|
struct DeepSeekResponsesAPILLM {
  api_key : String
  model : String
}

///|
pub fn DeepSeekResponsesAPILLM::DeepSeekResponsesAPILLM(
  api_key : String,
  model? : String = "deepseek-v4-flash",
) -> DeepSeekResponsesAPILLM {
  { api_key, model }
}

///|
pub impl @agentloop.LLM for DeepSeekResponsesAPILLM with fn generate(
  self,
  context,
) {
  let q = @async.Queue(kind=@aqueue.Blocking(0))
  QueueStream::{
    q,
    f: () => stream(self.api_key, self.model, context, q),
    task: None,
  }
}

///|
async fn stream(
  api_key : String,
  model : String,
  context : @agentloop.Context,
  out : @async.Queue[@agentloop.AssistantMessageEvent],
) -> Unit {
  let client = @http.post_stream("\{BASE_URL}/v1/responses", headers={
    "Content-Type": "application/json",
    "Authorization": "Bearer \{api_key}",
    "Accept-Encoding": "identity", // disable gzip for streaming
  })
  defer client.close()
  let input = encode_responses_input(context)
  let body : Json = {
    "model": model,
    "instructions": context.system_prompt,
    "stream": true,
    "reasoning": { "effort": "high" },
    "tools": [
      ..[
        for f in context.tools => {
          match f {
            WebSearch => ({ "type": "web_search" } : Json)
            Function(tool) =>
              {
                "type": "function",
                "name": tool.name,
                "description": tool.description,
                "parameters": tool.parameters,
                "strict": tool.strict,
              }
            Custom(tool) =>
              {
                "type": "custom",
                "name": tool.name,
                "description": tool.description,
              }
          }
        }
      ],
    ],
    "tool_choice": "auto",
    "input": input,
  }
  client.write(body.stringify())
  let resp = client.end_request()
  guard resp.code >= 200 && resp.code < 300 else {
    let text = client.read_all().text()
    let message = "DeepSeek API error \{resp.code}: \{text}"
    fail(message)
  }

  read_responses_sse_stream(client, out)
}

///|
struct QueueStream {
  q : @async.Queue[@agentloop.AssistantMessageEvent]
  f : async () -> Unit
  mut task : @async.Task[Unit]?
}

///|
pub impl @agentloop.AssistantMessageEventStream for QueueStream with fn next(
  self,
) {
  if self.task is None {
    self.task = Some(@async.with_task_group() <| tg => { tg.spawn(self.f) })
  }
  self.q.get()
}

///|
pub impl @agentloop.AssistantMessageEventStream for QueueStream with fn close(
  self,
) {
  if self.task is Some(task) {
    task.cancel()
    self.task = None
  }
  self.q.close()
}
