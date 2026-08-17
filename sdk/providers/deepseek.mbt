///|
/// https://api-docs.deepseek.com/guides/responses_api/
const BASE_URL = "https://api.deepseek.com"

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
  let client = @http.post_stream("\{BASE_URL}/v1/responses", headers={
      "Content-Type": "application/json",
      "Authorization": "Bearer \{self.api_key}",
      "Accept-Encoding": "identity", // disable gzip for streaming
    })
    defer client.close()
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
    client.write(body.stringify())
    let resp = client.end_request()
    guard resp.code >= 200 && resp.code < 300 else {
      let text = client.read_all().text()
      let message = "DeepSeek API error \{resp.code}: \{text}"
      fail(message)
    }
    let result = read_responses_sse_stream(
      client,
      sink~,
      api="openai-responses",
      provider="deepseek",
      model=self.model_id,
      custom_tool_input_properties~,
    )
    result
}
