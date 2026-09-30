///|
/// Scripted stand-in for a real provider, mirroring pi's `faux` provider
/// (`packages/ai/src/providers/faux.ts`): a test enqueues terminal
/// `AssistantMessage`s and each `generate` replays the next one through `sink`
/// as streaming events before returning it. This keeps agent-loop / session
/// tests free of network and credentials, and makes the sequence of model turns
/// an explicit part of the test.
///
/// Deliberately small: no deferred responses, token-rate pacing, usage
/// estimation or prompt caching. What is here is what loop-level tests need —
/// scripted text, thinking and tool calls, streamed in chunks so a test can
/// abort mid-stream.
pub struct FauxLLM {
  api : String
  provider : String
  model : String
  mut responses : Array[@agent_loop.AssistantMessage]
  mut cursor : Int
  /// 流式分片之间的间隔(毫秒);0 表示不等待,让分片背靠背发出。
  chunk_delay_ms : Int
  /// 每个流式分片的最大 UTF-16 长度(至少 1)。
  chunk_size : Int
}

///|
pub fn FauxLLM::FauxLLM(
  api? : String = "faux",
  provider? : String = "faux",
  model? : String = "faux-1",
  chunk_delay_ms? : Int = 0,
  chunk_size? : Int = 16,
) -> FauxLLM {
  let size = if chunk_size <= 0 { 1 } else { chunk_size }
  FauxLLM::{
    api,
    provider,
    model,
    responses: [],
    cursor: 0,
    chunk_delay_ms,
    chunk_size: size,
  }
}

///|
/// Replace the scripted queue and rewind to its start.
pub fn FauxLLM::set_responses(
  self : FauxLLM,
  responses : ArrayView[@agent_loop.AssistantMessage],
) -> Unit {
  self.responses = responses.to_owned()
  self.cursor = 0
}

///|
/// Append to the scripted queue without rewinding.
pub fn FauxLLM::append_responses(
  self : FauxLLM,
  responses : ArrayView[@agent_loop.AssistantMessage],
) -> Unit {
  for response in responses {
    self.responses.push(response)
  }
}

///|
/// How many scripted responses have not been consumed yet.
pub fn FauxLLM::pending_responses(self : FauxLLM) -> Int {
  self.responses.length() - self.cursor
}

///|
/// A text block for use inside `faux_message`.
pub fn faux_text(text : String) -> @agent_loop.AssistantMessageContent {
  @agent_loop.AssistantMessageContent::Text(text, signature={})
}

///|
/// A thinking block for use inside `faux_message`.
pub fn faux_thinking(text : String) -> @agent_loop.AssistantMessageContent {
  @agent_loop.AssistantMessageContent::Thinking(text, signature={})
}

///|
/// Monotonic default tool-call ids so a batch of `faux_tool_call`s stays
/// addressable without the test threading an id through.
let faux_call_seq : Ref[Int] = Ref(0)

///|
/// A tool-call block for use inside `faux_message`.
pub fn faux_tool_call(
  name : String,
  arguments : Json,
  id? : String,
) -> @agent_loop.AssistantMessageContent {
  let id = match id {
    Some(id) => id
    None => {
      faux_call_seq.val += 1
      "call-\{faux_call_seq.val}"
    }
  }
  @agent_loop.AssistantMessageContent::ToolCall({ id, name, arguments, }, signature={})
}

///|
/// A terminal assistant message for `set_responses`.
pub fn faux_message(
  content : Array[@agent_loop.AssistantMessageContent],
  stop_reason? : @agent_loop.StopReason = @agent_loop.StopReason::Stop,
  error_message? : String? = None,
  api? : String = "faux",
  provider? : String = "faux",
  model? : String = "faux-1",
  timestamp? : UInt64 = 0,
) -> @agent_loop.AssistantMessage {
  {
    content,
    api,
    provider,
    model,
    stop_reason,
    error_message,
    usage: None,
    timestamp,
  }
}

///|
/// Split `text` into chunks of at most `size` UTF-16 code units. Text always
/// yields at least one (possibly empty) chunk so a block still emits
/// start/delta/end.
fn split_chunks(text : String, size : Int) -> Array[String] {
  let chunks : Array[String] = []
  let total = text.length()
  let mut index = 0
  while index < total {
    let end = if index + size < total { index + size } else { total }
    chunks.push(text[index:end].to_owned())
    index = end
  }
  if chunks.length() == 0 {
    chunks.push("")
  }
  chunks
}

///|
async fn FauxLLM::pace(self : FauxLLM) -> Unit {
  if self.chunk_delay_ms > 0 {
    @async.sleep(self.chunk_delay_ms)
  }
}

///|
/// Snapshot the in-flight message; `content` is copied so later mutation of the
/// accumulator cannot rewrite an already-emitted partial.
fn FauxLLM::snapshot(
  self : FauxLLM,
  content : Array[@agent_loop.AssistantMessageContent],
  stop_reason : @agent_loop.StopReason,
  error_message? : String,
) -> @agent_loop.AssistantMessage {
  {
    content: content.map(block => block),
    api: self.api,
    provider: self.provider,
    model: self.model,
    stop_reason,
    error_message,
    usage: None,
    timestamp: 0,
  }
}

///|
fn FauxLLM::aborted(
  self : FauxLLM,
  content : Array[@agent_loop.AssistantMessageContent],
) -> @agent_loop.AssistantMessage {
  self.snapshot(
    content,
    @agent_loop.StopReason::Aborted,
    error_message="Interrupted",
  )
}

///|
pub extend FauxLLM with @agent_loop.LLM::{generate}

///|
pub impl @agent_loop.LLM for FauxLLM with fn generate(
  self : FauxLLM,
  _ctx : @agent_loop.Context,
  sink~ : async (@agent_loop.GenerationEvent) -> Unit,
  abort~ : @agent_loop.AbortSignal,
) -> @agent_loop.AssistantMessage {
  guard self.cursor < self.responses.length() else {
    fail(
      "FauxLLM: no scripted response left for generate call #\{self.cursor + 1}",
    )
  }
  let scripted = self.responses[self.cursor]
  self.cursor += 1
  let acc : Array[@agent_loop.AssistantMessageContent] = []
  sink(
    @agent_loop.GenerationEvent::Start(
      partial=self.snapshot(acc, @agent_loop.StopReason::Pending),
    ),
  )
  let mut index = 0
  for block in scripted.content {
    if abort.is_aborted() {
      return self.aborted(acc)
    }
    match block {
      @agent_loop.AssistantMessageContent::Text(text, signature~) => {
        acc.push(@agent_loop.AssistantMessageContent::Text("", signature={}))
        sink(
          @agent_loop.GenerationEvent::TextStart(
            content_index=index,
            partial=self.snapshot(acc, @agent_loop.StopReason::Pending),
          ),
        )
        let mut so_far = ""
        for piece in split_chunks(text, self.chunk_size) {
          self.pace()
          if abort.is_aborted() {
            return self.aborted(acc)
          }
          so_far += piece
          acc[index] = @agent_loop.AssistantMessageContent::Text(so_far, signature={})
          sink(
            @agent_loop.GenerationEvent::TextDelta(
              content_index=index,
              delta=piece,
              partial=self.snapshot(acc, @agent_loop.StopReason::Pending),
            ),
          )
        }
        acc[index] = @agent_loop.AssistantMessageContent::Text(text, signature~)
        sink(
          @agent_loop.GenerationEvent::TextEnd(
            content_index=index,
            content=text,
            partial=self.snapshot(acc, @agent_loop.StopReason::Pending),
          ),
        )
      }
      @agent_loop.AssistantMessageContent::Thinking(text, signature~) => {
        acc.push(
          @agent_loop.AssistantMessageContent::Thinking("", signature={}),
        )
        sink(
          @agent_loop.GenerationEvent::ThinkingStart(
            content_index=index,
            partial=self.snapshot(acc, @agent_loop.StopReason::Pending),
          ),
        )
        let mut so_far = ""
        for piece in split_chunks(text, self.chunk_size) {
          self.pace()
          if abort.is_aborted() {
            return self.aborted(acc)
          }
          so_far += piece
          acc[index] = @agent_loop.AssistantMessageContent::Thinking(so_far, signature={})
          sink(
            @agent_loop.GenerationEvent::ThinkingDelta(
              content_index=index,
              delta=piece,
              partial=self.snapshot(acc, @agent_loop.StopReason::Pending),
            ),
          )
        }
        acc[index] = @agent_loop.AssistantMessageContent::Thinking(
          text,
          signature~,
        )
        sink(
          @agent_loop.GenerationEvent::ThinkingEnd(
            content_index=index,
            content=text,
            partial=self.snapshot(acc, @agent_loop.StopReason::Pending),
          ),
        )
      }
      @agent_loop.AssistantMessageContent::ToolCall(tool_call, signature~) => {
        acc.push(
          @agent_loop.AssistantMessageContent::ToolCall(
            { id: tool_call.id, name: tool_call.name, arguments: {}, },
            signature={},
          ),
        )
        sink(
          @agent_loop.GenerationEvent::ToolCallStart(
            content_index=index,
            partial=self.snapshot(acc, @agent_loop.StopReason::Pending),
          ),
        )
        for
          piece in split_chunks(
            tool_call.arguments.stringify(),
            self.chunk_size,
          ) {
          self.pace()
          if abort.is_aborted() {
            return self.aborted(acc)
          }
          sink(
            @agent_loop.GenerationEvent::ToolCallDelta(
              content_index=index,
              delta=piece,
              partial=self.snapshot(acc, @agent_loop.StopReason::Pending),
            ),
          )
        }
        acc[index] = @agent_loop.AssistantMessageContent::ToolCall(
          tool_call,
          signature~,
        )
        sink(
          @agent_loop.GenerationEvent::ToolCallEnd(
            content_index=index,
            tool_call~,
            partial=self.snapshot(acc, @agent_loop.StopReason::Pending),
          ),
        )
      }
      // The generation protocol has no hosted-tool streaming events; pass the
      // block through so a scripted hosted call still reaches the loop.
      @agent_loop.AssistantMessageContent::HostedToolCall(tool, signature~) =>
        acc.push(
          @agent_loop.AssistantMessageContent::HostedToolCall(tool, signature~),
        )
    }
    index += 1
  }
  guard !(scripted.stop_reason is @agent_loop.StopReason::Pending) else {
    fail("FauxLLM: scripted response must not have a Pending stop_reason")
  }
  scripted
}
