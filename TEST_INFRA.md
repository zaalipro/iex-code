# Next-Level IexCode: Comprehensive Test Infrastructure & Methodology Specification

## 1. Test Philosophy & Architecture

The IexCode test infrastructure adheres to a strict **4-Tier Opaque-Box & Integration Testing Methodology**. Every power feature and engine is tested strictly against interface contracts, user requirements, and observable behaviors across OTP GenServers, supervised tasks, Phoenix PubSub telemetry channels, LiveView sockets, and developer tooling CLI adapters.

### Core Testing Pillars:
1. **Opaque-Box Verification**: Tests validate outputs, side effects, state mutations, and DOM elements without coupling to private internal state.
2. **Self-Contained & Isolated Sandboxes**: Every test executes within its own isolated filesystem sandbox (`System.tmp_dir!()`), temporary Git repository, and Ecto SQLite sandbox.
3. **No External Network Dependencies**: All LLM streaming, token ingestion, and Git remote operations are fully isolated via in-memory mock adapters (`MockLLMServer`, local bare Git remotes).
4. **Adversarial & Fault-Tolerant Verification**: Tests actively probe process crashes, socket disconnections, malformed inputs, unicode corruption, TOCTOU race conditions, and timeout bounds.

```
+-----------------------------------------------------------------------------------------------+
|                                    4-TIER TEST ARCHITECTURE                                   |
+-----------------------------------------------------------------------------------------------+
| Tier 1: Category-Partition Feature Coverage (Happy path across all discrete capabilities)    |
| Tier 2: Boundary Value Analysis (BVA) & Edge Cases (Clamping, empty states, stress limits)     |
| Tier 3: Pairwise Combinatorial Interactions (Cross-feature interactions & telemetry)          |
| Tier 4: Real-World Workload Scenarios (End-to-end multi-step developer workflows)             |
+-----------------------------------------------------------------------------------------------+
```

---

## 2. 4-Tier Testing Methodology

### Tier 1: Category-Partition Functional Coverage
Deconstructs each requirement into discrete equivalence classes and verifies standard operational paths:
- **Command Palette (`Cmd+K`)**:
  - Modal opening, backdrop rendering, close trigger via ESC / click-away.
  - Search filtering by query string against Actions, Views, Files, and Sessions.
  - Category pill filter isolation (`"all"`, `"actions"`, `"views"`, `"files"`, `"sessions"`).
  - Item execution: Tab switching, file buffer opening, test execution dispatch.
- **Visual Test Runner**:
  - Panel rendering under `active_tab="tests"`.
  - Execution triggers for `"all"`, `"failed"`, `"stale"`, and single `"file"` test runs.
  - Progress bar rendering (0% -> 100%) driven by PubSub/task telemetry.
  - Metrics summary strip display (Total, Passed, Failures, Duration, Seed).
- **AutoFix Studio**:
  - Structured failure card rendering with Left vs Right assertion diffs.
  - 1-click AutoFix proposal formulation and unified diff preview.
  - Atomic patch application via `MultiPatch` and verification re-run.
  - Transaction rollback on demand.
- **AST Query Explorer**:
  - Symbol query searching across project source trees.
  - Filtering by type badges (`def`, `defp`, `defmodule`, `defmacro`, `@spec`, `@callback`).
  - Code snippet display with line numbers and 1-click jump to editor.
- **Git Branch & Multi-File Staging Hub**:
  - Branch listing (`Git.branches/1`), switching (`Git.switch_branch/3`), and branch creation.
  - 3-tier staging tree: Staged, Unstaged, and Untracked rails.
  - Single and bulk staging/unstaging (`stage_file`, `unstage_file`, `stage_all`, `unstage_all`).
  - Granular hunk unstaging (`HunkOps.unstage_hunk/4`).
  - Conventional AI commit message formulation and direct committing.

### Tier 2: Boundary Value Analysis (BVA) & Edge Cases
Exhaustively tests limits, empty conditions, and exception pathways:
- **Command Palette**:
  - Empty search results (render empty state card without crashing).
  - Arrow navigation boundary clamping (index `< 0` and index `>= length`).
  - Special regex characters in search query (`[`, `]`, `*`, `+`, `?`, `\`, `"`, `$` ).
  - Jumping to deleted or moved files.
- **Visual Test Runner**:
  - Test suite timeouts and OS port process kills.
  - Compilation errors in `lib/` before test execution starts (`%CompilationError{}`).
  - Duplicate / rapid test trigger requests during an active execution run.
- **AutoFix Studio**:
  - Unfixable errors (graceful fallback notification when no heuristic applies).
  - TOCTOU file modification between proposal preview and atomic application.
  - Syntax error prevention during patch synthesis (`Code.string_to_quoted`).
- **AST Explorer**:
  - Syntax-invalid or unparseable files in workspace (skipped with warning without crashing search).
  - Module definitions without function bodies, empty files, or deeply nested macros.
- **Git Branching & Hunk Operations**:
  - Operating on non-git directories (`{:error, :not_a_git_repo}`).
  - Switching to non-existent branches without `:create` flag.
  - Unstaging a hunk when index is empty or target hunk ID does not exist.
  - Committing with empty staged index.

### Tier 3: Pairwise Combinatorial Interactions
Tests multi-component interactions where two or more subsystems interlock:
- **Command Palette + Test Runner**: Triggering "Run All Tests" from Command Palette switches tab to `"tests"` and initiates async test task.
- **Command Palette + AST Explorer**: Triggering "AST Symbol Search" opens AST Explorer with pre-filled search query.
- **Command Palette + File Editor**: Selecting a file result in Command Palette switches tab to `"files"`, loads the file into `@open_buffers`, and sets `@selected_file`.
- **Test Runner + AutoFix + Git Hub**: Test failure -> AutoFix patch applied -> modified file immediately surfaces in Git Staging Hub under Unstaged changes -> Git diff reflects AutoFix changes.
- **AST Explorer + File Editor**: Clicking "Jump to Editor" on an AST symbol card switches tab to `"files"`, opens buffer, and pushes `"jump_to_editor_line"` client hook.
- **Git Staging + Commit Generator + Log**: Stage multi-file changes -> AI commit generator formats conventional message -> commit created -> commit appears in Git log and status becomes clean.

### Tier 4: Real-World Workload Scenarios
Simulates realistic end-to-end multi-step developer sessions:
1. **Full Red-Green-Refactor Flow**:
   - Developer opens workspace, navigates to Test Runner.
   - Runs test suite, encounters 1 failing assertion.
   - Triggers 1-Click AutoFix, reviews diff preview in modal, applies patch atomically.
   - Test automatically re-runs and passes (100% green).
   - Switches to Git Hub, verifies unstaged diff, stages file, generates AI commit message, and commits.
2. **Codebase Exploration & Navigation Flow**:
   - Developer presses `Cmd+K`, types function name, jumps to AST Explorer.
   - Filters symbols by `@spec` and `def`, reviews syntax snippets.
   - Jumps to editor at symbol line, modifies file, uses Command Palette to switch back to Test Runner.
3. **Branch Feature Workflow**:
   - Developer creates a new feature branch `feature/power-tools` via Git Hub.
   - Stages specific files, unstages an accidental hunk from the index, and creates a clean commit.

---

## 3. Test Suites Directory Layout & Inventory

```
test/
├── iex_code/
│   ├── e2e/
│   │   ├── support/
│   │   │   ├── e2e_case.ex                         # Base CaseTemplate & sandbox fixtures
│   │   │   └── mock_llm_server.ex                  # In-memory SSE streaming mock server
│   │   ├── tier1_feature_test.exs                  # Tier 1 Feature Coverage (F1-F17)
│   │   ├── tier2_boundary_test.exs                 # Tier 2 Boundary & Corner Cases
│   │   ├── tier3_cross_feature_test.exs            # Tier 3 Cross-Feature Interactions
│   │   └── tier4_real_world_scenario_test.exs      # Tier 4 Real-World Application Scenarios
│   └── tools/
│       ├── ast_search_test.exs                     # AST Query Engine & Extractor Unit Tests
│       ├── auto_fix_test.exs                       # AutoFix Heuristics & Diagnostics Unit Tests
│       ├── diff_parser_and_hunk_ops_test.exs       # Unified Diff Parser & Hunk Ops Tests
│       ├── git_test.exs                            # Git Status, Stage, Commit, Diff Unit Tests
│       ├── git_branch_test.exs                     # Git Branch, Switch, Fetch, Pull Unit Tests
│       ├── hunk_unstage_test.exs                   # Granular Hunk Unstaging Unit Tests
│       ├── multi_patch_test.exs                    # MultiPatch Atomic Transaction Tests
│       └── test_runner_test.exs                    # TestRunner Port & Parser Unit Tests
└── iex_code_web/
    └── live/
        ├── workspace_live_test.exs                 # Core LiveView navigation & mounts
        ├── workspace_live_command_palette_test.exs # Command Palette LiveView E2E Tests
        ├── workspace_live_test_runner_test.exs     # Test Runner & AutoFix LiveView E2E Tests
        ├── workspace_live_ast_git_test.exs         # AST Explorer & Git Hub LiveView E2E Tests
        ├── workspace_live_editor_diffs_test.exs    # Inline Editor & Diff Hunk UI Tests
        └── workspace_live_ui_controls_test.exs     # UI Buttons & Modals Control Audit Tests
```

---

## 4. Test Execution Guide

### Run Full Test Suite:
```bash
mix test
```

### Run Dedicated Power Feature Test Suites:
```bash
# Command Palette LiveView Tests
mix test test/iex_code_web/live/workspace_live_command_palette_test.exs

# Visual Test Runner & AutoFix Studio Tests
mix test test/iex_code_web/live/workspace_live_test_runner_test.exs

# AST Query Explorer & Git Hub Tests
mix test test/iex_code_web/live/workspace_live_ast_git_test.exs

# Git Branch Backend Unit Tests
mix test test/iex_code/tools/git_branch_test.exs

# Granular Hunk Unstaging Backend Unit Tests
mix test test/iex_code/tools/hunk_unstage_test.exs
```

### Run Full 4-Tier E2E Suite:
```bash
mix test test/iex_code/e2e/
```

### Run Clean Verification Pipeline:
```bash
mix precommit
```

---

## 5. Verification & Acceptance Criteria Matrix

| Subsystem | Target Test File | Tier 1 (Happy) | Tier 2 (Boundary) | Tier 3 (Cross) | Tier 4 (Scenario) | Acceptance Criteria |
|---|---|:---:|:---:|:---:|:---:|---|
| **Command Palette** | `workspace_live_command_palette_test.exs` | ✓ | ✓ | ✓ | ✓ | Keyboard toggle (`Cmd+K`), category filtering, fuzzy search, Arrow key clamping, execution dispatch |
| **Visual Test Runner** | `workspace_live_test_runner_test.exs` | ✓ | ✓ | ✓ | ✓ | All/Failed/Stale/File runs, real-time progress bar, failure cards with Left/Right diffs |
| **1-Click AutoFix** | `workspace_live_test_runner_test.exs` | ✓ | ✓ | ✓ | ✓ | Proposal formulation, diff modal preview, atomic apply via MultiPatch, auto verification re-run, rollback |
| **AST Explorer** | `workspace_live_ast_git_test.exs` | ✓ | ✓ | ✓ | ✓ | Symbol query search, type badges (`def`, `defp`, `spec`, `macro`), syntax snippets, jump-to-editor |
| **Git Branch Hub** | `workspace_live_ast_git_test.exs`, `git_branch_test.exs` | ✓ | ✓ | ✓ | ✓ | Branch listing, branch switching, branch creation, fetch/pull synchronization |
| **Staging & Hunks** | `workspace_live_ast_git_test.exs`, `hunk_unstage_test.exs` | ✓ | ✓ | ✓ | ✓ | 3-tier staging rails, single/bulk staging, granular hunk unstaging, AI commit generator |
