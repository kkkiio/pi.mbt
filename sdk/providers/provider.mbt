///|
pub(open) trait LLMProvider {
  fn new_llm(Self, String) -> &@agentloop.LLM raise
}
