defmodule IexCode.Execution.TeamworkTest do
  use ExUnit.Case, async: true

  alias IexCode.Execution.Teamwork
  alias IexCode.Execution.Teamwork.Blueprint

  describe "patterns/0" do
    test "returns all 5 orchestration patterns" do
      patterns = Teamwork.patterns()
      assert length(patterns) == 5

      ids = Enum.map(patterns, & &1.id)

      assert "iterative_coding" in ids
      assert "distributed_coding" in ids
      assert "root_cause_and_fix" in ids
      assert "self_verification" in ids
      assert "system_migration" in ids
    end
  end

  describe "generate_blueprint/2" do
    test "generates default blueprint for standard objective" do
      objective = "Build high-performance rate limiter with sliding window counter"
      blueprint = Teamwork.generate_blueprint(objective)

      assert %Blueprint{} = blueprint
      assert blueprint.objective == objective
      assert is_binary(blueprint.id)
      assert String.starts_with?(blueprint.id, "tw-")

      assert blueprint.pattern in [
               "iterative_coding",
               "distributed_coding",
               "root_cause_and_fix",
               "self_verification",
               "system_migration"
             ]

      assert is_binary(blueprint.summary)
      assert length(blueprint.milestones) >= 3
      assert length(blueprint.agent_squad) >= 4
      assert blueprint.estimated_tokens > 0
      assert blueprint.estimated_duration_min > 0
      assert blueprint.boost? == false
    end

    test "boost mode elevates token budget and reasoning effort" do
      objective = "Refactor Phoenix channel multiplexer"
      normal = Teamwork.generate_blueprint(objective, boost?: false)
      boosted = Teamwork.generate_blueprint(objective, boost?: true)

      assert boosted.boost? == true
      assert boosted.estimated_tokens > normal.estimated_tokens
      assert Enum.any?(boosted.agent_squad, &(&1.reasoning_effort == "high"))
    end

    test "explicit pattern selection is respected" do
      objective = "Fix race condition in pubsub broker"
      bp = Teamwork.generate_blueprint(objective, pattern: "root_cause_and_fix")

      assert bp.pattern == "root_cause_and_fix"
      assert bp.pattern_name == "Root Cause & Fix"
      assert Enum.any?(bp.milestones, &(&1.agent_role == "deep_investigator"))
    end
  end

  describe "regenerate_with_pattern/2" do
    test "switches blueprint pattern while preserving objective and boost state" do
      bp =
        Teamwork.generate_blueprint("Optimize PostgreSQL JSON queries",
          boost?: true,
          pattern: "iterative_coding"
        )

      assert bp.pattern == "iterative_coding"
      assert bp.boost? == true

      switched = Teamwork.regenerate_with_pattern(bp, "self_verification")
      assert switched.pattern == "self_verification"
      assert switched.pattern_name == "Self-Verification & Audit"
      assert switched.objective == bp.objective
      assert switched.boost? == true
      assert length(switched.milestones) >= 3
    end
  end

  describe "serialization: to_map/1 and from_map/1" do
    test "round-trips blueprint faithfully" do
      bp =
        Teamwork.generate_blueprint("Decompose monolith into umbrella apps", boost?: true)

      map = Teamwork.to_map(bp)

      assert is_map(map)
      assert map["id"] == bp.id
      assert map["objective"] == bp.objective
      assert map["boost"] == true
      assert is_list(map["milestones"])
      assert is_list(map["agent_squad"])

      reconstructed = Teamwork.from_map(map)
      assert %Blueprint{} = reconstructed
      assert reconstructed.id == bp.id
      assert reconstructed.objective == bp.objective
      assert reconstructed.pattern == bp.pattern
      assert reconstructed.boost? == true
      assert length(reconstructed.milestones) == length(bp.milestones)
      assert length(reconstructed.agent_squad) == length(bp.agent_squad)
    end
  end

  describe "format_cli/1" do
    test "renders rich ANSI boxed preview string" do
      bp = Teamwork.generate_blueprint("Add distributed consensus via Raft", boost?: true)
      cli = Teamwork.format_cli(bp)

      assert is_binary(cli)
      assert cli =~ "TEAMWORK ORCHESTRATION BLUEPRINT"
      assert cli =~ "Add distributed consensus via Raft"
      assert cli =~ "BOOST ACTIVE - 3-TIER REASONING"
      assert cli =~ "Multi-Agent Squad"
      assert cli =~ "Execution Milestones"
    end
  end

  describe "pattern-specific milestone generators" do
    test "system_migration generates phased schema and cutover milestones" do
      bp =
        Teamwork.generate_blueprint("Migrate legacy users table to accounts schema",
          pattern: "system_migration"
        )

      assert bp.pattern == "system_migration"
      phases = Enum.map(bp.milestones, & &1.phase)

      assert Enum.any?(phases, &String.contains?(&1, "Pre-Migration"))
      assert Enum.any?(phases, &String.contains?(&1, "Dual-Write"))
      assert Enum.any?(phases, &String.contains?(&1, "Integrity Validation"))
      assert Enum.any?(phases, &String.contains?(&1, "Cutover"))
    end

    test "distributed_coding generates modular decoupled synthesis milestones" do
      bp =
        Teamwork.generate_blueprint("Parallelize image processing pipelines",
          pattern: "distributed_coding"
        )

      assert bp.pattern == "distributed_coding"
      titles = Enum.map(bp.milestones, & &1.title)

      assert Enum.any?(titles, &String.contains?(&1, "Protocol Specification"))
      assert Enum.any?(titles, &String.contains?(&1, "Parallel Module Implementation"))
      assert Enum.any?(titles, &String.contains?(&1, "Contract Reconciliation"))
      assert Enum.any?(titles, &String.contains?(&1, "Precommit Gate"))
    end

    test "custom model propagates to squad agent specifications" do
      bp =
        Teamwork.generate_blueprint("Build web scraper",
          model: "claude-3-7-sonnet"
        )

      assert Enum.all?(bp.agent_squad, &(&1.model == "claude-3-7-sonnet"))
    end
  end

  describe "toggle_boost/1 and milestone lifecycle" do
    test "toggle_boost flips boost and recalculates budgets" do
      bp = Teamwork.generate_blueprint("Fix race condition", boost?: false)
      assert bp.boost? == false

      boosted = Teamwork.toggle_boost(bp)
      assert boosted.boost? == true
      assert boosted.estimated_tokens > bp.estimated_tokens
      assert Enum.any?(boosted.agent_squad, &(&1.reasoning_effort == "high"))

      unboosted = Teamwork.toggle_boost(boosted)
      assert unboosted.boost? == false
    end

    test "milestone_stats and sync_milestones track progress across stages" do
      bp = Teamwork.generate_blueprint("Audit security", pattern: "self_verification")

      stats_init = Teamwork.milestone_stats(bp)
      assert stats_init.total == length(bp.milestones)
      assert stats_init.completed == 0
      assert stats_init.percent == 0

      bp_exploring = Teamwork.sync_milestones(bp, :exploring)
      stats_exploring = Teamwork.milestone_stats(bp_exploring)
      assert stats_exploring.completed >= 1
      assert stats_exploring.in_progress >= 1
      assert stats_exploring.percent > 0

      bp_complete = Teamwork.sync_milestones(bp, :complete)
      stats_complete = Teamwork.milestone_stats(bp_complete)
      assert stats_complete.completed == stats_complete.total
      assert stats_complete.percent == 100
      assert stats_complete.pending == 0

      # Also test with map representation
      map_bp = Teamwork.to_map(bp)
      synced_map = Teamwork.sync_milestones(map_bp, :coding)
      map_stats = Teamwork.milestone_stats(synced_map)
      assert map_stats.completed >= 1
      assert map_stats.in_progress >= 1
    end

    test "implements Access behaviour on Milestone, AgentSpec, and Blueprint" do
      bp = Teamwork.generate_blueprint("Verify Access protocol implementation")

      # Bracket access with strings and atoms on Blueprint
      assert bp["objective"] == "Verify Access protocol implementation"
      assert bp[:objective] == "Verify Access protocol implementation"
      assert bp["boost?"] == false
      assert bp[:boost?] == false

      # get_in support
      assert get_in(bp, ["pattern"]) == bp.pattern
      assert get_in(bp, [:pattern]) == bp.pattern

      # Milestone struct Access
      milestone = hd(bp.milestones)
      assert milestone["id"] == 1
      assert milestone[:id] == 1
      assert milestone["status"] == "pending"
      assert milestone[:status] == "pending"
      assert get_in(milestone, ["title"]) == milestone.title

      # AgentSpec struct Access
      agent = hd(bp.agent_squad)
      assert agent["role"] == "sentinel_orchestrator"
      assert agent[:role] == "sentinel_orchestrator"
      assert agent["model"] == "deepseek-v4-pro"
    end

    test "milestone progression visits all 4 phases before completion" do
      bp =
        Teamwork.generate_blueprint("Build high-throughput ingestion",
          pattern: "iterative_coding"
        )

      assert length(bp.milestones) == 4

      # Phase 1: Planning / Discovery
      bp_planning = Teamwork.sync_milestones(bp, :planning)
      statuses_plan = Enum.map(bp_planning.milestones, & &1.status)
      assert statuses_plan == ["in_progress", "pending", "pending", "pending"]

      # Phase 2: Exploring / Core Feature
      bp_exploring = Teamwork.sync_milestones(bp, :exploring)
      statuses_exp = Enum.map(bp_exploring.milestones, & &1.status)
      assert statuses_exp == ["completed", "in_progress", "pending", "pending"]

      # Phase 3: Coding / Integration & UX
      bp_coding = Teamwork.sync_milestones(bp, :coding)
      statuses_code = Enum.map(bp_coding.milestones, & &1.status)
      assert statuses_code == ["completed", "completed", "in_progress", "pending"]

      # Phase 4: Verifying / Precommit Gate
      bp_verifying = Teamwork.sync_milestones(bp, :verifying)
      statuses_ver = Enum.map(bp_verifying.milestones, & &1.status)
      assert statuses_ver == ["completed", "completed", "completed", "in_progress"]

      # Phase 5: Complete
      bp_done = Teamwork.sync_milestones(bp, :complete)
      statuses_done = Enum.map(bp_done.milestones, & &1.status)
      assert statuses_done == ["completed", "completed", "completed", "completed"]

      # Phase 6: Failed state transition
      bp_failed = Teamwork.sync_milestones(bp_verifying, :failed)
      statuses_fail = Enum.map(bp_failed.milestones, & &1.status)
      assert statuses_fail == ["completed", "completed", "completed", "failed"]
    end

    test "update_milestone modifies specific milestone in blueprint" do
      bp = Teamwork.generate_blueprint("Refactor engine", pattern: "iterative_coding")

      updated =
        Teamwork.update_milestone(bp, 1, %{
          status: "completed",
          description: "Updated spec"
        })

      first_milestone = hd(updated.milestones)
      assert first_milestone.status == "completed"
      assert first_milestone.description == "Updated spec"

      # Also test with atom-keyed map
      atom_map = %{milestones: [%{id: 1, status: "pending", title: "Task 1"}]}
      updated_map = Teamwork.update_milestone(atom_map, 1, %{status: "in_progress"})
      assert hd(updated_map.milestones).status == "in_progress"
    end
  end
end
