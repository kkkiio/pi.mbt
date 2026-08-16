///|
type EventListener = async (@agent_loop.AgentEvent) -> Unit

///|
pub struct FanOutListener {
  listeners : Array[EventListener]
}

///|
pub fn FanOutListener::FanOutListener() -> FanOutListener {
  FanOutListener::{ listeners: [] }
}

///|
pub async fn FanOutListener::on_event(
  self : FanOutListener,
  event : @agent_loop.AgentEvent,
) -> Unit {
  for listener in self.listeners {
    listener(event)
  }
}
