defmodule IexCode.Execution.BoostEngineTest do
  use ExUnit.Case, async: true

  alias IexCode.Execution.BoostEngine

  describe "boost_policy/2" do
    test "elevates model parameters to maximum cognitive reasoning" do
      base_policy = %{"temperature" => 0.7, "agent_max_turns" => 10}
      boosted = BoostEngine.boost_policy(base_policy)

      assert boosted["boost"] == true
      assert boosted["boost_tier"] == "deep_reasoning_v1"
      assert boosted["boost_hierarchy"] == ["orchestrator", "deep_coder", "verifier"]
      assert boosted["reasoning_effort"] == "high"
      assert boosted["thinking_budget"] == 16_384
      assert boosted["max_tokens"] >= 16_384
      assert boosted["max_completion_tokens"] >= 16_384
      assert boosted["agent_max_turns"] >= 20
      assert boosted["swarm_agent_count"] >= 5
    end
  end

  describe "hierarchy/0" do
    test "returns the 3-tier reasoning hierarchy specifications" do
      hierarchy = BoostEngine.hierarchy()

      assert is_list(hierarchy)
      assert length(hierarchy) == 3

      [orchestrator, deep_coder, verifier] = hierarchy
      assert orchestrator.id == "orchestrator"
      assert orchestrator.tier == 1
      assert deep_coder.id == "deep_coder"
      assert deep_coder.tier == 2
      assert verifier.id == "verifier"
      assert verifier.tier == 3

      assert Enum.all?(hierarchy, &(&1.reasoning_effort == "high"))
    end
  end

  describe "boost_context/3 and to_map/1" do
    test "synthesizes complete codebase context with AST symbols and Git summary" do
      objective = "Refactor connection pooling in PostgreSQL adapter"
      enriched = BoostEngine.boost_context(objective, File.cwd!())

      assert is_map(enriched)
      assert enriched.objective == objective
      assert is_list(enriched.symbols)
      assert is_binary(enriched.git_summary)
      assert enriched.prompt_enhancement =~ "BOOST MODE ENGAGED"
      assert enriched.prompt_enhancement =~ "3-TIER REASONING HIERARCHY ACTIVE"
      assert enriched.prompt_enhancement =~ "Tier 1 (Sentinel Orchestrator)"
      assert enriched.prompt_enhancement =~ "Tier 2 (DeepCoder)"
      assert enriched.prompt_enhancement =~ "Tier 3 (DeepInvestigator & Verifier)"

      map = BoostEngine.to_map(enriched)
      assert is_map(map)
      assert Map.has_key?(map, "symbols")
      assert Map.has_key?(map, "git_summary")
      assert Map.has_key?(map, "prompt_enhancement")
    end

    test "handles missing or empty project paths gracefully without crashing" do
      enriched = BoostEngine.boost_context("Check invariants", nil)
      assert enriched.git_summary == "Git status: clean"
      assert enriched.symbols == []
    end
  end

  describe "effective_prompt/1" do
    test "returns plain objective when no boost or blueprint metadata present" do
      run = %{objective: "Implement basic endpoint", metadata: %{}}
      assert BoostEngine.effective_prompt(run) == "Implement basic endpoint"

      assert BoostEngine.effective_prompt("Plain objective string") == "Plain objective string"
      assert BoostEngine.effective_prompt(nil) == ""
    end

    test "augments prompt with boost context when prompt_enhancement exists" do
      run = %{
        objective: "Fix race condition",
        metadata: %{"prompt_enhancement" => "⚡ BOOST MODE ENGAGED [3-TIER REASONING]"}
      }

      effective = BoostEngine.effective_prompt(run)
      assert effective =~ "Fix race condition"
      assert effective =~ "⚡ BOOST MODE ENGAGED"
    end

    test "augments prompt with teamwork blueprint milestones when blueprint exists" do
      blueprint =
        IexCode.Execution.Teamwork.generate_blueprint("Synthesize streaming pipeline")

      run = %{
        objective: "Synthesize streaming pipeline",
        metadata: %{"teamwork_blueprint" => IexCode.Execution.Teamwork.to_map(blueprint)}
      }

      effective = BoostEngine.effective_prompt(run)
      assert effective =~ "Synthesize streaming pipeline"
      assert effective =~ "TEAMWORK ORCHESTRATION BLUEPRINT"
      assert effective =~ "Execution Milestones"
    end

    test "handles atom and string keys in metadata uniformly" do
      run_atoms = %{
        objective: "Test atoms",
        metadata: %{prompt_enhancement: "BOOST_ACTIVE"}
      }

      assert BoostEngine.effective_prompt(run_atoms) =~ "BOOST_ACTIVE"
    end
  end
end
