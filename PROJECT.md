# Project: Codex CLI Desktop Parity & Studio-Grade Settings with Multi-Provider Reasoning Engine

## Architecture
This project elevates `iex-code` to full parity with Codex CLI desktop and implements a studio-grade Settings system with granular, model-aware reasoning effort configuration across diverse AI providers and local LLMs:

1. **Adaptive Multi-Provider Reasoning Engine (R1)**:
   - Unified capability detection (`IexCode.LLM.Capabilities`) distinguishing reasoning models (OpenAI o1/o3/o3-mini/o4, Claude 3.7 Sonnet, Gemini Flash Thinking, DeepSeek R1) from standard models.
   - Dynamic profile resolution (`IexCode.LLM.Reasoning`) combining global defaults, per-model custom overrides matrix, and session options with parameter clamping and omission rules.
   - Native payload construction (`IexCode.LLM.PayloadBuilder`):
     - OpenAI: serializes `reasoning_effort` ("low", "medium", "high"), automatically strips `temperature`, and maps `max_tokens` to `max_completion_tokens`.
     - Anthropic: serializes extended thinking (`thinking: %{"type" => "enabled", "budget_tokens" => budget}`), clamps `temperature` to 1.0, and ensures `max_tokens > budget_tokens`.
     - Gemini: serializes `thinkingConfig` (`thinkingBudget`, `thinkingLevel`) and compatible proxy payloads.
     - Local/DeepSeek R1: stateful `<think>...</think>` stream parsing (`IexCode.LLM.ThinkTagParser`) extracting reasoning metadata without leaking tags into editor/chat streams.
   - Settings schema persistence for `default_reasoning_effort`, `default_thinking_budget`, and `model_overrides` map.

2. **Codex CLI Desktop Feature Gap Parity (R2)**:
   - Autonomous Tool Execution Safety Policy (`IexCode.Tools.SafetyPolicy`): Configurable execution safety tiers (`full_auto`, `prompt_dangerous`, `read_only`) with per-tool category overrides (`shell_execution`, `file_mutations`, `git_push`, `web_search`, `read_only`).
   - Interactive Tool Approval Modal in `WorkspaceLive` (`#tool-approval-modal`): Intercepts dangerous mutating actions with command/diff previews and "Approve Once", "Always Allow for Session", and "Deny" actions.
   - Context Window Compaction & Token Management (`IexCode.LLM.ContextCompactor`): Automated compaction strategies (`token_compaction`, `rolling_summary`, `sliding_window`) triggered when token counts exceed threshold percent.
   - Custom System Instructions & Workspace Personas (`IexCode.LLM.SystemPromptBuilder`): Composites base role prompts, persona presets (`pragmatic_engineer`, `architect`, `security_auditor`, `minimalist`), custom instructions, coding style guidelines, and repository instruction files (`AGENTS.md`, `CODEX.md`).
   - Environment Variables & Secrets Sandbox: `isolated` and `inherit_filtered` execution sandbox modes for subshells/PTY, custom environment variables, and `SecretMasker` output scrubbing.
   - Desktop Sound & Appearance Ergonomics: Configurable sound volume and chimes in `IexCode.Desktop.Sound` with Web Audio PubSub fallback, plus persistent `theme_accent` and `layout_density`.

3. **Studio-Grade Settings UI & Diagnostics (R3)**:
   - Dedicated glassmorphic Settings studio at `/settings` and `/settings/:tab` across 6 tabs: Providers, Reasoning, Tool Approvals, Context & Personas, Environment, Sound & Appearance (preserving legacy section DOM IDs `#models`, `#execution`, etc. for backwards compatibility).
   - Interactive Provider & Model Cards: Dynamic model discovery and 1-click live latency ping tests for OpenAI, Anthropic, Ollama, LM Studio, and llama.cpp.
   - Live Reasoning Payload Previewer: Real-time visual inspector displaying the exact serialized JSON payload for any selected model based on current reasoning settings.
   - Command Palette (`Cmd+K`) integration: Direct indexed shortcuts and actions for jumping to individual settings tabs.
   - WorkspaceLive Quick Drawer: Right-aligned slide-over glass drawer for quick settings adjustments with deep-link to full studio.
   - Instant persistence & PubSub propagation: SQLite updates broadcast on `"settings"` topic, immediately consumed by active swarms without restarting.

4. **End-to-End LLM Client & Swarm Integration (R4)**:
   - Dynamic turn-by-turn resolution in `ModelRoute.resolve/2` and `Policy` so active swarms (`WorkspaceLive`, `SwarmSupervisor`, `RunDispatcher`, `AgentLoop`, `CoderAgent`, `PlannerAgent`) automatically apply active reasoning profiles.
   - Thinking trace display (`<.thinking_trace />`) rendered in chat messages from persisted reasoning metadata.
   - Tool execution approval interception in `AgentLoop` and `SessionServer`.

5. **Comprehensive Automated Test Suite & Precommit Compliance**:
   - Automated unit, component, and LiveView test suites covering payload serialization, tool safety policies, context compaction, settings studio tabs, latency ping, and approval modal flows.
   - Adversarial test suites for invalid reasoning values, payload boundary limits, and concurrency contention.
   - 100% clean `mix precommit` pass with 0 compiler warnings, 0 format issues, and 0 test failures.

## Feature Inventory
| # | Feature | Description | Milestone | Source |
|---|---------|-------------|-----------|--------|
| 1 | Model Capabilities Detection | Detect reasoning capabilities (o1/o3/o4, Claude 3.7, Gemini, DeepSeek) and supported parameters | M1 | ORIGINAL_REQUEST §R1 |
| 2 | Reasoning Profile Resolution | Resolve global defaults, per-model overrides matrix, and session options with parameter clamping/omission | M1 | ORIGINAL_REQUEST §R1 |
| 3 | OpenAI Reasoning Serialization | Serialize `reasoning_effort`, omit `temperature`, map `max_tokens` to `max_completion_tokens` | M1 | ORIGINAL_REQUEST §R1 |
| 4 | Anthropic Extended Thinking | Serialize `thinking` map (`type: enabled`, `budget_tokens`), clamp `temperature` to 1.0, enforce `max_tokens > budget` | M1 | ORIGINAL_REQUEST §R1 |
| 5 | Gemini & Proxy Thinking Payloads | Serialize `thinkingBudget`/`thinkingLevel` for native Gemini and OpenAI-compatible proxy thinking configs | M1 | ORIGINAL_REQUEST §R1 |
| 6 | Local Model Think Tag Parsing | Stateful streaming parser (`ThinkTagParser`) buffering `<think>` tags for DeepSeek R1 / Ollama / LM Studio | M1 | ORIGINAL_REQUEST §R1 |
| 7 | Settings Reasoning Schema & Migration | Ecto migration adding `default_reasoning_effort`, `default_thinking_budget`, and `model_overrides` map | M1 | ORIGINAL_REQUEST §R1 |
| 8 | Autonomous Tool Safety Policy | `SafetyPolicy` evaluating safety tiers (`full_auto`, `prompt_dangerous`, `read_only`) and per-category overrides | M2 | ORIGINAL_REQUEST §R2 |
| 9 | Context Window Compactor | Implement 3 compaction strategies (`token_compaction`, `rolling_summary`, `sliding_window`) with prune thresholds | M2 | ORIGINAL_REQUEST §R2 |
| 10 | System Prompt & Persona Builder | Composite base role prompts, personas, custom system prompt, coding style, and `AGENTS.md`/`CODEX.md` | M2 | ORIGINAL_REQUEST §R2 |
| 11 | Environment Sandbox & Secret Masking | `isolated` and `inherit_filtered` execution sandbox, custom env vars, and `SecretMasker` output scrubber | M2 | ORIGINAL_REQUEST §R2 |
| 12 | Desktop Sound & Appearance Settings | Sound volume flag (`-v`), chime mapping, Web Audio PubSub fallback, persistent theme accents and layout density | M2 | ORIGINAL_REQUEST §R2 |
| 13 | Codex CLI Settings Schema & Migration | Ecto migration adding approval tiers, compaction settings, personas, env vars, sound and appearance fields | M2 | ORIGINAL_REQUEST §R2 |
| 14 | Tabbed Settings Studio Architecture | Router `/settings/:tab` and LiveView 6-tab studio layout preserving legacy section DOM IDs | M3 | ORIGINAL_REQUEST §R3 |
| 15 | Interactive Provider Cards & Live Ping | Dynamic model discovery and 1-click live latency ping tests across OpenAI, Anthropic, Ollama, LM Studio, llama.cpp | M3 | ORIGINAL_REQUEST §R3 |
| 16 | Live Reasoning Payload Previewer | Real-time visual JSON inspector rendering serialized payload for selected model & reasoning settings | M3 | ORIGINAL_REQUEST §R3 |
| 17 | Command Palette Settings Tab Shortcuts | Indexed Command Palette actions for jumping directly to specific settings tabs (`Cmd+K`) | M3 | ORIGINAL_REQUEST §R3 |
| 18 | Workspace Quick Settings Drawer | Right-aligned slide-over glass drawer for instant workspace adjustments and deep link to studio | M3 | ORIGINAL_REQUEST §R3 |
| 19 | Interactive Tool Approval Modal Flow | LiveView approval modal in `WorkspaceLive` with command/diff preview, approve once, allow session, and deny | M4 | ORIGINAL_REQUEST §R2 |
| 20 | Swarm Route & Policy Integration | Wire `ModelRoute.resolve/2` and `Policy` to inject reasoning parameters into turn-by-turn swarm execution | M4 | ORIGINAL_REQUEST §R4 |
| 21 | Agent Loop & Session Server Integration | Integrate safety approvals, context compaction, and system prompt builder into `AgentLoop` and `SessionServer` | M4 | ORIGINAL_REQUEST §R4 |
| 22 | Thinking Trace Telemetry Wiring | Persist reasoning metadata on messages and render live thinking trace in chat | M4 | ORIGINAL_REQUEST §R4 |
| 23 | Reasoning Engine Unit & Payload Test Suite | Unit tests for capabilities detection, profile resolution, and OpenAI/Anthropic/Gemini/Ollama payload serialization | M5 | Acceptance Criteria |
| 24 | Safety Policy & Context Compaction Test Suite | Unit tests for safety policy evaluation, tier overrides, compaction strategies, and prompt builder | M5 | Acceptance Criteria |
| 25 | Settings Studio & Live Diagnostics Test Suite | LiveView integration tests for 6 studio tabs, provider ping, payload previewer, and Command Palette | M5 | Acceptance Criteria |
| 26 | Tool Approval Modal & Swarm Test Suite | LiveView integration tests for approval interception, decision handling, and swarm reasoning adaptation | M5 | Acceptance Criteria |
| 27 | Adversarial Hardening & Precommit Suite | Adversarial tests (invalid reasoning, boundary limits, concurrency) and clean `mix precommit` execution | M5 | Acceptance Criteria |

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| 1 | Adaptive Multi-Provider Reasoning Engine & Settings Persistence | Capabilities detection, profile resolution, OpenAI/Anthropic/Gemini/Ollama serialization, ThinkTagParser, reasoning schema & migration | None | DONE |
| 2 | Codex CLI Desktop Parity & Autonomous Tool Safety Engine | SafetyPolicy, safety tiers & category overrides, ContextCompactor, SystemPromptBuilder, env sandbox & SecretMasker, sound & appearance | M1 | DONE |
| 3 | Studio-Grade Settings UI & Diagnostics | Tabbed `/settings/:tab` studio, legacy section ID preservation, Provider Cards with live ping, Live Payload Previewer, Command Palette shortcuts, Quick Drawer | M1, M2 | DONE |
| 4 | Swarm, Tool Approval Modal & Runtime Integration | LiveView Tool Approval Modal (`#tool-approval-modal`), wire SafetyPolicy, ContextCompactor, SystemPromptBuilder, ModelRoute into AgentLoop & SessionServer | M1, M2, M3 | DONE |
| 5 | Comprehensive Test Suite, Adversarial Hardening & Precommit | Tiers 1-4 automated test suites, adversarial tests, live ping/modal flows, clean `mix precommit` (0 warnings, 0 failures) | M1, M2, M3, M4 | DONE |

## Interface Contracts

### M1: Reasoning Engine & Serialization
- `IexCode.LLM.Capabilities`:
  - `detect(provider, model) -> %{reasoning_supported: boolean(), type: :openai | :anthropic | :gemini | :local | :none, default_effort: String.t(), default_budget: integer()}`
  - `supports_temperature?(provider, model) -> boolean()`
  - `supports_extended_thinking?(provider, model) -> boolean()`
- `IexCode.LLM.Reasoning`:
  - `resolve_profile(provider, model, %AppSettings{} = settings, opts \\ []) -> %{reasoning_effort: String.t() | nil, thinking_budget: integer() | nil, temperature: float() | nil, max_tokens: integer()}`
  - `serialize_payload(provider, model, messages, system_prompt, %AppSettings{} = settings, opts \\ []) -> map()`
- `IexCode.LLM.ThinkTagParser`:
  - `parse_stream_delta(delta, state) -> {parsed_text, parsed_reasoning, new_state}`

### M2: Codex CLI Safety & Compaction
- `IexCode.Tools.SafetyPolicy`:
  - `evaluate(tool_name, %AppSettings{} = settings, session_overrides \\ %{}) -> :allow | {:prompt, String.t()} | {:deny, String.t()}`
  - `category_for_tool(tool_name) -> String.t()`
- `IexCode.LLM.ContextCompactor`:
  - `compact(messages, %AppSettings{} = settings, model_name) -> list(map())`
  - `estimate_tokens(messages) -> integer()`
- `IexCode.LLM.SystemPromptBuilder`:
  - `build(base_role_prompt, project_root, %AppSettings{} = settings) -> String.t()`
- `IexCode.Tools.SecretMasker`:
  - `scrub(output, list(String.t())) -> String.t()`

### M3: Settings Studio & Diagnostics
- `IexCode.LLM.Discovery`:
  - `ping_provider(provider, base_url, api_key) -> {:ok, latency_ms :: integer(), models :: list(String.t())} | {:error, reason :: any(), latency_ms :: integer()}`
- `IexCodeWeb.SettingsLive`:
  - Route: `/settings` and `/settings/:tab`
  - Assigns: `:active_tab` (`:providers`, `:reasoning`, `:approvals`, `:context`, `:environment`, `:appearance`), `:provider_latencies`, `:preview_payload_json`
  - Events: `"set_tab"`, `"ping_provider"`, `"update_reasoning_preview"`, `"save_model_override"`

### M4: Swarm & Tool Approval Modal
- `IexCodeWeb.WorkspaceLive`:
  - Modal: `#tool-approval-modal`
  - Assigns: `:active_approval`, `:show_approval_modal`
  - Events: `"approve_tool_action"`, `"always_allow_tool_category"`, `"deny_tool_action"`
- PubSub events:
  - `{:tool_approval_requested, approval}`
  - `{:tool_approval_decided, approval}`
  - `{:settings_updated, settings}`

### M5: Automated Verification & Gate
- Unit suites: `test/iex_code/llm/reasoning_test.exs`, `test/iex_code/tools/safety_policy_test.exs`, `test/iex_code/llm/context_compactor_test.exs`, `test/iex_code/llm/system_prompt_builder_test.exs`
- LiveView suites: `test/iex_code_web/live/settings_studio_test.exs`, `test/iex_code_web/live/tool_approval_modal_test.exs`, `test/iex_code_web/live/settings_live_test.exs`
- Precommit: `mix precommit` passes with 0 warnings, 0 format errors, 0 test failures.

## Code Layout
- `lib/iex_code/llm/capabilities.ex`: Model capability detection.
- `lib/iex_code/llm/reasoning.ex`: Reasoning profile resolution and payload serialization.
- `lib/iex_code/llm/think_tag_parser.ex`: Stateful stream chunk `<think>` tag parser.
- `lib/iex_code/llm/openai.ex`: Updated OpenAI adapter with reasoning effort and temperature omission.
- `lib/iex_code/llm/anthropic.ex`: Updated Anthropic adapter with extended thinking and temperature 1.0 clamping.
- `lib/iex_code/tools/safety_policy.ex`: Tool execution safety tiers and category overrides.
- `lib/iex_code/tools/secret_masker.ex`: Output secret scrubbing engine.
- `lib/iex_code/llm/context_compactor.ex`: Context compaction strategies.
- `lib/iex_code/llm/system_prompt_builder.ex`: System prompt and persona composer.
- `lib/iex_code/settings/app_settings.ex`: Extended Ecto schema for settings.
- `lib/iex_code/settings.ex`: Extended settings context functions.
- `lib/iex_code/desktop/sound.ex`: Updated desktop sound player with volume flag and PubSub fallback.
- `lib/iex_code_web/router.ex`: Tabbed routes for `/settings/:tab`.
- `lib/iex_code_web/live/settings_live.ex`: Studio Settings LiveView with 6 tabs, ping tests, previewer.
- `lib/iex_code_web/live/settings_live.html.heex`: Glassmorphic template preserving legacy section DOM IDs.
- `lib/iex_code_web/command_palette.ex`: Added Settings tab actions.
- `lib/iex_code_web/live/workspace_live.ex`: Tool approval modal handling and quick drawer.
- `lib/iex_code_web/live/workspace_live.html.heex`: Tool approval modal markup and quick drawer markup.
- `priv/repo/migrations/*`: Ecto migrations adding new settings columns.
- `test/*`: Automated test suites for all milestones.
