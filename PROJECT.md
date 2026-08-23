# Project: Interactive PTY Terminal with xterm.js & Supervised OTP Backend

## Architecture
```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           WorkspaceLive (Frontend)                          │
│   ├── TerminalHook (xterm.js + FitAddon + SearchAddon + WebLinksAddon)     │
│   ├── Quick Action Toolbar (iex, mix test, mix precommit, git status/diff)  │
│   └── Visual Occupant Pill ("🤖 Agent Active" vs "User Interactive")        │
└─────────────────────────────────────▲───────────────────────────────────────┘
                                      │ Phoenix PubSub / LiveView push_event
                                      │ Topic: "session:<session_id>:terminal"
┌─────────────────────────────────────▼───────────────────────────────────────┐
│                      IexCode.Tools.TerminalServer (Facade)                   │
│   ├── ensure_started/2, send_input/2, resize/3, send_signal/2               │
│   ├── run_command/2, run_agent_command/4, get_history/1, clear/1, restart/2 │
│   ├── search_history/3, kill/1, whereis/1, running?/1, get_state/1          │
└─────────────────────────────────────▲───────────────────────────────────────┘
                                      │ Dynamic Registry & Supervision
┌─────────────────────────────────────▼───────────────────────────────────────┐
│                    IexCode.Tools.TerminalSupervisor                         │
│   └── IexCode.Tools.TerminalSession (GenServer per workspace session)       │
│       ├── Registered at {:via, Registry, {IexCode.SessionRegistry, ...}}    │
│       ├── Ring buffer history management, UTF8Buffer & replay               │
│       ├── Occupant state management (:user | {:agent, name, op_id})         │
│       └── IexCode.Tools.PTYAdapter (priv/pty_shim.py + Port fallback)       │
│           └── Native OS Shell Process (zsh / bash / iex -S mix)             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Feature Inventory
| # | Feature | Description | Milestone | Source |
|---|---------|-------------|-----------|--------|
| 1 | Supervised PTY Process Spawner | Spawns interactive shell (`zsh`/`bash`/`iex -S mix`) in workspace root via PTY master/slave pair | M1 (DONE) | ORIGINAL_REQUEST §R1 |
| 2 | Bidirectional Stdin / Keystroke Forwarding | Dispatches raw keystrokes and escape sequences (Ctrl+C, Ctrl+D, Ctrl+Z) to shell | M1 (DONE) | ORIGINAL_REQUEST §R1 |
| 3 | PubSub Raw Output Streaming | Streams stdout/stderr chunks in real-time over PubSub topic `session:<session_id>:terminal` | M1 (DONE) | ORIGINAL_REQUEST §R1 |
| 4 | Dynamic Window Resizing (SIGWINCH) | Resizes PTY dimensions (columns x rows) upon terminal container resize | M1 (DONE) | ORIGINAL_REQUEST §R1 |
| 5 | Shell Lifecycle & Clean Termination | Gracefully restarts, kills, or re-spawns shell process without leaving zombie processes | M1 (DONE) | ORIGINAL_REQUEST §R1 |
| 6 | Sliding Ring Buffer Memory Storage | Maintains recent terminal output chunks with UTF-8 safety and instant replay on mount | M1 (DONE) | ORIGINAL_REQUEST §R3 |
| 7 | Agent Command Execution Dispatch | Allows `ExplorerAgent`, `CoderAgent`, `VerifierAgent` to dispatch shell commands | M2 (DONE) | ORIGINAL_REQUEST §R3 |
| 8 | Live Agent Execution Streaming & Telemetry | Broadcasts agent execution lifecycle and live output chunks over PubSub and telemetry | M2 (DONE) | ORIGINAL_REQUEST §R3 |
| 9 | Visual Terminal Occupation Indicator | Displays visual banner/status badge showing User Session vs Agent Occupied | M2 (DONE) | ORIGINAL_REQUEST §R3 |
| 10 | Searchable Terminal History API | Server-side and client-side searchable terminal scrollback API | M2 (DONE) | ORIGINAL_REQUEST §R3 |
| 11 | xterm.js Terminal Canvas & Hook | Mounts full xterm.js terminal with ANSI truecolor rendering, font ligatures, cursor styles | M3 (DONE) | ORIGINAL_REQUEST §R2 |
| 12 | Terminal Dimension Auto-Fitting (`fitAddon`) | Observes resize observer events and pushes updated `cols`/`rows` to LiveView | M3 (DONE) | ORIGINAL_REQUEST §R2 |
| 13 | Quick Action Toolbar | One-click launch buttons: `iex -S mix`, `mix test`, `mix precommit`, `git status`, `git diff` | M3 (DONE) | ORIGINAL_REQUEST §R2 |
| 14 | Terminal Clear & History Reset | Clears xterm.js screen and resets terminal viewport | M3 (DONE) | ORIGINAL_REQUEST §R2 |
| 15 | LiveView Workspace Integration | Connects `WorkspaceLive` and `WorkspaceComponents` to PTY backend via PubSub & events | M3 (DONE) | ORIGINAL_REQUEST §R2 |
| 16 | E2E Test Suite Pass (Tiers 1-4) | 100% pass across unit, integration, LiveView, and stress test tiers | M4 | ORIGINAL_REQUEST §R4 |
| 17 | Adversarial Coverage Hardening (Tier 5) | White-box adversarial testing, edge cases, flood resistance, and zombie checks | M4 | ORIGINAL_REQUEST §R4 |
| 18 | Strict Precommit Verification | 0 compiler warnings, 0 format discrepancies, 100% test pass rate on `mix precommit` | M4 | ORIGINAL_REQUEST §R4 |

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| M1 | Backend OTP Supervision & PTY Engine | `TerminalSupervisor`, `TerminalSession`, `TerminalServer`, `PTYAdapter`, `priv/pty_shim.py`, PubSub streaming, buffer, resize, signal traps | None | DONE |
| M2 | Agent Terminal Execution & Telemetry | `run_agent_command/4`, agent telemetry events, occupant state management, search API, agent integration | M1 | DONE |
| M3 | Frontend xterm.js Integration & LiveView Hook | `package.json`, `@xterm/xterm`, `TerminalHook`, `WorkspaceLive`, `WorkspaceComponents.terminal_session/1`, quick actions, CSS vendoring | M1, M2 | DONE |
| M4 | Final Milestone: E2E Verification & Hardening | Pass 100% E2E test suite (Tiers 1-4), Tier 5 adversarial hardening, clean `mix precommit` verification | M1, M2, M3, TEST_READY | IN_PROGRESS |

## Interface Contracts

### `IexCode.Tools.TerminalServer`
```elixir
@spec ensure_started(session_id :: String.t(), opts :: keyword()) :: {:ok, pid()} | {:error, term()}
@spec send_input(session_id :: String.t(), data :: binary(), opts :: keyword()) :: :ok | {:error, term()}
@spec resize(session_id :: String.t(), cols :: pos_integer(), rows :: pos_integer()) :: :ok | {:error, term()}
@spec send_signal(session_id :: String.t(), signal :: atom() | binary()) :: :ok | {:error, term()}
@spec run_command(session_id :: String.t(), command :: String.t()) :: :ok | {:error, term()}
@spec run_agent_command(session_id :: String.t(), command :: String.t(), agent_name :: String.t(), opts :: keyword()) ::
        {:ok, %{output: String.t(), exit_code: integer(), duration_ms: integer()}} | {:error, term()}
@spec search_history(session_id :: String.t(), query :: String.t() | Regex.t(), opts :: keyword()) ::
        {:ok, [%{line_number: integer(), text: String.t(), match_range: {integer(), integer()}}]} | {:error, term()}
@spec get_history(session_id :: String.t()) :: binary()
@spec clear(session_id :: String.t()) :: :ok
@spec restart(session_id :: String.t(), opts :: keyword()) :: {:ok, pid()} | {:error, term()}
@spec kill(session_id :: String.t()) :: :ok
@spec whereis(session_id :: String.t()) :: pid() | nil
@spec running?(session_id :: String.t()) :: boolean()
@spec get_state(session_id :: String.t()) :: {:ok, map()} | {:error, :not_found}
```

### PubSub Topic: `"session:<session_id>:terminal"`
- `{:terminal_output, %{session_id: String.t(), data: binary(), timestamp: DateTime.t()}}`
- `{:terminal_status, %{session_id: String.t(), status: atom(), shell: binary(), occupant: term()}}`
- `{:terminal_occupant, %{session_id: String.t(), occupant: :user | {:agent, String.t(), String.t() | nil}}}`
- `{:terminal_exit, %{session_id: String.t(), exit_code: integer(), reason: term()}}`
- `{:terminal_cleared, %{session_id: String.t()}}`
- `{:terminal_resized, %{session_id: String.t(), cols: integer(), rows: integer()}}`

## Code Layout
```
lib/iex_code/
├── application.ex                             # Starts TerminalSupervisor in supervision tree
├── tools/
│   ├── terminal_supervisor.ex                 # DynamicSupervisor for active TerminalSessions
│   ├── terminal_server.ex                     # Public client facade
│   ├── terminal_session.ex                    # GenServer per workspace session
│   └── pty_adapter.ex                         # PTY process spawner and fallback
priv/
└── pty_shim.py                                # POSIX PTY master/slave bridge

lib/iex_code_web/
├── live/
│   └── workspace_live.ex                      # LiveView terminal events, subscriptions, push_events
└── components/
    └── workspace_components.ex                # terminal_session/1 template, toolbar, xterm viewport

assets/
├── package.json                               # @xterm/xterm, addons dependencies
├── vendor/
│   └── xterm.css                              # Vendored xterm CSS for Tailwind v4
├── js/
│   ├── app.js                                 # Register TerminalHook in Hooks
│   └── hooks/
│       └── terminal_hook.js                   # xterm.js hook, FitAddon, events, paste
└── css/
    └── app.css                                # Imports vendor/xterm.css

test/
├── iex_code/
│   ├── tools/
│   │   ├── terminal_session_test.exs          # Backend unit tests
│   │   ├── terminal_server_test.exs           # Facade unit tests
│   │   └── terminal_stress_test.exs           # High-throughput & crash tests
│   ├── engine/
│   │   └── agent_terminal_execution_test.exs  # Agent telemetry & command tests
│   └── e2e_terminal/
│       └── e2e_pty_terminal_test.exs          # Opaque-box E2E test suite
└── iex_code_web/
    └── live/
        └── workspace_live_terminal_test.exs   # LiveView integration tests
```
