# ADR 0001: Transient-failure retry architecture and error-message lifecycle

- Status: Accepted
- Date: 2026-08-17

## Context

Terminal-Bench 2.1 CI runs exposed two transient provider failures that killed
agent runs permanently:

- `OSError("@socket.Tcp::read(): Connection reset by peer")` — TCP reset
  mid-SSE-stream.
- `Responses stream idle for 120000ms` — SSE stream stall past the idle
  timeout.

A first fix (PR #11) retried the whole `generate` call, re-emitting stream
events, which leaked retry semantics into the agent-loop event protocol.
Reference implementations (pi in TypeScript, openseek in MoonBit) instead
split retry handling across layers, and that model is adopted here.

This ADR has two parts: the retry layering, and — the part with the most
lasting design impact — the **error-message lifecycle**: when an assistant
turn fails, where does that failed message live, and who ever sees it?

## The error-message lifecycle (the core decision)

When a turn fails with a retryable error and the session auto-retries, the
failed assistant message (call it A₁) is superseded by the retried turn's
message (A₂). Three places can each choose to keep or drop A₁:

| | Keep A₁? | Rationale |
| --- | --- | --- |
| **Journal (on-disk history)** | **Keep** | The journal is a write-ahead log; failure evidence must not be erased. |
| **Live context (what the LLM sees during the run)** | **Drop** | Before retrying, A₁ is popped from the in-memory message buffer, so the retried call never sees its own half-produced attempt. |
| **Resumed context (what the LLM sees after reloading a session)** | **Drop** | Hydration filters out assistant messages with `stop_reason = Error`, so a resumed session never replays a failed turn into the prompt. |

Consequences of this combination:

- The disk journal may contain `[user, A₁(error), A₂(success), …]` — a
  complete, honest history.
- The model never sees A₁, live or after resume — context is always the
  clean, successful path.
- Live and resumed behavior are identical by construction.

### Alternatives considered

**Persist everything, resume unfiltered (pi's behavior).**
pi keeps error messages in the journal and its resume path
(`buildSessionContext`) filters only `deferred` messages, so a resumed pi
session *does* replay superseded error messages into the model context,
while its live retry removes them — live and resume disagree. pi accepts
this; prefix-cache locality doesn't suffer because provider caches have
minute-scale TTLs and never survive a process restart. Rejected: we prefer
live/resume consistency over mimicking pi's incidental behavior.

**Persist only terminal errors.**
A failed message reaches the journal only when the retry budget is
exhausted or the error is not retryable; hydration needs no filter because
the journal already reads as "what the model actually saw". Rejected:
superseded failures leave no trace in the journal, weakening failure
forensics — the journal should be self-sufficient as a record of what
happened.

Note on cross-tool compatibility: pi reading a pim journal includes our
error messages in context (pi filters nothing else); pim reading any journal
drops them. Both are safe; the contexts differ only by whether a failed
attempt is visible to the model.

## Retry layering (the mechanical part)

1. **Provider retry window: connection through the first complete SSE
   event** (openseek's `bail` semantics). A failed attempt emits zero events
   to the sink, so retries are invisible to the agent loop. This window is
   slightly wider than pi's (which stops at response headers) and also
   covers "headers received but the stream stalls before producing
   anything".
2. **Typed classification inside the provider**: a package-private
   `RetryableApiError` is raised at raise sites (idle timeout, 429/5xx);
   `@async.retry`'s `fatal_error` blacklist (cancellation, plain `fail`,
   already-produced-an-event) decides retryability. No string matching at
   this layer.
3. **Mid-stream failure becomes an error message**: the agent loop converts
   a raised `generate` into an `AssistantMessage` with `stop_reason: Error`,
   ending the turn normally. The agent loop itself carries no retry logic.
4. **Session-level auto-retry**: `AgentSession` retries a turn whose
   terminal message is a retryable error — bounded (3 attempts), exponential
   backoff, emitting `AgentSessionEvent::AutoRetryStart` / `AutoRetryEnd`.
   Retryability pattern-matches `error_message` against pi's blacklist
   (quota/billing, context overflow) and whitelist (overloaded, rate limit,
   5xx, transport) — across layer boundaries errors are text, and pi does
   the same.
5. `AgentSessionEvent` is the session-level event union
   (`Loop(AgentEvent)` plus session events), keeping retry signals out of
   the agent loop's `AgentEvent`.

### Alternatives considered for the retry window

- **Whole-stream retry with event buffering** (PR #11 first draft): buffer
  an attempt's events and replay only on success. No duplicate downstream
  events, but kills live streaming. Rejected.
- **Whole-stream retry with live re-emission** (PR #11 as merged): the
  restart contract (`Start` may repeat) becomes part of the event protocol,
  diverging from pi's clean layering. Superseded by this ADR.
- **pi's exact window (until response headers)**: narrower than `bail`; a
  stream that stalls before its first event is not retried. Not chosen.

## Consequences

- The agent-loop event protocol carries no retry semantics.
- Provider code raises typed retryable errors; classification
  text-matching exists only at the session layer, mirroring pi.
- `AgentSession.subscribe` listeners receive `AgentSessionEvent` instead of
  `AgentEvent` — a breaking change for `cmd/pim` and `--mode json` wiring,
  mechanically a one-layer `Loop(...)` unwrap.
- Benchmark resilience comes from whole-turn re-runs rather than
  regeneration of half-streamed messages — slightly more tokens per
  recovery, in exchange for clean protocol semantics.
- The journal contains failed turns that the model never saw. Analysis
  tooling must be aware that `stopReason: "error"` entries are historical
  records, not context that was sent to the model.
