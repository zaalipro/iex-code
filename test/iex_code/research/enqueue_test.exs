defmodule IexCode.Research.EnqueueTest do
  use IexCode.DataCase, async: false

  alias IexCode.Research.Results
  alias IexCode.Runs.RunDispatcher
  alias IexCode.{Projects, Runs, Sessions}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "iex-code-research-enqueue-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, project} = Projects.create_project(%{name: "Research enqueue", root_path: root})
    {:ok, session} = Sessions.create_session(%{project_id: project.id, title: "Research"})
    %{project: project, session: session}
  end

  test "queues an exact immutable level policy with conservative budgets", context do
    attrs = %{
      project_id: context.project.id,
      session_id: context.session.id,
      objective: "Compare asynchronous research schedulers",
      metadata: %{"source" => "test"}
    }

    assert {:ok, run} =
             RunDispatcher.enqueue_research(attrs, %{
               level: "medium",
               ranked_providers: ["duckduckgo"],
               max_sources: 6
             })

    assert run.kind == "deep_research"
    assert run.mode == "research"
    assert run.execution_engine == "dag_v1"
    assert run.max_attempts == 1
    assert run.token_budget > 0
    assert run.cost_budget_cents > 0
    assert run.time_budget_ms == 20 * 60_000
    assert run.metadata["source"] == "test"

    assert run.metadata["research"]["level_policy"] == %{
             "level" => "medium",
             "multistep_rounds" => 2,
             "lead_per_step" => 1,
             "async_subagents" => 3
           }

    steps = Runs.list_steps(run)
    assert Enum.count(steps, &(&1.kind == "research_plan")) == 2
    assert Enum.all?(steps, &(&1.effect_class in ~w(pure provider)))

    assert Enum.all?(Enum.filter(steps, &(&1.kind == "research_plan")), fn step ->
             step.params["max_queries"] == 3
           end)

    assert Enum.all?(Enum.filter(steps, &(&1.kind == "research_ranked_search")), fn step ->
             step.params["max_search_calls"] == 3
           end)

    result = Results.get_by_run(run)
    assert is_integer(result.id)
    assert result.level == "medium"
    assert result.status == "queued"
  end

  test "invalid level and unavailable providers fail before inserting anything", context do
    attrs = %{
      project_id: context.project.id,
      session_id: context.session.id,
      objective: "Must fail"
    }

    assert {:error, :invalid_research_level} =
             RunDispatcher.enqueue_research(attrs, %{
               level: "extreme",
               ranked_providers: ["duckduckgo"],
               max_sources: 4
             })

    assert {:error, :unsupported_research_provider} =
             RunDispatcher.enqueue_research(attrs, %{
               level: "low",
               ranked_providers: ["bing"],
               max_sources: 4
             })

    assert Runs.list_runs(session_id: context.session.id) == []
  end

  test "omitted and out-of-range launcher limits normalize before persistence", context do
    attrs = %{
      project_id: context.project.id,
      session_id: context.session.id,
      objective: "Normalize exact research limits"
    }

    assert {:ok, defaulted} =
             RunDispatcher.enqueue_research(attrs, %{
               level: "low",
               ranked_providers: ["duckduckgo"]
             })

    assert defaulted.metadata["research"]["max_sources"] == 40
    assert defaulted.metadata["research"]["fetch_parallelism"] == 6

    default_fetch =
      defaulted
      |> Runs.list_steps()
      |> Enum.find(&(&1.kind == "research_source_fetch"))

    assert default_fetch.params["max_sources"] == 40
    assert default_fetch.params["max_parallel_fetches"] == 6

    attrs = Map.put(attrs, :objective, "Normalize invalid exact research limits")

    assert {:ok, normalized} =
             RunDispatcher.enqueue_research(attrs, %{
               level: "low",
               ranked_providers: ["duckduckgo"],
               max_sources: 0,
               fetch_parallelism: 99
             })

    assert normalized.metadata["research"]["max_sources"] == 40
    assert normalized.metadata["research"]["fetch_parallelism"] == 6
  end

  test "accepts a bounded string-keyed launch map without mixed Ecto params", context do
    assert {:ok, run} =
             RunDispatcher.enqueue_research(
               %{
                 "project_id" => context.project.id,
                 "session_id" => context.session.id,
                 "objective" => "String-keyed research launch",
                 "metadata" => %{"source" => "external_api"}
               },
               %{
                 "level" => "low",
                 "ranked_providers" => ["duckduckgo"],
                 "max_sources" => 5
               }
             )

    assert run.objective == "String-keyed research launch"
    assert run.metadata["source"] == "external_api"
    assert run.metadata["research"]["max_sources"] == 5
  end
end
