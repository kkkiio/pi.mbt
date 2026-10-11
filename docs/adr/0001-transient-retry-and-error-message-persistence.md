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
message (A₂). Two questions decide its fate:

| | Keep A₁? | How |
| --- | --- | --- |
| **Journal (on-disk history)** | **Keep** | The journal is a write-ahead log; failure evidence must not be erased. |
| **Model context (what the model sees)** | **Drop** | Two layers, below. |

The retry records the omission rather than editing memory: before backing off,
the session appends a `context_edit` targeting A₁'s entry, and the model
context is recomputed from the journal. A₁ therefore leaves the context the
same way on every path — live, retried, or reloaded — because the context is a
projection of the journal and the omission is part of the journal. This is
pi's mechanism (`_omitRecoveryAttempt` → `appendContextEdit(targetId, null)`),
and the entry carries pi's wire shape so a pi tool can read it.

The omission is load-bearing rather than cosmetic. A retry continues with
`run_agent_loop_continue`, which rejects a transcript ending in an assistant
message: the failed turn is exactly such a tail, so a retry can only proceed
once the omission has been recorded.

A second layer covers what the omission cannot: the request build drops any
`stop_reason = Error` / `Aborted` assistant message (`transform_messages`,
mirroring pi). Two cases need it. A transcript that never went through this
session — hand-written, imported, or written before the omission existed —
carries no edit. And when the retry budget is exhausted the session records no
omission, because nothing supersedes the failed turn: A₁ stays in the journal
and in the projection, and only the request build keeps it out of the prompt.

Consequences of this combination:

- The disk journal may contain `[user, A₁(error), context_edit(A₁), A₂(success), …]`
  — a complete, honest history.
- The model never sees A₁ — context is always the clean, successful path.
- `session.messages` is a function of the journal, so a reloaded session
  projects what a live one does, with no second mechanism to keep in step.

### Alternatives considered

**Drop A₁ from memory instead of recording the omission.**
Pop it from the in-memory buffer before a retry, and filter it while hydrating.
This was the first implementation. Rejected: the pop is not persisted, so a
reloaded session could not reproduce it, and the two mechanisms had to be kept
in step by hand. pi reached the same conclusion — its `buildSessionProjection`
filters nothing; the omission is recorded instead.

**Persist only terminal errors.**
A failed message reaches the journal only when the retry budget is
exhausted or the error is not retryable, so the journal would already read as
"what the model actually saw". Rejected: superseded failures leave no trace
in the journal, weakening failure forensics — the journal should be
self-sufficient as a record of what happened.

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
   the same. Each attempt re-enters the loop through
   `run_agent_loop_continue`, so the failed turn must already be omitted
   from the context (see the lifecycle section).
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
