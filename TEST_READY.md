# E2E Test Suite Ready: Next-Level IexCode Power Features

## 1. Test Execution Commands

### Power Features & Integration Test Suites:
- Command Palette LiveView Suite:
  ```bash
  mix test test/iex_code_web/live/workspace_live_command_palette_test.exs
  ```
- Visual Test Runner & 1-Click AutoFix Studio Suite:
  ```bash
  mix test test/iex_code_web/live/workspace_live_test_runner_test.exs
  ```
- AST Query Explorer & Git Hub LiveView Suite:
  ```bash
  mix test test/iex_code_web/live/workspace_live_ast_git_test.exs
  ```
- Git Branch Backend Suite:
  ```bash
  mix test test/iex_code/tools/git_branch_test.exs
  ```
- Granular Hunk Unstaging Backend Suite:
  ```bash
  mix test test/iex_code/tools/hunk_unstage_test.exs
  ```

### Full 4-Tier E2E & Core Test Suites:
- Full E2E Test Suite (Tiers 1-4):
  ```bash
  mix test test/iex_code/e2e/
  ```
- Individual Tiers:
  ```bash
  mix test test/iex_code/e2e/tier1_feature_test.exs
  mix test test/iex_code/e2e/tier2_boundary_test.exs
  mix test test/iex_code/e2e/tier3_cross_feature_test.exs
  mix test test/iex_code/e2e/tier4_real_world_scenario_test.exs
  ```
- Full Test Suite & Precommit Pipeline:
  ```bash
  mix test
  mix precommit
  ```

---

## 2. Test Architecture & Coverage Summary

| Tier / Subsystem | Test Suite Path | Test Count | Focus & Methodology |
|---|---|:---:|---|
| **Command Palette (R2)** | `test/iex_code_web/live/workspace_live_command_palette_test.exs` | 10 | Modal toggle (`Cmd+K`), multi-domain fuzzy search, category pills, keyboard navigation, tab/file jumps |
| **Visual Test Runner & AutoFix (R3)** | `test/iex_code_web/live/workspace_live_test_runner_test.exs` | 6 | All/Failed/Stale/File runs, progress bar telemetry, failure cards, assertion diffs, 1-click AutoFix modal & apply |
| **AST Explorer & Git Hub (R4, R5)** | `test/iex_code_web/live/workspace_live_ast_git_test.exs` | 7 | AST symbol search, type badges, jump-to-editor line, branch switching, 3-tier staging tree, AI commit generator |
| **Git Branch Backend (R5)** | `test/iex_code/tools/git_branch_test.exs` | 11 | `Git.branches/1`, `Git.switch_branch/3`, `Git.create_branch/3`, `Git.fetch/2`, `Git.pull/3` in tmp fixtures |
| **Hunk Unstaging Backend (R5)** | `test/iex_code/tools/hunk_unstage_test.exs` | 5 | `HunkOps.unstage_hunk/4` with string and integer IDs, staged vs unstaged index verification |
| **Tier 1: Feature Coverage** | `test/iex_code/e2e/tier1_feature_test.exs` | 85 | 5 happy-path test cases for each feature F1..F17 |
| **Tier 2: Boundary & Corner Cases** | `test/iex_code/e2e/tier2_boundary_test.exs` | 85 | 5 boundary/crash/stress test cases for each feature F1..F17 |
| **Tier 3: Cross-Feature Interactions** | `test/iex_code/e2e/tier3_cross_feature_test.exs` | 22 | Pairwise subsystem integration interactions |
| **Tier 4: Real-World Scenarios** | `test/iex_code/e2e/tier4_real_world_scenario_test.exs` | 10 | Full end-to-end multi-agent coding workflows |
| **Core Tools & Engine Unit Suites** | `test/iex_code/tools/`, `test/iex_code/engine/` | 127 | Pure Elixir AST parsing, diff parsing, MultiPatch, LLM resilience, Kanban, Sessions |
| **Total Comprehensive Test Suite** | **All Suites** | **368** | **Full 4-Tier & Power Feature Test Suite** |

---

## 3. Requirement Traceability Matrix

| Requirement | Power Feature | Implementation Module(s) | Test Suites |
|---|---|---|---|
| **R1** | Dead Code Elimination & Stale Cleanup | `WorkspaceLive`, `WorkspaceComponents` | `workspace_live_ui_controls_test.exs`, `workspace_live_test.exs` |
| **R2** | Global Command Palette (`Cmd+K`) | `IexCodeWeb.CommandPalette`, `WorkspaceLive` | `workspace_live_command_palette_test.exs` |
| **R3** | Visual Test Runner & 1-Click AutoFix Studio | `IexCode.Tools.TestRunner`, `IexCode.Tools.AutoFix`, `WorkspaceLive` | `workspace_live_test_runner_test.exs` |
| **R4** | AST Query Explorer & Symbol Navigator | `IexCode.Tools.ASTSearch`, `WorkspaceLive` | `workspace_live_ast_git_test.exs`, `ast_search_test.exs` |
| **R5** | Git Branch & Multi-File Staging Hub | `IexCode.Tools.Git`, `IexCode.Tools.Git.HunkOps`, `WorkspaceLive` | `workspace_live_ast_git_test.exs`, `git_branch_test.exs`, `hunk_unstage_test.exs` |
| **R6** | Comprehensive Verification & Precommit Pass | All modules | All 368 tests & `mix precommit` |

---

## 4. Test Harness Infrastructure Components
- **`TEST_INFRA.md`**: Authoritative testing architecture defining the 4-tier methodology, category partitions, boundary value analysis, pairwise matrices, and real-world scenarios.
- **`test/iex_code/e2e/support/e2e_case.ex`**: Standard test case template with filesystem sandbox creation (`create_temp_workspace/1`), temp Git repository initialization (`init_temp_git_repo/1`), PubSub subscription and draining helpers, and LiveView mount helpers.
- **`test/iex_code/e2e/support/mock_llm_server.ex`**: In-memory SSE streaming mock server.
