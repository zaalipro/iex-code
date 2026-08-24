# IexCode

IexCode is a local-first desktop coding harness built with Elixir/OTP, Phoenix 1.8,
LiveView, SQLite, and xterm.js. It brings an agent session, the working tree, tests,
Git, and a real interactive terminal into one workspace.

The application combines supervised coding agents with a **durable, journaled run
plane**. Background work is queued in SQLite and claimed by leased OTP workers; run
state and an ordered event history are persisted independently of the browser. See
[`PROJECT.md`](PROJECT.md) for the architecture and remaining roadmap.

## Workspace

The main LiveView exposes nine connected tools:

| Area | Current capability |
| --- | --- |
| Kanban | Task CRUD, eight workflow states, priorities, assignees, filters, schedules, and subtasks |
| Swarm | Durable Mission Control for coding and deep-research runs, with budgets, provider manifests, cited artifacts, and run-scoped pause/resume/steer/cancel |
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

> The durable dispatcher allows only one active background run per project. This is
> coarse dispatcher exclusivity, not a complete workspace lock: interactive editor, terminal,
> and Git actions can still overlap the run. Avoid manual write-heavy work until the run
> reaches review or completion.

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

### Model providers

Open **Settings** to configure an OpenAI-compatible or Anthropic endpoint, API key,
default model, temperature, and token limit. The model gateway has first-class
OpenAI-compatible and Anthropic adapters. A Gemini model may be used when exposed
through a compatible endpoint; direct Gemini and local-model transports remain roadmap work.

The research gateway is independent of the model transport. It includes normalized
adapters for **Tavily, Brave, Exa, Serper, Google Programmable Search, Bing, SearxNG,
and DuckDuckGo**, ordered fallback/fan-out, deterministic URL deduplication, partial
failure reporting, and bounded concurrency. Public source fetches reject local/private/
link-local/reserved destinations, validate every DNS answer and redirect, pin the
validated address against DNS rebinding, restrict content types, and cap time and bytes.

Use **Run setup** in the composer or the `/research` command to queue a deep-research
mission. Research runs persist plan, federated-search, safe-fetch, and synthesis stages,
the normalized evidence manifest, and a citation-indexed Markdown report. No-key or
all-provider failure is reported honestly; the harness does not invent a report.

API keys are currently persisted in the local SQLite settings row. They are not stored
in an operating-system keychain or encrypted vault. Protect the database file and do
not share it.

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

- Durable background runs survive LiveView disconnects and preserve their journal across
  application restarts. An orphaned active run becomes `interrupted`; automatic
  checkpoint resume is intentionally not implemented yet.
- Coding runs retain a fixed `prepare → execute` shell and the four-agent swarm remains
  sequential. Deep-research runs add persisted plan/search/fetch/synthesis nodes, but the
  harness is not yet a general arbitrary parallel DAG scheduler.
- Calendar work now has a supervised UTC cron scheduler with atomic claims, stable
  occurrence keys, recurrence, existing-run recovery, and stale-claim recovery. Rich
  notification and dead-letter workflows remain future work.
- Run events are sequenced in SQLite. The current LiveView reloads a bounded 500-event
  list rather than a LiveView stream or paginated tail, and normal chat does not yet
  persist every model token/reasoning delta as an event.
- Approval, command, and artifact records exist; a deny-by-default tool policy and full
  approval inbox are not yet enforced for every LLM tool call.
- Background runs have worker leases and the dispatcher excludes another active run for
  the same project. File-level locks and a Git-exclusive coordination gate are not
  implemented, and interactive host controls can bypass the dispatcher. Durable and
  interactive work in the same session also shares live steering/terminal channels.
- Wall-clock budgets are enforced by the dispatcher. Token budgets accumulate and stop
  covered planner/coder/research boundaries when providers report usage; providers that
  omit streaming usage cannot be measured. Cost limits remain display-only until a
  versioned pricing ledger exists. Forced cancellation stops the supervised BEAM worker;
  a tool-spawned external descendant may still require OS-level cleanup.
- Pause, resume, cancel, and steer are now ordered run-scoped control records with journal
  outcomes and a Mission Control timeline. They are delivered on a run-only channel, but
  a general restart-replayed control consumer and immediate interruption of every
  in-flight provider/tool call are not complete yet.
- Rollback ownership is durable and run-scoped for MultiPatch/AutoFix mutations. Direct
  `write_file`, `patch_file`, Git, and terminal effects are not covered by that manifest.
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
