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

- Commands, tests, Git operations, file reads/writes, and the PTY run in the project root by default.
- Ordinary runs do **not** implicitly create a container or Git worktree unless `spawn_agent` (`isolate_worktree: true`), `IexCode.Sandbox.Worktree`, or `run_command` (`sandbox_policy`) is explicitly invoked.
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

## Lean defaults and bounded work

Fresh settings and missing run preferences select **durable background, single-agent**
work for ordinary prompts. Saved preferences are not migrated: a stored Swarm choice
still selects Swarm, whether it was deliberate or inherited from an older default.
To opt in, open **Settings → Run defaults**, set **Prompt dispatch** to **Durable
background** and **Default mission type** to **Single agent**, then save. This changes
subsequent applicable submissions, not existing sessions, drafts, or queued policies.

Use `/swarm OBJECTIVE` or select **Swarm** in **Run setup** for a coding fleet.
`/run` forces durable single; `/chat` and `/ask` remain live interactive single.
Goal, boost, teamwork, Typed DAG, and research retain their explicit workflows.
Single does not automatically escalate to Swarm.

### History and native tools

- Chat uses a replaceable **50-message** window with **Older / Newer / Latest**.
  Preview content is capped at 4,096 bytes and reasoning at 2,048 bytes per message.
  Copy and expansion fetch complete session-scoped content on demand. One requested
  full detail body is an explicit exception; changing/closing it does not accumulate
  older bodies. All durable history remains stored.
- Durable single selects the latest **20** messages in stable time/ID order, then
  applies its existing role/current-run filtering. Interactive history selects at
  most **50** before compaction. Final-answer replay looks up the existing
  `run-final:<run_id>` identity directly.
- Peer and completed-operation pages each retain **50** recent items with bounded
  previews and older-history access. Pending/running operations and their necessary
  ancestors are explicit row-cap exceptions. Peer history lasts only as long as its
  existing coordinator/ETS retention, not a new durable archive.
- Native `read_file` defaults to **800 lines**. It reads in **16,384-byte chunks**,
  with a **65,536-byte line/carry** ceiling and **2,097,152-byte scan** ceiling.
  Explicit ranges cannot bypass byte limits. Fixed chunk/UTF-8 carry overhead remains.
- Native `grep_search` prunes excluded directories before descent and bounds work to
  **5,000 yielded names** (including excluded names), **500 eligible files**,
  **10 matches/file**, **100 total matches**, and **8,388,608 scanned bytes**.
  It also caps per-file scans at 2,097,152 bytes, depth at 64, and directory-response
  wire/pending path text separately at 2,097,152 bytes. Python 3's invocation-scoped
  directory helper adds startup cost, not a background indexing service.
- Grep rejects queries over **4,096 bytes** before pattern work. Both native tools
  cap the complete text response, including notices/errors, at **256,000 bytes**.
  Unfinished scans identify truncation/incompleteness and explain how to narrow the
  request; a partial search is not presented as a complete “no matches” result.
  Workspace containment and outward-symlink checks remain in force.

### Context, output, and thinking

Interactive single, durable single, swarm planner, and swarm coder budget the actual
serialized adapter payload, including instructions, authorized schemas, transcript,
and protocol overhead. Older complete tool-call/reply exchanges can be compacted;
required instructions, the current objective, and pending steering are preserved.
Mandatory overflow fails visibly **before transport**, without provider-outage retry.

The estimate is `ceil(serialized_bytes × 1.25 / 4) + 128` input tokens. A separate
guard allows at most three bytes per available input token after output and protocol
reserve, with an absolute **2,000,000-byte JSON** ceiling. These are conservative
estimates, not exact tokenization or a model-limit database. Unknown remote model
names use the configured context setting, which defaults to **128,000 tokens**;
set it to a suitable limit for your endpoint. Local OpenAI-compatible requests also
respect the existing **`num_ctx: 16_384`** ceiling.

Output and thinking defaults are each **4,096 tokens**, but effective provider/profile
overrides govern the request. OpenAI-compatible budgeting reserves the sent
`max_tokens` or `max_completion_tokens`. Anthropic thinking can raise `max_tokens`
to at least thinking budget plus 1,024; the raised output already includes thinking
and is not reserved twice. Lower output/thinking allowances can leave more room for
input. Completed historical receipts still replay without a new model request.

### Transient output and cancellation

Coding text appears as escaped, explicitly transient previews for single and swarm
roles, separate from saved conversation messages. Runtime batching defaults to
**75 ms**, with **16,384-byte answer and reasoning buffers** per invocation.
The workspace renders at most **eight** previews and retains **64** bounded fencing
entries (with at most 256 invocation identities). Split think tags do not leak reasoning
into answer text. Truncated previews do not truncate the persisted final answer.

Retry epochs, turns, attempts, and generations fence stale events. Reconnect reloads
authoritative saved history, not an exact replay of lost partial text; new continuation
is labeled partial. Session switches clear unrelated previews. A saved final answer
and actual terminal state override previews. HTTP completion alone is not successful
durable settlement; cancellation, provider failure, owner loss, or persistence failure
cannot turn partial output into success.

Durable single stream callbacks check attempt-local authority rather than reading
SQLite per chunk. Default authority refresh and read timeout are each **1 second**;
default cancellation grace is **1.5 seconds**, respecting a dispatcher's custom grace.
Validity ends at the confirmed monotonic lease deadline even if refresh blocks.
Missed cancellation notification detection is bounded by refresh plus read timeout,
then cleanup grace, subject to scheduler progress. Durable fences before effects and
settlement, existing approvals, provider-route checks, and workspace reservations
remain authoritative. These controls are not an OS sandbox or rollback of effects
that were already authorized.

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

### Owner authentication and remote deployment

Local loopback mode remains passwordless only while `IEX_CODE_ALLOW_REMOTE` is
disabled and the request uses a loopback peer and localhost-style Host. Remote mode
requires one owner configured at runtime with `IEX_CODE_AUTH_USERNAME` and
`IEX_CODE_AUTH_PASSWORD_HASH`; the latter must be the exact
`pbkdf2_sha256$600000$base64salt$base64digest` format (16-byte salt, 32-byte digest).
Credentials are never stored in SQLite, cookies, logs, or settings.

The public application exposes only `/login`, `/health/ready`, and static assets.
Login and logout POSTs require valid CSRF, and stale logout cannot revoke a newer
session. Protected LiveViews, reports, websocket, and
longpoll requests are denied before workspace initialization. Sessions are encrypted,
HttpOnly, SameSite=Lax, Secure in remote mode, and expire after eight hours; logout
rotates the in-memory authority epoch and disconnects all its sockets. Restart also
invalidates sessions. Revocation does not cancel or undo already authorized durable
work. Login is globally limited to five attempts, refilling one every 12 seconds,
with at most one password derivation active. This can temporarily limit the owner's
login too, and is not internet-scale denial-of-service protection.

Provision a deployment host privately with the reviewed no-echo helper:

```bash
sudo -n /usr/local/sbin/iex-code-owner-auth-provision /etc/iex-code-web/app.env
```

Run it from a real private TTY. It does not accept credentials on the command line,
never echoes passwords or hashes, atomically replaces both auth keys, and requires an
application restart. The container health check uses `/health/ready`, without
following a redirect to the login page.

Missing or invalid remote credentials, cookie secret, or unsafe Origin/debug
configuration refuses startup before application children initialize. Keep the
app loopback-bound behind hostname TLS; nginx loopback traffic still needs sign-in.
No public signup, user database, SSO, or authentication proxy is needed. See
[`deploy/owner-auth.md`](deploy/owner-auth.md). The old deployment script's host and
state-reuse assumptions must be explicitly reviewed for a fresh deployment.

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

Configure an OpenAI-compatible, Anthropic, or Gemini endpoint, API key, default model,
temperature, and token limit there. The model gateway has first-class
OpenAI-compatible, Anthropic, and native Gemini (`v1beta`) adapters, and Gemini models
may also be routed through an OpenAI-compatible endpoint. Ollama, LM Studio, and
llama.cpp use the OpenAI-compatible adapter and local endpoint discovery. This is
distinct from the grounded Gemini search transport below.

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

## Frontier coding harness capabilities

- **2026 frontier model matrix & native `Gemini` adapter**: `IexCode.LLM.Capabilities` and
  `IexCode.LLM.Reasoning` detect 2025–2026 frontier models across OpenAI (`gpt-5*`, `codex*`,
  `o1*`, `o3*`, `o4*` with `minimal`–`xhigh` effort inference), Anthropic extended thinking
  (`claude-sonnet-4*`, `claude-opus-4*`, `claude-haiku-4-5*`, `claude-5*`), and Gemini
  (`gemini-2.5*`, `gemini-3*`, `gemini-4*`, `carbon`, `hydrogen`, `argon`), backed by the
  Req-based `IexCode.LLM.Gemini` `v1beta` chat/streaming adapter (`thinkingBudget`, thought-part
  extraction, `functionCall`/`functionResponse` tool loops, `usageMetadata`, and
  `RequestPreparation` payload measurement).
- **Ambiguity-safe `MultiPatch` with diagnostic hints**: `IexCode.Tools.MultiPatch` and
  `Matcher` reject ambiguous multi-occurrence targets unless disambiguated via `anchor_line` or
  `allow_multiple: true`, returning `Matcher.diagnose_failure/2` line numbers or closest
  matching line windows for self-recovery.
- **`repo_map` & `diagnostics` tools**: Read-only `repo_map` (`IexCode.Tools.RepoMap`) builds
  bounded (`16,000`-byte default), `focus_query`-ranked symbol maps from Elixir ASTs and
  polyglot headers; `diagnostics` performs fast Elixir AST syntax checks plus optional
  `compile: true` verification under `{:project, :exclusive}` workspace locking, alongside
  legacy role tool alias resolution (`view_file`, `replace_file_content`, `write_to_file`,
  `find_by_name`).
- **POSIX process-group command reaper**: `IexCode.Tools.ProcessGroupRunner` isolates
  `run_command` and compile diagnostics in dedicated OS process groups (`setsid`), sending
  `SIGTERM` then `SIGKILL` to `-pgid` on timeout, stop, or port closure so backgrounded
  descendants never leak.
- **`LoopGuard` doom-loop protection & runtime hardening**: `IexCode.Engine.LoopGuard` tracks
  canonical `{tool_name, args_digest, error?, output_digest}` signatures in `AgentLoop` and
  `CoderAgent`, appending `[HARNESS LOOP GUARD]` guidance on the 3rd consecutive identical
  failing call and halting cleanly with `{:agent_doom_loop_detected, tool_name}` on the 5th.
  Agent/coordinator histories cap at `@history_limit 20`, and detached LiveViews validate
  session UUIDs and existence before `PubSub.subscribe/2`.
- **Coding-aware context compaction & hierarchical `AGENTS.md` / `CLAUDE.md` rules**:
  `IexCode.LLM.ContextCompactor` preserves atomic tool-call/reply exchange groups across OpenAI
  (`tool_calls`/`tool`), Anthropic (`tool_use`/`tool_result`), and Gemini
  (`functionCall`/`functionResponse`), synthesizes structured working-memory summaries (touched
  files, patches, test outcomes, errors, plan steps), prunes bulky tool outputs while retaining
  diff headers and Elixir `lib/`/`test/` stack frames, and supports opt-in model-aware context
  windows (`:auto`). `IexCode.LLM.SystemPromptBuilder` discovers and SHA-256-deduplicates root
  and `active_paths`-scoped nested `AGENTS.md`, `CLAUDE.md`, `.cursorrules`, and
  `.github/copilot-instructions.md` rules under strict `WorkspacePath` containment (32 KB per
  file, 48 KB aggregate).
- **Hardened OS sandboxes, ephemeral Git worktrees, and atomic `TimeTravel`**:
  `IexCode.Sandbox.Backend` and `Policy` confine macOS Seatbelt subshells without
  `(with no-sandbox)`, reject SBPL injection characters, and reap timed-out process groups with
  bounded approval caches (`1,024` max) in `IexCode.Sandbox.Manager`. `IexCode.Sandbox.Worktree`
  manages detached ephemeral Git worktrees with lock-guarded atomic `apply_back/3` and orphan
  pruning, while `IexCode.TimeTravel` enforces `WorkspacePath`/symlink containment, drift
  detection (`check_drift/1`, `allow_drift: false`), and atomic rollback writes with backup
  recovery.
- **`SubAgent` summaries, read-only modes, and isolated worktrees**: `IexCode.Engine.SubAgent`
  (`spawn_agent`) returns bounded `"summary"` (20,000 chars) and `"message_id"` fields,
  terminalizes child `Run` rows under delegated worker lease authority, enforces `"coder"`,
  `"research"`, and `"read_only"` modes (intersecting `SubAgent.read_only_tools/0` with parent
  `allowed_tools` so children cannot escalate permissions), and supports `isolate_worktree: true`
  to execute children in temporary detached Git worktrees returning `"changed_files"` and
  `"diff_stat"`.
- **Smart incremental `TestSelector` & hardened `TestRunner` / `AutoFix`**:
  `IexCode.Tools.TestSelector` ranks affected tests from modified, staged, and untracked files
  across direct paths, convention mirrors, and AST/alias module references; `TestRunner`
  (`run_tests`) reaps timed-out ExUnit process groups via `ProcessGroupRunner` and supports
  `changed`, `changed_files`, `stale`, and `partition` (`"auto"` / `:auto` or explicit
  `MIX_TEST_PARTITION` with automatic `*_test<partition>.db*` cleanup); and `AutoFix` rejects
  patch targets outside the workspace or inside `deps/` / `_build/`.
- **8-task `eval/tasks` coding benchmark suite**: `mix iex_code.eval` (`IexCode.Eval.Runner` and
  `Scoring`) runs 8 reproducible coding benchmarks (`example-markdown-typo`,
  `elixir-pagination-boundary`, `elixir-multi-file-contract`, `elixir-repeated-block-patch`,
  `elixir-genserver-bounded-state`, `elixir-compile-repair`, `elixir-context-bugfix`,
  `elixir-otp-timeout-leak`) with `--only`, `--category`, `--tag`, `--json-out`, process-group
  grading timeouts, automatic workdir cleanup, `pass@k` category summaries, and
  turn/tool/token/cost telemetry.

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
mix test --max-cases 1 --seed 0 test/benchmarks/lean_harness_bench_test.exs
```

The repository includes unit, LiveView, end-to-end, adversarial, concurrency, and PTY
tests. Historical pass reports under `.agents/` are development records, not a
substitute for running the gate on the current checkout.

### Recorded harness measurements

The deterministic benchmark uses real SQLite/files/supervision and loopback Req/SSE,
not a paid model. Run it serially. Normal test commands use the configured test database;
for disposable, credential-free validation use the isolated wrapper/configuration
described in [the measurement note](docs/lean-harness-performance.md).

Equivalent baseline/M1/final fixtures show eliminated work, not a provider speedup:

| Fixture | Before hot-path changes | Final |
| --- | ---: | ---: |
| Short single, 4 / 64 chunks, total queries | 65 / 125 | 61 / 61 |
| Same fixture, run SELECTs | 28 / 88 | 24 / 24 |
| 40 / 2,000 old messages, loaded message rows | 82 / 4,002 | 20 / 20 |
| Replay with 2,000 old messages, loaded rows | 4,005 | 2, no new HTTP |
| Read 16,000 / 128,000 lines, scanned bytes | Unavailable | 32,768 / 32,768 |
| Grep 600 candidates, opened files / matches | Opened files unavailable / 100 | 10 / 100 |

At final validation, comparable-duration 4/400-chunk control fixtures both used
64 queries and 27 run SELECTs. Request-preparation fixtures at 40/2,000 old messages
both retained 15 request messages, 5,005 JSON bytes and **1,693 estimated input tokens
+ 128 output tokens**, within a 2,000-token setting and 5,232-byte guard. The separate
4/4,000-chunk preview fixture retained 16,384 answer bytes with zero queries and two
events using a 1,000 ms test batching interval. This is not a default-cadence event SLA.

Final checks: **13 benchmark tests and 267 focused affected tests passed**;
warnings-as-errors compilation and format checking passed. Full isolated `mix precommit`
**failed, exit 2: 3,643 tests, one failure**, the unchanged research manifest assertion
expecting 20 steps but receiving 17 (`workspace_live_async_runs_test.exs:222`).
It was not excluded or repaired. Prior crash/palette timing failures remain historical
observations, not retroactively passing gates.

The authorized real-provider workspace task read a synthetic `numbers.txt` and saved
“Alpha is 17, beta is 25, and their sum is 42.” with observed transient output.
Mission totals, including readiness, are **3 HTTP attempts / 3,552 provider-reported
input/output tokens**, with no outstanding reservation, under the 6-request/10,000-token
allowance. No additional paid measurement was made. Estimates and reported usage differ.

Wall timings and endpoint BEAM memory are noisy, not peak/RSS or fixed percentage
guarantees; grep's Python helper can cost more wall time than the old unbounded scan.
The original fixture has no UI first-visible timing, filesystem scan counters, or
provider usage. Current bounds and correctness/cancellation evidence accompany the
comparison; unavailable baseline metrics are not reconstructed. See the measurement
note for source revisions, timings, resource samples, commands, and limitations.

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
endpoint should bind to loopback behind a trusted TLS reverse proxy.

When `IEX_CODE_ALLOW_REMOTE=true`, the built-in single-owner authentication protects
browser routes, reports, websocket and longpoll transports. It is not a signup or
multi-user system. Local passwordless access remains restricted to the existing loopback
peer and Host policy when remote mode is disabled. Multi-tenant isolation and encrypted
secret storage are not present.

### Reviewed hostname deployment

The reviewed production deployment uses the committed auth-enabled revision, fresh
SQLite state, app bind `127.0.0.1:14052`, and nginx for `https://iex.llmotions.com`.
Keep the generated owner credential on the host and retrieve
`/etc/iex-code-web/owner-credential.txt` privately. Do not expose its contents in
chat, logs, repository files, or agent evidence, or overwrite it. This app credential
is separate from SSH/server credentials.

The approved Iex-only certificate flow uses Ubuntu `certbot` without the nginx plugin.
The exact rollout commands and validation outcomes are recorded in
[`docs/deployment.md`](docs/deployment.md). Renewal is scoped to this hostname and
runs `nginx -t` before reload. The package-global `certbot.timer` stays disabled; only
the Iex timer is enabled.
