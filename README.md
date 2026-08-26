# IexCode

IexCode is a local-first desktop coding harness built with Elixir/OTP, Phoenix 1.8,
LiveView, SQLite, and xterm.js. It brings an agent session, the working tree, tests,
Git, and a real interactive terminal into one workspace.

The application combines supervised coding agents with a **durable, journaled run
plane**. Background work is queued in SQLite and claimed by leased OTP workers; run
state and an ordered event history are persisted independently of the browser. See
[`PROJECT.md`](PROJECT.md) for the architecture and remaining roadmap.

## Workspace

The main LiveView exposes ten connected tools:

| Area | Current capability |
| --- | --- |
| Kanban | Task CRUD, eight workflow states, priorities, assignees, filters, schedules, and subtasks |
| Swarm | Durable Mission Control for coding and deep-research runs; coding adds persisted dynamic fleets and per-agent controls, while research adds provider manifests and cited artifacts |
| Research | Dedicated deep-research workspace with exact level semantics, provider selection, recent runs, checksum-verified reports, and session-scoped prior-result attachments |
| Calendar | Monthly task view, task inspection/editing, manual “run now,” and supervised UTC schedule dispatch |
| Changes | Staged, unstaged, and untracked rails; inline/split diffs; hunk actions; branches and commits |
| Tests | Asynchronous ExUnit runs, parsed failures, AutoFix proposals, preview, apply, and rollback |
| AST | Elixir symbol search for modules, functions, macros, specs, and types, with jump-to-file |
| Chat | Persisted session conversation, model selection, tool-backed agent runs, and rich response rendering |
| Files | Searchable tree, multiple buffers, dirty tracking, save/revert, and jump-to-line |
| Terminal | Supervised native PTY with xterm.js, ANSI output, resize, signals, history, and quick actions |

Settings and the global command palette are available across the workspace.

## Execution model

IexCode deliberately operates on the selected project **in place**:

- Commands, tests, Git operations, file reads/writes, and the PTY run in the project root.
- IexCode does **not** create a Git worktree, container, or application sandbox for a run.
- Processes inherit the permissions of the user who started IexCode.
- Multi-file patches use preflight validation, atomic writes, and snapshots where that
  tool is used, but arbitrary terminal commands are not transactional.

This model is fast and transparent, but it is also powerful. Open only repositories
you trust, review proposed changes, keep valuable work committed, and do not expose the
development server to an untrusted network.

> Coding runs now hold a renewable, durable project reservation. Guarded editor,
> terminal, test, patch, and Git paths acquire compatible project/file/Git resources,
> wait or fail closed on conflicts, and expose ownership in Mission Control. This is
> **cooperative IexCode coordination**, not OS isolation: native processes and arbitrary
> in-process code that bypass the guarded entry points can still write the checkout.

## Requirements

- Elixir `~> 1.15` and a compatible Erlang/OTP release
- Node.js and npm for the xterm.js assets
- Git
- Python 3 and a POSIX environment for the native PTY shim (macOS/Linux)
- SQLite support required by `ecto_sqlite3`

The PTY implementation is POSIX-oriented. Windows has not been established as a
supported native-terminal environment.

## Setup

```bash
git clone <repository-url>
cd iex-code
mix setup
mix phx.server
```

Open [http://localhost:4000](http://localhost:4000). Development binds to loopback by
default.

`mix setup` fetches Elixir dependencies, creates and migrates the SQLite database,
installs npm dependencies, and builds the assets.

### Local Mix CLI

The Mix tasks use the same parser, execution-policy resolver, project/session scope
checks, request-key idempotency, and durable run records as the workspace composer.
They are local host-control commands, not a remote API.

```bash
# Enqueue explicit durable work in the current project
mix iex_code.run /run "inspect the supervision tree and fix the race"
mix iex_code.run /swarm "upgrade the authentication flow and verify it"
mix iex_code.run /goal "ship the release checklist"
mix iex_code.run /goal --draft "prepare the release checklist for review"
mix iex_code.run /research --level high "compare the available queue designs"

# Select an existing project/session and retain a stable retry identity
mix iex_code.run --project /path/to/project --session SESSION_ID \
  --request-key operator-request-42 /run "verify the failing boundary"

# Override bounded execution policy for this run only
mix iex_code.run --priority high --max-attempts 5 --token-budget 50000 \
  --cost-budget-cents 1500 --time-budget-minutes 45 --agent-max-turns 12 \
  /run "complete and verify the migration"
mix iex_code.run --swarm-agents 8 --swarm-retries 4 \
  /swarm "audit and harden the control plane"

# Keep this Mix node alive until the run reaches a terminal state
mix iex_code.run --wait --timeout 900 /swarm "fix and verify the regression"

# Inspect and control durable runs
mix iex_code.runs --project /path/to/project --limit 20
mix iex_code.control RUN_ID status
mix iex_code.control DRAFT_RUN_ID start
mix iex_code.control RUN_ID pause
mix iex_code.control RUN_ID resume
mix iex_code.control --request-key operator-steer-42 RUN_ID steer "focus on the lease handoff"
mix iex_code.control RUN_ID cancel
mix iex_code.control RUN_ID retry
```

`iex_code.run` accepts a project path or persisted project ID and an optional
session ID. A path launch reuses the most recent session for that project or
creates one when none exists. A supplied session must belong to the supplied
project. `--request-key` is useful when retrying an ambiguous submission: the
same key and semantics resolve to the same run, while conflicting reuse fails
closed. The task returns the generated key when it creates one. Mix-task options
belong before `COMMAND`; command-specific options such as `/goal --draft` and
`/research --level high` belong after their slash command.

Per-launch policy switches are strict and use the same validation as the
Settings page and workspace Run setup: priority is `low`, `normal`, `high`, or
`critical`; attempts are `1..10`; token and cost budgets are `1..10000000`;
time is `1..10080` minutes; agent/coder turns are `1..20`; swarm size is `4..32`;
and swarm retries are `0..10`. The turn snapshot bounds the single-agent loop or
each durable swarm coder model/tool loop independently, including every
diagnostic repair invocation; changing Settings later cannot alter an already
queued run. These switches contain no credentials and affect only the new run's
immutable execution-policy snapshot.

Use `iex_code.control DRAFT_RUN_ID start` to queue a reviewed goal draft; `start`
fails for non-draft runs rather than acting as an alias for resume.

`--wait` defaults to five minutes and accepts a maximum timeout of 24 hours.
Without `--wait`, the command returns after durable enqueue; the short-lived Mix
VM deliberately starts no dispatcher, scheduler, or run worker. A continuously
running IexCode desktop/server node pointed at the same SQLite database claims
and executes queued work. Pause, resume, and steering are stored as generation-
scoped `RunControl` receipts for that lease-owning node to poll and acknowledge;
`--request-key` makes an ambiguous control retry idempotent. Cancel writes durable
cancellation intent, while draft start and eligible retry perform only their
validated database transition. Status and list are read-only database clients.
If the only executing BEAM instance exits during an active run, startup
reconciliation marks that run `interrupted` rather than pretending it resumed.
`--json` is available on all three tasks and deliberately omits run metadata,
execution-policy internals, credentials, and provider endpoints. Run listing is
bounded to 20 rows by default and 100 at most.

The shared command matrix is:

| Input | Workspace behavior | Mix CLI behavior |
| --- | --- | --- |
| Ordinary text | Uses the configured prompt dispatch. Interactive dispatch uses the live session; background dispatch uses the selected single-agent or swarm mission. The workspace also owns its explicit Typed DAG and Research setup modes. | Uses the configured dispatch policy. A result that resolves to interactive is rejected because a Mix task has no live conversation transport. |
| `/chat OBJECTIVE`, `/ask OBJECTIVE` | Explicit live, process-local conversation. | Rejected as interactive. |
| `/run OBJECTIVE` | Durable bounded single-agent model/tool loop (`coding_agent` / `single`). | Same durable run. |
| `/swarm OBJECTIVE` | Durable run-scoped coding fleet (`coding_swarm` / `swarm`). | Same durable run. |
| `/goal OBJECTIVE` | Durable swarm goal; the global goal policy may queue it or save it as a draft. Entering `/goal` alone opens the goal form. | Same durable goal; an objective is required. |
| `/goal --draft OBJECTIVE` | Always creates a durable draft. | Same durable draft. `--wait` is rejected until the draft is started. |
| `/research [--level low\|medium\|high\|ultra] OBJECTIVE` | Exact static `dag_v1` research. Entering `/research` alone opens the Research workspace. | Same exact research launch; an objective is required. |
| `/deep_research`, `/deep_research N` | Opens the same-session ready-result picker or attaches result `N`; it does not launch research. | Rejected as a non-durable UI action. |
| `/kanban` | Navigation action. | Rejected as a non-durable action. |
| `/help` | Lists the supported exact slash commands. | Prints the same supported-command list. |

Durable single-agent work is not the old one-request chat path. It runs a
bounded multi-turn model/tool loop, journals each tool call as a `RunCommand`,
checks pause/cancel/lease authority at model and tool boundaries, consumes
run-scoped steering between turns, and persists the final assistant message.
It still does not make arbitrary tools transactional or automatically resume
an instruction after process loss.

### Model providers

Open **Settings** at `/settings`, or `/sessions/:id/settings` when returning to a
specific session. Both routes edit the singleton **global defaults** row; the
session route supplies context and a return destination, not a per-session
settings record. Existing sessions retain their persisted model/provider/
temperature until changed from the workspace, while new durable work snapshots
the effective, secret-free execution policy at submission. Credentials,
provider endpoint maps, and arbitrary settings data are excluded from that run
snapshot.
Durable coding policies retain only a SHA-256 identity of the effective model
provider/model/base-URL route. Credentials may be rotated, but changing that
non-secret route makes queued and in-progress single-agent or swarm model calls
fail before transport; interactive chat intentionally continues to use current
live settings.

The Settings page covers model defaults and credentials, prompt dispatch,
single/swarm/research mission defaults, priority and budgets, maximum agent
turns, goal auto-start, fleet size/retries, tool defaults, exact research caps,
ranked-provider readiness/order, editor auto-save, provider-reported usage, and
read-only runtime facts. Blank credential fields preserve saved values; the
explicit **Remove credential** actions clear them.

Configure an OpenAI-compatible or Anthropic endpoint, API key, default model,
temperature, and token limit there. The model gateway has first-class
OpenAI-compatible and Anthropic adapters. A Gemini model may be used when exposed
through a compatible endpoint; a direct general-purpose Gemini chat transport and local-model
transports remain roadmap work. This is distinct from the grounded Gemini search transport below.

The research gateway is independent of the model transport. It includes normalized
adapters for **Tavily, Brave, Exa, Perplexity Search, Firecrawl Search, Linkup Search,
Serper, SerpApi, Google Programmable Search, Bing, SearxNG, and DuckDuckGo**, descriptor
metadata, deterministic round-robin result interleaving,
URL deduplication with cross-provider provenance, partial failure reporting, and bounded
concurrency. Bing is a retired compatibility adapter and is used only when explicitly
requested; Google Programmable Search is closed to new customers and marked sunsetting
on January 1, 2027, and the credential-free DuckDuckGo HTML adapter is marked unofficial.
Perplexity uses its structured Search API rather than Sonar, and Linkup requests ranked
`searchResults` rather than its synthesized `sourcedAnswer`. A separate programmatic
grounded-answer plane implements OpenAI Responses `web_search`, Anthropic Messages
`web_search_20260318`, and Gemini Interactions `google_search`; Azure Foundry remains an
explicitly unsupported descriptor until its project-specific authentication and connection
contract can be represented safely. Public source fetches reject local/private/
link-local/reserved destinations, validate every DNS answer and redirect, pin the
validated address against DNS rebinding, restrict content types, and cap time and bytes.

Use **Run setup** in the composer or the `/research` command to queue the same exact
`dag_v1` deep-research workflow as the dedicated Research page. New launches use the exact
`low`, `medium`, `high`, or `ultra` policy; the quick/standard/deep setting remains only for
already-persisted `legacy_v1` compatibility. Existing legacy research rows remain executable by
their fixed-stage runner and are never silently reinterpreted. No-key or all-provider failure is
reported honestly, and the harness does not invent a report.

Every newly created legacy or DAG deep-research run receives a monotonically increasing integer
result ID in the same SQLite transaction. A successful legacy runner or DAG finalizer commits
exact `_APP_DIR/research/<id>/result.md` and `_APP_DIR/research/<id>/report.html` paths through
content-addressed, symlink-rejecting storage before the result becomes ready. The HTML is a
self-contained, script-free rendering. Open, HTML-download, and Markdown-download routes read the
files through their recorded SHA-256 digests and fail closed on missing or changed content. Those
routes retain the application's trusted-local-user boundary; they are not multi-user
authorization.

Open the dedicated **Research** workspace at `/research`, or use `/sessions/:id/research` for a
specific session. It lists recent investigations and ready numbered reports. The chat command
`/deep_research` opens a session-scoped picker; `/deep_research N` selects one ready result by
number. Up to 12 selected reports can be injected server-side into the next ordinary prompt as
bounded, checksum-verified, explicitly untrusted evidence. This attachment mechanism does not
create a new durable research agent. For a follow-up Research launch, the run instead snapshots
immutable same-session result ID/checksum references: the raw objective alone drives external
search queries, while the verified prior-report bodies are supplied only to final synthesis as
untrusted, non-citation context under the same 90 KB aggregate ceiling.

The tab also launches durable static `dag_v1` research with exact `low`, `medium`, `high`, and
`ultra` levels and one or more selected ranked-search providers. Their contracts are respectively 1/2/3/4
multistep rounds and bounded asynchronous query-fanout ceilings of 2/3/4/10, with one logical lead
per step. Ranked and grounded search implement that fanout as handler-internal `Task.async_stream`
work, not durable `run_agents` with independent identity or controls. Run-level
pause/resume/cancel still apply. A research run has one whole-run attempt: paid provider work is
not replayed by whole-run retry, although replay-safe/receipt-backed DAG steps retain their own
bounded attempt semantics within that authoritative run. Grounded-search handlers are registered for typed
manifests, but grounded-provider selection is not exposed by the launchers. The composer,
`/research`, and dedicated page all create exact DAG runs; only already-persisted legacy rows keep
the legacy execution path.

Research settings persist the default exact level, maximum sources, conflict-audit requirement,
maximum cost in cents, maximum tokens, and time budget in minutes, together with ranked-provider
configuration and order. **Forty sources is a hard launch and final-envelope boundary**, not just
a UI suggestion: values outside `1..40` are rejected rather than truncated. The launcher requires
at least one selected, automatically selectable ranked provider and fails before inserting a run
when the selection is empty or not ready. Readiness requires an enabled, non-retired adapter plus
its required key and, for SearxNG or Google Programmable Search, its required instance/engine
identifier. Configure these values in **Settings**. Provider credentials remain outside the
manifest and are resolved from live settings immediately before an effect. A credential-only
rotation does not invalidate queued research. The launcher instead persists a secret-free digest
of the selected providers' effective order, endpoints, engines/options, and synthesis route; a
change to that non-secret routing fails before the next paid provider effect and requires a newly
reviewed launch.

The research adapter computes conservative token and cost reservations from the complete static
manifest. When an explicit token or cost budget is supplied, it must admit those declared
reservations or launch fails before run insertion; an omitted cap defaults to the manifest
requirement. Provider effects reserve declared request/token/cost ceilings before dispatch and
settle actual or conservative usage through generation-fenced receipts. This is deliberately
stricter than coding-run accounting, which depends on usage reported after provider responses.

API keys are currently persisted in the local SQLite settings row. They are not stored
in an operating-system keychain or encrypted vault. Protect the database file and do
not share it. Settings structs redact credentials when inspected, and settings writes
disable SQL query logging so credentials are not emitted as bind parameters.

### Durable coding fleets

When the dispatcher claims a durable coding run, it materializes a persisted run-scoped
fleet. The topology always contains one planner, one coder, one verifier, and a bounded
number of explorers; explorers run concurrently and are merged in stable ordinal order.
The configured agent count is now an execution policy (bounded to 4–32 for the current
legacy coding engine), rather than display-only state.

Every fleet member has a stable run-local identity, lifecycle, desired state, heartbeat,
generation-fenced lease, task/progress, usage, and ordered targeted controls in SQLite.
Mission Control renders those records through a LiveView stream and can pause, resume,
cancel, restart, or steer one exact worker without enumerating every agent in the session.
Each card also shows the latest bounded durable control receipt. Steering distinguishes a
request that is persisted and queued from guidance that the current worker generation has
consumed, instead of treating dispatch as proof of consumption.

The persisted objective, run kind/mode, and execution-engine identifier form an execution
manifest that application changesets do not permit later lifecycle updates to rewrite.
Creation and retry validate the supplied manifest through its selected engine, claims select
only engines that are currently available, and the dispatcher revalidates a claimed manifest
before preparation or execution. `dag_v1` is available for finite, immutable workflows whose
kinds exist in its closed registry; unknown kinds and mutation handlers fail closed. Existing
`legacy_v1` rows are never silently reinterpreted as DAGs. Within a live legacy
run, agent calls resolve the current PID and lease generation from the run fleet
immediately before invocation. An operator restart after an agent crash can advance the
generation and let a later phase bind to the replacement, while the abandoned generation
remains unable to report state or usage.

The older interactive-session cards remain clearly labeled role templates and are not used
as durable fleet truth.

### Durable goals and recovery guarantees

Autonomous goals created from the workspace are durable from submission onward. Each form
submission carries a stable session-scoped request key, backed by a unique SQLite index, so a
browser retry or concurrent duplicate resolves to the same run instead of launching duplicate
fleets. The goal title and complete instructions are retained in run metadata and the executable
objective. Unchecking **Queue for execution now** creates a real `draft` run; Mission Control can
start or cancel that draft later without relying on LiveView or `SessionServer` memory.
The exact `/goal OBJECTIVE` command uses the same intake, and `/goal --draft OBJECTIVE` always
creates the same durable draft contract. Entering `/goal` without an objective in the workspace
opens the richer goal form rather than inventing an objective.

Execution authority is the complete tuple of run ID, run attempt, lease owner, lease generation,
and unexpired lease. Progress, usage, controls, DAG compensation, child terminalization, and final
run settlement validate that tuple. Parent, current-attempt graph, and fleet terminalization share
one transaction, so a stale worker cannot finish children after a retry has taken ownership.
Control claims similarly record their target attempt/generation, claim generation, and expiry;
startup and periodic reconciliation reject stale controls and recover abandoned claims.

Only one swarm coordinator may own a session across connected Erlang nodes. `SessionServer`
adopts that owner after its own restart, routes durable pause/resume/cancel/steer through the run
control plane, and treats prompts received while paused as steering rather than starting another
coordinator. Fleet recovery uses bounded retries that extend beyond the old lease horizon,
rehydrates interrupted agents, replays controls fairly in bounded batches, and uses concurrent
graceful shutdown with a forced-stop fallback.

Operational telemetry deliberately avoids IDs, prompts, commands, and arbitrary error strings as
metric tags. A supervised bounded `MetricsStore` consumes operation, terminal, and 30-second
control-plane aggregates for runs, fleets, DAG attempts, controls, approvals, and workspace locks.
SQLite remains authoritative; the store is a restartable local health view, not another ledger.

### Typed DAG workflows

Run setup also exposes an explicit **Typed DAG** mission. `dag_v1` accepts a
static JSON manifest, canonicalizes and hashes it before persistence, and schedules dependency
roots and fan-in nodes from SQLite. Independent ready nodes run concurrently through a bounded
runner (four by default, configurable up to 32); append-only step-attempt rows record the run
generation, step generation, lease, heartbeat, retry timing, checkpoint receipt, and terminal
outcome. Claims and completions are generation-fenced, and Mission Control rehydrates a layered
graph with readiness, dependencies, attempts, retry state, lease health, and checkpoint timing.

Version one intentionally has a closed handler catalog:

- `project_inventory` lists at most 2,000 immediate entries below a contained project path.
- `read_file` reads one contained, regular UTF-8 file up to 256 KB.
- `aggregate` combines the bounded durable results of one or more dependencies.
- `research_plan`, `research_ranked_search`, `research_grounded_search`,
  `research_evidence_merge`, `research_source_fetch`, `research_evidence_audit`,
  `research_report_synthesize`, and `research_report_verify` execute the finite research graph.

The three project handlers are replay-safe and pure/read-only. Research provider effects use
fenced pre-use reservations and bounded atomic response-payload replay. Intermediate research
contracts are canonical digested attempt results rather than durable subagent rows or materialized
`RunArtifact` rows; `DagFinalizer` reconciles verified Markdown into content-addressed
`Research.Results` Markdown and HTML directly, at startup, and on a bounded periodic pass. A manifest may contain at
most 128 nodes, 512 edges,
32 dependencies per node, 32 topological levels, and five attempts per node. Step params are
bounded JSON maps and checkpoint callbacks accept bounded JSON values (64 KB, depth 12, at most
512 items per collection); both reject secret-shaped keys. Handler kind is resolved only through
the closed registry—persisted module/MFA/closure configuration is not executable. The Run setup
editor accepts at most 256 KB of raw JSON before stricter canonical manifest checks run.

Run-wide pause/resume marks active attempts and cooperative tokens paused and stops new claims;
a short built-in read may still reach settlement before observing a checkpoint. Cancel
terminalizes current attempts; safe handler failures use durable exponential retry backoff; and
explicit run retry retains attempt history while resetting the same immutable logical graph
under a new run generation. Steering is not supported for `dag_v1`. Existing legacy coding and
research rows remain on `legacy_v1`; their descriptive dependency labels are never reinterpreted
by the DAG scheduler. The dedicated exact-level Research launcher creates new `dag_v1` rows.

## Verification

Run the project-required quality gate after changes:

```bash
mix precommit
```

The alias compiles with warnings as errors, removes unused dependency locks, formats
the project, migrates the test database, and runs the test suite. Useful narrower
commands include:

```bash
mix test
mix test test/iex_code_web/live/workspace_live_test.exs
mix format --check-formatted
mix compile --warnings-as-errors
```

The repository includes unit, LiveView, end-to-end, adversarial, concurrency, and PTY
tests. Historical pass reports under `.agents/` are development records, not a
substitute for running the gate on the current checkout.

## Current limitations

- Durable background runs and goal drafts survive LiveView disconnects and preserve their journal across
  application restarts. An orphaned active run still becomes `interrupted`; `dag_v1` can
  retry an expired replay-safe step while its parent run lease remains current, but process/app
  loss does not automatically resume the outer run. Explicit retry starts a new generation only
  when attempts remain. Exact research intentionally has one whole-run attempt, so interrupted or
  terminal research requires operator review and a new launch rather than replaying paid work.
- Legacy coding runs retain a fixed `prepare → execute` shell and fixed role phases. Their fleet
  topology is durable and dynamic, with bounded parallel explorers, and their dependency labels
  remain descriptive. Separately, `dag_v1` schedules finite immutable graphs of the three
  project-read handlers and eight registered research handlers with durable attempts, parallel
  readiness, leases, fencing, checkpoints, retries, and run-level controls. It is not a general
  coding/mutation DAG; unknown kinds still fail closed.
- Calendar work now has a supervised UTC cron scheduler with atomic claims, stable
  occurrence keys, recurrence, existing-run recovery, and stale-claim recovery. Rich
  notification and dead-letter workflows remain future work.
- Run events are sequenced in SQLite. The current LiveView reloads a bounded 500-event
  list rather than a LiveView stream or paginated tail, and normal chat does not yet
  persist every model token/reasoning delta as an event.
- Approval, command, and artifact records exist; a deny-by-default tool policy and full
  approval inbox are not yet enforced for every LLM tool call.
- Coding runs have worker leases plus renewable project-exclusive workspace reservations.
  Guarded file, patch, test, terminal, hunk, and Git actions use capability-authorized
  project/file/Git resources with wait records, heartbeats, fencing generations, and a
  live ownership view. The plane is cooperative: direct calls to lower-level mutation
  modules, external editors/processes, filesystem aliases not represented by canonical
  paths, and orphaned command descendants can bypass or outlive it.
- The project-read handlers declare `project_read_v1`; research handlers declare separate
  evidence/provider/fetch/model resource contracts and use the fenced provider-effect boundary.
  `dag_v1` still does not acquire per-step workspace-lock permits for native mutation. Mutation
  handlers require real resource admission and generation-bound delegation before registration;
  the native workspace boundary remains cooperative rather than an OS sandbox.
- Wall-clock budgets are enforced by the dispatcher. Token budgets accumulate and stop
  covered planner/coder/research boundaries when providers report usage. Durable fleet
  cost thresholds likewise fail a run after reported `cost_cents` crosses the configured
  limit. When either reported fleet threshold is crossed, the manager cancels and stops the
  run's sibling agents and terminalizes their durable rows rather than leaving a partially
  live fleet behind. These active fleet thresholds are not pre-use reservations, and providers
  that omit usage or cost cannot be measured without the still-planned versioned pricing ledger.
  Registered research DAG provider effects instead use fenced pre-use reservations. Universal
  pricing and a reservation plane shared with coding/legacy research remain future work.
  Forced cancellation stops the supervised BEAM worker; a tool-spawned external descendant
  may still require OS-level cleanup.
- Pause, resume, cancel, restart, and steer have ordered, idempotent per-agent records in
  addition to run-wide controls. Fleet work is run-scoped, generation-fenced, and uses a
  run-local supervised task group. Checkpoint-safe pause/cancellation is covered in the
  integrated agent/provider/tool paths; OS-native descendants and replay of a control
  interrupted between an uncheckpointed effect and acknowledgement still require the
  conservative recovery rules documented in `docs/RUN_FLEET_SECURITY.md`.
- DAG pause/resume/cancel and whole-run retry are supported, but per-node operator controls,
  manual approval-gate handlers, steering, and dynamic graph expansion are not. Checkpoint
  rows are fenced and bounded; there is no automatic checkpoint resume. Current recovery is
  limited to starting a new attempt for the closed replay-safe handlers, not resuming arbitrary
  code at an instruction boundary.
- The research DAG provider plane has bounded reservation/effect accounting, but broad versioned
  pricing across every provider path remains incomplete. Coding and legacy research still account
  after responses and can overshoot through already in-flight work.
- The dedicated exact-level launcher now enqueues the bounded static research graph and selects
  ranked-search providers. Its eight handlers and direct/startup finalizer are registered, and an
  end-to-end finite-DAG test reaches checksum-addressed Markdown and HTML. Full current-checkout
  precommit plus Ego Lite desktop/mobile smoke remain the final release proof; this documentation
  does not claim that gate has passed.
- Research fanout is handler-internal `Task.async_stream` work, not persisted or independently
  controlled fleet agents. Static manifests cannot expand dynamically; grounded-provider UI
  selection, durable per-subagent identity/control, broader pricing, and mutation handlers remain
  future work.
- Rollback ownership is durable and run-scoped for MultiPatch/AutoFix mutations. Direct
  file, Git, test, and terminal effects are coordinated while they execute but are not
  made transactional or added to the rollback manifest.
- The shared model streaming client bounds successful streamed responses to 2 MB and
  collected error bodies to 64 KB. Structured error collections/depth are bounded, and
  exact credentials supplied through recognized authentication headers are redacted from
  HTTP, network, request, and callback-error results. These transport limits do not replace
  provider/tool authorization or make model output trusted.
- API keys still need OS-keychain/envelope-encrypted storage.

These are the focus of the next phases in [`PROJECT.md`](PROJECT.md).

## Production notes

Production releases require at least `DATABASE_PATH`, `SECRET_KEY_BASE`, and an
appropriate `PHX_HOST`; set `PHX_SERVER=true` to start the endpoint. The production
endpoint also binds to loopback unless `IEX_CODE_BIND` explicitly overrides it.

IexCode is a development-stage, trusted-local-user tool. Browser routes are guarded by
a loopback address/host check. `IEX_CODE_ALLOW_REMOTE=true` is an explicit escape hatch,
not an authentication system; do not enable it without an authenticated, hardened proxy.
Multi-tenant isolation and encrypted secret storage are not present.
