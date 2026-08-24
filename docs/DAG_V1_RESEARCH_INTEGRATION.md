# `dag_v1` integration design for adaptive research

## Status

The finite, immutable, read-only `dag_v1` core is available. Its closed registry currently
executes only `project_inventory`, `read_file`, and `aggregate`. The durable scheduler owns
ready-node claims, bounded concurrency, append-only attempts, leases, generation fencing,
checkpoint receipts, retry backoff, pause/resume/cancel handling, and terminal recovery.

This document defines the **future research integration contract**, not a claim that research
runs use `dag_v1` today. Every `research_*` kind emitted by `IexCode.Research.DagAdapter` remains
unregistered and therefore fails manifest validation. Ranked search, grounded search, model,
fetch, evidence, artifact, citation, usage, and cost handlers must remain fail-closed until their
provider-effect and persistence contracts are implemented. Existing `legacy_v1` coding and
research rows are never reinterpreted as DAGs.

## Domain-neutral scheduler boundary

The scheduler knows only allowlisted step kinds, dependencies, attempts, leases, checkpoints,
and bounded outputs. It must not branch on `deep_research`, a provider name, or a research step
kind. The active scheduler is deliberately static. Resource declarations are descriptor-bound
metadata for the current read-only kinds, not yet a general lock manager; hierarchical budget
reservation, artifact commits, and dynamic graph expansion remain research activation gates.

1. A workflow adapter creates immutable plain nodes using the canonical `DagManifest` fields:
   key, kind, title, dependencies, JSON params, and maximum attempts.
2. Persisted kind strings resolve through the closed `DagStepRegistry`. A persisted module name
   is never executable configuration. The core already persists descriptor versions; every
   research handler needs its own reviewed versioned descriptor before registration.
3. The active core atomically claims ready nodes only when dependencies completed and the parent
   run lease is authoritative. Future provider handlers additionally require resource acquisition
   and pre-use budget reservation before claim or external dispatch.
4. The active core fences transitions, checkpoint receipts, and result settlement by run/step
   attempt plus lease generation. Research adds fenced usage settlement and artifact commits.
5. A handler returns bounded JSON; only the scheduler validates and commits it. A future dynamic
   manifest revision may permit proposed children only after validating the parent's immutable
   expansion allowlist, total-node and per-parent limits, known registry kinds, resource policy,
   remaining budget, duplicate keys, and cycles in one transaction.
6. Terminal run state stops new claims and the runner cooperatively cancels active work. Every
   future research handler must additionally checkpoint cancellation immediately before each
   provider request and artifact effect; forceful cancellation must not pretend an external
   provider call was reversed.

`IexCode.Runs.DagManifest`, `DagStepRegistry`, and `DagStepHandler` define the current closed
core. `IexCode.Research.DagAdapter` emits only their plain node shape. Its research kinds are not
registered, so research manifests remain deliberately invalid while unrelated read-only DAG
manifests execute normally.

## Additional persistence required before research activation

The active core already persists immutable handler version/effect/replay/resource/timeout fields,
a manifest digest, and append-only step attempts with parent-run and step lease generations,
checkpoint receipts, retry timing, result digests, and terminal history. Research still needs
versioned input/output evidence contracts and append-only usage settlements. Provider request
identity and billing data must not be hidden in an overwritten step result.

Artifacts need an immutable content-addressed body store or file URI. The existing artifact row
may reference that body, but content, byte size, media type, SHA-256, producer attempt, and
contract version must be committed as one logical terminalization protocol. Large source bodies
must not be duplicated inside SQLite metadata.

Any future dynamic child insertion needs a unique
`(run_id, expansion_parent_attempt, expansion_key)` and
the transaction must append the child nodes, dependency edges, expansion event, and parent
result/checkpoint together. Recovery can replay that transaction idempotently, not rerun an
unknown external effect.

## Adaptive research as a plugin

`IexCode.Research.DagAdapter` currently emits up to six bounded rounds statically as an
integration fixture. Each later plan depends on the prior audit and its future handler may return
a no-op decision when coverage is sufficient. This encodes intended adaptive round boundaries
without granting a model authority to create arbitrary executable nodes. It is not runnable
until all emitted kinds are registered. A future manifest revision can replace preallocated
rounds with bounded dynamic expansion after that protocol is available:

```text
plan(round N)
  ├─ search.ranked(query × provider) ─┐
  ├─ search.grounded(query × model) ──┼─ evidence.merge
  └───────────────────────────────────┘       │
                                      source.fetch(URL × policy)
                                               │
                                        evidence.audit
                                          /          \
                            unresolved gaps            sufficient coverage
                                  plan(N+1)             report.synthesize
                                                             │
                                                       report.verify
```

Ranked and grounded outputs remain different contracts. `search.ranked` yields provider-ranked
rows. `search.grounded` yields an answer bundle with URL citations, hosted search-call proof,
provider identity, and usage. `evidence.merge` may normalize both into evidence records but must
not invent a rank for a grounded answer or discard its answer-level provenance.

The static adapter gives each provider/plane/round batch its own node, so concurrency,
cancellation, retries, health, and costs are visible at that boundary. Its query-ledger artifact
must retain each request separately. A future bounded-expansion revision should use one node per
request with deterministic keys derived from round, normalized query, plane, and provider.
Provider credentials are resolved at execution through a scoped secret resolver; they never
enter step params, results, events, or artifacts. A revisioned non-secret provider snapshot
reference pins selection and filter policy while still allowing key rotation.

## Evidence and citation boundaries

Future research handlers should publish versioned artifacts at these commit points:

- **research plan** — questions, rationale, filters, round, and stopping criteria;
- **query ledger** — provider/query identity, timing, status, normalized error, cost/usage, and
  exact raw-response content hash or retention reference;
- **evidence set** — canonical URL, retrieval time, source/provider provenance, content hash,
  bounded extracted passages, publication metadata, and fetch status;
- **claim ledger** — atomic report claims linked to evidence passage IDs, entailment verdict,
  conflict/uncertainty notes, and verifier version;
- **verified report** — Markdown body plus citation index whose entries reference claim-ledger
  and evidence IDs rather than only positional prompt numbers.

The synthesis handler produces a draft, not the final report. `research.report.verify` must reject
out-of-range links, unsupported claims, uncited factual sentences, fabricated URLs, and citation
targets whose evidence body/hash is absent. Verification failure can expand a bounded repair or
new-evidence round; it cannot silently mark the report complete.

## Budgets and stopping

The active read-only DAG core has no provider/token/cost reservation plane. Before a future
research provider step is claimed or issues a request, reserve its declared maximum
requests/search calls/tokens/cost from the parent run. Settle provider-reported actuals atomically
and return unused reservation.
Unknown-price providers require an explicit conservative ceiling or operator approval; missing
usage is not zero usage. The coordinator receives only remaining-budget summaries, never keys.

Stop when coverage thresholds and citation verification pass, or when max rounds, wall time,
sources, nodes, requests, tokens, or cost are exhausted. Budget exhaustion terminalizes pending
siblings deterministically and preserves the best verified partial artifact, explicitly labeled
partial. Adaptive expansion must never bypass the run's original ceiling.

## Control and recovery semantics

The active runner already prevents new claims while paused, propagates cancellation through
supervised control tokens, and fences retry attempts. Research steering and targeted
query/provider controls are not implemented. Their future contract is append-only: steering is
consumed by a specific planning attempt and may influence a later round but cannot rewrite
completed evidence. Targeted cancel affects one query/provider node and lets merge/audit decide
whether evidence remains sufficient. Restart creates a new step attempt and fences the old one.

Only checkpoints created before an external effect or after its idempotent durable receipt are
replayable. A provider call without an idempotency contract is retried as a new attempt and its
query ledger records both attempts. A fetched content hash can be reused without fetching again.
Synthesis can resume from committed evidence and claim ledgers; it must not repeat completed
search merely because the BEAM process restarted.

## Research activation gates

- Register only fully implemented, typed `research_*` handlers; unknown kinds and versions fail
  closed without affecting the active read-only registry.
- Provider-effect resource policy, request idempotency, cancellation, timeout, and recovery tests.
- Transactional artifact/evidence commits and deterministic recovery after every commit boundary.
- Transactional bounded expansion only if a later manifest revision adopts dynamic graphs.
- Hierarchical budget reservation/settlement and terminal sibling behavior.
- Ranked and grounded conformance suites, cancellation immediately before every request, and
  secret-redaction tests across errors/events/artifacts.
- Evidence/body checksum, claim-entailment, citation-integrity, and partial-report tests.
- Mission Control streams arbitrary graph nodes and exposes query/provider controls without
  implying dispatch equals consumption or a draft equals a verified report.
- Full precommit and Ego Lite desktop/mobile smoke. Close the Ego task space without clearing
  the user's browser sessions.
