# E2E Test Infra: Next-Level IexCode

## Test Philosophy
- **Opaque-Box & Requirement-Driven**: Tests are derived strictly from `ORIGINAL_REQUEST.md` and user requirements, exercising public module APIs, OTP processes, PubSub channels, LiveView components, and CLI tooling.
- **Progressive Testability**: Verification mechanisms use isolated sandboxes, temporary git repositories, and mock streaming servers without depending on external network access.
- **Methodology**: Category-Partition + Boundary Value Analysis (BVA) + Pairwise Interaction Testing + Real-World Workload Testing.

## Test Architecture & Layout
The E2E test suite lives in `test/iex_code/e2e/`:
- `test/iex_code/e2e/support/e2e_case.ex`: Base test case providing sandbox temp directory creation, git repo initialization, PubSub event capture helpers, and LiveView mount helpers.
- `test/iex_code/e2e/support/mock_llm_server.ex`: In-memory / HTTP SSE mock server for simulating streaming deltas, chunk fragmentation, unicode splits, network errors, and retries.
- `test/iex_code/e2e/tier1_feature_test.exs`: Tier 1 Feature Coverage (>=5 happy-path test cases per feature for F1-F17).
- `test/iex_code/e2e/tier2_boundary_test.exs`: Tier 2 Boundary & Corner Cases (>=5 edge cases per feature for F1-F17).
- `test/iex_code/e2e/tier3_cross_feature_test.exs`: Tier 3 Cross-Feature Combinations (pairwise integration).
- `test/iex_code/e2e/tier4_real_world_scenario_test.exs`: Tier 4 Real-World Application Scenarios.

## Test Runner Invocation
- Run full E2E test suite:
  ```bash
  mix test test/iex_code/e2e/
  ```
- Run individual tiers:
  ```bash
  mix test test/iex_code/e2e/tier1_feature_test.exs
  mix test test/iex_code/e2e/tier2_boundary_test.exs
  mix test test/iex_code/e2e/tier3_cross_feature_test.exs
  mix test test/iex_code/e2e/tier4_real_world_scenario_test.exs
  ```

## Feature Inventory & Coverage Mapping
| # | Feature | Source (Requirement) | Tier 1 (Min 5) | Tier 2 (Min 5) | Tier 3 | Tier 4 |
|---|---------|---------------------|:--------------:|:--------------:|:------:|:------:|
| F1 | AppSettings Query Safety | `PROJECT.md § F1` / Safe querying | 5 | 5 | ✓ | ✓ |
| F2 | OTP Subagent Process Tree | `ORIGINAL_REQUEST.md § R1` (Isolated agents) | 5 | 5 | ✓ | ✓ |
| F3 | OTP Process Crash Monitoring | `ORIGINAL_REQUEST.md § R1` (Process.monitor) | 5 | 5 | ✓ | ✓ |
| F4 | Autonomous Error Feedback Loop | `ORIGINAL_REQUEST.md § R1` (Feedback loops) | 5 | 5 | ✓ | ✓ |
| F5 | Live Telemetry & Card Streaming | `ORIGINAL_REQUEST.md § R2` (Progress & latency) | 5 | 5 | ✓ | ✓ |
| F6 | Hierarchical Operation Tree | `ORIGINAL_REQUEST.md § R2` (Operation tree) | 5 | 5 | ✓ | ✓ |
| F7 | Interactive Code Diff Viewer | `ORIGINAL_REQUEST.md § R2` (Side-by-side & inline diffs) | 5 | 5 | ✓ | ✓ |
| F8 | File Tree Explorer & Search | `ORIGINAL_REQUEST.md § R2` (File tree & search) | 5 | 5 | ✓ | ✓ |
| F9 | Terminal Session Integration | `ORIGINAL_REQUEST.md § R2` (Shell execution & ANSI) | 5 | 5 | ✓ | ✓ |
| F10 | AST-Aware Search Engine | `ORIGINAL_REQUEST.md § R3` (AST search) | 5 | 5 | ✓ | ✓ |
| F11 | Multi-File Atomic Patching | `ORIGINAL_REQUEST.md § R3` (Multi-file patching) | 5 | 5 | ✓ | ✓ |
| F12 | Automated Test Runner & Parser | `ORIGINAL_REQUEST.md § R3` (Test runner & parser) | 5 | 5 | ✓ | ✓ |
| F13 | Instant Auto-Fix Engine | `ORIGINAL_REQUEST.md § R3` (Test failures to patch) | 5 | 5 | ✓ | ✓ |
| F14 | Git Integration Engine | `ORIGINAL_REQUEST.md § R3` (Git diff, stage, commit) | 5 | 5 | ✓ | ✓ |
| F15 | Streaming SSE LLM Client | `ORIGINAL_REQUEST.md § R4` (SSE Streaming) | 5 | 5 | ✓ | ✓ |
| F16 | UTF-8 Stream Sanitizer Buffer | `ORIGINAL_REQUEST.md § R4` (Multibyte buffer) | 5 | 5 | ✓ | ✓ |
| F17 | LLM Resilience & Retries | `ORIGINAL_REQUEST.md § R4` (Exponential backoff) | 5 | 5 | ✓ | ✓ |

## Minimum Thresholds & Target Counts
- **Tier 1 (Feature Coverage)**: 17 features × 5 = 85+ test cases
- **Tier 2 (Boundary & Corner Cases)**: 17 features × 5 = 85+ test cases
- **Tier 3 (Cross-Feature Combinations)**: 20+ pairwise integration test cases
- **Tier 4 (Real-World Application Scenarios)**: 10+ end-to-end workflow test cases
- **Total Minimum Target**: ~200+ comprehensive test assertions & cases
