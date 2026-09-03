# Project: Studio-Grade Developer Cockpit & UI/Interaction Overhaul

## Architecture
This project transforms `iex-code` into a world-class, studio-grade developer cockpit featuring:
1. **Studio-Grade Glassmorphism & Layout Ergonomics (R1)**:
   - Deep carbon slate design system (`--color-carbon-950` through `400`), subtle glassmorphic backdrop filters (`.glass-surface`, `.glass-header`, `.glass-footer`), refined typography, and layout density toggles (`compact` vs `comfortable`).
   - Fluid collapsible tool panels with global keyboard shortcuts: `Cmd+B` to toggle the left sidebar and `Cmd+J` to toggle a docked bottom terminal panel without leaving the current view.
2. **Interactive Swarm & Workflow Visualizer Canvas (R2)**:
   - Visual interactive SVG/HTML hybrid canvas component (`SwarmCanvas`) with smooth drag-to-pan and wheel-to-zoom capabilities.
   - Dynamic cubic Bézier connector edges rendering real-time multi-agent swarm hierarchies and DAG dependency graphs.
   - Five normalized visual task states (`idle`, `planning`, `running`, `verified`, `failed`) with halo effects and animated live message flow pulses.
   - Per-node telemetry pills displaying real-time token counts (`input + output`) and physical memory metrics.
3. **High-Fidelity Side-by-Side & Unified Diff Inspector (R3)**:
   - Robust split (side-by-side) diff row alignment pairing additions and deletions with empty spacer rows to prevent vertical drift.
   - Intra-line word-level change highlighting using Elixir standard library `String.myers_difference/2`.
   - Syntax coloration for code tokens across Elixir and common file types.
   - Unification of `IexCode.TimeTravel` snapshot checkpoints with `interactive_diff_viewer` allowing split/unified viewing, intra-line diffs, and 1-click hunk rollback in both main workspace and detached `DiffLive`.
4. **Command Palette 2.0 & Frictionless Keyboard Navigation (R4)**:
   - Pure-Elixir fuzzy subsequence scoring engine searching across 8 entity categories: files, active swarms, sessions, model endpoints, git branches, terminal commands, views, and actions.
   - Rich split-pane modal (`max-w-4xl`) with interactive left results list and dynamic right preview cards showing metadata, diff stats, latency, and code previews.
   - Full action execution dispatch in LiveView for branch switching, terminal command execution, model selection, swarm inspection, and window detachment.
5. **Comprehensive Automated Testing & Precommit Compliance (Acceptance Criteria)**:
   - Automated LiveView and component test suites verifying collapsible panel state, layout density toggles, swarm canvas node updates, diff alignment, and Command Palette 2.0 filtering and execution.
   - 100% clean `mix precommit` execution with 0 compiler warnings, 0 format errors, and 0 test failures.

## Feature Inventory
| # | Feature | Description | Milestone | Source |
|---|---------|-------------|-----------|--------|
| 1 | Tailwind v4 Theme & Carbon Slate Tokens | Custom `@theme` tokens for carbon surfaces (`--color-carbon-950..400`), typography, and glass surfaces | M1 | ORIGINAL_REQUEST §R1 |
| 2 | Glassmorphic Utility Classes | Reusable `.glass-surface`, `.glass-surface-elevated`, `.glass-header`, `.glass-footer` backdrop filters | M1 | ORIGINAL_REQUEST §R1 |
| 3 | Layout Density Mode & Controls | Reactive `:layout_density` assign (`compact` vs `comfortable`), `data-density` attributes, and header toggle | M1 | ORIGINAL_REQUEST §R1 |
| 4 | Collapsible Left Sidebar (`Cmd+B`) | Sidebar collapse state, `Cmd+B` keyboard listener, fixed desktop CSS media queries, and header toggle button | M1 | ORIGINAL_REQUEST §R1 |
| 5 | Collapsible Bottom Terminal Panel (`Cmd+J`) | Docked terminal panel above status footer, `Cmd+J` shortcut listener, and quick actions (`mix test`, `mix precommit`) | M1 | ORIGINAL_REQUEST §R1 |
| 6 | MenuBar Shortcut Synchronization | Fix `MenuBar`'s `{:desktop_action, :toggle_sidebar}` and add `{:desktop_action, :toggle_terminal}` routing | M1 | ORIGINAL_REQUEST §R1 |
| 7 | Interactive Swarm SVG/HTML Canvas | Hybrid SVG/HTML canvas component with drag-to-pan, wheel-to-zoom, and responsive viewBox | M2 | ORIGINAL_REQUEST §R2 |
| 8 | Cubic Bézier Connector Edges | Dynamic SVG paths connecting DAG dependency steps and hierarchical swarm agent parents/children | M2 | ORIGINAL_REQUEST §R2 |
| 9 | Live Message Flow Pulses | Animated stroke-dasharray traveling pulses along active execution edges on PubSub events | M2 | ORIGINAL_REQUEST §R2 |
| 10 | Normalized Visual Task States | 5 canonical visual states (`idle`, `planning`, `running`, `verified`, `failed`) with colored halos | M2 | ORIGINAL_REQUEST §R2 |
| 11 | Per-Node Token & Memory Metrics | Compact telemetry pills on canvas nodes rendering token counts and memory footprint | M2 | ORIGINAL_REQUEST §R2 |
| 12 | Detached & Embedded DAG Unification | Integrate the interactive visualizer in both `WorkspaceLive` Swarm tab and `Detached.DagLive` | M2 | ORIGINAL_REQUEST §R2 |
| 13 | Synchronized Split Diff Row Alignment | Row pairing algorithm for `hunk_split_lines` with spacer rows ensuring perfect horizontal alignment | M3 | ORIGINAL_REQUEST §R3 |
| 14 | Intra-Line Word-Level Highlighting | Word/token diffing using `String.myers_difference/2` wrapping changes in highlighted chips | M3 | ORIGINAL_REQUEST §R3 |
| 15 | Diff Syntax Coloration | Syntax token styling for keywords, strings, atoms, and comments in diff viewports | M3 | ORIGINAL_REQUEST §R3 |
| 16 | Time-Travel & Interactive Diff Unification | Feed atomic checkpoint snapshots into `interactive_diff_viewer` with split/unified toggles and 1-click rollback | M3 | ORIGINAL_REQUEST §R3 |
| 17 | Detached Diff Time-Travel Scrubber | Integrate time-travel checkpoint timeline and rollback into `Detached.DiffLive` | M3 | ORIGINAL_REQUEST §R3 |
| 18 | Command Palette 2.0 Subsequence Engine | Fuzzy scoring algorithm with word boundary bonuses and category prefix filters (`>`, `@`, `#`, `$`, `/`, `!`) | M4 | ORIGINAL_REQUEST §R4 |
| 19 | Complete 8-Category Entity Indexing | Index Actions, Views, Files, Sessions, Active Swarms, Models, Git Branches, and Terminal Commands | M4 | ORIGINAL_REQUEST §R4 |
| 20 | Split-Pane Layout & Rich Preview Cards | `max-w-4xl` modal with left results list and dynamic right preview card rendering rich metadata | M4 | ORIGINAL_REQUEST §R4 |
| 21 | Full Action Execution Dispatch | LiveView event dispatch for switching branches, executing terminal commands, selecting models, and detaching windows | M4 | ORIGINAL_REQUEST §R4 |
| 22 | Keyboard Hints & Navigation Footer | Visual keyboard hint chips (`Cmd+K`, `Cmd+B`, `Cmd+J`, `↑↓`, `↵`, `esc`, prefix syntax) in palette footer | M4 | ORIGINAL_REQUEST §R4 |
| 23 | Layout & Ergonomics Test Suite | LiveView tests for sidebar collapse, bottom terminal dock, layout density toggling, and keyboard events | M5 | Acceptance Criteria |
| 24 | Swarm Canvas & Visualizer Test Suite | Component and LiveView tests for SVG canvas rendering, node updates, and pulse states | M5 | Acceptance Criteria |
| 25 | Diff Inspector & Intra-Line Test Suite | Unit and LiveView tests for split row alignment, word diffs, syntax styling, and time-travel rollback | M5 | Acceptance Criteria |
| 26 | Command Palette 2.0 Test Suite | Component and integration tests for fuzzy search across all 8 categories, preview cards, and action execution | M5 | Acceptance Criteria |
| 27 | Precommit Compliance Verification | 100% clean `mix precommit` execution with 0 warnings, 0 format errors, 0 unused deps, and 0 test failures | M5 | Acceptance Criteria |

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| 1 | Studio-Grade Glassmorphism & Layout Ergonomics | Tailwind v4 `@theme`, carbon tokens, glass utilities, density toggles, collapsible sidebar (`Cmd+B`), docked bottom terminal (`Cmd+J`), `MenuBar` sync | None | DONE |
| 2 | Interactive Swarm & Workflow Visualizer Canvas | `SwarmCanvas` component, SVG Bézier edges, flow pulses, visual task states, per-node telemetry pills, unified DAG view | M1 | DONE |
| 3 | High-Fidelity Side-by-Side & Unified Diff Inspector | Split diff row alignment, intra-line word diffs (`String.myers_difference/2`), syntax coloration, time-travel diffs & rollback in main and detached diff | M1 | PLANNED |
| 4 | Command Palette 2.0 & Frictionless Navigation | Fuzzy subsequence engine, 8 entity categories, split modal with rich preview cards, action execution, keyboard hints | M1 | PLANNED |
| 5 | E2E Integration, Visual Regression & Precommit Hardening | LiveView test suites across R1-R4, visual regression safeguards, and clean `mix precommit` | M1, M2, M3, M4 | PLANNED |

## Interface Contracts

### M1: Layout Ergonomics & Styling Tokens (COMPLETED)
- `assets/css/app.css`:
  - Design tokens: `--color-carbon-950` (#07090d), `--color-carbon-900` (#0a0d12), `--color-carbon-850` (#0d1117), `--color-carbon-800` (#11151c), `--color-carbon-700` (#1c2128), `--color-carbon-600` (#21262d), `--color-carbon-500` (#30363d).
  - Classes: `.glass-surface`, `.glass-surface-elevated`, `.glass-header`, `.glass-footer`.
  - Density: `[data-density="comfortable"]` and `[data-density="compact"]`.
- `WorkspaceLive` Assigns & Events:
  - Assigns: `:sidebar_collapsed` (bool), `:bottom_terminal_open` (bool), `:layout_density` ("comfortable" | "compact").
  - Events:
    - `"toggle_sidebar"` -> flips `@sidebar_collapsed` defensively.
    - `"toggle_bottom_terminal"` -> flips `@bottom_terminal_open` defensively.
    - `"toggle_layout_density"` -> toggles between `"comfortable"` and `"compact"` defensively.
  - Info:
    - `{:desktop_action, :toggle_sidebar}` -> routes to `"toggle_sidebar"`.
    - `{:desktop_action, :toggle_terminal}` -> routes to `"toggle_bottom_terminal"`.

### M2: Interactive Swarm Canvas
- `IexCodeWeb.Components.SwarmCanvas`:
  - `swarm_canvas(assigns)`: Renders interactive SVG/HTML canvas.
  - Required assigns: `:nodes`, `:edges`, `:active_run`, `:selected_node_id`, `:zoom_level`, `:pan_offset`.
- Visual Task States:
  - Canonical 5 states: `:idle`, `:planning`, `:running`, `:verified`, `:failed`.
  - Node telemetry: `%{tokens_in: integer, tokens_out: integer, memory_mb: float}`.

### M3: Diff Inspector & Intra-Line Highlighting
- `IexCodeWeb.Components.WorkspaceComponents`:
  - `interactive_diff_viewer(assigns)`: supports `diff_mode="split" | "unified"`.
  - `hunk_split_lines(assigns)`: pairs left (`deletion`) and right (`addition`) rows with `{:empty, :empty}` spacers.
  - Intra-line word diffs: `IexCodeWeb.DiffHighlighter.word_diff(old_line, new_line)` returning `[{:eq, str}, {:del, str}, {:ins, str}]`.
- Checkpoint Integration:
  - Checkpoint snapshots from `IexCode.TimeTravel` convert to unified diffs and render via `interactive_diff_viewer` with 1-click hunk/checkpoint rollback.

### M4: Command Palette 2.0
- `IexCodeWeb.CommandPalette`:
  - `search(query, files, sessions, category_filter \\ "all", extra \\ %{})`:
    - `extra` keys: `:swarms`, `:models`, `:branches`, `:terminal_commands`.
    - Category filters: `"all"`, `"actions"`, `"swarms"`, `"files"`, `"models"`, `"branches"`, `"terminal"`, `"views"`, `"sessions"`.
    - Result item: `%{id: string, title: string, subtitle: string, category: atom, event: string, shortcut: string, preview: map(), score: integer}`.
- LiveView Execution:
  - `execute_command_palette_item(socket, item)`: dispatches branch switches, terminal commands, model selections, and window detachment.

### M5: Automated Testing & Precommit Compliance
- Tests in `test/iex_code_web/`:
  - `test/iex_code_web/live/workspace_live_layout_test.exs` (PASS)
  - `test/iex_code/e2e/ui_studio_cockpit_e2e_test.exs` (PASS - 20/20)
  - `test/iex_code_web/components/swarm_canvas_test.exs`
  - `test/iex_code_web/components/diff_inspector_test.exs`
  - `test/iex_code_web/components/command_palette_component_test.exs`
  - `test/iex_code_web/live/workspace_live_command_palette_test.exs`
- Gate: `mix precommit` passes with 0 warnings, 0 format errors, 0 test failures.

## Code Layout
- `assets/css/app.css`: Tailwind v4 theme, carbon slate tokens, glass classes, density variables.
- `assets/js/app.js`: Global keyboard handlers (`Cmd+B`, `Cmd+J`, `Cmd+K`), palette hook.
- `assets/js/hooks/terminal_hook.js`: Key event pass-through for shortcut keys.
- `lib/iex_code_web/components/layouts.ex`: Root and app layout ergonomics.
- `lib/iex_code_web/desktop/menu_bar.ex`: Native macOS menu bar items and event broadcasts.
- `lib/iex_code_web/live/workspace_live.ex`: Main LiveView state, assigns, and event handlers.
- `lib/iex_code_web/live/workspace_live.html.heex`: Main workspace template, shell, sidebar, bottom terminal dock, status footer.
- `lib/iex_code_web/components/swarm_canvas_components.ex`: Interactive SVG/HTML canvas, Bézier edges, pulses.
- `lib/iex_code_web/components/dag_components.ex`: Updated DAG projection view using SwarmCanvas.
- `lib/iex_code_web/components/workspace_components.ex`: Interactive diff viewer, split row alignment, word diffs, command palette modal.
- `lib/iex_code_web/diff_highlighter.ex`: Intra-line word diffing using `String.myers_difference/2` and syntax tokens.
- `lib/iex_code_web/command_palette.ex`: Subsequence fuzzy engine and 8-category indexing.
- `lib/iex_code_web/live/detached/dag_live.ex`: Detached DAG visualizer LiveView.
- `lib/iex_code_web/live/detached/diff_live.ex`: Detached Git & Time-Travel diff LiveView.
- `test/iex_code_web/live/workspace_live_layout_test.exs`: M1 layout ergonomics tests.
- `test/iex_code_web/components/swarm_canvas_test.exs`: M2 Swarm visualizer tests.
- `test/iex_code_web/components/diff_inspector_test.exs`: M3 diff alignment and word diff tests.
- `test/iex_code_web/components/command_palette_component_test.exs`: M4 Command Palette 2.0 tests.
