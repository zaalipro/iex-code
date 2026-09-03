# E2E Test Infra: Advanced Autonomous Engineering Suite (`iex-code`)

## Test Philosophy
- Opaque-box, requirement-driven derived strictly from `ORIGINAL_REQUEST.md` (§R1 - §R4).
- No dependency on private module internals; interfaces test public GenServer, LiveView events, PubSub broadcasts, and tools.
- Methodology: Category-Partition + Boundary Value Analysis + Pairwise Combinatorial Testing + Real-World Workloads.

## Feature Inventory & Test Coverage Goals
| # | Feature | Requirement | Tier 1 (Feature) | Tier 2 (Boundary) | Tier 3 (Cross-Feature) | Tier 4 (Workload) |
|---|---------|-------------|:----------------:|:-----------------:|:----------------------:|:-----------------:|
| 1 | Detached Window Manager | R1 | 5 | 5 | ✓ | ✓ |
| 2 | Detached LiveViews (Terminal, Diff, DAG) | R1 | 5 | 5 | ✓ | ✓ |
| 3 | PubSub Event Synchronization | R1 | 5 | 5 | ✓ | ✓ |
| 4 | Offline Vector Embeddings & SQLite Storage | R2 | 5 | 5 | ✓ | ✓ |
| 5 | Ranked Semantic Code Retrieval (<1s) | R2 | 5 | 5 | ✓ | ✓ |
| 6 | Pre-Mutation Checkpoints (All Tools) | R3 | 5 | 5 | ✓ | ✓ |
| 7 | Multi-Step 1-Click Rollback Scrubber | R3 | 5 | 5 | ✓ | ✓ |
| 8 | Multi-Model Structured Assessment Schema | R4 | 5 | 5 | ✓ | ✓ |
| 9 | Agreement Matrix & Consensus Arbitration | R4 | 5 | 5 | ✓ | ✓ |
| 10 | Consensus Gating & RunApproval Integration | R4 | 5 | 5 | ✓ | ✓ |

## Test Architecture
- **Runner**: `mix test` (and `mix precommit`)
- **Isolation**: Serialized execution with sandboxed SQLite databases and isolated mock HTTP servers (`IexCode.E2E.MockLLMServer`).
- **LiveView Testing**: `Phoenix.LiveViewTest` driving detached windows, scrubber sliders, diff viewers, and voting matrix.
- **Directory Layout**:
  - `test/iex_code/desktop/window_manager_test.exs`: Desktop window lifecycle, hiding, headless fallback.
  - `test/iex_code_web/live/detached/`: LiveView tests for detached Terminal, Diff, and DAG views.
  - `test/iex_code/semantic_index/`: Embedding client, chunking, dot-product math, SQLite storage, and sub-second retrieval.
  - `test/iex_code/time_travel/`: Mutation snapshotting, multi-step rollback, orphaned file cleanup.
  - `test/iex_code/consensus/`: Matrix math, pairwise concordance, arbitration, and RunApproval gating.
  - `test/iex_code/e2e/autonomous_suite_e2e_test.exs`: End-to-end integration workflows.

## Real-World Application Scenarios (Tier 4)
| # | Scenario | Features Exercised | Complexity |
|---|----------|--------------------|------------|
| 1 | Multi-Window Collaborative Editing | Detached Terminal & Diff windows receiving concurrent swarm updates via PubSub | High |
| 2 | Semantic Code Search during Agent Planning | Local embeddings indexed, querying function signatures with ranking and line targets | Medium |
| 3 | Swarm Multi-File Refactor with Instant Rollback | Swarm touches 5 files via write_file/patch_file/multi_patch, user scrubs back 3 checkpoints | High |
| 4 | Contested Code Patch Arbitration | Cloud model approves, local model flags security vulnerability, arbitration gates patch into RunApproval | High |
| 5 | Full Autonomous Suite End-to-End Run | Search -> Plan -> Consensus Vote -> Pre-mutation Checkpoint -> Patch Apply -> Detached LiveView Sync | Extreme |

## Coverage Thresholds
- Tier 1: ≥5 per feature
- Tier 2: ≥5 per feature (empty inputs, missing servers, large diffs, concurrent writes)
- Tier 3: Pairwise coverage across Window Sync × Checkpoints × Consensus
- Tier 4: ≥5 realistic end-to-end workload scenarios
