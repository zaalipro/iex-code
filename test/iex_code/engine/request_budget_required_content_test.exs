defmodule IexCode.Engine.RequestBudgetRequiredContentTest do
  use IexCode.DataCase, async: false

  alias IexCode.{Projects, Repo, Runs, Sessions, Settings, Tools}
  alias IexCode.Engine.{AgentLoop, PlanStore, SessionServer, SwarmCoordinator}
  alias IexCode.E2E.MockLLMServer
  alias IexCode.LLM.RequestBudgetError
  alias IexCode.Tools.MultiPatch.Snapshot

  setup do
    provider = start_supervised!({MockLLMServer, scenario: :sse_chunks})
    root = Path.join(System.tmp_dir!(), "required-budget-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, _} =
      Settings.update_settings(%{
        openai_api_key: "fixture",
        openai_base_url: GenServer.call(provider, :get_info).url <> "/v1",
        max_tokens: 100,
        context_window_tokens: 2_000,
        context_compaction_strategy: "sliding_window",
        custom_system_prompt: nil,
        coding_style_rules: nil,
        workspace_persona: "minimalist",
        tool_approval_mode: "full_auto"
      })

    {:ok, project} = Projects.create_project(%{name: "Required budget", root_path: root})

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Required budget",
        swarm_mode: false,
        model_provider: "openai",
        model_name: "unknown-budget-fixture"
      })

    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")
    %{provider: provider, root: root, project: project, session: session}
  end

  test "planner overflow leaves earlier successful work and checkpoints unchanged", ctx do
    write(ctx, "successful.txt", "Earlier successful work")
    before = Snapshot.list_snapshots(ctx.session.id)
    assert [_] = before

    assert {:error, %RequestBudgetError{}} =
             SwarmCoordinator.run(ctx.session.id, String.duplicate("objective ", 3_000),
               project_root: ctx.root,
               allowed_tools: [],
               max_retries: 0
             )

    assert File.read!(Path.join(ctx.root, "successful.txt")) == "Earlier successful work"
    assert Snapshot.list_snapshots(ctx.session.id) == before
    assert MockLLMServer.get_requests(ctx.provider) == []

    # The public session rollback remains intentionally session-wide.
    assert {:ok, :rolled_back} =
             SwarmCoordinator.perform_rollback(ctx.root, %SwarmCoordinator.State{
               session_id: ctx.session.id,
               session: ctx.session,
               project_root: ctx.root
             })

    refute File.exists?(Path.join(ctx.root, "successful.txt"))
  end

  test "budget cleanup still restores mutations made during the current invocation", ctx do
    write(ctx, "successful.txt", "Earlier successful work")
    before = Snapshot.list_snapshots(ctx.session.id)
    {:ok, _} = Sessions.update_session(ctx.session, %{status: "paused"})

    assert {:ok, owner} =
             SwarmCoordinator.run_swarm(ctx.session.id, String.duplicate("objective ", 3_000),
               project_root: ctx.root,
               allowed_tools: [],
               max_retries: 0
             )

    monitor = Process.monitor(owner)
    assert_receive {:swarm_stage_changed, %{stage: :init}}, 5_000

    # The paused invocation has captured its boundary. Use the same authorized
    # mutation/snapshot seam as its tools, without introducing a fault endpoint.
    write(ctx, "successful.txt", "Current invocation change")
    write(ctx, "current.txt", "Current invocation file")
    SwarmCoordinator.resume(ctx.session.id)
    assert_receive {:DOWN, ^monitor, :process, ^owner, {:request_budget_failed, _}}, 10_000

    assert File.read!(Path.join(ctx.root, "successful.txt")) == "Earlier successful work"
    refute File.exists?(Path.join(ctx.root, "current.txt"))
    assert Snapshot.list_snapshots(ctx.session.id) == before
    assert MockLLMServer.get_requests(ctx.provider) == []
  end

  for guidance_size <- [100, 600] do
    test "actual normalized User (Steer) wrapper is required at size #{guidance_size}", ctx do
      server = start_supervised!({SessionServer, ctx.session.id})
      guidance = String.duplicate("guidance ", unquote(guidance_size))
      assert {:ok, normalized} = SessionServer.send_steering(ctx.session.id, "  " <> guidance)
      assert normalized == String.trim(guidance)
      assert [steering] = Sessions.list_messages(ctx.session.id)
      assert steering.agent_name == "User (Steer)"
      assert steering.content == "🧭 **Steering Guidance**: " <> normalized

      {:ok, _} =
        Sessions.create_message(%{
          session_id: ctx.session.id,
          role: "assistant",
          content: String.duplicate("Old removable context ", 1_000)
        })

      assert :ok =
               SessionServer.send_prompt(ctx.session.id, "Current objective", allowed_tools: [])

      await_single(server)

      if unquote(guidance_size) == 100 do
        assert [%{body: body}] = MockLLMServer.get_requests(ctx.provider)
        assert Enum.any?(body["messages"], &(&1["content"] == steering.content))
        assert Enum.any?(body["messages"], &(&1["content"] == "Current objective"))
      else
        assert MockLLMServer.get_requests(ctx.provider) == []
        assert Sessions.get_session(ctx.session.id).status == "failed"

        assert Enum.any?(
                 Sessions.list_messages(ctx.session.id),
                 &(&1.content =~ "context budget")
               )

        assert Repo.get!(Sessions.Message, steering.id).content == steering.content
      end
    end
  end

  test "only the persisted current objective is required among identical tied historical prompts",
       ctx do
    objective = String.duplicate("current objective ", 160) |> String.trim()
    timestamp = DateTime.utc_now() |> DateTime.truncate(:second)

    # Both sides of any freshly generated UUID, at the same timestamp.
    Repo.insert_all(Sessions.Message, [
      %{
        id: "00000000-0000-4000-8000-000000000000",
        session_id: ctx.session.id,
        role: "user",
        content: objective,
        inserted_at: timestamp,
        updated_at: timestamp
      },
      %{
        id: "ffffffff-ffff-4fff-bfff-ffffffffffff",
        session_id: ctx.session.id,
        role: "user",
        content: objective,
        inserted_at: timestamp,
        updated_at: timestamp
      }
    ])

    server = start_supervised!({SessionServer, ctx.session.id})
    assert :ok = SessionServer.send_prompt(ctx.session.id, objective, allowed_tools: [])
    await_single(server)
    assert [%{body: body}] = MockLLMServer.get_requests(ctx.provider)
    assert Enum.count(body["messages"], &(&1["content"] == objective)) == 1
    assert Sessions.get_session(ctx.session.id).status == "idle"
    assert Enum.count(Sessions.list_messages(ctx.session.id), &(&1.content == objective)) == 3
  end

  for strategy <- ["token_compaction", "sliding_window", "rolling_summary"] do
    test "#{strategy} rejects an oversized current request_input answer before transport", ctx do
      {:ok, _} =
        Settings.update_settings(%{
          context_window_tokens: 8_000,
          context_compaction_strategy: unquote(strategy)
        })

      {run, opts, _bundle} = pause_for_input(ctx)
      answer = String.duplicate("required answer ", 3_000) <> "Required tail"

      assert {:error, %RequestBudgetError{}} =
               AgentLoop.resume(run, ctx.root, fn _, _ -> :ok end, answer, opts)

      assert MockLLMServer.get_requests(ctx.provider) == []
      refute Sessions.get_run_final_message(run)

      assert %{status: "failed", error_message: message} =
               Runs.get_command_by_idempotency_key(run, "agent-loop:model:1:turn:2")

      assert message =~ "No model request was sent"
    end
  end

  test "resume preserves the complete exchange and legacy fingerprint, then replays its receipt",
       ctx do
    {:ok, _} = Settings.update_settings(%{context_window_tokens: 8_000})
    {run, opts, bundle} = pause_for_input(ctx)
    answer = "Use path A. " <> String.duplicate("constraint ", 300) <> "Required tail"

    assert {:ok, first} = AgentLoop.resume(run, ctx.root, fn _, _ -> :ok end, answer, opts)
    assert [%{body: body}] = MockLLMServer.get_requests(ctx.provider)
    assert [assistant, plan_reply, answer_reply] = Enum.take(body["messages"], -3)
    assert Enum.map(assistant["tool_calls"], & &1["id"]) == ["plan-call", "ask-call"]
    assert plan_reply["tool_call_id"] == "plan-call"
    assert answer_reply["tool_call_id"] == "ask-call"
    assert answer_reply["content"] == "User answer: " <> answer

    legacy_messages =
      bundle.messages ++
        [%{role: "assistant", content: bundle.text, tool_calls: bundle.tool_calls}] ++
        bundle.tool_messages ++
        [%{role: "tool", tool_call_id: "ask-call", content: "User answer: " <> answer}]

    expected_hash =
      legacy_messages
      |> Jason.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    command = Runs.get_command_by_idempotency_key(run, "agent-loop:model:1:turn:2")
    assert command.arguments["context_sha256"] == expected_hash
    assert command.status == "completed"

    {:ok, _} =
      Settings.update_settings(%{
        context_window_tokens: 1_000,
        max_tokens: 2_000,
        openai_api_key: nil
      })

    assert {:ok, second} = AgentLoop.execute(run, ctx.root, fn _, _ -> :ok end, opts)
    assert second.replayed?
    assert Map.delete(second, :replayed?) == first
    assert Runs.get_command_by_idempotency_key(run, command.idempotency_key) == command
    assert length(MockLLMServer.get_requests(ctx.provider)) == 1
    assert Enum.count(Sessions.list_messages(ctx.session.id), &(&1.role == "assistant")) == 1
  end

  test "resume replays an existing unmarked model receipt without rebudgeting it", ctx do
    {run, opts, bundle} = pause_for_input(ctx)
    answer = "Use path A"

    legacy_messages =
      bundle.messages ++
        [%{role: "assistant", content: bundle.text, tool_calls: bundle.tool_calls}] ++
        bundle.tool_messages ++
        [%{role: "tool", tool_call_id: "ask-call", content: "User answer: " <> answer}]

    hash =
      legacy_messages
      |> Jason.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    initial = Runs.get_command_by_idempotency_key(run, "agent-loop:model:1:turn:1")
    arguments = Map.merge(initial.arguments, %{"turn" => 2, "context_sha256" => hash})

    authority = [
      lease_owner: run.lease_owner,
      run_attempt: run.attempt,
      lease_generation: run.lease_generation
    ]

    {:ok, queued} =
      Runs.enqueue_command_worker(
        run,
        "agent-loop:model:1:turn:2",
        %{tool_name: "__llm_chat__", arguments: arguments, max_attempts: 1},
        authority
      )

    {:ok, running} =
      Runs.transition_command_worker(queued, "running", %{attempt: 1}, authority)

    {:ok, completed} =
      Runs.transition_command_worker(
        running,
        "completed",
        %{
          output:
            Jason.encode!(%{
              "text" => "Historical resume completion",
              "tool_calls" => [],
              "usage" => %{"input_tokens" => 7, "output_tokens" => 11, "cost_cents" => 2}
            })
        },
        authority
      )

    {:ok, _} =
      Settings.update_settings(%{
        context_window_tokens: 1_000,
        max_tokens: 2_000,
        openai_api_key: nil
      })

    assert {:ok, result} = AgentLoop.resume(run, ctx.root, fn _, _ -> :ok end, answer, opts)
    assert result.content == "Historical resume completion"
    assert result.usage == %{input_tokens: 7, output_tokens: 11, cost_cents: 2}
    assert Runs.get_command_by_idempotency_key(run, completed.idempotency_key) == completed
    assert MockLLMServer.get_requests(ctx.provider) == []
  end

  test "checkpoint read failure refuses interactive execution before its first phase", ctx do
    write(ctx, "successful.txt", "Earlier successful work")
    before = Snapshot.list_snapshots(ctx.session.id)
    Repo.query!("ALTER TABLE mutation_snapshots RENAME TO budget_snapshot_read_failure")

    try do
      assert {:error, :rollback_boundary_unavailable} =
               SwarmCoordinator.run(ctx.session.id, String.duplicate("objective ", 3_000),
                 project_root: ctx.root,
                 allowed_tools: [],
                 max_retries: 0
               )
    after
      Repo.query!("ALTER TABLE budget_snapshot_read_failure RENAME TO mutation_snapshots")
    end

    assert Snapshot.list_snapshots(ctx.session.id) == before
    assert File.read!(Path.join(ctx.root, "successful.txt")) == "Earlier successful work"
    assert MockLLMServer.get_requests(ctx.provider) == []
    refute_received {:swarm_stage_changed, %{stage: :init}}
  end

  defp pause_for_input(ctx) do
    {:ok, _} =
      Runs.create_run(%{
        project_id: ctx.project.id,
        session_id: ctx.session.id,
        objective: "Resume objective",
        kind: "coding_agent",
        mode: "single",
        metadata: %{
          "execution_policy" => %{
            "allowed_tools" => ["request_input", "update_plan"],
            "max_tokens" => 100
          }
        }
      })

    {:ok, run} = Runs.claim_next_run("required-budget-worker", lease_ms: 300_000)
    on_exit(fn -> PlanStore.clear(run.id) end)
    Process.put(:agent_loop_receiver, self())

    Process.put(:agent_loop_responses, [
      {:ok,
       %{
         text: "Need a decision.",
         tool_calls: [
           %{id: "plan-call", name: "update_plan", args: %{"steps" => [%{"title" => "Choose"}]}},
           %{id: "ask-call", name: "request_input", args: %{"question" => "Which path?"}}
         ],
         usage: %{}
       }}
    ])

    opts = [
      tool_executor: Tools,
      run_lease_owner: run.lease_owner,
      run_attempt: run.attempt,
      run_lease_generation: run.lease_generation
    ]

    assert {:paused, paused} =
             AgentLoop.execute(
               run,
               ctx.root,
               fn _, _ -> :ok end,
               Keyword.put(opts, :llm, IexCode.AgentLoopLLMStub)
             )

    assert paused.request["tool_call_id"] == "ask-call"
    bundle = PlanStore.take_pause(run.id)
    PlanStore.put_pause(run.id, bundle)
    {run, opts, bundle}
  end

  defp write(ctx, path, content) do
    assert {:ok, _} =
             Tools.execute(
               "write_file",
               %{
                 "path" => path,
                 "content" => content,
                 "project_id" => ctx.project.id,
                 "session_id" => ctx.session.id
               },
               ctx.root
             )
  end

  defp await_single(server) do
    task = :sys.get_state(server).current_task
    monitor = if task, do: Process.monitor(task)
    assert_receive {:message_created, %{role: "assistant"}}, 10_000
    if monitor, do: assert_receive({:DOWN, ^monitor, :process, ^task, _}, 5_000)
    assert_receive {:session_status_changed, status} when status in ["idle", "failed"], 5_000
    if status == "idle", do: assert_receive({:session_status_changed, "idle"}, 5_000)
    assert :sys.get_state(server).current_task == nil
  end
end
