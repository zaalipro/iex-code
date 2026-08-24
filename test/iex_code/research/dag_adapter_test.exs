defmodule IexCode.Research.DagAdapterTest do
  use ExUnit.Case, async: true

  alias IexCode.Research.DagAdapter
  alias IexCode.Runs.DagManifest

  @canonical_fields ~w(key kind title depends_on params max_attempts)a

  test "emits canonical static nodes with adaptive rounds and visible provider fanout" do
    assert {:ok, nodes} =
             DagAdapter.build("Compare durable asynchronous coding harnesses",
               ranked_providers: [:tavily, "brave"],
               grounded_providers: [:openai_responses],
               max_rounds: 2,
               max_queries_per_round: 10,
               max_sources: 80,
               provider_snapshot_ref: "settings://search-providers/revision/42"
             )

    assert length(nodes) == 16
    assert Enum.all?(nodes, &(Map.keys(&1) |> Enum.sort() == Enum.sort(@canonical_fields)))

    first_plan = Enum.find(nodes, &(&1.key == "research.plan.1"))
    second_plan = Enum.find(nodes, &(&1.key == "research.plan.2"))
    assert first_plan.depends_on == []
    assert second_plan.depends_on == ["research.evidence.audit.1"]
    assert second_plan.params["coverage_policy"]["skip_round_when_prior_audit_is_sufficient"]

    ranked = Enum.filter(nodes, &(&1.kind == "research_ranked_search"))
    grounded = Enum.filter(nodes, &(&1.kind == "research_grounded_search"))
    assert length(ranked) == 4
    assert length(grounded) == 2
    assert Enum.all?(ranked, &(&1.params["plane"] == "ranked_results"))
    assert Enum.all?(grounded, &(&1.params["plane"] == "grounded_answer"))

    merge = Enum.find(nodes, &(&1.key == "research.evidence.merge.1"))
    assert merge.params["grounded_answers_are_not_ranked_rows"]

    assert Enum.sort(merge.depends_on) ==
             Enum.sort([
               "research.search.ranked.1.tavily",
               "research.search.ranked.1.brave",
               "research.search.grounded.1.openai_responses"
             ])

    assert List.last(nodes).kind == "research_report_verify"
  end

  test "fails closed for missing, unknown, or unsupported provider identifiers" do
    assert {:error, :no_research_provider} = DagAdapter.build("Research", [])

    assert {:error, :unsupported_research_provider} =
             DagAdapter.build("Research", ranked_providers: ["made_up"])

    assert {:error, :unsupported_research_provider} =
             DagAdapter.build("Research", grounded_providers: ["azure_foundry"])
  end

  test "canonical registry rejects research nodes until every typed handler is registered" do
    assert {:ok, nodes} =
             DagAdapter.build("Research", ranked_providers: ["duckduckgo"], max_rounds: 1)

    assert {:error, {:invalid_dag_step, 0, {:unsupported_kind, "research_plan"}}} =
             DagManifest.normalize(nodes)

    assert Enum.all?(DagAdapter.required_kinds(), &(&1 not in DagManifest.kinds()))
  end

  test "keeps credentials out, exposes artifact boundaries, and bounds node count" do
    assert {:ok, nodes} =
             DagAdapter.build("Research",
               ranked_providers: ["duckduckgo"],
               grounded_providers: ["anthropic_messages"],
               max_rounds: 6,
               provider_snapshot_ref: "settings://search-providers/current"
             )

    assert length(nodes) <= 128
    encoded = Jason.encode!(nodes)
    refute encoded =~ "api_key"
    refute encoded =~ "authorization"

    kinds = nodes |> Enum.map(& &1.params["artifact_kind"]) |> Enum.uniq()
    assert "research_query_ledger" in kinds
    assert "research_claim_ledger" in kinds
    assert "research_verified_report" in kinds

    assert DagAdapter.required_kinds() ==
             ~w(
               research_plan
               research_ranked_search
               research_grounded_search
               research_evidence_merge
               research_source_fetch
               research_evidence_audit
               research_report_synthesize
               research_report_verify
             )
  end

  test "all current providers and rounds remain within the canonical 128-step limit" do
    ranked =
      ~w(tavily brave exa perplexity firecrawl linkup serper serpapi google bing searxng duckduckgo)

    grounded = ~w(openai_responses anthropic_messages gemini_interactions)

    assert {:ok, nodes} =
             DagAdapter.build("Research",
               ranked_providers: ranked,
               grounded_providers: grounded,
               max_rounds: 6
             )

    assert length(nodes) == 116
    assert length(nodes) <= 128
    assert Enum.count(nodes, &(&1.kind == "research_ranked_search")) == 72
    assert Enum.count(nodes, &(&1.kind == "research_grounded_search")) == 18
  end
end
