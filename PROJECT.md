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
│ LiveView UI: 9 Tabs (Kanban, Swarm, Calendar, Changes/Git, Tests,     │
│ AST Explorer, Chat, Files/Editor, Terminal, Settings), 4-Column Agent │
│ Cards, DAG Hierarchy, Command Palette (Cmd+K), Real-Time Telemetry    │
└───────────────────────────────────────────────────────────────────────┘
```

## Feature Inventory
Every feature from the Survey phase is mapped to its assigned milestone.

| # | Feature | Description | Milestone | Status | Source |
|---|---------|-------------|-----------|--------|--------|
| 1 | Kanban Subtask Checklist & Management | Add/toggle/delete subtask items with dynamic progress recalculation in Task Detail Drawer | M1 | IN_PROGRESS | Survey / R1 |
| 2 | Task Detail Drawer Inline Editing | Editable fields for title, description, and tags with persistence via `update_task` | M1 | IN_PROGRESS | Survey / R1 |
| 3 | Agile Status Whitelist Normalization | Automatic mapping for `"in_progress" -> "running"`, `"failed" -> "blocked"`, `"complete" -> "done"` in `Kanban.move_task_status/2` | M1 | IN_PROGRESS | Survey / R1 |
| 4 | Swarm Steering Input Auto-Reset | Clear `@steer_text` in socket assigns immediately upon submitting steering message | M1 | IN_PROGRESS | Survey / R1 |
| 5 | Calendar Schedule Type Selection Event | Populate `handle_event("set_task_schedule_type", ...)` to update schedule type assigns | M1 | IN_PROGRESS | Survey / R1 |
| 6 | Settings Hub Complete Form & Persistence | Expose `anthropic_api_key`, `anthropic_base_url`, `swarm_agent_count`, `auto_save`, `temperature`, `max_tokens` with SQLite persistence | M2 | PLANNED | Survey / R1 |
| 7 | Dynamic Usage History Telemetry | Replace static placeholder rows in Settings modal with real session/operation token stats | M2 | PLANNED | Survey / R1 |
| 8 | File Explorer Scalability & Folder Hierarchy | Expand file browsing beyond 100-file cap with directory grouping and collapsible tree | M2 | PLANNED | Survey / R1 |
| 9 | AI Chat Direct Code Insertion | Add "Insert into Editor" action on markdown code blocks to push code into active file buffer | M2 | PLANNED | Survey / R1 |
| 10 | Visual Test Runner & AutoFix Studio | Port execution, ANSI parser, failure cards, deterministic AutoFix heuristics, rollback | M3 | DONE | Survey / R1 |
| 11 | AST Query Explorer & Symbol Navigator | AST parser, query validation, type filters, symbol table, jump-to-editor | M3 | DONE | Survey / R1 |
| 12 | 3-Tier Git Staging Hub & Branch Manager | Branches, status, staging rails, HunkOps index unstage, AI commit composer | M3 | DONE | Survey / R1 |
| 13 | Native Workspace Execution | Direct execution on `/Users/zaali/dev/iex-code` without sandboxing or git worktree isolation | M3 | DONE | Survey / R2 |
| 14 | Comprehensive Verification & Precommit | 100% test pass on `mix test` and clean verification with 0 warnings on `mix precommit` | M3 | PLANNED | Survey / R3 |

## Milestones

| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| M1 | Tab Workflows & Action Refinement | Kanban subtasks checklist, task drawer inline editing, agile status normalization, steering text auto-reset, calendar schedule type handler | none | IN_PROGRESS |
| M2 | Settings Hub, File Explorer & Chat Refinement | Full Settings modal form & persistence, dynamic usage history, scalable file explorer hierarchy, chat "Insert into Editor" action | M1 | PLANNED |
| M3 | Comprehensive Verification, Adversarial Hardening & Precommit | Full test suite verification across all 9 tabs, Reviewer, Challenger, and Forensic Auditor verification, 100% `mix test` and clean `mix precommit` | M1, M2 | PLANNED |

## Interface Contracts

### 1. Kanban Subtasks & Metadata (`IexCode.Kanban`)
- `Kanban.add_subtask(task_id, %{"title" => title})` -> `{:ok, task}` | `{:error, reason}`
- `Kanban.toggle_subtask(task_id, subtask_id)` -> `{:ok, task}` | `{:error, reason}`
- `Kanban.delete_subtask(task_id, subtask_id)` -> `{:ok, task}` | `{:error, reason}`
- `Kanban.move_task_status(task, status)` -> `{:ok, task}` (supports `"in_progress"`, `"failed"`, `"complete"` normalization)

### 2. Settings Management (`IexCode.Settings`)
- `Settings.get_settings()` -> `%AppSettings{}`
- `Settings.update_settings(attrs)` -> `{:ok, %AppSettings{}}` | `{:error, changeset}`
- Supports: `openai_api_key`, `openai_base_url`, `anthropic_api_key`, `anthropic_base_url`, `default_model_provider`, `default_model`, `swarm_agent_count`, `auto_save`, `temperature`, `max_tokens`

### 3. Editor & Chat Buffer Insertion (`IexCodeWeb.WorkspaceLive`)
- `handle_event("insert_code_to_editor", %{"code" => code}, socket)` -> inserts code snippet into active buffer
- `handle_event("set_task_schedule_type", %{"type" => type}, socket)` -> updates schedule type

## Code Layout
- `lib/iex_code/application.ex`: Supervision tree.
- `lib/iex_code/kanban/`: `task.ex`, `kanban.ex` (+ subtask functions).
- `lib/iex_code/settings/`: `app_settings.ex`, `settings.ex`.
- `lib/iex_code/engine/`: `session_server.ex`, `swarm_coordinator.ex`, `swarm_orchestrator.ex`.
- `lib/iex_code/tools/`: `ast_search.ex`, `test_runner.ex`, `auto_fix.ex`, `multi_patch.ex`, `git.ex`.
- `lib/iex_code/llm/`: `openai.ex`, `anthropic.ex`, `stream_client.ex`, `resilience.ex`.
- `lib/iex_code_web/live/`: `workspace_live.ex`, `workspace_live.html.heex`, `workspace_components.ex`, `command_palette.ex`.
- `assets/js/`: `app.js` (with `CommandPalette`, `CodeEditor`, `TerminalAutoScroll`, `CodeCopy`, `KeyboardSubmit` hooks).
- `test/iex_code/`: Unit tests for kanban, settings, engine, and tools.
- `test/iex_code_web/live/`: LiveView integration tests across all 9 tabs.

