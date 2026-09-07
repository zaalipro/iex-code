defmodule IexCode.Execution.TeamworkPreview do
  @moduledoc """
  Multi-agent Teamwork Preview orchestration framework.

  Analyzes high-level goals and objectives to synthesize a structured Teamwork
  Blueprint featuring:
  - Selected blueprint pattern (Iterative Coding, Distributed Coding, Root Cause & Fix, Self-Verification)
  - Sequential and parallel milestone breakdown with acceptance criteria and deliverables
  - Specialized agent squad composition (Sentinel Orchestrator, DeepCoder, DeepInvestigator, Test Verifier, Security Auditor)
  - Resource and token budget estimation
  - Serialization to durable run metadata and rich ANSI CLI / LiveView rendering
  """

  defmodule Milestone do
    @moduledoc false
    defstruct [
      :id,
      :phase,
      :title,
      :agent_role,
      :agent_title,
      :description,
      :target_files,
      :deliverables,
      :acceptance_criteria,
      :status
    ]
  end

  defmodule AgentSpec do
    @moduledoc false
    defstruct [
      :role,
      :title,
      :model,
      :reasoning_effort,
      :mission,
      :capabilities
    ]
  end

  defmodule Blueprint do
    @moduledoc false
    defstruct [
      :id,
      :objective,
      :pattern,
      :pattern_name,
      :summary,
      :milestones,
      :agent_squad,
      :estimated_tokens,
      :estimated_duration_min,
      :boost?,
      :created_at
    ]
  end

  @patterns [
    %{
      id: "iterative_coding",
      name: "Iterative Coding",
      description: "Progressive architecture, implementation, verification, and hardening loop."
    },
    %{
      id: "distributed_coding",
      name: "Distributed Coding",
      description: "Parallel independent module synthesis with automated contract merging."
    },
    %{
      id: "root_cause_and_fix",
      name: "Root Cause & Fix",
      description:
        "Deep diagnostic investigation, minimal repro, surgical patch, regression gate."
    },
    %{
      id: "self_verification",
      name: "Self-Verification & Audit",
      description:
        "Rigorous implementation with adversarial edge-case testing and precommit gating."
    },
    %{
      id: "system_migration",
      name: "System Migration",
      description:
        "Multi-stage schema/code migration with zero-downtime cutover and fallback verification."
    }
  ]

  @doc "Returns available blueprint patterns for teamwork orchestration."
  def patterns, do: @patterns

  @doc """
  Generates a multi-agent teamwork blueprint for an objective.
  """
  def generate_blueprint(objective, opts \\ []) do
    clean_obj = String.trim(to_string(objective || "System enhancement objective"))
    boost? = Keyword.get(opts, :boost?, false)
    pattern = Keyword.get(opts, :pattern) || select_pattern(clean_obj)
    pattern_meta = Enum.find(@patterns, &(&1.id == pattern)) || hd(@patterns)
    model = Keyword.get(opts, :model) || "deepseek-v4-pro"

    squad = compose_squad(boost?, clean_obj, model)
    milestones = generate_milestones(pattern, clean_obj, squad)

    %Blueprint{
      id: "tw-" <> Ecto.UUID.generate(),
      objective: clean_obj,
      pattern: pattern,
      pattern_name: pattern_meta.name,
      summary: summarize_strategy(pattern, clean_obj),
      milestones: milestones,
      agent_squad: squad,
      estimated_tokens: if(boost?, do: 85_000, else: 45_000),
      estimated_duration_min: if(boost?, do: 12, else: 8),
      boost?: boost?,
      created_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @doc "Regenerates an existing blueprint with a different selected pattern."
  def regenerate_with_pattern(%Blueprint{} = bp, new_pattern, opts \\ []) do
    boost? = Keyword.get(opts, :boost?, bp.boost?)

    model =
      Keyword.get(opts, :model) ||
        (bp.agent_squad != [] and hd(bp.agent_squad).model) ||
        "deepseek-v4-pro"

    generate_blueprint(bp.objective, pattern: new_pattern, boost?: boost?, model: model)
  end

  @doc "Toggles boost mode on a blueprint, re-synthesizing agent reasoning efforts and budget estimates."
  def toggle_boost(%Blueprint{} = bp) do
    model =
      (bp.agent_squad != [] && hd(bp.agent_squad).model) || "deepseek-v4-pro"

    generate_blueprint(bp.objective, pattern: bp.pattern, boost?: not bp.boost?, model: model)
  end

  @doc """
  Calculates milestone completion counts and percentage from a blueprint, map, or milestones list.
  """
  def milestone_stats(blueprint_or_milestones) do
    milestones =
      cond do
        is_struct(blueprint_or_milestones, Blueprint) -> blueprint_or_milestones.milestones
        is_map(blueprint_or_milestones) -> blueprint_or_milestones["milestones"] || []
        is_list(blueprint_or_milestones) -> blueprint_or_milestones
        true -> []
      end

    total = length(milestones)

    completed =
      Enum.count(milestones, fn m ->
        status =
          cond do
            is_struct(m) -> m.status
            is_map(m) -> m["status"] || m[:status]
            true -> nil
          end

        status == "completed"
      end)

    in_progress =
      Enum.count(milestones, fn m ->
        status =
          cond do
            is_struct(m) -> m.status
            is_map(m) -> m["status"] || m[:status]
            true -> nil
          end

        status == "in_progress"
      end)

    failed =
      Enum.count(milestones, fn m ->
        status =
          cond do
            is_struct(m) -> m.status
            is_map(m) -> m["status"] || m[:status]
            true -> nil
          end

        status == "failed"
      end)

    pending = max(0, total - completed - in_progress - failed)
    percent = if total > 0, do: round(completed / total * 100), else: 0

    %{
      total: total,
      completed: completed,
      in_progress: in_progress,
      failed: failed,
      pending: pending,
      percent: percent
    }
  end

  @doc """
  Synchronizes milestone execution statuses according to current swarm stage.
  Stages: :init, :planning, :exploring, :coding, :verifying, :complete, :failed
  """
  def sync_milestones(blueprint_or_list, stage, opts \\ [])

  def sync_milestones(milestones, stage, _opts) when is_list(milestones) do
    Enum.map(milestones, fn m ->
      m_id =
        cond do
          is_struct(m) -> m.id
          is_map(m) -> m["id"] || m[:id] || 1
          true -> 1
        end

      current_status =
        cond do
          is_struct(m) -> m.status || "pending"
          is_map(m) -> m["status"] || m[:status] || "pending"
          true -> "pending"
        end

      new_status =
        case stage do
          :init ->
            if m_id == 1, do: "in_progress", else: "pending"

          :planning ->
            cond do
              m_id == 1 -> "in_progress"
              true -> "pending"
            end

          :exploring ->
            cond do
              m_id == 1 -> "completed"
              m_id == 2 -> "in_progress"
              true -> "pending"
            end

          :coding ->
            cond do
              m_id == 1 -> "completed"
              m_id == 2 -> "in_progress"
              true -> "pending"
            end

          :verifying ->
            cond do
              m_id in [1, 2] -> "completed"
              m_id == 3 -> "in_progress"
              true -> "pending"
            end

          :complete ->
            "completed"

          :failed ->
            if current_status == "in_progress", do: "failed", else: current_status

          _ ->
            current_status
        end

      cond do
        is_struct(m, Milestone) ->
          %{m | status: new_status}

        is_map(m) ->
          Map.put(m, "status", new_status)

        true ->
          m
      end
    end)
  end

  def sync_milestones(%Blueprint{} = bp, stage, opts) do
    %{bp | milestones: sync_milestones(bp.milestones, stage, opts)}
  end

  def sync_milestones(%{"milestones" => milestones} = bp_map, stage, opts)
      when is_list(milestones) do
    Map.put(bp_map, "milestones", sync_milestones(milestones, stage, opts))
  end

  def sync_milestones(other, _stage, _opts), do: other

  @doc "Updates a specific milestone by ID in a blueprint struct or map."
  def update_milestone(blueprint_or_list, milestone_id, updates) when is_map(updates) do
    case blueprint_or_list do
      %Blueprint{} = bp ->
        updated =
          Enum.map(bp.milestones, fn m ->
            if m.id == milestone_id do
              struct(m, updates)
            else
              m
            end
          end)

        %{bp | milestones: updated}

      %{"milestones" => milestones} = map ->
        str_id = to_string(milestone_id)

        updated =
          Enum.map(milestones, fn m ->
            if to_string(m["id"] || m[:id]) == str_id do
              Enum.reduce(updates, m, fn {k, v}, acc ->
                Map.put(acc, to_string(k), v)
              end)
            else
              m
            end
          end)

        Map.put(map, "milestones", updated)

      milestones when is_list(milestones) ->
        str_id = to_string(milestone_id)

        Enum.map(milestones, fn m ->
          if to_string(m["id"] || m[:id]) == str_id do
            Enum.reduce(updates, m, fn {k, v}, acc ->
              Map.put(acc, to_string(k), v)
            end)
          else
            m
          end
        end)

      other ->
        other
    end
  end

  @doc "Converts a Blueprint struct into a JSON-serializable map for run metadata."
  def to_map(%Blueprint{} = bp) do
    %{
      "id" => bp.id,
      "objective" => bp.objective,
      "pattern" => bp.pattern,
      "pattern_name" => bp.pattern_name,
      "summary" => bp.summary,
      "estimated_tokens" => bp.estimated_tokens,
      "estimated_duration_min" => bp.estimated_duration_min,
      "boost" => bp.boost?,
      "created_at" => bp.created_at,
      "agent_squad" =>
        Enum.map(bp.agent_squad, fn a ->
          %{
            "role" => a.role,
            "title" => a.title,
            "model" => a.model,
            "reasoning_effort" => a.reasoning_effort,
            "mission" => a.mission,
            "capabilities" => a.capabilities
          }
        end),
      "milestones" =>
        Enum.map(bp.milestones, fn m ->
          %{
            "id" => m.id,
            "phase" => m.phase,
            "title" => m.title,
            "agent_role" => m.agent_role,
            "agent_title" => m.agent_title,
            "description" => m.description,
            "target_files" => m.target_files,
            "deliverables" => m.deliverables,
            "acceptance_criteria" => m.acceptance_criteria,
            "status" => m.status || "pending"
          }
        end)
    }
  end

  def to_map(nil), do: nil

  @doc "Reconstructs a Blueprint struct from a map."
  def from_map(%{"objective" => objective} = map) do
    squad =
      (map["agent_squad"] || [])
      |> Enum.map(fn a ->
        %AgentSpec{
          role: a["role"],
          title: a["title"],
          model: a["model"],
          reasoning_effort: a["reasoning_effort"],
          mission: a["mission"],
          capabilities: a["capabilities"] || []
        }
      end)

    milestones =
      (map["milestones"] || [])
      |> Enum.map(fn m ->
        %Milestone{
          id: m["id"],
          phase: m["phase"],
          title: m["title"],
          agent_role: m["agent_role"],
          agent_title: m["agent_title"],
          description: m["description"],
          target_files: m["target_files"] || [],
          deliverables: m["deliverables"] || [],
          acceptance_criteria: m["acceptance_criteria"] || [],
          status: m["status"] || "pending"
        }
      end)

    %Blueprint{
      id: map["id"] || "tw-" <> Ecto.UUID.generate(),
      objective: objective,
      pattern: map["pattern"] || "iterative_coding",
      pattern_name: map["pattern_name"] || "Iterative Coding",
      summary: map["summary"] || "",
      milestones: milestones,
      agent_squad: squad,
      estimated_tokens: map["estimated_tokens"] || 45_000,
      estimated_duration_min: map["estimated_duration_min"] || 8,
      boost?: map["boost"] || false,
      created_at: map["created_at"]
    }
  end

  def from_map(_), do: nil

  @doc "Renders a formatted ANSI terminal summary of the blueprint for CLI."
  def format_cli(%Blueprint{} = bp) do
    boost_badge = if bp.boost?, do: " [⚡ BOOST ACTIVE - 3-TIER REASONING]", else: ""

    header = """
    ╔═══════════════════════════════════════════════════════════════════════════════╗
    ║                      TEAMWORK ORCHESTRATION BLUEPRINT                         ║
    ╚═══════════════════════════════════════════════════════════════════════════════╝
    Objective:   #{bp.objective}
    Pattern:     #{bp.pattern_name}#{boost_badge}
    Est. Budget: #{bp.estimated_tokens} tokens (~#{bp.estimated_duration_min} min)
    Strategy:    #{bp.summary}

    ── Multi-Agent Squad ────────────────────────────────────────────────────────────
    """

    squad_lines =
      Enum.map_join(bp.agent_squad, "\n", fn a ->
        "  • #{String.pad_trailing(a.title, 24)} [#{a.model} | effort: #{a.reasoning_effort}]\n    Mission: #{a.mission}"
      end)

    milestone_header =
      "\n\n── Execution Milestones ─────────────────────────────────────────────────────────\n"

    milestone_lines =
      Enum.map_join(bp.milestones, "\n\n", fn m ->
        files =
          if m.target_files != [],
            do: "\n    Target Files: #{Enum.join(m.target_files, ", ")}",
            else: ""

        deliverables = Enum.map_join(m.deliverables, "\n", &"      - #{&1}")
        criteria = Enum.map_join(m.acceptance_criteria, "\n", &"      ✓ #{&1}")

        """
        [Stage #{m.id}] #{m.phase}: #{m.title}
          Assigned: #{m.agent_title} (#{m.agent_role})#{files}
          Deliverables:
        #{deliverables}
          Acceptance Criteria:
        #{criteria}
        """
      end)

    header <> squad_lines <> milestone_header <> milestone_lines
  end

  # --- Internal Helpers ---

  defp select_pattern(obj) do
    lower = String.downcase(obj)

    cond do
      matches_any?(lower, ~w(fix bug race error deadlock crash fail broken regression issue)) ->
        "root_cause_and_fix"

      matches_any?(lower, ~w(migrate migration schema database upgrade cutover)) ->
        "system_migration"

      matches_any?(lower, ~w(test audit security verify precommit harden sanitize)) ->
        "self_verification"

      matches_any?(lower, ~w(parallel distributed modules components decouple separate)) ->
        "distributed_coding"

      true ->
        "iterative_coding"
    end
  end

  defp matches_any?(text, keywords) do
    Enum.any?(keywords, &String.contains?(text, &1))
  end

  defp summarize_strategy("root_cause_and_fix", obj) do
    "Sentinel coordinates deep failure isolation, reproduces via minimal test, applies targeted patch, and verifies regression-free state for '#{truncate(obj, 60)}'."
  end

  defp summarize_strategy("system_migration", obj) do
    "Phased zero-downtime transformation with schema prep, backward-compatible dual-writes, full validation, and safe cutover for '#{truncate(obj, 60)}'."
  end

  defp summarize_strategy("self_verification", obj) do
    "Adversarial test-driven implementation with automated invariant checking, edge-case probing, and precommit compliance for '#{truncate(obj, 60)}'."
  end

  defp summarize_strategy("distributed_coding", obj) do
    "Parallel decomposition across decoupled interfaces with independent worker agents and Sentinel contract reconciliation for '#{truncate(obj, 60)}'."
  end

  defp summarize_strategy(_pattern, obj) do
    "Progressive iterative delivery: Sentinel architecture -> DeepCoder implementation -> Investigator verification -> Quality audit for '#{truncate(obj, 60)}'."
  end

  defp compose_squad(boost?, _obj, model) do
    effort = if boost?, do: "high", else: "medium"

    [
      %AgentSpec{
        role: "sentinel_orchestrator",
        title: "Sentinel Orchestrator",
        model: model,
        reasoning_effort: effort,
        mission:
          "Decomposes goals, manages agent handoffs, enforces contracts, and oversees checkpoints.",
        capabilities: ["planning", "swarm_consensus", "contract_validation"]
      },
      %AgentSpec{
        role: "deep_coder",
        title: "DeepCoder",
        model: model,
        reasoning_effort: effort,
        mission:
          "Synthesizes modular, idiomatic code adhering to project architecture and AST conventions.",
        capabilities: ["code_synthesis", "ast_refactor", "tool_execution"]
      },
      %AgentSpec{
        role: "deep_investigator",
        title: "DeepInvestigator",
        model: model,
        reasoning_effort: effort,
        mission:
          "Explores codebase AST, pinpoints edge-case hazards, inspects logs, and diagnoses failures.",
        capabilities: ["ast_search", "root_cause_analysis", "diagnostics"]
      },
      %AgentSpec{
        role: "test_verifier",
        title: "Test Verifier",
        model: model,
        reasoning_effort: if(boost?, do: "high", else: "medium"),
        mission:
          "Designs ExUnit test suites, probes adversarial boundary cases, and drives auto-remediation.",
        capabilities: ["ex_unit", "adversarial_testing", "regression_gate"]
      },
      %AgentSpec{
        role: "security_auditor",
        title: "Security & Safety Auditor",
        model: model,
        reasoning_effort: "medium",
        mission:
          "Verifies secret masking, execution safety policies, and clean precommit compliance.",
        capabilities: ["safety_policy", "secret_masking", "precommit_audit"]
      }
    ]
  end

  defp generate_milestones("root_cause_and_fix", obj, _squad) do
    [
      %Milestone{
        id: 1,
        phase: "Phase 1: Investigation",
        title: "Failure Isolation & Minimal Repro",
        agent_role: "deep_investigator",
        agent_title: "DeepInvestigator",
        description:
          "Analyze error logs, trace execution paths, and craft a minimal reproducing test case.",
        target_files: infer_target_files(obj),
        deliverables: ["Root cause analysis document", "Failing reproduction test"],
        acceptance_criteria: [
          "Reproduction test reliably captures failure",
          "Root cause identified without guesswork"
        ],
        status: "pending"
      },
      %Milestone{
        id: 2,
        phase: "Phase 2: Surgical Patch",
        title: "Implement Targeted Fix",
        agent_role: "deep_coder",
        agent_title: "DeepCoder",
        description:
          "Apply minimal, sound code changes resolving root cause without touching unrelated logic.",
        target_files: infer_target_files(obj),
        deliverables: ["Targeted bugfix patch", "Updated type specs and docs"],
        acceptance_criteria: [
          "Reproduction test passes cleanly",
          "No behavioral regressions in surrounding code"
        ],
        status: "pending"
      },
      %Milestone{
        id: 3,
        phase: "Phase 3: Verification",
        title: "Adversarial Edge-Case Testing",
        agent_role: "test_verifier",
        agent_title: "Test Verifier",
        description:
          "Execute full suite and stress test boundary conditions around the patched area.",
        target_files: ["test/"],
        deliverables: ["Expanded regression test suite", "Boundary condition coverage report"],
        acceptance_criteria: ["100% test suite pass", "Zero concurrency or boundary leaks"],
        status: "pending"
      },
      %Milestone{
        id: 4,
        phase: "Phase 4: Release Gate",
        title: "Audit & Precommit Cleanliness",
        agent_role: "security_auditor",
        agent_title: "Security & Safety Auditor",
        description:
          "Audit safety policy compliance, verify secret masking, and pass mix precommit.",
        target_files: [],
        deliverables: ["Precommit verification log", "Security audit clearance"],
        acceptance_criteria: [
          "mix precommit passes with 0 warnings and 0 failures",
          "Clean Git working tree"
        ],
        status: "pending"
      }
    ]
  end

  defp generate_milestones("self_verification", obj, _squad) do
    [
      %Milestone{
        id: 1,
        phase: "Phase 1: Specification",
        title: "Invariants & Acceptance Specification",
        agent_role: "sentinel_orchestrator",
        agent_title: "Sentinel Orchestrator",
        description:
          "Define rigorous invariant specifications, contracts, and test plan for '#{truncate(obj, 40)}'.",
        target_files: infer_target_files(obj),
        deliverables: ["System invariant specification", "Pre-flight test matrix"],
        acceptance_criteria: ["Explicit boundaries identified", "All test scenarios documented"],
        status: "pending"
      },
      %Milestone{
        id: 2,
        phase: "Phase 2: Implementation",
        title: "Contract-Driven Implementation",
        agent_role: "deep_coder",
        agent_title: "DeepCoder",
        description:
          "Develop the required logic adhering strictly to the contract and architectural specs.",
        target_files: infer_target_files(obj),
        deliverables: ["Core implementation files", "Unit test scaffolding"],
        acceptance_criteria: ["All contract assertions satisfied", "0 compiler warnings"],
        status: "pending"
      },
      %Milestone{
        id: 3,
        phase: "Phase 3: Adversarial Probe",
        title: "Adversarial & Property Verification",
        agent_role: "test_verifier",
        agent_title: "Test Verifier",
        description:
          "Subject implementation to boundary values, nil inputs, race contention, and stress tests.",
        target_files: ["test/"],
        deliverables: ["Adversarial test suite", "Stress test telemetry report"],
        acceptance_criteria: ["Zero edge-case failures", "Complete property coverage"],
        status: "pending"
      },
      %Milestone{
        id: 4,
        phase: "Phase 4: Quality Clearance",
        title: "Full Precommit & Code Review Gate",
        agent_role: "security_auditor",
        agent_title: "Security & Safety Auditor",
        description: "Verify formatting, dialyzer specs, lint checks, and precommit compliance.",
        target_files: [],
        deliverables: ["Clean precommit run", "Final sign-off manifest"],
        acceptance_criteria: ["mix precommit passes cleanly", "Zero formatting defects"],
        status: "pending"
      }
    ]
  end

  defp generate_milestones("system_migration", obj, _squad) do
    target_files = infer_target_files(obj)

    [
      %Milestone{
        id: 1,
        phase: "Phase 1: Pre-Migration Analysis",
        title: "Schema & Dependency Analysis",
        agent_role: "sentinel_orchestrator",
        agent_title: "Sentinel Orchestrator",
        description:
          "Map existing data structures, verify foreign key constraints, and draft backward-compatible migration plan for '#{truncate(obj, 40)}'.",
        target_files: target_files,
        deliverables: ["Schema dependency graph", "Zero-downtime migration RFC"],
        acceptance_criteria: [
          "Zero breaking schema changes without transition layer",
          "Explicit rollback strategy documented"
        ],
        status: "pending"
      },
      %Milestone{
        id: 2,
        phase: "Phase 2: Dual-Write Layer",
        title: "Backward-Compatible Schema & Interface Synthesis",
        agent_role: "deep_coder",
        agent_title: "DeepCoder",
        description:
          "Author Ecto migrations and dual-write adapter layer guaranteeing safe schema evolution.",
        target_files: target_files,
        deliverables: ["Ecto migration scripts", "Compatibility adapter modules"],
        acceptance_criteria: [
          "Migrations run idempotently up and down",
          "Clean compilation with 0 warnings"
        ],
        status: "pending"
      },
      %Milestone{
        id: 3,
        phase: "Phase 3: Integrity Validation",
        title: "Data Migration & Rollback Probing",
        agent_role: "test_verifier",
        agent_title: "Test Verifier",
        description:
          "Execute data backfill simulations, verify constraint integrity, and test automated rollback procedures.",
        target_files: ["test/"],
        deliverables: ["Data integrity test suite", "Rollback verification report"],
        acceptance_criteria: [
          "100% data integrity verified under concurrent traffic",
          "Rollback executes cleanly without data loss"
        ],
        status: "pending"
      },
      %Milestone{
        id: 4,
        phase: "Phase 4: Cutover & Gate",
        title: "Final Cutover & Precommit Gate",
        agent_role: "security_auditor",
        agent_title: "Security & Safety Auditor",
        description:
          "Deprecate legacy adapters, verify zero lock contention, and achieve clean mix precommit clearance.",
        target_files: [],
        deliverables: ["Cutover sign-off manifest", "Clean precommit run"],
        acceptance_criteria: [
          "mix precommit passes with 0 warnings and 0 failures",
          "Zero lingering deprecated code paths"
        ],
        status: "pending"
      }
    ]
  end

  defp generate_milestones("distributed_coding", obj, _squad) do
    target_files = infer_target_files(obj)

    [
      %Milestone{
        id: 1,
        phase: "Phase 1: Interface Contracts",
        title: "Modular Interface & Protocol Specification",
        agent_role: "sentinel_orchestrator",
        agent_title: "Sentinel Orchestrator",
        description:
          "Decompose '#{truncate(obj, 40)}' into decoupled module boundaries with typed Elixir behaviors and contracts.",
        target_files: target_files,
        deliverables: ["Behavior & contract specs", "Parallel worker assignment matrix"],
        acceptance_criteria: [
          "Decoupled boundaries without cyclic dependencies",
          "Clear boundary type specifications"
        ],
        status: "pending"
      },
      %Milestone{
        id: 2,
        phase: "Phase 2: Parallel Synthesis",
        title: "Parallel Module Implementation",
        agent_role: "deep_coder",
        agent_title: "DeepCoder",
        description:
          "Implement decoupled modules independently adhering strictly to the defined behaviors and AST structures.",
        target_files: target_files,
        deliverables: ["Independent module implementations", "Isolated component tests"],
        acceptance_criteria: [
          "Each module implements its behavior contract",
          "Clean compilation across all isolated units"
        ],
        status: "pending"
      },
      %Milestone{
        id: 3,
        phase: "Phase 3: Integration & Reconciliation",
        title: "Contract Reconciliation & Cross-Module Wiring",
        agent_role: "deep_coder",
        agent_title: "DeepCoder",
        description:
          "Wire decoupled modules together, resolve integration friction, and verify end-to-end event flows.",
        target_files: target_files,
        deliverables: ["Integrated system harness", "Integration pipeline specs"],
        acceptance_criteria: [
          "End-to-end integration tests pass cleanly",
          "Zero inter-module state leaks"
        ],
        status: "pending"
      },
      %Milestone{
        id: 4,
        phase: "Phase 4: Adversarial Audit",
        title: "End-to-End Stress & Precommit Gate",
        agent_role: "test_verifier",
        agent_title: "Test Verifier",
        description:
          "Probe boundary conditions, race concurrency, run full test suite, and pass mix precommit.",
        target_files: ["test/"],
        deliverables: ["Comprehensive stress test suite", "Precommit clearance report"],
        acceptance_criteria: [
          "100% test pass rate across all concurrent modules",
          "mix precommit passes with 0 warnings"
        ],
        status: "pending"
      }
    ]
  end

  defp generate_milestones(_pattern, obj, _squad) do
    target_files = infer_target_files(obj)

    [
      %Milestone{
        id: 1,
        phase: "Phase 1: Discovery",
        title: "Architecture & Interface Planning",
        agent_role: "sentinel_orchestrator",
        agent_title: "Sentinel Orchestrator",
        description:
          "Analyze project context, map dependencies, and draft the execution blueprint for '#{truncate(obj, 40)}'.",
        target_files: target_files,
        deliverables: ["Architecture design RFC", "Component dependency map"],
        acceptance_criteria: ["Clear module boundaries", "No architectural conflicts identified"],
        status: "pending"
      },
      %Milestone{
        id: 2,
        phase: "Phase 2: Implementation",
        title: "Core Feature & Subsystem Synthesis",
        agent_role: "deep_coder",
        agent_title: "DeepCoder",
        description:
          "Implement primary business logic, schema changes, and service functions with AST alignment.",
        target_files: target_files,
        deliverables: ["Engine code changes", "Interface adapters"],
        acceptance_criteria: [
          "Clean compilation with 0 warnings",
          "Modular structure adhering to Phoenix/OTP standards"
        ],
        status: "pending"
      },
      %Milestone{
        id: 3,
        phase: "Phase 3: LiveView & UX",
        title: "Workspace & LiveView Integration",
        agent_role: "deep_coder",
        agent_title: "DeepCoder",
        description:
          "Connect subsystem to LiveView workspace, command palette, and interactive UI controls.",
        target_files: ["lib/iex_code_web/live/workspace_live.ex"],
        deliverables: ["Interactive LiveView components", "Visual state telemetry"],
        acceptance_criteria: [
          "Responsive real-time UI updates",
          "Subtle micro-interactions with deep carbon theme"
        ],
        status: "pending"
      },
      %Milestone{
        id: 4,
        phase: "Phase 4: Verification",
        title: "ExUnit Suite & Precommit Gate",
        agent_role: "test_verifier",
        agent_title: "Test Verifier",
        description:
          "Author comprehensive unit/LiveView tests, run verification, and achieve clean mix precommit.",
        target_files: ["test/"],
        deliverables: [
          "Automated unit & integration tests",
          "mix precommit clean verification pass"
        ],
        acceptance_criteria: ["100% test pass rate", "Zero regressions in existing test suite"],
        status: "pending"
      }
    ]
  end

  defp infer_target_files(obj) do
    lower = String.downcase(obj)

    cond do
      String.contains?(lower, "parser") or String.contains?(lower, "command") ->
        ["lib/iex_code/execution/command_parser.ex", "lib/iex_code/execution/router.ex"]

      String.contains?(lower, "llm") or String.contains?(lower, "reasoning") or
          String.contains?(lower, "model") ->
        ["lib/iex_code/llm/capabilities.ex", "lib/iex_code/llm/openai.ex"]

      String.contains?(lower, "swarm") or String.contains?(lower, "team") ->
        ["lib/iex_code/execution/teamwork_preview.ex", "lib/iex_code_web/live/workspace_live.ex"]

      String.contains?(lower, "settings") ->
        ["lib/iex_code_web/live/settings_live.ex", "lib/iex_code/settings/app_settings.ex"]

      true ->
        ["lib/iex_code/execution/", "lib/iex_code_web/live/"]
    end
  end

  defp truncate(text, max_len) do
    if String.length(text) <= max_len do
      text
    else
      String.slice(text, 0, max_len - 3) <> "..."
    end
  end
end
