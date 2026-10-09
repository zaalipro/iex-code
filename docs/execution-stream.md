# Ephemeral execution stream

`IexCode.Engine.ExecutionStream` is the runtime bridge from model callbacks to
the existing session PubSub topic. It is deliberately not a message journal:
model deltas are held in a bounded in-memory answer/reasoning preview and are
never written to `messages` or a durable partial-text table.

## Event API

Start one helper per model invocation under
`IexCode.Engine.ExecutionStreamSupervisor`:

```elixir
identity =
  ExecutionStream.scope(session_id, :coder,
    execution_id: run_id,
    run_attempt: attempt,
    run_lease_generation: generation
  )

{:ok, stream} =
  DynamicSupervisor.start_child(
    IexCode.Engine.ExecutionStreamSupervisor,
    {ExecutionStream, identity: identity, owner: self()}
  )

on_chunk = ExecutionStream.callback(stream)
```

The helper broadcasts `{:execution_stream, event}` on
`"session:#{session_id}"`. Every event includes the scoped identity
(`execution_id`, `attempt_id`, `generation`, `role`, `agent_id`,
`invocation_id`, `turn`, and `retry_epoch`) plus a monotonically increasing
event `sequence`. `status` is one of `:started`, `:streaming`, `:reset`,
`:settled`, `:complete`, `:paused`, `:cancelled`, `:failed`, `:owner_down`,
or another terminal status supplied by the caller. `text` and `reasoning` are
separate bounded strings; `truncated?` marks a preview cap.

Call `ExecutionStream.push(stream, {:stream_reset, epoch})` through the normal
LLM callback path when resilience starts a retry. The helper clears only that
invocation, increments its local `retry_epoch`, and emits `:reset`. The sentinel
number is diagnostic only: gateway retry and fallback counters can repeat, so
each actual reset advances the local epoch. The transport is synchronous, so
an old HTTP attempt cannot continue calling after its retry begins.

Call `ExecutionStream.finish(stream, status)` after the provider result and
persistence decision are known. It flushes parser carry and pending timer text
before emitting the terminal event, then stops normally. Owner death emits
`:owner_down` with the last partial preview and cleans up the timer. Consumers
must reconcile terminal events by identity and sequence, and must treat the
persisted final message plus durable terminal state as authoritative. A
successful HTTP response alone is not a successful execution.

## Bounds and integration

The default batch timer is 75 ms, scheduled only when the capped snapshot
changes. Answer and reasoning each retain at most 16,384 UTF-8 bytes. Synchronous
callback calls apply backpressure; large deltas are processed in 4,096-byte
pieces, with at most three UTF-8 carry bytes and seven think-tag carry bytes.
Retained substrings are copied to avoid retaining a larger source binary.
No timer or mailbox accumulates a token journal. `truncated?` explicitly marks
a capped preview. Final persisted answer content is unchanged by these caps.
Native structured reasoning remains in the provider's final response, while
inline split `<think>` content is separated in previews by the existing parser.
Transient strings are data, not safe HTML.

Interactive single uses the persisted user-message ID as `execution_id`.
Durable single uses its run ID, attempt and lease generation. Planner/coder
use the coordinator's run ID or root operation ID, plus durable attempt and
lease generation and available fleet agent identity. `turn/2` ends the prior
model turn, clears its buffers, assigns a new `invocation_id`, and starts the
next one. A callback captured before the turn change is ignored. Late callbacks
after helper settlement are no-ops. Helpers are temporary supervised children
and monitor the execution owner; `with_stream/2` finalizes every return,
exception or throw. The helper is NOT an authority or workspace-lock owner:
the existing cancellation tokens, database fences and reservation lifetimes
remain unchanged.

Single-agent final messages carry JSON-keyed `metadata["stream_identity"]`,
including the last turn and retry epoch. A swarm's synthesized message carries
`metadata["stream_scope"]` identifying the exact session/execution/attempt/
generation group, which replaces all role previews for that group. Old durable
receipts/final messages remain valid and are not rewritten. Replaying a durable
final starts no helper and performs no model request.

## Workspace consumer rules

- Keep previews separate from persisted message streams. Match session and
  execution scope before applying an event. Key invocation/turn/role separately.
- Accept only increasing sequences for the same helper lifecycle and reject
  stale attempt/generation/agent-generation identities. A reset replaces only
  its invocation; it must not clear other roles or executions.
- `:complete` ends a model/role invocation, not the execution. It can precede
  tools, verification, final persistence, or an eventual failure. `:settled`
  means a single final message was committed, not that the dispatcher has
  terminalized its run. Use the actual terminal run/session state.
- Persisted final identity takes precedence regardless of notification order.
  Do not revive a settled group after a late delta, duplicate final or terminal
  notification. A failed/cancelled/owner-down preview is partial, never success.
- On reconnect, reload authoritative persisted history. Do not require replay
  of old preview text. A subsequent snapshot is a capped continuation and must
  be labeled partial. Session switches drop foreign previews.

This change establishes and tests the runtime protocol only. LiveView display,
escaping, bounded projection and browser assertions belong to workspace
streaming integration.
