# Lean harness measurements

This is a finite fixture comparison, not a monitoring service or competitive
benchmark. Measurements use Elixir 1.18.4, OTP 28, Req 0.5.18, SQLite, one serial
validation lane, and synthetic files/local loopback SSE on an eight-core/16 GiB
macOS host. VM/process samples are endpoints, not peak allocation measurements.

## Execution order and equivalent workloads

1. **Baseline, 2026-10-08:** runtime `749d303`, fixture committed as `e4f75b4`
   before hot-path edits. Ten tests produced 14 scenario measurements. Test-only
   isolation repairs in `2a36d14` added a collector-lifecycle test and preserved
   all 14 scenario parameters and structural observations.
2. **M1 checkpoint, 2026-10-09:** `b111ab4`, 11 tests, zero failures, 14
   measurements. History, file, and attempt-control optimizations were present.
3. **Final M2, 2026-10-10:** `6e3c9f5`, 13 tests, zero failures, 16 measurements
   in 1.6 seconds. Two request-preparation scenarios were added during M2;
   the original 14 workloads are equivalent, not reconstructed baseline runs.
   This documentation feature changes no runtime or benchmark implementation.

Original workloads:

- Short durable single: no old history, 4/64 eight-byte text events, `read_file`
  allowlist, output 128, two-turn cap with one turn exercised.
- Long history: 40/2,000 fixed-width alternating user/assistant rows, 64 text
  events. History seeding occurs outside the timed region.
- Files: 16,000/128,000 LF lines, 528,000/4,224,000 bytes; 600 eligible grep
  candidates with 20 matches each and four excluded nested files.
- Cancel after the first text callback; silent provider released only after
  durable cancellation. These retain the original fixture release semantics.
- Final-message replay at each history size, with no new provider/tool effects.

The test-only LLM bridge exercises the actual OpenAI adapter/Req/SSE, not complete
production settings/route selection. Direct file-tool fixtures are not model/tool
multi-turn benchmarks. Optional swarm performance was not measured; separate
workspace integration tests/browser evidence exercise its correctness.

## Structural comparison

Loaded message rows sum query results, including repeat loads, not distinct
retained rows. Run SELECTs include finite effect/settlement fences, not only
authority refreshes. Query telemetry covers supervised children in each serial
measured region; unrelated background polling is disabled.

| Metric | Baseline | M1 | Final M2 |
| --- | ---: | ---: | ---: |
| Short single 4/64 chunks: total queries | 65/125 | 61/61 | 61/61 |
| Same: run SELECTs | 28/88 | 24/24 | 24/24 |
| Same: loaded message rows | 2/2 | 1/1 | 1/1 |
| History 40/2,000: loaded message rows | 82/4,002 | 20/20 | 20/20 |
| Same: total queries / run SELECTs | 125/88 each | 61/24 each | 61/24 each |
| Same: request bytes | 7,343 each | 7,343 each | 7,343 each |
| Replay 40/2,000: loaded rows | 85/4,005 | 2/2 | 2/2 |
| Same: total queries / run SELECTs | 7/2 each | 7/3 each | 7/3 each |
| Cancel-after-first: total queries / run SELECTs | 58/24 | 56/22 | 56/22 |
| Released silence: total queries / run SELECTs | 56/22 | 55/21 | 55/21 |
| Read 16,000/128,000 lines: scanned bytes | Unavailable | 32,768 each | 32,768 each |
| Same: output bytes | 30,374/30,375 | 30,485 each | 30,485 each |
| Grep: scanned bytes / opened eligible files | Unavailable | 4,600/10 each | 4,600/10 each |
| Grep: matches / response bytes | 100/4,209 each | 100/4,387 each | 100/4,387 each |

Replay's extra run SELECT after bounded history is the initial supervised guard
confirmation. It preserves authority for direct callers, not a duplicate model
request. Final answers and chunk contents are unchanged. New incomplete notices
account for file-output differences.

Each current grep yields 604 names (600 candidates plus four excluded directory
names), opens ten files, and receives 6,654 response-wire bytes from one Python
helper. Excluded descendants are not visited. Original visited/scan counters and
helper RSS are unavailable. Early foundation traversal counters counted popped
candidates rather than yielded names and must not be compared as the same metric.

### Larger fixtures and safety

The final 267-test affected suite includes:

- Comparable-duration actual Req/SSE control scenarios: four synchronized batches
  with a 100 ms test refresh cadence. **4/400 chunks both produced 64 queries and
  27 run SELECTs**, in 315,974/324,164 microseconds. The callback path itself
  performs no database queries. The short benchmark alone is not fixed-duration
  evidence.
- Silent transport without release, blocked/failed refresh, lease expiry,
  owner loss, replacement attempts, approval waits, late approval, durable
  effect fences, replay, and reservation retention/release checks. Default
  refresh/read/grace are 1,000/1,000/1,500 ms; local expiry does not wait for
  SQLite and physical cleanup follows grace under scheduler progress.
- SQL preview pages at 60/2,000 stored rows: 50 projected rows, three queries,
  at most 52 selected message rows; content/reasoning capped at 4,096/2,048
  bytes. Cursor traversal, scoped full detail and complete copy remain intact.
  Completed-operation/peer windows are 50; active operations/ancestors and one
  requested full detail are explicit exceptions. Peer metadata scanning bounds
  retained state, not all scan/temporary JSON encoding work.
- Giant-line/oversized read, range, excluded-heavy 5,000/6,000-name trees,
  invalid UTF-8 tails, traversal/query/complete-response limits and symlink
  containment fixtures. Native bounds are stated in the root README.
- Shared actual-payload preparation for all four coding paths, complete
  tool exchanges, mandatory objective/steering, effective output/thinking/local
  reserves, zero-transport overflow, and historical receipt compatibility.
- Preview **4/4,000 × 4,096-byte chunks**: zero queries, **16,384 retained answer
  bytes and two events** for both. The helper fixture uses a 1,000 ms batching
  interval and explicit finish, not the default 75 ms cadence. It took
  445/139,227 microseconds. Retry, parser, stale-event, persistence failure,
  cancellation, reconnect and final reconciliation tests accompany the bound.

Current request-preparation fixtures select 20 history rows at both 40/2,000
population sizes, retain 15 request messages, and produce **5,005 JSON bytes**,
**1,693 estimated input tokens + 128 output reserve** against a **2,000-token
limit / 5,232-byte guard**. Components are 62 instruction bytes, 421 schema
bytes, 4,408 transcript bytes, 114 protocol bytes, plus 128 estimated protocol
tokens. No equivalent pre-edit actual-request preparation metric exists.

## Timing and resources, with limitations

| Sample | Baseline wall µs / endpoint caller bytes | Final wall µs / endpoint caller bytes |
| --- | ---: | ---: |
| Short 4 chunks, cold first transport | 77,900 / 149,776 | 110,604 / 94,768 |
| Short 64 chunks | 21,061 / 113,184 | 14,056 / 107,600 |
| History 2,000 | 36,854 / 4,733,520 | 13,711 / 9,591,848 |
| Replay history 2,000 | 19,367 / 2,548,280 | 1,533 / 9,650,776 |
| Read 16,000 lines | 8,161 / 2,546,552 | 6,403 / 143,192 |
| Read 128,000 lines | 72,237 / 28,655,880 | 1,593 / 143,192 |
| Grep small/large file fixture | 43,525/38,928 | 102,519/54,888 |

The large-history caller heap includes prior fixture seeding and GC timing.
Bounded fetched rows do not prove smaller endpoint memory in every sample.
Final grep helper peak RSS was 17,432,576/17,563,648 bytes, including the Python
interpreter, while caller endpoint memory was 143,488 bytes. These are not a
combined BEAM/helper peak. Python startup/protocol/validation has real cost;
grep latency did not uniformly improve. Collector overhead, cold adapter
startup, host scheduling and GC make fixed speed percentages inappropriate.

Final first-text callback times were 79,997 µs for the cold short run and
821/1,458/826 µs for warm short64/history40/history2000. Baseline equivalents
were 48,498/1,058/986/1,050 µs. These are **not first-visible UI latency**.
The original fixture has no LiveView subscription. The historical text in its
availability fields refers to the old discarded callback, not current behavior.
Browser/runtime evidence separately proves preview-before-completion ordering,
without claiming a before/after browser latency measurement.

Original scan counters, UI retained rows/timing, provider usage, and peak/RSS
were unavailable. They are not fabricated retrospectively. Synthetic SSE
deliberately reports no usage. Its legacy byte/4 estimate (356 short, 1,836
history) differs from the current margin/guard estimate and is not tokenizer
or provider usage.

## Real workspace evidence and budget

The authorized integration ran through the actual isolated workspace, read
synthetic `numbers.txt` once, and saved:

> Alpha is 17, beta is 25, and their sum is 42.

Two model requests used 6,473/6,756 serialized bytes, 2,151/2,240 estimated
input tokens, output reserves 256 each, and conservative total reservations
2,407/2,496. Provider-reported total usage was **1,745/1,783** tokens,
3,459 input plus 69 output combined. The mission readiness call adds 24 tokens:
**3 HTTP attempts, 3,552 reported tokens, zero outstanding reservation** under
the six-attempt/10,000-token ceiling. Arithmetic remainder is three attempts
and 6,448 tokens, not permission for further calls.

Transient output and one persisted answer were observed; no new paid calls
were made for final measurement. Automatic retries/redirects were disabled
by the authorized integration guard. Two guard rejections were pretransport,
not HTTP attempts. The selected provider was not benchmarked before/after
through the same workspace, so no provider or live latency gain is claimed.
Sanitized successful integration evidence is reused, not replayed.

## Commands and exact final outcomes

From the repository, ordinary developer commands are:

```sh
mix precommit
mix compile --warnings-as-errors
mix format --check-formatted
mix test --max-cases 1 --seed 0 test/benchmarks/lean_harness_bench_test.exs
```

These use the normal configured test database. Do not run them on user data
when isolation is required. This mission used its existing clean-environment
wrapper, disposable `runtime/test.db`, private test build, disabled background
polling, synthetic projects and loopback-only transports:

```sh
cd /Users/zaali/dev/iex-code
M=/Users/zaali/.factory/missions/391f4665-46a3-41be-8f78-0f62e02b26ac
sh "$M/init.sh"
sh "$M/runtime/validation-env.sh" mix do loadconfig "$M/runtime/config.exs" + precommit
sh "$M/runtime/validation-env.sh" mix do loadconfig "$M/runtime/config.exs" + compile --warnings-as-errors
sh "$M/runtime/validation-env.sh" mix format --check-formatted
sh "$M/runtime/validation-env.sh" mix do loadconfig "$M/runtime/config.exs" + \
  test --max-cases 1 --seed 0 test/benchmarks/lean_harness_bench_test.exs
```

The wrapper is a mission-local artifact, not an installed project dependency.
Outside that environment, configure your own disposable test database/build
before substituting the commands. Benchmark output lines are `LEAN_BENCH`
JSON; the existing test collector retains no SQL, prompts, keys or paths.

Final focused command, using the same wrapper/config:

```sh
sh "$M/runtime/validation-env.sh" mix do loadconfig "$M/runtime/config.exs" + \
  test --max-cases 1 --seed 0 \
  test/iex_code/engine/attempt_control_test.exs \
  test/iex_code/engine/challenger9_otp_stress_test.exs \
  test/iex_code/engine/agent_loop_test.exs \
  test/iex_code/engine/agent_cancellation_test.exs \
  test/iex_code/engine/execution_stream_test.exs \
  test/iex_code/engine/execution_stream_paths_test.exs \
  test/iex_code/engine/request_budget_paths_test.exs \
  test/iex_code/engine/session_server_bounded_history_test.exs \
  test/iex_code/llm/request_preparation_test.exs \
  test/iex_code/llm/context_compactor_test.exs \
  test/iex_code/llm/stream_client_test.exs \
  test/iex_code/llm/resilience_test.exs \
  test/iex_code/sessions_bounded_history_test.exs \
  test/iex_code/sessions_operation_history_test.exs \
  test/iex_code/swarm/peer_stream_history_test.exs \
  test/iex_code/tools/bounded_file_tools_test.exs \
  test/iex_code/tools/bounded_directory_test.exs \
  test/iex_code/tools_workspace_locks_test.exs \
  test/iex_code/runs/executor_test.exs \
  test/iex_code_web/live/workspace_history_test.exs \
  test/iex_code_web/live/workspace_streaming_test.exs \
  test/iex_code_web/live/workspace_request_budget_test.exs \
  test/iex_code_web/live/workspace_integrated_test.exs
```

| Final check | Actual outcome |
| --- | --- |
| Benchmark | Exit 0, 13 tests / 0 failures, 1.6 s, seed 0 |
| Focused affected | Exit 0, 267 tests / 0 failures, 41.8 s, seed 0 |
| Full precommit | **Exit 2, 3,643 tests / 1 failure**, 782.8 s, seed 827034 |
| Explicit compile | Exit 0, warnings-as-errors |
| Explicit format check | Exit 0 |

The full failure is the unchanged research manifest count, expected 20/actual
17 at `workspace_live_async_runs_test.exs:222` (test starts at line 163).
It was neither excluded nor fixed. The full gate is **not green**. Raw output
also retains intentional synthetic fault, Sandbox/default-fallback, Exqlite
client-exit and helper broken-pipe diagnostics; none is relabeled a pristine
run. Earlier full-suite crash latency 72.013 ms over 50 ms and palette timing
3,134 µs over 500 µs remain recorded historical failures, with isolated rerun
observations, not threshold waivers or proven causes. The final gate had
neither timing failure; final focused crash samples were 0.45–0.91 ms.

Mission-local raw records: `runtime/final-{benchmark,focused,precommit}.log`.
Retained baseline: `library/evidence/baseline-measurements.json` and original
benchmark log. M1: `validation/lean-execution/scrutiny/evidence/benchmark-round2.log`.
Some historical temporary raw gate logs/screenshots were lost; retained
summaries remain historical records, not recreated measurements.
