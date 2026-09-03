# Project: Next-Level Native Desktop Capabilities for `iex-code`

## Architecture
This project extends `iex-code` with four next-level native desktop capabilities:
1. **Desktop Notifications & Sound Cues (`IexCode.Desktop.Notifier` & `IexCode.Desktop.Sound`)**:
   Native macOS notification center integration via `Desktop.Window.show_notification` and auditory cues via `/usr/bin/afplay` for swarm lifecycle milestones (completion, verification rejection, step failure, pending human approval) with headless/test guards.
2. **Real-time Memory & VM Telemetry (`IexCode.Observability.MemoryPoller`)**:
   Background GenServer polling OS RSS (`ps -o rss=`), BEAM allocators (`:erlang.memory()`), active processes, and micro-GC statistics (`:erlang.statistics(:garbage_collection)`), broadcasting over `"telemetry:memory"` to an interactive LiveView footer status pill.
3. **Dynamic macOS Dock Badging & Window Title (`IexCode.Desktop.Dock`)**:
   Tracks running swarm workers and waiting human approvals (e.g. `3 running, 1 waiting`), dynamically updating window title (`Desktop.Window.set_title`), LiveView page title, and macOS Dock badge.
4. **Zero-Config Local LLM Auto-Discovery (`IexCode.LLM.Discovery`)**:
   Non-blocking probes for local inference servers (Ollama :11434, LM Studio :1234, llama.cpp :8080), querying models and making them selectable in `WorkspaceLive` and `SettingsLive` with zero API key configuration.
5. **E2E Testing & Precommit Compliance**:
   Comprehensive test coverage across all four capabilities with 0 compiler warnings, 0 test failures, and clean `mix precommit`.

## Feature Inventory
| # | Feature | Description | Milestone | Source |
|---|---------|-------------|-----------|--------|
| 1 | Native macOS Desktop Notifications | Dispatch native notification banner on swarm events using `Desktop.Window.show_notification` with headless fallback | M1 | ORIGINAL_REQUEST §R1 |
| 2 | Auditory Sound Cues | Play macOS system sounds (`Hero.aiff`, `Sosumi.aiff`, `Basso.aiff`, `Ping.aiff`) via `/usr/bin/afplay` on lifecycle events | M1 | ORIGINAL_REQUEST §R1 |
| 3 | Swarm Lifecycle Event Integration | Hook into task completion, verification rejection, step failure, and pending approval | M1 | ORIGINAL_REQUEST §R1 |
| 4 | OS RSS Memory Poller | Sample resident set size on macOS via `ps -o rss=` in lightweight GenServer | M2 | ORIGINAL_REQUEST §R2 |
| 5 | BEAM Memory & Micro-GC Telemetry | Sample `:erlang.memory()`, `:erlang.system_info(:process_count)`, and micro-GC delta throughput | M2 | ORIGINAL_REQUEST §R2 |
| 6 | LiveView Footer Status Pill | Interactive status pill at bottom of LiveView workspace with luxury tooltip popover and GC trigger | M2 | ORIGINAL_REQUEST §R2 |
| 7 | Dynamic Window Title Updates | Update window title to reflect active worker and approval counts (`3 running, 1 waiting`) | M3 | ORIGINAL_REQUEST §R3 |
| 8 | Dynamic macOS Dock Icon Badging | Set Dock badge state and broadcast activity counts across swarm workers | M3 | ORIGINAL_REQUEST §R3 |
| 9 | Local LLM Server Probes | Concurrent non-blocking probes for Ollama (:11434), LM Studio (:1234), llama.cpp (:8080) | M4 | ORIGINAL_REQUEST §R4 |
| 10 | Zero-Config Provider Routing | Allow local endpoints without requiring manual API keys (fallback token / bypass check) | M4 | ORIGINAL_REQUEST §R4 |
| 11 | Local Model Picker in LiveView | Surface discovered local models in `WorkspaceLive` and `SettingsLive` with 1-click selection | M4 | ORIGINAL_REQUEST §R4 |
| 12 | Automated Tests & Precommit | Comprehensive unit and LiveView integration tests, clean `mix precommit` | M5 | Acceptance Criteria |

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| 1 | Native Notifications & Sound Cues | `IexCode.Desktop.Notifier`, `IexCode.Desktop.Sound`, swarm lifecycle hooks | None | DONE |
| 2 | Memory & Telemetry Poller with Footer Pill | `IexCode.Observability.MemoryPoller`, `"telemetry:memory"`, LiveView footer | None | DONE |
| 3 | Dynamic Dock Badging & Window Title | `IexCode.Desktop.Dock`, worker & approval state tracking, title sync | M1 | DONE |
| 4 | Zero-Config Local LLM Auto-Discovery | `IexCode.LLM.Discovery`, provider routing, LiveView model picker | None | DONE |
| 5 | E2E Integration & Precommit | Full test suites, edge case verification, `mix precommit` | M1, M2, M3, M4 | DONE |

## Interface Contracts

### M1: Desktop Notifier & Sound
- `IexCode.Desktop.Notifier.notify(message, opts)`:
  - `opts`: `[title: String.t(), type: :info | :warning | :error, sound: atom() | nil]`
  - Checks if `Desktop.Window` is alive (atom or PID); if not, logs and returns `{:ok, :fallback}`.
- `IexCode.Desktop.Sound.play(event_type)`:
  - `event_type`: `:swarm_completed | :verification_rejected | :step_failed | :approval_requested`
  - Spawns background task to run `/usr/bin/afplay -t 5 /System/Library/Sounds/<sound>.aiff`.
  - No-ops if `Mix.env() == :test` or `Application.get_env(:iex_code, :desktop_sound_enabled) == false`.

### M2: Observability Memory Poller
- `IexCode.Observability.MemoryPoller`:
  - Broadcasts `{:memory_telemetry, %IexCode.Observability.MemorySnapshot{}}` to topic `"telemetry:memory"`.
  - `MemorySnapshot`: `%{rss_bytes: integer(), beam_total_bytes: integer(), beam_processes_bytes: integer(), beam_system_bytes: integer(), process_count: integer(), gc_runs: integer(), gc_words_reclaimed: integer(), delta_gc_runs: integer(), delta_reclaimed_bytes: integer()}`.
  - `MemoryPoller.current_metrics()`: returns `%MemorySnapshot{}` synchronously for initial LiveView mount.

### M3: Desktop Dock & Window Title
- `IexCode.Desktop.Dock.set_activity(running_count, waiting_count)`:
  - Formats title: `"IexCode - #{running_count} running, #{waiting_count} waiting"`
  - Calls `Desktop.Window.set_title(IexCodeWindow, title)` if window alive.
  - Broadcasts `{:dock_activity_updated, %{running: running_count, waiting: waiting_count}}`.

### M4: Local LLM Auto-Discovery
- `IexCode.LLM.Discovery.scan()`:
  - Returns `%{ollama: %{online?: boolean(), models: list()}, lm_studio: %{online?: boolean(), models: list()}, llama_cpp: %{online?: boolean(), models: list()}}`.
- `IexCode.LLM.Discovery.Server`:
  - Periodic background polling every 30s; broadcast to `"llm:discovery"`.
  - `IexCode.LLM.Discovery.Server.get_discovered_models()` returns list of model descriptors.
- `IexCode.Execution.ModelRoute` & `IexCode.LLM`:
  - When provider is local or `is_local_endpoint?(base_url)`, bypass `:no_api_key` error by using token `"local"`.

## Code Layout
- `lib/iex_code/desktop/notifier.ex`: Desktop notification dispatcher.
- `lib/iex_code/desktop/sound.ex`: Audio cues player.
- `lib/iex_code/desktop/dock.ex`: Activity tracking, dock badge & window title manager.
- `lib/iex_code/desktop/swarm_hooks.ex`: Swarm lifecycle event subscriber.
- `lib/iex_code/observability/memory_poller.ex`: Memory & BEAM telemetry poller.
- `lib/iex_code/observability/memory_snapshot.ex`: Telemetry data structure.
- `lib/iex_code_web/live/components/memory_telemetry_pill.ex` (or embedded component in `workspace_live.html.heex`): Footer status pill.
- `lib/iex_code/llm/discovery.ex`: Local LLM probe engine.
- `lib/iex_code/llm/discovery/server.ex`: Discovery GenServer.
- `test/iex_code/desktop/notifier_test.exs`
- `test/iex_code/desktop/sound_test.exs`
- `test/iex_code/desktop/dock_test.exs`
- `test/iex_code/observability/memory_poller_test.exs`
- `test/iex_code/llm/discovery_test.exs`
- `test/iex_code_web/live/workspace_live_telemetry_test.exs`
- `test/iex_code_web/live/workspace_live_model_picker_test.exs`
