defmodule IexCode.Engine.RequestBudgetPathsTest do
  use IexCode.DataCase, async: false

  alias IexCode.{Projects, Runs, Sessions, Settings}
  alias IexCode.Engine.{AgentLoop, SessionServer}
  alias IexCode.Engine.Agents.{CoderAgent, PlannerAgent}
  alias IexCode.E2E.MockLLMServer
  alias IexCode.LLM.RequestBudgetError

  setup do
    provider = start_supervised!({MockLLMServer, scenario: :sse_chunks})
    url = GenServer.call(provider, :get_info).url
    root = Path.join(System.tmp_dir!(), "request-budget-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, _} =
      Settings.update_settings(%{
        openai_api_key: "fixture",
        openai_base_url: url <> "/v1",
        max_tokens: 100,
        context_window_tokens: 2_000
      })

    {:ok, project} = Projects.create_project(%{name: "Budget", root_path: root})

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Budget",
        swarm_mode: false,
        model_provider: "openai",
        model_name: "unknown-fixture"
      })

    %{provider: provider, project: project, session: session, root: root}
  end

  for role <- [:planner, :coder] do
    test "#{role} budgets fitting actual payload and rejects mandatory overflow without transport",
         ctx do
      module = if unquote(role) == :planner, do: PlannerAgent, else: CoderAgent

      pid =
        start_supervised!(
          {module, session_id: ctx.session.id, session: ctx.session, project_root: ctx.root}
        )

      call = if unquote(role) == :planner, do: &PlannerAgent.plan/3, else: &CoderAgent.code/3

      assert {:ok, _} =
               call.(pid, "Small objective",
                 allowed_tools: [],
                 steer_directives: ["Keep compatibility"]
               )

      assert [%{body: body}] = MockLLMServer.get_requests(ctx.provider)
      assert body["max_tokens"] == 100
      assert byte_size(Jason.encode!(body)) <= (2_000 - 100 - 128) * 3
      assert div(byte_size(Jason.encode!(body)) * 5 + 15, 16) + 128 + 100 <= 2_000
      assert Enum.any?(body["messages"], &String.contains?(Jason.encode!(&1), "Small objective"))
      refute Map.has_key?(body, "tools")
      MockLLMServer.clear_requests(ctx.provider)

      assert {:error, %RequestBudgetError{}} =
               call.(pid, String.duplicate("mandatory ", 3_000), allowed_tools: [])

      assert MockLLMServer.get_requests(ctx.provider) == []
    end
  end

  test "durable single rejects before transport and does not consume pending steering", ctx do
    {:ok, _} =
      Runs.create_run(%{
        project_id: ctx.project.id,
        session_id: ctx.session.id,
        objective: "Objective",
        kind: "coding_agent",
        mode: "single",
        metadata: %{"execution_policy" => %{"allowed_tools" => [], "max_tokens" => 100}}
      })

    {:ok, running} = Runs.claim_next_run("budget-worker", lease_ms: 60_000)

    {:ok, control} =
      Runs.enqueue_control(running, "budget-steer", %{
        kind: "steer",
        payload: %{"guidance" => String.duplicate("steering ", 700)}
      })

    {:ok, _} = Runs.claim_control(control.id, "budget-worker")

    opts = [
      run_lease_owner: "budget-worker",
      run_attempt: running.attempt,
      run_lease_generation: running.lease_generation
    ]

    assert {:error, %RequestBudgetError{}} =
             AgentLoop.execute(running, ctx.root, fn _, _ -> :ok end, opts)

    assert Runs.get_control(control.id).status == "claimed"
    assert MockLLMServer.get_requests(ctx.provider) == []
    refute Sessions.get_run_final_message(running)
    assert [%{status: "failed", error_message: message}] = Runs.list_commands(running)
    assert message =~ "No model request was sent"
  end

  test "legacy receipt identity does not treat an ordinary steering-prefixed objective as a control",
       ctx do
    objective = "Steering guidance: " <> String.duplicate("x", 9_000)

    {:ok, _} =
      Runs.create_run(%{
        project_id: ctx.project.id,
        session_id: ctx.session.id,
        objective: objective,
        kind: "coding_agent",
        mode: "single",
        metadata: %{"execution_policy" => %{"allowed_tools" => [], "max_tokens" => 100}}
      })

    {:ok, run} = Runs.claim_next_run("budget-worker", lease_ms: 60_000)

    assert {:error, %RequestBudgetError{}} =
             AgentLoop.execute(run, ctx.root, fn _, _ -> :ok end,
               run_lease_owner: run.lease_owner,
               run_attempt: run.attempt,
               run_lease_generation: run.lease_generation
             )

    expected =
      Jason.encode!([%{role: "user", content: objective}])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    assert [command] = Runs.list_commands(run)
    assert command.arguments["context_sha256"] == expected
  end

  test "interactive swarm budget overflow cannot become a successful fallback plan", ctx do
    assert {:error, %RequestBudgetError{}} =
             IexCode.Engine.SwarmCoordinator.run(
               ctx.session.id,
               String.duplicate("mandatory ", 3_000),
               project_root: ctx.root,
               allowed_tools: [],
               max_retries: 0
             )

    assert MockLLMServer.get_requests(ctx.provider) == []
    assert Sessions.get_session(ctx.session.id).status == "failed"

    refute Enum.any?(
             Sessions.list_messages(ctx.session.id),
             &String.contains?(&1.content, "Swarm Execution Complete")
           )
  end

  test "durable single sends the budgeted authorized payload and replays after settings change",
       ctx do
    {:ok, _} =
      Runs.create_run(%{
        project_id: ctx.project.id,
        session_id: ctx.session.id,
        objective: "Check the fixture",
        kind: "coding_agent",
        mode: "single",
        metadata: %{
          "execution_policy" => %{"allowed_tools" => ["read_file"], "max_tokens" => 100}
        }
      })

    {:ok, run} = Runs.claim_next_run("budget-worker", lease_ms: 60_000)

    opts = [
      run_lease_owner: run.lease_owner,
      run_attempt: run.attempt,
      run_lease_generation: run.lease_generation
    ]

    assert {:ok, first} = AgentLoop.execute(run, ctx.root, fn _, _ -> :ok end, opts)
    assert [%{body: body}] = MockLLMServer.get_requests(ctx.provider)
    assert body["max_tokens"] == 100
    assert [%{"function" => %{"name" => "read_file"}}] = body["tools"]
    assert Enum.any?(body["messages"], &(&1["content"] == "Check the fixture"))
    assert byte_size(Jason.encode!(body)) <= (2_000 - 100 - 128) * 3
    assert div(byte_size(Jason.encode!(body)) * 5 + 15, 16) + 128 + 100 <= 2_000

    {:ok, _} =
      Settings.update_settings(%{
        context_window_tokens: 1_000,
        max_tokens: 2_000,
        openai_api_key: nil
      })

    assert {:ok, second} = AgentLoop.execute(run, ctx.root, fn _, _ -> :ok end, opts)
    assert second.replayed?
    assert first == Map.delete(second, :replayed?)
    assert length(MockLLMServer.get_requests(ctx.provider)) == 1

    assert length(Enum.filter(Sessions.list_messages(ctx.session.id), &(&1.role == "assistant"))) ==
             1
  end

  test "interactive single sends fitting objective and allowlist without losing content", ctx do
    {:ok, _} =
      Sessions.create_message(%{
        session_id: ctx.session.id,
        role: "user",
        content: String.duplicate("Old removable context ", 1_000)
      })

    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{ctx.session.id}")
    server = start_supervised!({SessionServer, ctx.session.id})

    assert :ok =
             SessionServer.send_prompt(ctx.session.id, "Check the fixture",
               allowed_tools: ["read_file"]
             )

    state = :sys.get_state(server)
    monitor = Process.monitor(state.current_task)
    assert_receive {:message_created, %{role: "assistant"}}, 10_000
    assert_receive {:DOWN, ^monitor, :process, _, _}, 5_000
    assert_receive {:session_status_changed, "idle"}, 5_000
    _ = :sys.get_state(server)
    assert [%{body: body}] = MockLLMServer.get_requests(ctx.provider)
    assert body["max_tokens"] == 100
    assert [%{"function" => %{"name" => "read_file"}}] = body["tools"]
    assert Enum.any?(body["messages"], &(&1["content"] == "Check the fixture"))
    assert byte_size(Jason.encode!(body)) <= (2_000 - 100 - 128) * 3
    assert div(byte_size(Jason.encode!(body)) * 5 + 15, 16) + 128 + 100 <= 2_000
  end

  test "interactive single exposes actionable failure instead of successful idle completion",
       ctx do
    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{ctx.session.id}")
    server = start_supervised!({SessionServer, ctx.session.id})

    assert :ok =
             SessionServer.send_prompt(ctx.session.id, String.duplicate("objective ", 3_000),
               allowed_tools: []
             )

    state = :sys.get_state(server)
    monitor = Process.monitor(state.current_task)
    assert_receive {:message_created, %{role: "assistant", content: content}}, 10_000
    assert content =~ "context budget"
    assert content =~ "Reduce"
    assert_receive {:DOWN, ^monitor, :process, _, _}, 5_000
    _ = :sys.get_state(server)
    assert MockLLMServer.get_requests(ctx.provider) == []
    assert Sessions.get_session(ctx.session.id).status == "failed"
  end
end
