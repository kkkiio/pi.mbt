///|
pub(open) trait LLMProvider {
  fn new_llm(Self, String, thinking? : String) -> &@agent_loop.LLM raise
}
