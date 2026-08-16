///|
pub(open) trait LLMProvider {
  fn new_llm(Self, String) -> &@agent_loop.LLM raise
}
