# Project: Next-Level IexCode: Desktop AI Coding Harness & Swarm Orchestrator

## Architecture
IexCode is a high-performance desktop AI coding harness and multi-agent swarm engine built with Elixir, OTP, Phoenix 1.8, and Phoenix LiveView 1.2.
It operates as a supervised multi-process system with isolated OTP subagents, real-time Phoenix PubSub telemetry, an advanced developer tooling engine (AST search, multi-file atomic patching, ExUnit test runner, Git integration), a resilient streaming LLM pipeline, and a responsive dark-mode desktop UI.

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
┌──────────────────────┐      ┌─────────────────────────────────────────┐
│ PubSub Telemetry     │      │ Power Developer Tooling:                │
│ session:<session_id> │      │ - AST Query Explorer (ASTSearch)        │
│ 0% -> 100% progress  │      │ - Visual Test Runner & AutoFix Studio   │
│ PID + latency ms     │      │ - Git Branch & Multi-File Staging Hub   │
└──────────┬───────────┘      │ - MultiPatch Atomic Transaction Engine  │
           │                  └─────────────────────────────────────────┘
           ▼
┌───────────────────────────────────────────────────────────────────────┐
│ LiveView UI: 4-Column Agent Cards, Hierarchical Operation DAG,        │
│ Interactive Controls (Start/Pause/Resume/Cancel/Steer), Command       │
│ Palette (Cmd+K), Visual Test Runner & AutoFix, AST Symbol Explorer,   │
│ 3-Tier Git Staging Hub, Thinking Trace & Message Inspector            │
└───────────────────────────────────────────────────────────────────────┘
```

## Feature Inventory
Every feature from the Survey phase is mapped to its assigned milestone.

| # | Feature | Description | Milestone | Status | Source |
|---|---------|-------------|-----------|--------|--------|
| 1 | Dead Code & Assigns Elimination | Eliminate obsolete assigns, clean up unused handlers, ensure 0 warnings | M1 | DONE | Survey / R1 |
| 2 | Fake Mock Elimination & Provider Resilience | Remove synthetic mocks from OpenAI/Anthropic; return explicit error tuples | M1 | DONE | Survey / R1 |
| 3 | SQLite Lock Contention & Retry Logic | Exponential backoff `retry_on_busy/3` on DB operations under concurrency | M1 | DONE | Survey / R1 |
| 4 | Global Command Palette (`Cmd+K`) | Keyboard shortcuts, fuzzy ranking engine, category pills, LiveView dispatch | M1 | DONE | Survey / R1 |
| 5 | Visual Test Runner & AutoFix Studio | Port execution, ANSI parser, failure cards, deterministic AutoFix heuristics | M1 | DONE | Survey / R1 |
| 6 | AST Query Explorer & Symbol Navigator | AST parser, query validation, type filters, symbol table, jump-to-editor | M1 | DONE | Survey / R1 |
| 7 | 3-Tier Git Staging Hub & Branch Manager | Branches, status, staging rails, HunkOps index unstage, AI commit composer | M1 | DONE | Survey / R1 |
| 8 | MultiPatch 3-Tier Atomic Engine | AST/Exact/Fuzzy matching, ETS snapshots, atomic disk writes, rollback | M1 | DONE | Survey / R1 |
| 9 | Autonomous Swarm Coordinator Loop | Planner -> Explorer -> Coder -> Verifier sequence in `SwarmCoordinator` | M2 | DONE | Survey / R2 |
| 10 | OTP Subagent GenServers | `PlannerAgent`, `ExplorerAgent`, `CoderAgent`, `VerifierAgent` under `AgentSupervisor` | M2 | DONE | Survey / R2 |
| 11 | Self-Correction Feedback Loop | Diagnostic hashing (`compute_error_signature`), cycle detection, max retries, AutoFix | M2 | DONE | Survey / R2 |
| 12 | Structured Failure Diagnostic Injection | Passing structured failure context and diffs to Coder for iterative repair | M2 | DONE | Survey / R2 |
| 13 | MultiPatch Transactional Rollback | Non-destructive snapshot rollback on unrecoverable error or user cancellation | M2 | DONE | Survey / R2 |
| 14 | Real-Time PubSub Lifecycle Streaming | Streaming `:operation_*`, `:swarm_stage_changed`, latency, 0-100% progress | M3 | DONE | Survey / R3 |
| 15 | 4-Column Subagent Telemetry Cards | Planner, Explorer, Coder, Verifier cards with glowing neon border, latency, progress, PID | M3 | DONE | Survey / R3 |
| 16 | Hierarchical Operation DAG & Drawers | Recursive DAG rendering with connector lines, status dots, and detail drawers | M3 | DONE | Survey / R3 |
| 17 | Interactive Swarm Controls | LiveView Start (`create_goal`), Pause, Resume, Abort (rollback/commit), Steer | M3 | DONE | Survey / R3 |
| 18 | Thought & Output Inspection | `<.thinking_trace>`, expanded message inspector, operation logs | M3 | DONE | Survey / R3 |
| 19 | Comprehensive Integration & Stress Tests | Multi-turn convergence, error feedback loops, cancellation/recovery, UI tests | M4 | DONE | Survey / R4 |
| 20 | Precommit Quality & Zero-Warning Pass | 100% test pass on `mix test` (796 tests) and clean verification under `mix precommit` | M4 | DONE | Survey / R4 |

## Milestones

| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| M1 | Foundation & Uncommitted Changes Hardening | M1–M6 uncommitted changes, code hygiene (0 compiler warnings, 0 format issues, 0 dead assigns, 0 fake mocks), SQLite concurrency, Command Palette, Visual Test Runner & AutoFix, AST Query Explorer, Git Staging Hub | none | DONE |
| M2 | Swarm Autonomous Loop & Self-Correction Engine | 4-agent swarm loop (`PlannerAgent`, `ExplorerAgent`, `CoderAgent`, `VerifierAgent`), structured failure diagnostics, cycle detection, instant AutoFix synergy, MultiPatch rollback, crash recovery | M1 | DONE |
| M3 | Real-Time PubSub Telemetry & Interactive UI Controls | PubSub streaming on `session:<session_id>`, 4-column cards, DAG operation tree, Start/Pause/Resume/Cancel/Steer LiveView controls, latency tracking, 0-100% progress bar, thought inspection | M1, M2 | DONE |
| M4 | Comprehensive Verification, E2E Integration & Precommit | Full test suite verification (796 tests passing), E2E integration test suite, `mix test` 100% pass, clean `mix precommit` with 0 warnings | M1, M2, M3 | DONE |

## Interface Contracts

### 1. Swarm Engine & Coordinator (`IexCode.Engine`)
- `SwarmOrchestrator.run_swarm(session_id, user_prompt, project_root, opts)` -> `{:ok, task_pid}`
- `SwarmCoordinator.run_swarm(session_id, user_prompt, project_root, opts)` -> `{:ok, task_pid}`
- `SwarmCoordinator.run(session_id, user_prompt, opts)` -> `{:ok, final_state}` | `{:error, reason}`
- `SwarmCoordinator.pause(session_id)` -> `:ok`
- `SwarmCoordinator.resume(session_id)` -> `:ok`
- `SwarmCoordinator.cancel(session_id, opts)` -> `:ok`

### 2. Subagents (`IexCode.Engine.Agents`)
- `PlannerAgent.plan(session_id, prompt, opts)` -> `{:ok, plan_summary}`
- `ExplorerAgent.explore(session_id, plan_or_prompt, opts)` -> `{:ok, explorer_context}`
- `CoderAgent.code(session_id, prompt, opts)` -> `{:ok, %{patches: list, result: str}}`
- `VerifierAgent.verify(session_id, opts)` -> `{:ok, summary}` | `{:error, {:verification_failed, diagnostics}}`

### 3. PubSub Telemetry Events (`session:<session_id>`)
- `{:operation_started, %Operation{}}`
- `{:operation_progress, %{id: op_id, progress: int, status: str, message: str, latency_ms: int}}`
- `{:operation_completed, %Operation{}}`
- `{:operation_failed, %Operation{}}`
- `{:swarm_stage_changed, %{session_id: str, stage: atom, progress: int, latency_ms: int, agent_pid: str, message: str}}`
- `{:session_status_changed, status_str}`
- `{:swarm_steered, %{session_id: str, steering: str, updated_prompt: str}}`
- `{:session_cancelled, %{session_id: str, action: atom}}`

### 4. Interactive Controls (`session:<session_id>:steer`)
- `{:pause, session_id}`
- `{:resume, session_id}`
- `{:cancel, session_id, opts}`
- `{:steer_message, text}`

## Code Layout
- `lib/iex_code/application.ex`: Supervision tree.
- `lib/iex_code/engine/`: `agent_registry.ex`, `agent_supervisor.ex`, `operation_manager.ex`, `session_server.ex`, `swarm_coordinator.ex`, `swarm_orchestrator.ex`.
- `lib/iex_code/engine/agents/`: `planner_agent.ex`, `explorer_agent.ex`, `coder_agent.ex`, `verifier_agent.ex`.
- `lib/iex_code/tools/`: `ast_search.ex`, `test_runner.ex`, `auto_fix.ex`, `multi_patch.ex`, `git.ex` (+ subdirectories).
- `lib/iex_code/llm/`: `openai.ex`, `anthropic.ex`, `stream_client.ex`, `resilience.ex`.
- `lib/iex_code_web/live/`: `workspace_live.ex`, `workspace_live.html.heex`, `workspace_components.ex`, `command_palette.ex`.
- `assets/js/`: `app.js` (with `CommandPalette`, `CodeEditor`, `TerminalAutoScroll`, `CodeCopy`, `KeyboardSubmit` hooks).
- `test/iex_code/engine/`: Agent and swarm coordinator unit & integration tests.
- `test/iex_code/tools/`: `ast_search_test.exs`, `test_runner_test.exs`, `auto_fix_test.exs`, `git_test.exs`, `multi_patch_test.exs`.
- `test/iex_code_web/live/`: `workspace_live_test.exs`, `workspace_live_command_palette_test.exs`, `workspace_live_test_runner_test.exs`, `workspace_live_ast_git_test.exs`, `workspace_live_telemetry_test.exs`, `workspace_live_ui_controls_test.exs`.
- `test/iex_code/e2e/`: Opaque-box E2E test suites (Tiers 1-5).
