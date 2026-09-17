# Harness hardening follow-up — 2026-09-17

Follow-up to `2026-09-05-harness-review.md`. All items below are implemented,
regression-tested, and green under `compile --warnings-as-errors`,
`format --check-formatted`, and targeted suites (full-suite verdict pending).

## Review items closed

- **#4 lease-heartbeat hardening — done.** `RunDispatcher` renewals go through
  `safe_renew_lease/4` (`:lease_renewal` seam); the heartbeat-failure lookup
  goes through `safe_get_run/2` (`:run_reader` seam). Storage exceptions fail
  one run closed instead of crashing the dispatcher. Fault-injection tests
  raise `DBConnection.ConnectionError` through the real `:heartbeat` callback.
- **#5 transcript guarantees, first half — done.** `AgentLoop.bounded_context/1`
  no longer cuts between an assistant tool request and its replies; it reuses
  the compactor boundary via new public `ContextCompactor.restore_exchange_boundary/2`.
  Covered by unit tests plus an end-to-end 15-parallel-tool-call test.
- **#1 ownership, first slice — done (stale-state fix).**
  `Workflows.Engine.update_run_record` returned the stale input run on every
  failure mode and all 11 call sites broadcast it as truth. It now returns
  `{:ok, run} | {:error, reason}` (`:run_persister` seam); pause/resume/retry
  reply `{:error, :persistence_failed}`, cancel reports honestly while still
  stopping, start failures route to `finalize_run_failure`. Fault-injection
  tests via a switchable persister.
- **#2 legacy cancellation — done (bounded slice).** New
  `IexCode.Engine.AgentCancellation` owns the cooperative flags; the six
  cancel/pause/resume sender sites (`SessionServer`, `SwarmCoordinator`) write
  flags directly instead of relying solely on mailbox delivery to agents
  blocked in `handle_call`. Per-agent keys preserved (no cross-talk on
  restart). Promptness proven by a latched-LLM test: flag flips while the
  plan is still in flight.

## Adjacent crash-class fixes (bug hunt)

- `WorkflowsLive`: UUID-validating fetch helpers for show/run routes and
  launch/delete events; nil-safe `submit_launch`; defensive pan/zoom coercion.
- `WorkspaceLive`: defensive int/date parsing in six handlers (date picker,
  command palette, autofix, symbol jump, quick settings, test-runner line);
  safe workflow lookup for workspace launch.
- Approval modal UX: Escape fails closed to Deny, Deny autofocused, `esc` hint.

## Still open (need product/architecture decisions)

- **#1 remainder**: `WorkflowRun belongs_to :run` has no production writers or
  readers — either drop the dead FK and document split ownership, or route one
  engine through the other.
- **#3 shared-core drift** (desktop/web lifecycle contracts): untouched.
- **#5 remainder**: OS process-group cleanup validation for `System.cmd`.
- Detached-window mounts (`terminal`/`dag`/`diff`) still `get_session!` on the
  URL id (500 on unknown session); low severity, programmatic URLs only.

## Verification caveat

Sandbox blocks `mix` TCP, so gates ran as `mix compile --no-deps-check
--warnings-as-errors`, `mix format --check-formatted`, and `mix test
--no-deps-check <files>`. A maintainer `mix precommit` (unsandboxed) is still
warranted before merge.
