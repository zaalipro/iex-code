# Original User Request

## 2026-09-04T04:28:29Z

Use a very large team of agents.

Take the `iex-code` desktop application to the next level by closing all feature gaps with Codex CLI desktop and implementing a rich, studio-grade Settings system that supports granular, model-aware reasoning effort configuration across diverse AI providers and local LLMs.

Working directory: /Users/zaali/dev/iex-code
Integrity mode: development

## Requirements

### R1. Adaptive Multi-Provider Reasoning Effort Configuration
Implement a unified, model-aware reasoning configuration engine that dynamically maps reasoning parameters to each provider's native format:
- **OpenAI & Compatible (o1, o3, o3-mini)**: `reasoning_effort` (`"low"`, `"medium"`, `"high"`), automatically omitting unsupported fields like `temperature` for reasoning models.
- **Anthropic (Claude 3.7 Sonnet, Claude 3.5)**: Extended thinking (`thinking: %{"type" => "enabled", "budget_tokens" => budget}`), ensuring temperature is clamped to `1.0` per API spec.
- **Google Gemini (2.0 / 3.8 Flash Thinking)**: `thinking_budget` and thinking level parameters.
- **Local & Open Models (DeepSeek R1, Ollama, LM Studio)**: Dedicated reasoning token parsing, thinking flags, and context budget allocation.
- **Per-Model Overrides Matrix**: Allow users to configure global default reasoning effort and define per-model custom overrides (reasoning effort, budget tokens, max tokens, temperature) with automatic capability detection.

### R2. Codex CLI Desktop Feature Gap Parity
Fill critical feature gaps compared to Codex CLI desktop:
- **Autonomous Tool Execution Approval Modes**: Support configurable execution safety tiers (`full_auto`, `prompt_dangerous`, `read_only`), with per-tool category overrides (`shell_execution`, `file_mutations`, `git_push`, `web_search`) and visual approval modals in LiveView.
- **Context Window Compaction & Token Management**: Implement automated context compaction strategies (`token_compaction`, `rolling_summary`, `sliding_window`) and configurable history prune thresholds to prevent token limits.
- **Custom System Instructions & Workspace Personas**: Allow defining project-level custom system prompts, persona presets, and coding style rules persisted in settings.
- **Environment Variables & Secrets Sandbox**: Secure configuration of custom environment variables passed into command execution and agent subshells.
- **Desktop Sound & Appearance Ergonomics**: Configurable sound effects (volume, completion chimes, error alerts), theme accents, and persistent layout density.

### R3. Studio-Grade Settings UI & Diagnostics
Build a comprehensive, glassmorphic Settings studio (accessible via `/settings`, Command Palette `Cmd+K`, and workspace drawer):
- **Interactive Provider & Model Cards**: Visual health indicators, 1-click live latency ping tests, and dynamic model discovery for OpenAI, Anthropic, Ollama, LM Studio, and llama.cpp.
- **Live Reasoning Payload Previewer**: Real-time visual inspector displaying the exact JSON payload generated for any selected model based on current reasoning effort settings.
- **Instant Persistence & PubSub Propagation**: Atomic SQLite settings updates broadcasted via `Phoenix.PubSub` so active swarms and chat sessions adapt immediately without restarting.

### R4. End-to-End LLM Client & Swarm Integration
Integrate the adaptive reasoning engine into `IexCode.LLM.Client`, `IexCode.LLM.OpenAI`, `IexCode.LLM.Anthropic`, and swarm dispatchers (`WorkspaceLive`, `SwarmSupervisor`, `RunDispatcher`) so all agent interactions, tools, and background runs automatically honor active reasoning profiles.

## Verification Resources

- Automated unit and component test suites covering reasoning payload generation for all model families (OpenAI, Anthropic, Gemini, Ollama).
- LiveView integration tests for the Settings studio tabs, live ping latency tests, and tool approval modal flows.
- Adversarial test suites for invalid reasoning values, payload compatibility, and concurrency contention.

## Acceptance Criteria

### Reasoning Engine & Providers
- [ ] OpenAI client correctly serializes `reasoning_effort` for o1/o3 models and omits `temperature`.
- [ ] Anthropic client correctly serializes `thinking` budget tokens and clamps `temperature` to 1.0.
- [ ] Settings schema persists global reasoning effort and per-model overrides.
- [ ] Live reasoning payload previewer renders the exact serialized payload in the UI.

### Codex CLI Parity & Tool Approvals
- [ ] Tool execution policy enforces `full_auto`, `prompt_dangerous`, and `read_only` modes with per-tool override capability.
- [ ] Context compaction strategy triggers when conversation token usage exceeds configured thresholds.
- [ ] Custom environment variables and system instructions are injected into agent execution contexts.

### Settings UI & Quality
- [ ] Settings studio renders with deep carbon glassmorphism, responsive tabs, and live provider ping diagnostic tools.
- [ ] Settings can be opened directly from WorkspaceLive via Command Palette and keyboard shortcuts.
- [ ] Automated test suites pass 100% with zero failures.
- [ ] `mix precommit` passes cleanly with 0 failures, 0 warnings, and clean formatting.
