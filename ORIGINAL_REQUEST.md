# Original User Request

## Initial Request — 2026-08-23T10:58:29Z

Review and harden all uncommitted changes across IexCode (M1–M6: dead code cleanup, Command Palette, Visual Test Runner & AutoFix, AST Query Explorer, Git Staging Hub), and elevate the desktop AI coding harness with a fully connected, self-correcting autonomous multi-agent swarm loop (Planner → Explorer → Coder → Verifier) with live PubSub telemetry and interactive controls.

Working directory: /Users/zaali/dev/iex-code
Integrity mode: development

## Requirements

### R1. Harden & Finalize Uncommitted Foundation (M1–M6)
- Review and harden all uncommitted changes across `lib/iex_code/`, `lib/iex_code_web/`, and `test/`.
- Ensure zero regressions in the Global Command Palette (`Cmd+K`), Visual Test Runner & 1-Click AutoFix Studio, AST Query Explorer, and 3-Tier Git Staging Hub.
- Maintain strict code hygiene: 0 compiler warnings (`mix compile --warnings-as-errors`), 0 formatting issues (`mix format --check-formatted`), and 0 dead assigns or stale mocks.

### R2. End-to-End Autonomous Swarm Loop & Feedback Cycles
- Wire `PlannerAgent`, `ExplorerAgent`, `CoderAgent`, and `VerifierAgent` into a fully autonomous, supervised multi-turn swarm execution loop within `IexCode.Engine.SwarmOrchestrator` / `SwarmCoordinator`:
  - **Planner**: Decomposes user goals into structured subtasks with clear verification criteria.
  - **Explorer**: Inspects project files, dependencies, and code symbols via `ASTSearch` to gather targeted context.
  - **Coder**: Implements code modifications and atomic patch proposals via `MultiPatch` and `AutoFix`.
  - **Verifier**: Runs ExUnit tests via `TestRunner` and verifies compilation/syntax integrity.
  - **Self-Correction Feedback Loop**: If verification fails (failing tests, compiler errors), automatically pass structured failure diagnostics back to Coder for iterative repair (up to configurable max iterations) before declaring success or failure.

### R3. Real-Time Swarm Telemetry & Interactive UI Controls
- Stream real-time agent lifecycle events, tool executions, execution latencies (ms), and 0% -> 100% progress metrics over Phoenix PubSub (`session:<session_id>`).
- Dynamically update the 4-column agent cards and hierarchical operation DAG in `WorkspaceLive`.
- Provide interactive controls in the LiveView interface to start a swarm run, pause, resume, abort, and inspect intermediate agent thoughts and tool outputs.

### R4. Comprehensive Verification & Precommit Standards
- Implement end-to-end integration and stress tests covering:
  - Full multi-turn autonomous swarm convergence on sample tasks.
  - Error feedback and self-correction when tests initially fail.
  - Swarm cancellation, timeout handling, and process crash recovery.
  - LiveView UI real-time telemetry rendering and user control dispatching.
- Guarantee a 100% pass rate on `mix test` and clean verification under `mix precommit`.

## Acceptance Criteria

### Foundation & Cleanliness
- [ ] All uncommitted changes compile cleanly with `mix compile --warnings-as-errors` and format with `mix format --check-formatted`.
- [ ] No stale mocks or dead assigns remain in `lib/iex_code/` or `lib/iex_code_web/`.

### Autonomous Swarm Loop
- [ ] Swarm coordinator orchestrates Planner -> Explorer -> Coder -> Verifier sequentially and iteratively for a given task goal.
- [ ] When a test failure occurs during verification, the failure diagnostic is fed back to Coder, a new patch is generated and applied, and verification re-runs until passing or max iterations reached.
- [ ] Multi-patch transactions apply atomically and rollback cleanly on unrecoverable failure.

### UI & Telemetry
- [ ] 4-column agent cards and operation tree update in real-time via PubSub with accurate agent status, millisecond latencies, and progress percentages.
- [ ] LiveView swarm controls (Start, Pause, Resume, Stop) dispatch reliably without WebSocket stalls.

### Test & Precommit Quality
- [ ] Full test suite (`mix test`) passes with 0 failures across all unit, integration, stress, and LiveView tests.
- [ ] `mix precommit` passes cleanly with 0 warnings.
