# Original User Request

## 2026-08-20T07:14:48Z

<USER_REQUEST>
# Next-Level IexCode: Desktop AI Coding Harness & Swarm Engine

An advanced Elixir and Phoenix LiveView desktop AI coding harness (IexCode) featuring asynchronous multi-process agent swarm execution, live tool progress telemetry, interactive code diffs, terminal execution, and project workspace management.

Working directory: /Users/zaali/dev/iex-code
Integrity mode: development

## Requirements

### R1. Autonomous Multi-Agent Swarm Intelligence & OTP Execution
Implement robust autonomous feedback loops between PlannerAgent, ExplorerAgent, CoderAgent, and VerifierAgent. Each subagent runs as an isolated, supervised OTP process that executes tools, evaluates outputs, performs self-correcting iterations, and streams real-time progress events over Phoenix PubSub.

### R2. World-Class Desktop UI/UX & Live Telemetry
Refine the 4-column subagent progress cards and hierarchical operation tree:
- Real-time animated progress bars with live execution latency metrics (ms) and PID monitors.
- Interactive side-by-side / inline syntax-highlighted code diff viewer for proposed and applied patches.
- Integrated file tree explorer with instant search, syntax preview, and terminal session integration.

### R3. Advanced Developer Tooling Suite
Equip the coding harness with comprehensive developer tools:
- AST-aware search and multi-file patching engine.
- Automated test runner with stack trace parsing and instant auto-fix suggestions.
- Git integration for workspace diffing, staging, and commit generation.

### R4. Multi-Provider Streaming & Resilience
Seamless streaming and fallback support for OpenAI-compatible endpoints (https://cli.llmotions.com/v1), Gemini models, Anthropic Claude, and local LLMs with auto-retry, UTF-8 byte sanitization, and graceful failure recovery.

## Verification Resources
- Test suite: `mix test` and `mix precommit`
- Endpoint integration: `https://cli.llmotions.com/v1` with model `gemini-3.7-flash-high`
- Browser validation: LiveView reactive interaction across tabs, swarm cards, and modals

## Acceptance Criteria

### Swarm & Process Architecture
- [ ] Swarm execution spawns dedicated OTP processes per agent and operation with live PubSub telemetry.
- [ ] All operations stream progress (0% -> 100%) with millisecond timings and process PIDs displayed in the 4-column card grid.
- [ ] Error feedback loops allow agents to auto-correct syntax and test failures autonomously.

### UI/UX & Interactivity
- [ ] All UI controls (new session `+`, swarm toggle, tab switches, file inspection, modals) connect immediately via WebSocket without timeouts.
- [ ] Stored operations and messages render cleanly without UTF-8 encoding crashes.
- [ ] Responsive dark-mode interface with monospace code views, progress indicators, and status badges.

### Quality & Tests
- [ ] Automated test suite runs with 0 failures and 0 compiler warnings via `mix precommit`.

</USER_REQUEST>
