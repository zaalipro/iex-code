# IexCode Product Architecture and Roadmap

## Product intent

IexCode is a local-first, native-workspace coding harness. Its purpose is to let a
developer delegate work to supervised agents, observe every operation, inspect and
edit artifacts, run verification, and decide what reaches Git without leaving one
Phoenix LiveView workspace.

The application includes a **durable asynchronous run system**: coding and deep-research
runs are queued in SQLite, claimed with leases, serialized per project, and recorded in
an ordered event journal. Run-scoped controls, research evidence, and citation-bearing
reports are durable. The next phases generalize these typed workflows into dependency-aware
parallel execution, governed tools, and resumable checkpoints.

“Asynchronous” does not mean “unobservable.” A run must always expose its plan,
dependencies, current owners, tool activity, artifacts, verification, cost, and the
decisions it is waiting for.

## Non-negotiable execution boundary

IexCode operates directly in the selected project root.

- No per-run Git worktrees.
- No containers or application sandbox layer.
- No shadow copy that becomes a second source of truth.
- File, Git, test, and shell operations use the native workspace and the launching
  user's OS permissions.

The safety strategy is therefore **coordination and review**, not isolation. Current
safety mechanisms include path containment for workspace tools, patch preflight and
staleness validation, atomic multi-file patch writes with snapshots, process timeouts,
supervision, and explicit rollback/commit choices in supported workflows. They do not
make arbitrary shell commands reversible.

The current cooperative lock plane persists project, file, and Git resources with
read/write/exclusive modes, wait records, lease heartbeats, fencing generations, and
opaque capabilities. Coding runs reserve the project; guarded editor, patch, test,
terminal, hunk, and Git paths coordinate with that reservation and surface conflicts.
This does not mediate arbitrary native processes or lower-level code that bypasses the
gateway, and lease expiry alone cannot prove that an orphaned OS descendant stopped.

## Current system

### Runtime topology

```text
IexCode.Application
├── IexCode.Repo (SQLite/WAL)
├── Phoenix.PubSub
├── Session Registry
├── Agent Registry
├── Task.Supervisor
├── WorkspaceLocks (capability gateway + private delegation registry)
├── SessionSupervisor (DynamicSupervisor)
│   └── SessionServer per active coding session
├── AgentSupervisor (DynamicSupervisor)
│   ├── PlannerAgent
│   ├── ExplorerAgent
│   ├── CoderAgent
│   └── VerifierAgent
├── TerminalSupervisor (DynamicSupervisor)
│   └── TerminalSession per active terminal
├── RunDispatcher (leased durable background workers)
├── Kanban.Scheduler (due/recurring task claims)
├── MultiPatch Snapshot Owner (durable SQLite + ETS cache)
└── IexCodeWeb.Endpoint
    └── WorkspaceLive
```

`SessionServer` owns the live lifecycle of a coding session. `SwarmCoordinator` runs
the fixed Planner → Explorer → Coder → Verifier workflow and can iterate after failed
verification. `OperationManager` executes supervised tasks, persists operation status,
monitors crashes, and broadcasts telemetry. LiveView subscribes to session and terminal
topics and rehydrates messages, operations, durable runs, steps, and sequenced events
when it mounts. `RunDispatcher` is independent of the socket and allows only one active
background run per project.

### Persisted records

| Record | What is persisted now |
| --- | --- |
| Project | Name, native root path, description, last-opened time |
| Session | Project, model/provider selection, swarm flag, lifecycle status |
| Message | Role, content, tool-call metadata, token/cost fields |
| Operation | Parent, agent, type, progress, result/error, PID string, timings |
| Kanban task | Workflow state, priority, assignee, subtasks, schedule, metadata |
| App settings | Model endpoints/keys plus eight search adapters, provider order, and research defaults |
| Run | Objective, typed executor, lifecycle, priority, progress, budgets, attempts, lease, timings |
| Run step | Typed coding nodes plus research plan/search/fetch/synthesis nodes, dependencies, attempts, result/error |
| Run event | Per-run monotonic sequence, type, source, bounded payload, occurrence time |
| Run command/control/approval/artifact | Tool command idempotency, ordered run controls, review decisions, cited reports, and artifact metadata |
| Mutation snapshot | Durable native-workspace rollback manifest, mirrored in ETS |
| Workspace lock | Canonical resource, mode, owner/run/session, batch wait state, lease, and fencing generation; capability stored only as a hash |

The current graph is deliberately small. General fan-out/fan-in DAG planning, durable
model-token deltas, enforced approval policy, and resumable checkpoints remain future
work.

### Workspace surface

| Surface | Implemented today |
| --- | --- |
| Kanban | CRUD, eight states, drag/move actions, filters, assignees, priorities, subtasks, and scheduling fields |
| Swarm | Mission Control with coding/deep-research manifests, budgets, ordered controls, evidence/report preview, plus the fixed four-agent coding swarm |
| Calendar | Month navigation, task editing/run-now, plus a supervised UTC cron scheduler with atomic claims, stable occurrence keys, recurrence, and stale recovery |
| Changes/Git | Status rails, inline/split diffs, stage/unstage, hunk operations, branches, fetch/pull, commit generation and commit |
| Tests/AutoFix | Async test subprocess, ANSI cleanup, structured failures, heuristic proposals, preview/apply/rollback and re-verification |
| AST | Elixir modules, functions, private functions, macros, specs, and types with editor jumps |
| Chat | Persisted messages, model switching, markdown/thinking presentation, tool-backed single-agent or swarm dispatch |
| Files/Editor | Tree/search, multiple buffers, dirty state, save/revert/close, jump-to-line, code insertion |
| Terminal | Native supervised PTY, xterm.js, input/signals/resize, scrollback/search, agent occupation, quick actions |
| Global controls | Settings, project/session selection, goal controls, usage view, and Cmd/Ctrl+K palette |

### Developer-tool layer

- `IexCode.Tools.ASTSearch`: Elixir AST symbol discovery.
- `IexCode.Tools.MultiPatch`: AST/exact/fuzzy matching, preflight validation,
  atomic writes, snapshots, and rollback.
- `IexCode.Tools.TestRunner`: native `mix test` execution and structured parsing.
- `IexCode.Tools.AutoFix`: bounded heuristic repair proposals.
- `IexCode.Tools.Git`: native status, diff, staging, branches, pull/fetch, and commit.
- `IexCode.Tools.TerminalServer`: supervised native interactive terminal facade.
- `IexCode.LLM`: OpenAI-compatible and Anthropic streaming, retry, fallback,
  circuit breaking, SSE parsing, and UTF-8 boundary handling.
- `IexCode.Research`: normalized Tavily/Brave/Exa/Serper/Google/Bing/SearxNG/
  DuckDuckGo federation, provider lifecycle descriptors, rank-interleaved results,
  duplicate-source provenance, hardened public fetching, evidence retention, and cited synthesis.

### Current lifecycle

```text
user prompt / manual goal
        │
        ▼
SessionServer ──starts──▶ supervised task
        │                       │
        │                single agent or
        │                fixed swarm loop
        │                       │
        ├◀──── PubSub telemetry ┤
        │                       │
        └── persists messages and operation summaries
```

Interactive session work survives a LiveView disconnect but not an application restart.
Durable background runs additionally survive process loss as records: on boot an expired
lease becomes `interrupted` and must be retried explicitly, preventing partial native
workspace effects from being replayed blindly.

## What is current, partial, and planned

| Capability | State | Notes |
| --- | --- | --- |
| Supervised OTP agents and operations | Current | Dynamic supervisors, registries, monitored tasks |
| Live PubSub progress | Current | Low-latency but ephemeral transport |
| Durable messages and operation summaries | Current | Rehydrated by LiveView |
| Native PTY and developer tools | Current | Execute in the real project root |
| Atomic MultiPatch rollback | Current | Applies only to writes performed through MultiPatch |
| Pause/resume/cancel/steer | Current | Ordered run-scoped control records and isolated delivery; restart replay/in-flight interruption remain partial |
| Fixed four-agent correction loop | Current | Sequential domain workflow, not a general scheduler |
| LLM streaming transport | Current | Parser/callback support exists |
| Token-by-token durable chat events | Partial | Normal session flow currently publishes the completed message |
| Calendar recurrence | Current | Supervised UTC polling, due claims, recurrence, stale recovery, and durable run enqueue |
| Model providers | Partial | OpenAI-compatible and Anthropic model transports; eight first-class web-search adapters are separate and current |
| Configurable swarm-agent count | Partial | Setting persists, but engine topology remains four canonical roles |
| Durable run/event model | Current | Transactional run/step/event/command/approval/artifact records; checkpoints remain planned |
| Run budgets | Partial | Wall time and provider-reported tokens enforced at covered boundaries; cost/pricing enforcement remains planned |
| Dependency-aware parallel DAG | Partial | Research has typed plan/search/fetch/synthesis nodes and provider fan-out; arbitrary DAG scheduling/locks remain planned |
| Native workspace coordination | Current cooperative baseline | Durable batched project/file/Git resources, FIFO-oriented waits, capability checks, heartbeats, fencing, dispatcher ownership, guarded UI/tools/terminal, and Mission Control; native bypass/physical-alias hardening remain |
| Approval and durable command records | Partial | Command idempotency keys and approval records exist; policy enforcement/inbox UX remain planned |
| Restart reconciliation | Partial | Expired workers become interrupted; safe checkpoint resume is not implemented |
| Automatic calendar worker | Current | Supervised claims, stable occurrence keys, recurrence, stale recovery, and existing-run reuse |
| Direct Gemini/local adapters | Planned | Compatible endpoints can be used today through OpenAI adapter |

## Target asynchronous architecture

```text
                         ┌───────────────────────┐
user / calendar / API ──▶│ durable Run Command  │
                         │ inbox                 │
                         └──────────┬────────────┘
                                    ▼
                         ┌───────────────────────┐
                         │ Run Dispatcher        │
                         │ claim + lease + limits│
                         └──────────┬────────────┘
                                    ▼
                         ┌───────────────────────┐
                         │ Run Supervisor        │
                         │ dependency scheduler  │
                         └──────┬─────────┬──────┘
                         ready steps      │ events
                                ▼         ▼
                   ┌───────────────┐  ┌─────────────────┐
                   │ agent / tool  │  │ append-only Run │
                   │ workers       │  │ Event journal   │
                   └───────┬───────┘  └────────┬────────┘
                           │ artifacts          │ replay/live tail
                           ▼                    ▼
                   ┌───────────────┐  ┌─────────────────┐
                   │ native locked │  │ LiveView run    │
                   │ workspace     │  │ console         │
                   └───────────────┘  └─────────────────┘
```

PubSub remains the fast notification layer. SQLite is the source of truth. A consumer
receiving a notification reads events after its last sequence number; dropped or
duplicated notifications therefore do not lose state.

### Durable records and remaining extensions

The following describes both the implemented ledger and the fields still needed for
the target scheduler. Items explicitly marked planned are not current behavior.

#### Run

- Owns a goal across process and socket lifetimes.
- Current states are `queued`, `running`, `paused`, `completed`, `failed`, `cancelled`,
  and `interrupted`; a distinct review-waiting state is planned.
- Stores priority, token/cost/time budgets, attempts, worker lease, and the latest event
  sequence. General execution policy and checkpoint cursors are planned.

#### Run step

- A typed unit of agent or tool work.
- Stores dependencies, params, result/error, attempts, progress, timestamps, and status.
  Per-step leases/timeouts and general ready-node scheduling are planned.
- Coding dispatch currently executes a fixed `prepare → execute` graph. Research adds
  durable plan/search/fetch/synthesis nodes and concurrent provider fan-out, but the
  dispatcher does not yet schedule an arbitrary dependency DAG.

#### Run event

- Append-only and monotonically sequenced within a run.
- Currently records run/step transitions, progress, command/approval/artifact creation,
  retries, and related metadata. Lock state has its own durable ledger and PubSub topic;
  model deltas and complete tool I/O remain planned.
- `(run_id, sequence)` is unique. Events do not currently have a producer idempotency key.

#### Artifact

- Stores typed artifact metadata and a URI linked to a run and optional producing step.
- Checksums and arbitrary metadata are supported; enforced workspace revision and
  lifecycle status are planned.

#### Run command, control, and approval

- Run commands have per-run idempotency keys; approval request/decision persistence APIs exist.
- Run controls have per-run monotonic sequences and idempotency keys, are claimed and
  resolved durably, and are delivered over run-isolated PubSub topics. A general replaying
  consumer for pending controls after dispatcher restart is not yet implemented.

#### Workspace coordination ledger

- Coding runs acquire a renewable project-exclusive batch before their executor starts;
  a conflicting claim remains durably waiting and keeps its requested ordering.
- Resource batches are all held or all waiting. Project, file, and Git resources support
  read/write/exclusive conflicts, opaque capability checks, heartbeats, expiry, and
  monotonically increasing fencing values while retained history exists.
- A private, unforgeable delegation context lets nested run tools reuse the outer
  reservation without distributing the raw capability. Read APIs, PubSub, Inspect,
  LiveView assigns, run metadata, and events expose redacted rows only.
- Guarded Tools, AutoFix/MultiPatch production paths, WorkspaceLive editor/Git/hunk/test
  actions, and terminal command/input lifecycles assert ownership immediately before
  their effect and release after cleanup. Mission Control and editor/terminal banners
  show held/waiting state without exposing capability or arbitrary owner strings.
- Coordination is still cooperative in the native checkout. Direct lower-level module
  calls, external editors/processes, hard-link or mount aliases, symlink/root swaps after
  validation, and orphaned subprocess descendants are outside a database lock's physical
  enforcement. It is not isolation, a sandbox, or a worktree.

## Target scheduler invariants

1. **Database state wins.** OTP processes are executors and caches, not the sole record
   of a run.
2. **At-least-once dispatch, idempotent effects.** Claims may be retried; step effects
   must use stable keys and preconditions.
3. **One ordered event stream per run.** Every state transition has a sequence number.
4. **No guarded write without ownership.** Current production mutation entry points hold
   and reassert a compatible workspace/file/Git capability. Universal physical path
   identity and revision/digest fencing across every lower-level API remain hardening work.
5. **Review is a state.** Waiting for a human does not occupy a worker or masquerade as
   running.
6. **Cancellation is cooperative, then forceful.** Stop new dispatch, signal active
   work, terminate after a deadline, and record the final outcome.
7. **Recovery is deterministic.** Current expired run leases become `interrupted` and
   require explicit retry; future checkpoints may resume only where a tool contract permits.
8. **History is bounded in memory, complete on disk.** The database journal is durable;
   cursor pagination and a windowed LiveView stream remain planned.

## Delivery roadmap

### A0 — Documentation and baseline

**State: current work**

- Maintain one product description covering the complete nine-tool workspace.
- Treat `mix precommit` on the current checkout as the quality gate; historical agent
  reports are supporting context, not current proof.
- Record platform and native-execution limitations explicitly.

### A1 — Durable run ledger

**State: run/step/event ledger implemented; checkpoints planned**

- Run, step, event, artifact, command, and approval persistence is implemented.
- Add explicit checkpoint persistence and recovery contracts.
- Centralize validated state transitions.
- Append events transactionally with their corresponding state change.
- Build session-history migration/adapters without breaking existing sessions.

**Exit:** a queued run and its event history survive an application restart. Cursor-based
storage replay is implemented; cursor-driven LiveView pagination remains in A5.

### A2 — Dispatcher and recovery

**State: leasing/reconciliation and ordered run controls implemented; checkpoint resume planned**

- Claim queued runs with renewable leases.
- Reconcile expired run/step claims on boot.
- Replay pending pause/resume/cancel/steer controls safely after dispatcher restart and
  add acknowledgement checkpoints inside every long provider/tool call.
- The current executor passes the run id into the four-agent coordinator and records
  progress; extend that integration for durable controls and checkpoint recovery.

**Exit:** disconnecting the browser has no effect on execution, and restarting the app
recovers a run according to its checkpoint and tool capabilities.

### A3 — Native workspace coordination

**State: cooperative baseline current; physical enforcement/recovery hardening remains**

- Durable project/file/Git resource batches, modes, opaque capabilities, heartbeat/expiry,
  wait records, fencing, dispatcher integration, and lock UI are implemented.
- Guarded file/patch/test/Git/terminal entry points declare conservative resources and
  nested coding tools use an unforgeable delegation from the run reservation.
- Add descriptor-relative/no-follow filesystem effects, physical filesystem identity,
  directory/descendant and rename-endpoint rules, digest/revision preconditions, durable
  restart recovery for wait capabilities, and quarantine for uncertain native children.
- Extend enforcement into every lower-level mutation API so arbitrary in-process callers
  cannot bypass the gateway.
- Preserve direct native execution; do not introduce worktrees or sandboxes.

**Exit:** all application mutation paths and physical aliases are fenced, and promotion
cannot occur until an expired native holder is confirmed stopped or quarantined.

### A4 — Dependency-aware execution

**State: planned; depends on A1–A3**

- Replace the fixed pipeline as the only orchestration option with a persisted DAG.
- Dispatch independent ready steps concurrently within run/workspace/provider budgets.
- Support fan-out/fan-in, typed outputs, retry policies, deadlines, cycle validation,
  and manual gates.
- Make agent count and role topology an engine policy rather than a display-only value.

**Exit:** a run can prove parallel execution of independent read/analysis steps while
serializing conflicting mutations and verification prerequisites.

### A5 — Event-native LiveView console

**State: partial; durable ledger and bounded journal view implemented**

- Tail and replay sequenced events with cursor pagination, LiveView streams, and bounded memory.
- Publish real response/reasoning/tool deltas instead of only completed messages.
- Show DAG state, lock ownership, queue position, retries, approvals, tokens, cost, and
  latency from recorded data.
- Provide artifact-centric plan, patch, test, terminal, and commit review.

**Exit:** reload/reconnect produces the same run view without fabricated metrics or
lost deltas.

### A6 — Scheduled and provider-complete operation

**State: core scheduler and eight-provider research federation implemented; model transport expansion planned**

- Supervised due-task claims, recurrence, stale recovery, and durable run creation are implemented.
- Add explicit retry policy, notification, and dead-letter workflows.
- Maintain shared conformance tests for Tavily, Brave, Exa, Serper, Google, Bing,
  SearxNG, and DuckDuckGo; add more providers through the registry contract.
  Bing is retained as an explicitly requested retired compatibility adapter;
  Google is labeled legacy and the DuckDuckGo HTML adapter unofficial.
- Add first-class direct Gemini and local-model adapters only when their transport,
  cancellation, usage, and error behavior meet the same contracts.
- Add encrypted/keychain-backed secret storage before shared or remote deployment.

**Exit:** due-task outcomes are observable through retry/dead-letter UX, and each
supported provider passes a shared conformance suite.

## Deliberate non-goals for the near term

- Remote multi-tenant execution.
- Pretending native commands are harmless or reversible.
- Using Git worktrees as the concurrency model.
- Replacing OTP/PubSub with an external job system before the local durable model is
  proven.
- Claiming arbitrary autonomous code changes are safe without verification and review.

## Code map

```text
lib/iex_code/
├── application.ex              # supervision tree
├── engine/                     # sessions, agents, operations, swarm coordination
├── llm/                        # provider clients, SSE, UTF-8, retry/fallback
├── tools/                      # files, AST, patches, tests, Git, terminal
├── projects.ex / projects/     # native workspaces
├── sessions.ex / sessions/     # conversations and operation history
├── kanban.ex / kanban/         # tasks, schedules, workflow
└── settings.ex / settings/     # local provider/application settings

lib/iex_code_web/
├── live/workspace_live.ex
├── live/workspace_live.html.heex
├── components/workspace_components.ex
└── command_palette.ex

assets/js/hooks/terminal_hook.js # xterm.js LiveView bridge
priv/pty_shim.py                 # POSIX PTY bridge
test/                            # unit, integration, E2E, adversarial, stress, PTY
```

## Quality gate

Every implementation milestone ends with:

```bash
mix precommit
```

Feature work should add focused domain tests, LiveView interaction tests using stable
DOM IDs, restart/recovery tests for durable execution, concurrency tests for claims and
locks, and native-workspace smoke tests. Browser smoke testing is part of release
verification, but is not replaced by static template assertions.
