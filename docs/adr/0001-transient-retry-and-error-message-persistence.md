# ADR 0001: Transient-failure retry architecture and journal persistence of error messages

- Status: Accepted
- Date: 2026-08-17

## Context

Terminal-Bench 2.1 CI runs exposed two transient provider failures that killed
agent runs permanently:

- `OSError("@socket.Tcp::read(): Connection reset by peer")` — TCP reset
  mid-SSE-stream.
- `Responses stream idle for 120000ms` — SSE stream stall past the idle
  timeout.

PR #11 added a whole-stream retry: the provider retries the entire `generate`
call even after partial streaming, re-emitting a fresh `Start` event sequence,
and `loop.mbt` treats a repeated `Start` as a stream restart. This maximizes
benchmark completion but leaks retry semantics into the agent-loop event
protocol: consumers of `AgentEvent` must understand that a message sequence
can restart.

Reference implementations handle this in two layers instead:

- **pi (TypeScript)**: provider retry covers only request establishment
  (`client.responses.create().withResponse()`), invisible to callers; a
  mid-stream failure ends the turn with `stopReason: "error"`; `AgentSession`
  then auto-retries the whole turn, emitting explicit `auto_retry_start` /
  `auto_retry_end` session events and removing the failed message from the
  agent state before re-running.
- **openseek**: provider retry "bails" once the first complete SSE event
  arrives — the retry window contains zero observable output, so it is fully
  caller-invisible.

pi's journal discipline for error messages: `message_end` persists every
assistant message including failed ones, and resume rebuilds context from the
full entry path (only `stopReason: "deferred"` is filtered). Live retry
removes the failed message from agent state, so live context and resumed
context differ (resume includes the superseded error message). pi accepts
this inconsistency: prefix caches are provider-side with minute-scale TTLs
and never survive a process restart anyway.

## Decision

### Layered retry

1. **Provider retry window: connection through the first complete SSE event**
   (openseek's `bail` semantics). A failed attempt emits zero events to the
   sink, so the retry is invisible to the agent loop and all downstream
   consumers. This window is slightly wider than pi's (which stops at
   response headers) and additionally covers "headers received but stream
   stalls before producing anything".
2. **Typed classification inside the provider**: a package-private
   `RetryableApiError` is raised at the raise sites (idle timeout, 429/5xx);
   `@async.retry`'s `fatal_error` blacklist (cancellation, plain `fail`,
   produced-any-event) decides retryability. No string matching at this
   layer.
3. **Mid-stream failure becomes an error message**: after the first SSE
   event, failures propagate; the agent loop converts a raised `generate`
   into an `AssistantMessage` with `stop_reason: Error`, ending the turn
   normally.
4. **Session-level auto_retry**: `AgentSession` retries a turn whose
   assistant message ended with a retryable error, bounded (3 attempts) with
   exponential backoff, emitting `AgentSessionEvent::AutoRetryStart` /
   `AutoRetryEnd`. Retryability at this layer pattern-matches `error_message`
   against pi's blacklist (quota/billing, context overflow) and whitelist
   (overloaded, rate limit, 5xx, transport) — once errors cross layer
   boundaries they are text, and pi does the same.
5. `AgentSessionEvent` is a session-level event union (`Loop(AgentEvent)` plus
   session events), keeping retry signals out of the loop's `AgentEvent`.

### Journal persistence of error messages (Option C)

6. Error assistant messages are **persisted unconditionally** at
   `MessageEnd` — the journal is a complete write-ahead log, including failed
   attempts later superseded by a retry.
7. **Hydration filters**: when rebuilding `message_buffer` from journal
   entries, assistant messages with `stop_reason: Error` are dropped, so the
   restored model context never contains superseded or partial failures.
   Live and resumed context are identical.

## Considered alternatives

### Retry window

- **Whole-stream retry with event buffering** (PR #11 first draft): buffer an
  attempt's events and replay them only on success. No duplicate downstream
  events, but kills live streaming — `--mode json` consumers and any future
  TUI would see updates arrive in a burst at the end. Rejected.
- **Whole-stream retry with live re-emission** (PR #11 as merged): best
  benchmark completion, but the restart contract (`Start` may repeat)
  becomes part of the event protocol, diverging from pi's clean layering.
  Superseded by this ADR.
- **pi's exact window (until response headers)**: narrower than `bail`; a
  stream that stalls before its first event is not retried. Not chosen.

### Error-message persistence and hydration

- **A — pi-faithful**: persist everything, hydration includes error messages
  (filter only `deferred`, which pim does not have). Live context excludes
  the superseded error while resumed context includes it — live/resume
  inconsistency. Rejected for the inconsistency.
- **B — terminal-only persistence**: error messages reach the journal only
  when the retry budget is exhausted or the error is not retryable. The
  journal reads as "what the model actually saw" and hydration needs no
  filter. Rejected: superseded failures leave no trace in the journal,
  weakening failure forensics (benchmark trajectories do keep them in harbor
  logs, but the journal should be self-sufficient).
- **C — persist all + filter at hydration (chosen)**: complete WAL on disk,
  clean context in memory, live/resume consistent. The filter is one guard
  in `AgentSession`'s constructor. Semantic trade-off: a terminally failed
  session resumes without the failure in context — acceptable, since
  resuming a failed session is almost always followed by a retry prompt
  anyway.

## Consequences

- The agent-loop event protocol carries no retry semantics; `loop.mbt`
  reverts the stream-restart handling from PR #11.
- Provider code raises typed retryable errors; classification text-matching
  exists only at the session layer, mirroring pi.
- `AgentSession.subscribe` listeners receive `AgentSessionEvent` instead of
  `AgentEvent` — a breaking change for `cmd/pim` and `--mode json` wiring,
  mechanically a one-layer `Loop(...)` unwrap.
- pi reading a pim journal (or vice versa) works at the codec level; note
  that pi's hydration includes error messages while pim's filters them, so
  cross-tool resume of the same journal produces slightly different contexts
  (pi keeps the failure, pim drops it). Both are safe; pim is the primary
  reader of its own journals.
- Benchmark resilience comes from the session-level auto-retry of a whole
  turn rather than regeneration of a half-streamed message — slightly more
  tokens spent per recovery, in exchange for clean protocol semantics.
