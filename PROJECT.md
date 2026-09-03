# Project: Advanced Autonomous Engineering Suite for `iex-code`

## Architecture
This project elevates `iex-code` into an advanced autonomous engineering suite featuring:
1. **Multi-Window Native Desktop Detachment (`IexCode.Desktop.WindowManager` & `WindowSupervisor`)**:
   Enables detaching focused workspace tools (dedicated Terminal multiplexer, Diff/Git Inspector, and DAG Research visualizer) into independent native macOS `Desktop.Window` instances (`IexCodeTerminalWindow`, `IexCodeDiffWindow`, `IexCodeDagWindow` with `on_close: :hide`) synchronized in real time with the main workspace via Phoenix PubSub.
2. **Offline Local Semantic Codebase Indexing & Vector Search (`IexCode.SemanticIndex.*`)**:
   Zero-cloud semantic code search and symbol indexing powered by local embeddings (via local Ollama / llama.cpp inference) stored in SQLite with packed float32 dot-product math for instantaneous (<10ms) contextual code retrieval during agent planning and file navigation.
3. **Atomic Workspace Time-Travel Checkpoints & 1-Click Rollback (`IexCode.TimeTravel.*`)**:
   Pre-mutation snapshot checkpoints capturing multi-file modifications across all swarm tools (`write_file`, `patch_file`, `multi_patch`) and an interactive visual LiveView time-travel scrubber enabling instant non-destructive rollbacks without orphaned edits.
4. **Multi-Model Adversarial Consensus & Swarm Voting (`IexCode.Consensus.*`)**:
   Cross-model peer review (cloud models + local Apple Silicon models) on critical code diffs and architecture plans, presenting visual agreement matrices and automated consensus arbitration before code application.
5. **Comprehensive Verification & Precommit Compliance**:
   Opaque-box E2E test suites across all four capabilities, LiveView reactive integration tests, 0 compiler warnings, 0 test failures, and 100% clean `mix precommit`.

## Feature Inventory
| # | Feature | Description | Milestone | Source |
|---|---------|-------------|-----------|--------|
| 1 | WindowManager & Dynamic WindowSupervisor | Supervisor managing native secondary `Desktop.Window` instances with `on_close: :hide` | M1 | ORIGINAL_REQUEST §R1 |
| 2 | Dedicated Detached Routes & LiveViews | Standalone `/sessions/:id/detached/{terminal,diff,dag}` LiveViews with edge-to-edge layouts | M1 | ORIGINAL_REQUEST §R1 |
| 3 | Bi-directional PubSub Window Synchronization | Real-time state synchronization for PTY streaming, Git mutations, and DAG execution across all windows | M1 | ORIGINAL_REQUEST §R1 |
| 4 | Main Workspace Detach UI & Menu Triggers | Detach buttons on headers, `MenuBar` shortcuts (`Cmd+Shift+3/4/5`), and Command Palette actions | M1 | ORIGINAL_REQUEST §R1 |
| 5 | SQLite Code Embeddings Schema | SQLite migration `create_code_embeddings` storing packed float32 vectors, hashes, and symbol metadata | M2 | ORIGINAL_REQUEST §R2 |
| 6 | Local Embedding Inference Client | Offline embedding client via `:req` connecting to local Ollama / llama.cpp `/v1/embeddings` | M2 | ORIGINAL_REQUEST §R2 |
| 7 | AST Symbol & Text Chunker | Extracts Elixir AST symbols and windowed code chunks with boundary metadata | M2 | ORIGINAL_REQUEST §R2 |
| 8 | Vector Math & Fast SQLite/ETS Search | Binary dot-product calculation on unit-normalized vectors with sub-second retrieval | M2 | ORIGINAL_REQUEST §R2 |
| 9 | Semantic Search Tool & LiveView UI | `semantic_code_search` tool in `IexCode.Tools` and interactive search panel in `WorkspaceLive` | M2 | ORIGINAL_REQUEST §R2 |
| 10 | Universal Pre-Mutation Snapshotting | Capture atomic pre-mutation snapshots in `write_file`, `patch_file`, and `multi_patch` | M3 | ORIGINAL_REQUEST §R3 |
| 11 | Sequential Time-Travel Rollback Engine | Reverse-chronological multi-step rollback restoring modified files and deleting created files | M3 | ORIGINAL_REQUEST §R3 |
| 12 | LiveView Visual Time-Travel Scrubber | Interactive slider, checkpoint inspection cards, unified diff previews, and 1-Click Rollback button | M3 | ORIGINAL_REQUEST §R3 |
| 13 | Pre-Mutation Patch Preview Interception | Intercept `CoderAgent` tool calls using `MultiPatch.preview_patches/3` for peer review | M4 | ORIGINAL_REQUEST §R4 |
| 14 | Multi-Model Structured Assessment Schema | JSON assessment format with 5-dimensional scores, votes, confidence, and critique points | M4 | ORIGINAL_REQUEST §R4 |
| 15 | Pairwise Agreement Matrix & Consensus Math | Matrix $A_{j,k}$, swarm concordance $\bar{A}$, weighted consensus $C$, and threshold arbitration | M4 | ORIGINAL_REQUEST §R4 |
| 16 | Visual Agreement Matrix LiveView UI | Heat-map agreement matrix, dimensional score progress bars, and manual arbitration controls | M4 | ORIGINAL_REQUEST §R4 |
| 17 | Comprehensive Test Suites & Precommit | Automated test suites for R1-R4, LiveView integration tests, and clean `mix precommit` | M5 | Acceptance Criteria |

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| 1 | Multi-Window Native Desktop Detachment | `IexCode.Desktop.WindowManager`, `WindowSupervisor`, dedicated routes, `TerminalLive`, `DiffLive`, `DagLive`, PubSub sync | None | DONE |
| 2 | Offline Local Semantic Indexing & Vector Search | SQLite migration, `EmbeddingClient`, `Chunker`, `Vector`, `Indexer`, search tool, LiveView search panel | None | DONE |
| 3 | Atomic Time-Travel Checkpoints & Rollback Scrubber | Pre-mutation snapshotting on all mutation tools, `TimeTravel` engine, LiveView scrubber UI in `changes` tab | None | DONE |
| 4 | Multi-Model Adversarial Consensus & Swarm Voting | `Consensus.Assessment`, `Evaluator`, `Matrix`, `Arbitrator`, patch preview interception, LiveView agreement matrix | None | DONE |
| 5 | E2E Integration, Hardening & mix precommit | Full test suites, edge case verification, LiveView tests, clean `mix precommit` | M1, M2, M3, M4 | DONE |

## Interface Contracts

### M1: Desktop WindowManager & PubSub Sync
- `IexCode.Desktop.WindowManager`:
  - `open_window(tool, session_id)`:
    - `tool`: `:terminal | :diff | :dag`
    - In desktop environment: starts or shows window `IexCodeTerminalWindow`, `IexCodeDiffWindow`, or `IexCodeDagWindow` with `on_close: :hide`.
    - In web/test environment: returns `{:ok, :web_url, url}`.
  - `close_window(tool)`: hides the window.
- PubSub Channels:
  - `"session:#{session_id}:terminal"`: PTY data chunks, clear events, agent occupancy locks.
  - `"project:#{project_id}:git"`: Git state mutation broadcasts to refresh diffs.
  - `"runs:session:#{session_id}"`: DAG run and step state transitions.

### M2: Semantic Indexing & Vector Search
- `IexCode.SemanticIndex.EmbeddingClient.embed(text_or_texts, opts \\ [])`:
  - Returns `{:ok, [list(float())]}` or `{:error, reason}`. Unit-normalizes vectors.
- `IexCode.SemanticIndex.Vector.dot_product(binary_vec1, binary_vec2)`:
  - Fast bitstring dot-product calculation on packed float32 binaries.
- `IexCode.SemanticIndex.Indexer.search(project_root, query, opts \\ [])`:
  - Options: `:limit` (default 10), `:symbol_type` (optional filter).
  - Returns ranked list of `%{file_path: string, start_line: integer, end_line: integer, symbol_name: string, symbol_type: string, score: float, snippet: string}`.

### M3: Atomic Checkpoints & Time-Travel Rollback
- `IexCode.TimeTravel`:
  - `create_checkpoint(session_id, project_root, patches, opts \\ [])`:
    - Saves pre-mutation snapshot atomically before disk write.
  - `list_checkpoints(session_id_or_project_root)`:
    - Returns ordered list of checkpoints with sequence numbers, timestamps, labels, diff stats.
  - `rollback_to(checkpoint_id, opts \\ [])`:
    - Sequentially rolls back all snapshots after `checkpoint_id` in reverse chronological order.
  - `rollback_latest(session_id_or_project_root)`:
    - Rolls back the single latest snapshot.

### M4: Multi-Model Adversarial Consensus
- `IexCode.Consensus.Assessment`:
  - Fields: `reviewer_id`, `provider`, `model`, `vote` (`:approve | :reject | :request_changes`), `confidence` (0.0..1.0), `scores` (`%{correctness: int, security: int, architecture: int, maintainability: int, testability: int}`), `critique` (list of strings).
- `IexCode.Consensus.Matrix.compute(assessments)`:
  - Returns `%{pairwise_matrix: map(), swarm_concordance: float(), weighted_score: float(), decision: :approved | :rejected | :contested}`.
- `IexCode.Consensus.Arbitrator.evaluate_diff(diff_or_patches, opts \\ [])`:
  - Queries panel of models, computes consensus matrix, and returns decision with `RunApproval` integration if gated.

## Code Layout
- `lib/iex_code/desktop/window_manager.ex`: Window lifecycle manager.
- `lib/iex_code/desktop/window_supervisor.ex`: Dynamic supervisor for detached windows.
- `lib/iex_code_web/live/detached/terminal_live.ex`: Standalone terminal multiplexer LiveView.
- `lib/iex_code_web/live/detached/diff_live.ex`: Standalone Git / diff inspector LiveView.
- `lib/iex_code_web/live/detached/dag_live.ex`: Standalone DAG execution visualizer LiveView.
- `lib/iex_code/semantic_index/embedding_client.ex`: Local inference client.
- `lib/iex_code/semantic_index/chunker.ex`: AST symbol and code chunker.
- `lib/iex_code/semantic_index/vector.ex`: Packed float32 vector math.
- `lib/iex_code/semantic_index/indexer.ex`: SQLite storage and search GenServer.
- `lib/iex_code/semantic_index/code_embedding.ex`: Ecto schema for SQLite vector table.
- `priv/repo/migrations/*_create_code_embeddings.exs`: SQLite migration.
- `lib/iex_code/time_travel.ex`: Atomic checkpointing and multi-step rollback engine.
- `lib/iex_code/time_travel/checkpoint.ex`: Checkpoint data structure and queries.
- `lib/iex_code/consensus/assessment.ex`: Structured vote schema.
- `lib/iex_code/consensus/matrix.ex`: Agreement matrix and consensus math.
- `lib/iex_code/consensus/evaluator.ex`: Multi-model panel evaluator.
- `lib/iex_code/consensus/arbitrator.ex`: Threshold gating and RunApproval bridge.
- `lib/iex_code_web/components/consensus_components.ex`: Agreement matrix UI components.
- `test/iex_code/desktop/window_manager_test.exs`
- `test/iex_code_web/live/detached/`
- `test/iex_code/semantic_index/`
- `test/iex_code/time_travel/`
- `test/iex_code/consensus/`
- `test/iex_code/e2e/autonomous_suite_test.exs`
