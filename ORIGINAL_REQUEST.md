# Original User Request

## 2026-08-23T08:22:54Z

Perform an exhaustive zero-gap feature audit and refinement pass across all 9 tabs and developer tools in IexCode (Kanban, Swarm, Calendar, Changes/Git, Tests/AutoFix, AST Explorer, Chat, Files/Editor, Terminal, and Settings), ensuring every button, action, view, and workflow operates end-to-end without sandboxing or git worktree isolation.

Working directory: /Users/zaali/dev/iex-code
Integrity mode: development

## Requirements

### R1. Comprehensive Tab & Tool Feature Gap Elimination
Audit every view, tab, modal, and drawer in `WorkspaceLive` and `WorkspaceComponents` to guarantee zero stubbed clicks, 100% active event handlers, and end-to-end functionality:
- **Kanban Board**: Full task creation, status transition, priority/assignee filtering, subtask management, and detail drawer editing.
- **Swarm Studio**: Start, pause, resume, cancel (with rollback/commit options), steer, live 4-column telemetry, DAG hierarchy, thinking trace inspection.
- **Visual Test Runner & AutoFix**: Full suite run, failed test run, single file run, ANSI log parsing, structured failure diffs, 1-click heuristic patch preview and apply.
- **AST Query Explorer**: Full symbol search across definitions (`def`, `defp`), macros, modules, and typespecs (`@spec`, `@type`), with jump-to-editor.
- **Git Staging & Diff Hub**: 3-tier staging rails (Staged, Unstaged, Untracked), side-by-side & inline diff viewer, granular hunk unstaging, branch switching/creation/fetch/pull, and AI commit message generation.
- **Inline File Editor & Explorer**: File tree navigation, fuzzy file search, buffer tabs, dirty tracking, saving, and jump-to-line.
- **Embedded Terminal**: Interactive command execution, quick actions (`mix test`, `mix precommit`, `git status`), ANSI formatting, command history, and process interruption.
- **AI Chat & Streaming**: Multi-model SSE streaming, prompt history, context injection, token/cost telemetry, and quick code insertion.
- **Calendar & Timeline**: Date grid navigation, scheduled task inspection, daily activity metrics, and session timeline.
- **Settings & Provider Hub**: Complete API key management, model selection (OpenAI, Anthropic, Gemini, local CLI proxy), temperature/token controls, and persistence.

### R2. Native Workspace Execution (No Sandbox, No Git Worktree)
- All tool operations (test execution, git commands, file reads/writes, terminal commands) operate directly and natively within the project's root directory (`/Users/zaali/dev/iex-code`).
- No virtual containers, sandboxes, or git worktree directories are required or created.

### R3. Adversarial Resilience, Quality & Precommit Verification
- Comprehensive unit, LiveView integration, and stress tests ensuring 100% feature coverage and edge-case handling across all tabs.
- Clean compilation (`mix compile --warnings-as-errors`), clean formatting (`mix format --check-formatted`), 0 dead assigns, and 0 compiler warnings under `mix precommit`.

## Acceptance Criteria

### Tab & Workflow Completeness
- [ ] Every interactive element (buttons, modals, inputs, drag/clicks) across all 9 tabs dispatches an active LiveView event with zero crashes or unhandled callbacks.
- [ ] Direct file editing, test execution, git staging, and terminal commands execute natively on the workspace root.

### Quality & Precommit
- [ ] `mix test` passes 100% across all suites with 0 failures.
- [ ] `mix precommit` passes with 0 compiler warnings, 0 unused deps, and 0 format errors.
## 2026-09-02T17:22:27Z

Build, package, and launch `iex-code` as a native macOS desktop application on this laptop using `elixir-desktop`, supporting both interactive development window execution and a production `.app` release pipeline.

Working directory: /Users/zaali/dev/iex-code
Integrity mode: development

## Requirements

### R1. Native Desktop Window & Development Launch
Configure `Desktop.Window` in `iex-code` with native window sizing, title, menu bar integration, and convenient launch tasks/scripts (e.g. `mix desktop` or `iex -S mix`) to launch a native macOS window displaying the LiveView workspace on this laptop.

### R2. Standalone macOS `.app` Release Packaging Pipeline
Configure OTP release assembly and desktop packaging in `mix.exs` (using `Desktop.Deployment.generate_installer/1` or release packaging steps) to compile assets and generate a standalone macOS `IexCode.app` bundle and installer.

### R3. Process Lifecycle & Clean Teardown
Implement native window close and quit handling ensuring that quitting the desktop app cleanly terminates the BEAM runtime, flushes SQLite WAL data, and releases database locks with zero orphan background processes.

## Verification Resources

- Automated window and process lifecycle verification testing startup, LiveView rendering, and clean shutdown.
- Local verification command launching the desktop window and inspecting the built release bundle.

## Acceptance Criteria

### Desktop Runtime & Windowing
- [ ] Native desktop window opens successfully and renders the `iex-code` Phoenix LiveView workspace.
- [ ] Development launch command starts the native window without requiring external browsers.
- [ ] Closing the window or triggering quit terminates the BEAM node cleanly with zero zombie processes.

### Release Packaging
- [ ] Production release packaging produces a valid macOS `.app` bundle structure without compilation errors.
- [ ] `mix precommit` passes cleanly with 0 failures and 0 warnings.

## 2026-09-03T03:35:00Z

Implement four next-level native desktop capabilities for `iex-code`: native macOS notifications on swarm lifecycle events, real-time physical memory and process telemetry in the LiveView footer, dynamic macOS Dock icon agent activity badging, and zero-config local LLM auto-discovery (Ollama, MLX, llama.cpp) for offline Apple Silicon swarms.

Working directory: /Users/zaali/dev/iex-code
Integrity mode: development

## Requirements

### R1. Native macOS System Notifications & Sound Cues
Dispatch native desktop notifications and sound cues upon swarm task completion, verification rejection, step failure, or pending human approval events using `Desktop.Window.show_notification` with graceful headless fallbacks.

### R2. Real-Time Physical Memory & Telemetry Chip in LiveView
Add a lightweight background memory poller that samples OS RSS and Erlang VM allocated heap (`:erlang.memory()`), broadcasting updates to LiveView to render an interactive status pill showing live footprint and micro-GC stats.

### R3. Dynamic macOS Dock Icon Badging & State
Dynamically update the macOS application Dock badge count and window title to reflect active swarm workers and waiting approval counts (e.g., `3 running`, `1 waiting`).

### R4. Zero-Config Local LLM Auto-Discovery
Implement an auto-detection probe in Settings and provider registry that discovers locally running inference servers (Ollama on `:11434`, LM Studio on `:1234`, or llama.cpp on `:8080`), querying available models and making them selectable with zero API key configuration.

## Verification Resources

- Automated test suites verifying notification triggers, memory poller broadcasts, dock badge calculations, and local LLM discovery endpoints.
- Integration tests in LiveView confirming telemetry rendering and provider picker updates.

## Acceptance Criteria

### Desktop System Integration
- [ ] Swarm completion, failure, and approval events trigger native macOS desktop notifications.
- [ ] Active swarm worker counts dynamically update the application Dock badge and window title.

### Observability & Local LLM
- [ ] LiveView footer renders a live memory pill showing OS RSS, BEAM allocated memory, and active process count with micro-GC details.
- [ ] Local LLM endpoints are auto-detected and surfaced in the provider model picker without requiring manual API keys.

### Codebase Health & Quality
- [ ] Automated tests cover notification triggers, memory sampling, dock badge logic, and local provider discovery.
- [ ] `mix precommit` passes cleanly with 0 failures, 0 warnings, and clean formatting.

## 2026-09-03T06:44:55Z

Use a very large team of agents.

Elevate `iex-code` into an advanced autonomous engineering suite featuring multi-window native desktop detachment, offline local semantic codebase indexing & vector search, atomic time-travel checkpointing & rollback scrubber, and multi-model adversarial consensus voting.

Working directory: /Users/zaali/dev/iex-code
Integrity mode: development

## Requirements

### R1. Multi-Window Native Desktop Detachment
Enable detaching focused workspace tools (dedicated Terminal multiplexer, Diff/Git Inspector, and DAG Research visualizer) into independent native macOS `Desktop.Window` instances synchronized in real time via Phoenix PubSub.

### R2. Offline Local Semantic Codebase Indexing & Vector Search
Provide zero-cloud semantic code search and symbol indexing powered by local embeddings (via local Ollama/llama.cpp inference) stored in SQLite for instantaneous contextual code retrieval during agent planning and file navigation.

### R3. Atomic Workspace Time-Travel Checkpoints & 1-Click Rollback
Implement pre-mutation snapshot checkpoints and an interactive visual LiveView time-travel scrubber enabling instant non-destructive rollbacks of multi-file modifications made by autonomous swarms.

### R4. Multi-Model Adversarial Consensus & Swarm Voting
Enable cross-model peer review (e.g. cloud models + local Apple Silicon models) on critical code diffs and architecture plans, presenting visual agreement matrices and automated consensus arbitration before code application.

## Verification Resources

- Automated test suites verifying multi-window PubSub sync, vector index/query accuracy, rollback file integrity, and multi-model consensus matrix calculations.
- LiveView integration tests ensuring reactive UI updates across all new views and controls.

## Acceptance Criteria

### Desktop Windowing & Search
- [ ] Detached windows (Terminal, Diff Inspector, DAG visualizer) mount as independent macOS windows and stay synchronized with the main workspace via PubSub.
- [ ] Codebase files are embedded and indexed locally in SQLite, returning ranked semantic code results with sub-second retrieval latency.

### Checkpoints & Consensus Voting
- [ ] Every autonomous swarm mutation creates an atomic snapshot checkpoint that can be fully rolled back via the LiveView time-travel scrubber without leaving orphaned edits.
- [ ] Multi-model consensus voting collects structured assessments from multiple providers, displays an agreement matrix in the UI, and enforces consensus thresholds before patch application.

### Codebase Health & Integrity
- [ ] Comprehensive test suites verify multi-window event synchronization, vector retrieval accuracy, rollback integrity, and consensus arbitration.
- [ ] `mix precommit` passes cleanly with 0 failures, 0 warnings, and clean formatting.


