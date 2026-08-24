# Durable Run Fleet Security Model

This document describes the security properties implemented by the durable, run-scoped agent
fleet and the limits that still apply. SQLite is the durable authority. OTP processes execute
that state; they are not durable identity or authorization by themselves.

## Trust boundaries

IexCode is a native host-control application. It can call model providers, execute commands,
and modify the selected checkout.

- Phoenix applies CSRF protection and local-host access checks. If
  `IEX_CODE_ALLOW_REMOTE=true` is set, the operator must provide authentication at the reverse
  proxy. Fleet APIs do not implement independent multi-user authorization.
- Model output, repository content, tool arguments, command output, and imported metadata are
  untrusted. The server derives the run's session, project, and root from persisted records;
  they are not selected by model/tool data.
- SQLite is the source of truth for fleet identity, generations, leases, controls, outcomes,
  usage, and event order.
- Registry names, PIDs, monitors, atomics, task links, and PubSub are node-local runtime
  mechanisms. They can disappear, duplicate, or become stale.
- Workspace locks coordinate cooperating IexCode paths. They do not create operating-system
  isolation.

## Implemented guarantees

### Durable identity and topology

Each logical worker is a `run_agents` row identified by its run, stable agent id/key, run
attempt, and lease generation. Parent relationships are checked against the same run and run
attempt by the manifest API. Immutable manifest drift is rejected rather than silently reusing
a row with a different role, adapter, parent, capability list, or configuration.

Fleet attachment refetches the run, checks its session/project relationship, loads the session
and project from storage, and uses the persisted project root. The runtime topology is bounded
to 32 workers and role-to-module selection is a closed allowlist of planner, explorer, coder,
and verifier agents.

Registry keys are run-scoped:

```text
{:run_agent, run_id, agent_id}
{:run_fleet, run_id, component}
```

There is no fallback from a durable agent lookup to a session-scoped worker. Registration is
validated against the expected PID, role, and generation after startup. A conflicting Registry
occupant fails closed. PIDs are runtime routing values only and are not persisted in fleet
control results.

### Hashed lease credentials and generation fencing

Each run fleet receives a cryptographically random bearer credential. The raw value remains in
the run-fleet supervision/runtime context. `run_agents.lease_owner` and
`run_agent_controls.claim_owner` store only its SHA-256 hash; both schema fields are redacted
from `Inspect`, and database checks require the 64-character lowercase hexadecimal form.
Comparisons hash the presented credential and use constant-time comparison.

Claiming an agent increments its generation. Heartbeat, transition, usage, control claim,
control resolution, and steering consumption verify the current credential, generation,
active lifecycle, and unexpired lease at the durable boundary. Expired generations cannot be
renewed. Reconciliation uses conditional owner/generation/status/expiry predicates so a fresh
heartbeat cannot be overwritten by a stale reconciliation read.

The runtime owner passed to agent and operation code contains only `run_id`, `agent_id`, and
generation. It does not contain the raw bearer credential. Fleet runtime calls route through
the owning `FleetManager`, which supplies the credential privately and refreshes the durable
row before accepting progress, completion, or usage.

### Scoped, ordered controls

Targeted controls bind:

```text
run_id + run_agent_id + target_generation + sequence + idempotency_key
```

The selected agent is fetched within the selected run, and the manager rejects controls from a
different run. Enqueue requires an active run and controllable agent. It allocates a monotonic
per-agent sequence transactionally. Reusing an idempotency key returns the existing control
only when kind, generation, payload, and requester match; conflicting reuse is rejected.

Only the oldest open control may be claimed. Claim and resolution are fenced by the current
hashed fleet credential, generation, live lease, target, and control lifecycle. A claimed
control acts as an ordering barrier. Claims older than the bounded claim timeout can be
reclaimed; stale-generation controls are superseded or rolled forward during a fenced
generation change. Restart has a dedicated transaction that advances the agent generation and
claims the head restart control together.

The manager replays open controls after rehydration and after heartbeats. Rejected controls
reconcile the desired state to the actual agent state. PubSub is not used to authorize or order
these actions.

### Durable, exactly-once steering consumption

A steering control is durably resolved as queued after validation. Consumption is a separate,
fenced database transaction. It selects queued steering in sequence order, changes the durable
result to `consumed`, and appends one `run.agent_steering_consumed` event. Later consumers no
longer match that row, so each control performs that durable queued-to-consumed transition
exactly once. Limits bound each drain, and consumption requires the live target generation.

This guarantee ends at the durable consumption checkpoint. A crash after that commit can stop
the coordinator before a downstream model observes the directive. It does not make downstream
model or native effects exactly once.

### Runtime ownership, pausing, and cancellation

Each run has a `RunFleetSupervisor` with a run-local task supervisor, dynamic agent supervisor,
and fleet manager. Fleet agents are started as temporary children, so an abnormal exit cannot
be automatically restarted under the old generation. The manager monitors the selected PID,
cancels its token, stops any registered child, and interrupts the fenced durable generation.

The primary planner, explorer, coder, and verifier work calls run through `FleetRuntime`. A
paused control token blocks new primary work until resume; a cancelled token rejects it.
Operation tasks inherit the fleet owner/control context, use the run-local task supervisor,
checkpoint the control token before the callback and progress effects, and are linked to their
owning agent. Run-wide stop enumerates only that run's fleet. Targeted pause, resume, restart,
and cancel do not enumerate other runs sharing the session.

### Recovery policy

The run-fleet supervision tree uses `:one_for_all`, and fleet agents themselves are temporary
children. A supervised manager-child restart tears down its sibling runtime children and
run-local operation tasks together while retaining the tree's private credential. The manager
rehydrates the manifest from SQLite, interrupts the prior incarnation through the credential
check, claims a higher generation, and replays recoverable controls. Persisted paused agents
restart paused. Old generations cannot report progress, usage, completion, or control outcomes
after replacement. Application/process loss still follows the outer run dispatcher's
interruption-and-explicit-retry policy; it does not silently resume the fleet.

Recovery does not replay arbitrary in-flight agent code. An uncheckpointed operation is
interrupted, and an explicit control/retry is required where the durable contract permits it.

### Redaction and notification boundaries

Fleet config, metadata, results, errors, and control payloads/results are size bounded and
reject recursively secret-shaped keys such as tokens, credentials, passwords, private keys,
and capabilities. Durable event sources and payloads do not contain the raw fleet bearer.
Workspace-lock read APIs and `Inspect` output redact their capability.

PubSub is a notification/projection channel, never authority. Consumers use durable ids and
sequences, and must tolerate dropped, duplicated, reordered, or stale messages. A PubSub tuple,
Registry entry, or live PID alone cannot authorize a fleet mutation.

### Usage accounting

Agent token, reported cost, latency, and request counts are recorded under the live generation
fence. Agent and parent-run totals update in one transaction. Provider-reported token usage can
fail the run and append budget/status events when the run token limit is exceeded; reported
cost does the same when `cost_budget_cents` is exceeded. The run dispatcher separately
enforces its configured worker wall-time limit.

## Remaining limitations

### No OS sandbox

Fleet and workspace fencing coordinate IexCode code paths; they are not a sandbox, container,
or worktree boundary. External editors, direct lower-level calls, independently launched
processes, hard links, mount/bind aliases, symlink/root swaps, and other physical path aliases
can bypass cooperative coordination.

### Workspace delegation is not agent-generation bound

The workspace gateway validates the outer run's private delegation reference, project, run,
session, covered resource, and live workspace capability immediately before cooperating
effects. The same run-level delegation is currently shared with fleet members. It does not yet
encode the individual agent id, generation, or cancellation epoch. A future subdelegation must
be revoked on agent pause/cancel/restart/expiry without revoking unrelated siblings.

### Native descendants may outlive cooperative cancellation

Run-local BEAM tasks and agent processes are supervised and linked, but a native command may
spawn descendants outside that process tree. Killing an owner or closing a port does not prove
that every OS descendant has stopped. Terminal ownership and workspace release therefore must
not be described as process isolation or proof of native cleanup.

### Budgets are accounted after use

Provider usage is settled after a response. There is no atomic pre-use reservation shared
across the run, agent subtree, and parallel agents. Crossing either `token_budget` or
`cost_budget_cents` fails the run when that reported usage is recorded, but neither value is a
pre-use hard ceiling: concurrent calls can overshoot by work already in flight. Hierarchical
token/cost allocations and reserve-before-start semantics remain to be implemented.

### General mutation replay is not checkpoint-safe

Control replay is durable and bounded, and steering consumption is exactly once. General LLM,
tool, filesystem, Git, terminal, and native effects do not yet have a universal checkpoint and
idempotency contract. Recovery must continue to interrupt rather than automatically replay an
uncertain mutation.

### Actor authorization remains local-user scoped

`requested_by` is audit data, not authentication. The current product assumes its protected
local operator boundary. Remote/multi-user deployments require an authenticated principal and
authorization policy before exposing fleet controls.

## Security verification checklist

- [x] Two runs in one session use disjoint Registry identities and stopping one leaves the
      other alive.
- [x] Unknown roles and conflicting Registry occupants fail closed.
- [x] Manifest bounds, parent scope, immutable-field equality, enums, lifecycle, and numeric
      invariants are checked.
- [x] Fleet bearer credentials are stored only as redacted hashes; the raw bearer is absent
      from durable events, public control results, and PubSub projections.
- [x] Heartbeats, transitions, usage, controls, and steering reject stale credentials or
      generations.
- [x] Duplicate controls are canonicalized by idempotency key; sequence order is enforced and
      abandoned claims can be reclaimed.
- [x] Restart advances generation atomically with its head control; stale workers are rejected.
- [x] Steering is consumed in order, under a live lease, at most once.
- [x] Paused/cancelled tokens gate new fleet work and run-local operation callbacks.
- [x] Abnormal fleet-agent exits do not auto-restart stale generations.
- [x] Manager-tree restart tears down old children and rehydrates higher generations.
- [x] Crafted run/session/project attachment scope is rejected.
- [ ] Add agent-generation-bound workspace subdelegation and revocation.
- [ ] Prove or quarantine uncertain native descendants before declaring cleanup complete.
- [ ] Add atomic hierarchical token/cost/time reservations before provider/tool dispatch.
- [ ] Add explicit checkpoint/idempotency contracts before replaying general mutations.
- [ ] Add authenticated actor authorization before supporting remote multi-user control.
