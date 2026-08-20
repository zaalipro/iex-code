# Project: Next-Level IexCode: Desktop AI Coding Harness & Swarm Engine

## Architecture
IexCode is a high-performance desktop AI coding harness and multi-agent swarm engine built with Elixir, OTP, Phoenix 1.8, and Phoenix LiveView 1.2.
It operates as a supervised multi-process system with isolated OTP subagents (`PlannerAgent`, `ExplorerAgent`, `CoderAgent`, `VerifierAgent`), real-time Phoenix PubSub telemetry, an advanced developer tooling engine (AST search, multi-file atomic patching, ExUnit test runner, Git integration), a resilient streaming LLM pipeline (OpenAI-compatible endpoints e.g. `cli.llmotions.com/v1`, Gemini, Claude, local models), and a responsive dark-mode desktop UI.

```
                          ┌───────────────────────────┐
                          │    IexCode.Application    │
                          └─────────────┬─────────────┘
                                        │
           ┌────────────────────────────┼────────────────────────────┐
           │                            │                            │
┌──────────▼──────────┐      ┌──────────▼──────────┐      ┌──────────▼──────────┐
│ SessionSupervisor   │      │ TaskSupervisor      │      │ AgentSupervisor     │
│ (DynamicSupervisor) │      │ (Task.Supervisor)   │      │ (DynamicSupervisor) │
└──────────┬──────────┘      └─────────────────────┘      └──────────┬──────────┘
           │                                                         │
┌──────────▼──────────┐                                   ┌──────────▼──────────┐
│ SessionServer       │                                   │ Dedicated Subagents │
│ (GenServer)         │                                   │ Planner / Explorer  │
└──────────┬──────────┘                                   │ Coder / Verifier    │
           │                                              └──────────┬──────────┘
           ▼                                                         │
┌─────────────────────┐                                              │
│ Swarm Coordinator   │◄─────────────────────────────────────────────┘
│ (Autonomous Loop)   │
└──────────┬──────────┘
           │
           ├──────────────────────────────┐
           ▼                              ▼
┌──────────────────────┐      ┌──────────────────────┐
│ PubSub Telemetry     │      │ Advanced Tooling:    │
│ session:<session_id> │      │ - AST Search         │
│ 0% -> 100% progress  │      │ - MultiPatch Engine  │
│ PID + latency ms     │      │ - TestRunner Parser  │
└──────────┬───────────┘      │ - Git Tools          │
           │                  └──────────────────────┘
           ▼
┌─────────────────────────────────────────────────────────────────┐
│ LiveView UI: 4-Column Cards, Hierarchical Tree, Diff Viewer,   │
│ Instant File Explorer, Terminal Session Runner                  │
└─────────────────────────────────────────────────────────────────┘
```

## Feature Inventory
Every feature identified during the Survey phase is enumerated and mapped to its assigned milestone.

| # | Feature | Description | Milestone | Status | Source |
|---|---------|-------------|-----------|--------|--------|
| F1 | AppSettings Query Safety | Fix `Repo.one(AppSettings)` crash on multiple records | M1 | DONE | Survey |
| F2 | OTP Subagent Process Tree | Isolated GenServers & `AgentSupervisor` for Planner, Explorer, Coder, Verifier | M2 | DONE | Survey / R1 |
| F3 | OTP Process Crash Monitoring | `Process.monitor/1` and `{:DOWN, ...}` handling in `OperationManager` | M2 | DONE | Survey / R1 |
| F4 | Autonomous Error Feedback Loop | Multi-iteration auto-correction loop when compiler/tests fail | M2 | DONE | Survey / R1 |
| F5 | Live Telemetry & Card Streaming | 0%->100% progress, millisecond timings, PID monitors, live status | M3 | DONE | Survey / R2 |
| F6 | Hierarchical Operation Tree | Visual nested parent-child operation tree using `parent_op_id` & CSS connectors | M3 | DONE | Survey / R2 |
| F7 | Interactive Code Diff Viewer | Side-by-side & inline syntax-highlighted diff viewer for proposed/applied patches | M3 | DONE | Survey / R2 |
| F8 | File Tree Explorer & Search | Collapsible directory tree, instant search filter, code syntax preview | M3 | DONE | Survey / R2 |
| F9 | Terminal Session Integration | Shell execution with ANSI escape code styling & auto-scrolling | M3 | DONE | Survey / R2 |
| F10 | AST-Aware Search Engine | Sourceror / Elixir AST symbol & definition traversal | M1 | DONE | Survey / R3 |
| F11 | Multi-File Atomic Patching | 3-tier patching engine (AST, exact, fuzzy) with atomic rollback | M1 | DONE | Survey / R3 |
| F12 | Automated Test Runner & Parser | Structured ExUnit stack trace and failure parser | M1 | DONE | Survey / R3 |
| F13 | Instant Auto-Fix Engine | Automatic bridge from parsed test failures to patch generation | M2 | DONE | Survey / R3 |
| F14 | Git Integration Engine | `git_status`, `git_diff`, `git_stage`, `git_commit`, semantic commit generator | M1 | DONE | Survey / R3 |
| F15 | Streaming SSE LLM Client | Multi-provider SSE streaming with delta chunks for OpenAI, Claude, local models | M1 | DONE | Survey / R4 |
| F16 | UTF-8 Stream Sanitizer Buffer | Stateful multibyte boundary chunk buffer preventing encoding crashes | M1 | DONE | Survey / R4 |
| F17 | LLM Resilience & Retries | Exponential backoff, jitter, and fallback provider routing | M1 | DONE | Survey / R4 |
| F18 | E2E Test Suite & Test Infra | Opaque-box 4-tier test harness covering all features and scenarios | M0 (Test Track) | DONE | Survey / AC |
| F19 | Final Quality & Precommit Pass | 100% E2E test pass, 0 test failures, 0 compiler warnings in `mix precommit` | M4 | DONE | Survey / AC |

## Milestones

| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| M0 | E2E Testing Track | Requirement-driven opaque-box test suite (Tiers 1-4) & test runner | none | DONE |
| M1 | Multi-Provider Streaming & Developer Tooling Engine | F1, F10, F11, F12, F14, F15, F16, F17 | none | DONE |
| M2 | Autonomous Swarm & OTP Process Architecture | F2, F3, F4, F13 | M1 | DONE |
| M3 | World-Class Desktop UI/UX & Live Telemetry | F5, F6, F7, F8, F9 | M1, M2 | DONE |
| M4 | Final E2E Pass, Adversarial Hardening & Precommit | F18, F19: Tier 1-4 pass + Tier 5 adversarial tests + `mix precommit` | M0, M1, M2, M3 | DONE |

## Interface Contracts

### 1. Developer Tooling (`IexCode.Tools`)
- `ast_search(project_root, query_map)` -> `{:ok, [%{file: path, line: int, type: atom, name: string, code: string}]}`
- `patch_files(project_root, [%{path: path, target: str, replacement: str}])` -> `{:ok, %{applied: int, diff: str}} | {:error, reason}`
- `run_tests(project_root, opts)` -> `{:ok, %{status: :passed | :failed, total: int, failures: [%{file: path, line: int, message: str, stacktrace: list}]}}`
- `git_operation(project_root, op, params)` -> `{:ok, result} | {:error, reason}`

### 2. Multi-Provider Streaming LLM (`IexCode.LLM`)
- `stream_chat(provider, model, messages, tools, opts, callback_fn)` -> `{:ok, final_message} | {:error, reason}`
- `UTF8Buffer.process_bytes(acc, raw_chunk)` -> `{valid_binary, rest_binary}`
- `Resilience.with_retry(fun, opts)` -> `{:ok, result} | {:error, reason}`

### 3. Swarm Coordination & Process Architecture (`IexCode.Engine`)
- `AgentSupervisor.start_agent(session_id, agent_type, opts)` -> `{:ok, pid}`
- `SwarmCoordinator.run(session_id, prompt, opts)` -> `{:ok, summary} | {:error, reason}`
- Subagent pubsub broadcasts: `{:operation_started, op}`, `{:operation_progress, op_id, pct, msg}`, `{:operation_completed, op}`, `{:operation_failed, op}`

### 4. LiveView Telemetry & UI Components (`IexCodeWeb`)
- `<.diff_viewer diff_text={@diff_text} mode={@diff_mode} />`
- `<.operation_tree operations={@operations} />`
- `<.subagent_cards operations={@operations} active_agent={@active_agent} />`
- `<.file_explorer files={@files} filter={@file_filter} selected_file={@selected_file} />`
- `<.terminal_session output={@terminal_output} />`

## Code Layout
- `lib/iex_code/application.ex`: Top-level OTP supervision tree.
- `lib/iex_code/engine/`: `AgentSupervisor`, `Agents.*` (`PlannerAgent`, `ExplorerAgent`, `CoderAgent`, `VerifierAgent`), `SwarmCoordinator`, `OperationManager`, `SessionServer`, `SessionSupervisor`.
- `lib/iex_code/tools/`: `ASTSearch`, `MultiPatch`, `TestRunner`, `AutoFix`, `Git`.
- `lib/iex_code/llm/`: `StreamClient`, `SSEParser`, `UTF8Buffer`, `Resilience`, `OpenAI`, `Anthropic`.
- `lib/iex_code_web/live/`: `WorkspaceLive`, `WorkspaceLive.HTML`, components (`DiffViewer`, `OperationTree`, `SubagentCards`, `FileExplorer`, `TerminalSession`).
- `test/`: Unit and integration test suites.
- `test/iex_code/e2e/`: Opaque-box E2E test suites (Tiers 1-5).
