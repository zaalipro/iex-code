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

## 2026-09-04T09:39:40Z

Use a very large team of agents.

Take the `iex-code` desktop application to the next level by building a Grok-like Workflows engine (`/create-workflow`, `/workflows`, visual running workflow tracker), upgrading Deep Research with citation graphs and conflict audits, and enhancing multi-agent Swarm coordination with live telemetry and interactive steering.

Working directory: /Users/zaali/dev/iex-code
Integrity mode: development

## Requirements

### R1. Grok-Like Workflows Engine & Schema (`/create-workflow`, `/workflows`)
Implement a first-class Workflows subsystem persisted per project in SQLite (`workflows` and `workflow_runs` schemas):
- **Workflow Definitions**: Support multi-step directed graphs with parameter variables (e.g., `{{feature_name}}`, `{{target_files}}`, `{{research_topic}}`). Steps can chain Deep Research, Swarm Code Generation, Automated Test Verification, Security & Safety Audits, and Git Commits.
- **Model-Aware Step Configuration**: Each step configures its model provider, model ID, reasoning effort (`none`, `low`, `medium`, `high`, `thinking_budget`), enabled tools, and safety policy (`full_auto`, `prompt_dangerous`).
- **Slash Commands & Palette Routing**:
  - `/create-workflow`: Interactive modal / prompt-driven assistant to construct and validate new workflows from natural language or visual builders.
  - `/workflows`: Dedicated route (`/workflows` or `/workflows/:id`) and workspace view listing all project workflows in glassmorphic cards with execution counts, tags, duration metrics, and 1-click launch.

### R2. Beautiful Real-Time Workflow Execution & Tracking Cockpit
Build a world-class, studio-grade visual execution tracker when a user launches a workflow:
- **Interactive SVG Workflow Canvas**: Renders the workflow graph with animated cubic Bézier connectors, glowing node states (`:pending`, `:running`, `:completed`, `:failed`, `:paused`), active step progress rings, and real-time execution pulses.
- **Step Telemetry & Live Inspector**: Clicking any step reveals live streaming outputs, agent thinking traces, token consumption, elapsed execution time, and generated artifacts (diffs, reports, code snippets).
- **Interactive Execution Controls**: Full control suite to pause, resume, cancel, or retry individual workflow steps or the entire run.

### R3. Advanced Deep Research Upgrades
Enhance the existing `IexCode.Research` subsystem:
- **Real-Time Citation & Source Graph**: Visual source cards showing domain trust ratings, relevance scores, and direct citation links in synthesized research reports.
- **Contradiction & Conflict Resolution**: Multi-source fact verification highlighting conflicting evidence and synthesizing confidence-weighted conclusions.
- **Export & Workflow Chaining**: Seamless handoff of research findings directly into downstream code synthesis and swarm implementation steps.

### R4. Multi-Agent Swarm Coordination & Dynamic Telemetry
Elevate multi-agent Swarm capabilities:
- **Dynamic Role Allocation**: Swarm coordinator adapts agent roles based on task complexity (e.g. Explorer, Architect, Coder, Auditor).
- **Consensus & Voting Matrices**: Pairwise agreement matrices for multi-model code review and automated merge gating.
- **Live Peer Message Stream**: Real-time visual timeline showing agent-to-agent communication pulses and task handoffs.

### R5. Comprehensive Test Suite & Precommit Pass
- Author comprehensive ExUnit test suites covering workflow persistence, execution engine, LiveView `/workflows` UI, SVG canvas components, Deep Research DAG enhancements, and swarm telemetry.
- Pass `mix precommit` cleanly with 0 failures, 0 warnings, and clean formatting repository-wide.

## Verification Resources

- Automated LiveView test suites verifying `/workflows` list rendering, `/create-workflow` modal creation, and real-time PubSub updates during workflow runs.
- Unit and property tests for workflow DAG resolution, cycle detection, variable substitution, and state transitions.
- End-to-end integration scenario testing full workflow execution from creation to completion.

## Acceptance Criteria

### Workflows Engine & Commands
- [ ] `/create-workflow` opens the workflow creation interface and successfully saves a valid workflow to the database.
- [ ] `/workflows` displays all project workflows with rich metadata cards, tags, and run history.
- [ ] Selecting and launching a workflow immediately opens the live tracking cockpit with real-time SVG step graph and state pulses.
- [ ] Workflow steps honor configured model reasoning efforts and tool approval policies.

### Tracking Cockpit & Controls
- [ ] Real-time updates reflect step execution status (`pending`, `running`, `completed`, `failed`) without page reloads.
- [ ] Step inspector displays live streaming thoughts, logs, and generated artifacts.
- [ ] User can pause, resume, retry, or cancel a running workflow run.

### Deep Research & Swarm
- [ ] Deep research generates rich citation cards and resolves conflicting source claims.
- [ ] Swarm visualizer reflects dynamic role assignments and consensus voting results.

### Code Quality & Precommit
- [ ] Automated test suites pass 100% with zero failures.
- [ ] `mix precommit` passes cleanly repository-wide with 0 compiler warnings and 0 format errors.
