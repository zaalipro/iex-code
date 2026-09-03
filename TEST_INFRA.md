# E2E Test Infrastructure: Studio-Grade Developer Cockpit UI Overhaul (`iex-code`)

## 1. Overview & Test Philosophy
The Studio-Grade Developer Cockpit E2E testing framework provides an authoritative, requirement-driven, opaque-box test infrastructure derived strictly from `ORIGINAL_REQUEST.md` (Release 2026-09-03) and `PROJECT.md`.

### Core Principles
- **Opaque-Box Verification**: Exercise functionality through public user interactions, LiveView events (`render_click`, `render_change`, `render_submit`), PubSub broadcasts, and DOM element assertions (`has_element?/2`, `element/2`).
- **No Mocking of Business Logic**: Real SQLite sandboxes, real git repos, and genuine Phoenix LiveView lifecycles (`IexCode.E2E.Case`).
- **Zero Facades**: Every test asserts real state transitions and DOM updates without hardcoded dummy values.
- **4-Tier Testing Methodology**:
  - **Tier 1: Feature Coverage** — Happy-path verification for every isolated feature across R1–R4.
  - **Tier 2: Boundary & Corner Cases** — Extreme inputs, empty states, rapid toggling, and keyboard conflict handling.
  - **Tier 3: Cross-Feature Combinations** — Interactions between concurrent UI subsystems (e.g. Command Palette with collapsed sidebar and docked terminal, diff mode switching during live checkpoints).
  - **Tier 4: Real-World Application Scenarios** — Complete developer workflow from prompt submission to swarm execution, visualizer telemetry inspection, split diff review, hunk rollback, and final workspace commit.

---

## 2. Feature Inventory & 4-Tier Coverage Matrix

| Requirement | Target Feature | Description | Tier 1 (Feature) | Tier 2 (Boundary) | Tier 3 (Cross-Feature) | Tier 4 (Workload) |
|---|---|---|:---:|:---:|:---:|:---:|
| **R1** | Collapsible Sidebar | `toggle_sidebar` event, `data-collapsed` DOM attributes, desktop toggle button | ✓ | ✓ | ✓ | ✓ |
| **R1** | Collapsible Bottom Terminal | `toggle_bottom_terminal` event, `#bottom-terminal-dock` mounting/unmounting | ✓ | ✓ | ✓ | ✓ |
| **R1** | Layout Density Modes | `toggle_layout_density` between "comfortable" & "compact", `data-density` shell attribute | ✓ | ✓ | ✓ | ✓ |
| **R1** | Desktop Menu Routing | PubSub `{:desktop_action, :toggle_sidebar}` and `{:desktop_action, :toggle_terminal}` routing | ✓ | ✓ | ✓ | ✓ |
| **R2** | Swarm / DAG Visualizer | SVG/HTML canvas structure, layout layers, and task hierarchy rendering | ✓ | ✓ | ✓ | ✓ |
| **R2** | Visual Node States | 5 canonical states: `idle`, `planning`, `running`, `verified`, `failed` | ✓ | ✓ | ✓ | ✓ |
| **R2** | Live Telemetry Pills | Per-node & global token counts (in/out) and memory footprints (MB) | ✓ | ✓ | ✓ | ✓ |
| **R3** | Split vs Unified Diff Viewer | `set_diff_mode` switching between `inline` (unified) and `split` (side-by-side) | ✓ | ✓ | ✓ | ✓ |
| **R3** | Intra-Line Word Diffs | Myers word-level difference highlighting for fine-grained change visibility | ✓ | ✓ | ✓ | ✓ |
| **R3** | 1-Click Hunk Rollback | `revert_hunk`, `reject_hunk`, and `accept_hunk` staging/revert controls | ✓ | ✓ | ✓ | ✓ |
| **R4** | Fuzzy Subsequence Search | Pure-Elixir fuzzy matcher searching files, views, actions, and sessions | ✓ | ✓ | ✓ | ✓ |
| **R4** | Category Filtering | Filter switching across `all`, `actions`, `views`, `files`, and `sessions` | ✓ | ✓ | ✓ | ✓ |
| **R4** | Keyboard Navigation | Arrow key navigation (`command_palette_navigate`) with index cycling | ✓ | ✓ | ✓ | ✓ |
| **R4** | Action Execution Dispatch | LiveView dispatch on Enter/click (`command_palette_execute_selected`) | ✓ | ✓ | ✓ | ✓ |

---

## 3. Test Architecture & Runners

### Environment & Base Fixtures
- **Test Case Module**: `IexCode.E2E.Case` (`async: false`)
- **Isolation**:
  - Sandboxed SQLite test database with transaction rollbacks via `IexCode.DataCase.setup_sandbox/1`.
  - Ephemeral temporary workspaces generated via `create_temp_workspace/1` and initialized git repos via `init_temp_git_repo/1`.
  - Process cleanups on exit via `drain_all_e2e_processes/0`.
  - Mock LLM server integration via `MockLLMServer`.

### Test Runner Commands
```bash
# 1. Run the Studio Cockpit E2E Test Suite exclusively:
mix test test/iex_code/e2e/ui_studio_cockpit_e2e_test.exs

# 2. Run all E2E test suites:
mix test test/iex_code/e2e/

# 3. Run full verification suite including precommit compliance:
mix precommit
```

---

## 4. Tier Specifications & Detailed Scenarios

### Tier 1: Feature Coverage (Happy Path)
1. **R1 Layout Ergonomics**:
   - `toggle_sidebar` collapses and expands the navigation rail, updating state and classes.
   - `toggle_bottom_terminal` mounts and unmounts the docked terminal container `#bottom-terminal-dock`.
   - `toggle_layout_density` alternates between `"comfortable"` and `"compact"`, updating the shell's `data-density` attribute.
   - PubSub desktop events `{:desktop_action, :toggle_sidebar}` and `{:desktop_action, :toggle_terminal}` dispatch correctly to LiveView.
2. **R2 Swarm & Visualizer**:
   - Renders visualizer canvas (`#dag-execution-projection` or `#swarm-canvas`) with active nodes and layers.
   - Verifies node representation across task states: `idle`, `planning`, `running`, `verified`, `failed`.
   - Displays live telemetry metrics (token counts and memory status pills).
3. **R3 High-Fidelity Diff Inspector**:
   - Toggles view mode between split (side-by-side) and inline (unified) diff via `set_diff_mode`.
   - Hunk cards render with granular controls: Accept, Reject, and Revert buttons.
   - Intra-line word highlighting correctly distinguishes additions and deletions.
4. **R4 Command Palette 2.0**:
   - Opens and closes via `toggle_command_palette` and `close_command_palette`.
   - Fuzzy searches across actions, views, and workspace files via `command_palette_search`.
   - Switches category tabs (`command_palette_set_category`) and updates the active results.
   - Navigates items with `command_palette_navigate` and executes selections via `command_palette_execute_selected`.

### Tier 2: Boundary & Corner Cases
- **Rapid Panel Toggling**: Rapid repeated toggling of sidebar, bottom terminal, and command palette does not leave stranded states or corrupted assigns.
- **Empty Queries & No Results**: Empty search inputs, whitespace queries, and non-existent category filters recover gracefully with clear fallback states.
- **Empty / Malformed Diffs**: Empty diff strings, files without hunks, and single-character modifications render cleanly without runtime exceptions.
- **Zero-Node Visualizer**: Empty task plans or cleared runs render empty state projections without throwing nil errors.
- **Keyboard Navigation Wraparound**: Boundary tests for navigating `up` from index 0 (wrapping to end) and `down` from the last item (wrapping to 0).

### Tier 3: Cross-Feature Combinations
- **Cockpit Compact Layout with Open Terminal & Collapsed Sidebar**: Full interaction matrix verifying layout density `compact` behaves seamlessly while sidebar is collapsed and the bottom terminal dock is open.
- **Command Palette Action Execution within Collapsed Cockpit**: Invoking palette actions (e.g. switching tabs, toggling swarm mode) while sidebar is collapsed updates view state without resetting user layout preferences.
- **Split Diff Inspection with Time-Travel Checkpoints**: Generating file mutations, scrubbing through checkpoints, and toggling between split and unified diff modes without losing hunk alignment.
- **Live Visualizer State Updates under Background PubSub Events**: LiveView receives concurrent background PubSub broadcasts (`:run_updated`, `:telemetry_broadcast`) while interacting with the docked terminal.

### Tier 4: Real-World Application Scenarios
- **Scenario 1: Complete Developer Cockpit Lifecycle**:
  1. Developer mounts workspace session with comfortable layout density.
  2. Customizes workspace ergonomics: collapses sidebar (`toggle_sidebar`) and docks bottom terminal (`toggle_bottom_terminal`) for maximum editor area.
  3. Uses Command Palette (`Cmd+K`) to jump to changes view.
  4. Inspects multi-file git changes in split side-by-side mode.
  5. Reviews intra-line word diffs and triggers 1-click hunk rollback on an unwanted modification.
  6. Opens bottom terminal dock to verify git status and staging.
  7. Toggles layout density to compact and verifies clean, uncorrupted DOM hierarchy.

---

## 5. Coverage & Verification Standards
- **Failure Tolerance**: 0 test failures.
- **Compiler Compliance**: 0 compiler warnings under `mix compile --warnings-as-errors`.
- **Precommit Check**: Passes `mix precommit` cleanly.
