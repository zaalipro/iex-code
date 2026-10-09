defmodule IexCodeWeb.WorkspaceIntegratedTest do
  use IexCodeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias IexCode.{Projects, Runs, Sessions, Settings}
  alias IexCode.E2E.MockLLMServer
  alias IexCode.Engine.FleetSupervisor
  alias IexCode.Runs.Executor
  alias IexCode.Test.LeanWorkspaceFixture, as: Fixture

  setup do
    provider = start_supervised!({MockLLMServer, scenario: :sse_chunks})
    receiver = self()
    MockLLMServer.set_scenario(provider, &Fixture.respond(&1, receiver))
    root = Path.join(System.tmp_dir!(), "integrated-workspace-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "fixture.txt"), Fixture.original())
    on_exit(fn -> File.rm_rf!(root) end)
    url = GenServer.call(provider, :get_info).url

    {:ok, _} =
      Settings.update_settings(%{
        openai_api_key: "fixture",
        openai_base_url: url <> "/v1",
        default_model: "integrated-fixture",
        max_tokens: 256,
        context_window_tokens: 8_000,
        agent_max_turns: 4,
        default_run_max_attempts: 1,
        swarm_max_retries: 0,
        default_reasoning_effort: "none",
        tool_approval_mode: "prompt_dangerous",
        tool_category_overrides: %{"file_mutations" => "prompt"},
        default_tools: %{"ast_search" => false, "web_search" => false}
      })

    {:ok, project} = Projects.create_project(%{name: "Integrated fixture", root_path: root})

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Integrated fixture",
        swarm_mode: false,
        model_provider: "openai",
        model_name: "integrated-fixture"
      })

    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")
    %{provider: provider, root: root, project: project, session: session}
  end

  test "ordinary workspace input compacts history, gates native edit and saves one final", ctx do
    for n <- 1..121 do
      {:ok, _} =
        Sessions.create_message(%{
          session_id: ctx.session.id,
          role: "assistant",
          content: "Older synthetic #{n}: " <> String.duplicate("context ", 1_000)
        })
    end

    {:ok, view, _} = live(ctx.conn, ~p"/sessions/#{ctx.session.id}?tab=chat")
    view |> form("#prompt-form", %{"prompt" => Fixture.objective()}) |> render_submit()
    [queued] = Runs.list_runs(session_id: ctx.session.id)
    assert queued.mode == "single"
    assert queued.kind == "coding_agent"
    assert {:ok, run} = Runs.claim_next_run("integrated-worker", lease_ms: 60_000)

    {:ok, control} =
      Runs.enqueue_control(run, "integrated-steer", %{
        kind: "steer",
        payload: %{"guidance" => "Preserve name=lean-fixture."}
      })

    {:ok, _} = Runs.claim_control(control.id, run.lease_owner)
    task = execute(run)
    monitor = Process.monitor(task)

    for turn <- 0..2 do
      assert_receive {:fixture_waiting, handler, :single, ^turn, body}, 5_000
      assert_payload(body, Fixture.objective())
      assert Jason.encode!(body) =~ "Preserve name=lean-fixture."
      assert Enum.count(body["messages"], &(&1["role"] == "assistant")) < 20
      assert_receive {:execution_stream, %{status: :streaming}}, 5_000
      assert has_element?(view, "#execution-preview-0")
      send(handler, :release)
    end

    assert_receive {:tool_approval_requested, _, _}, 5_000
    assert has_element?(view, "#tool-approval-modal")
    assert File.read!(Path.join(ctx.root, "fixture.txt")) == Fixture.original()
    view |> element("#approve-tool-once-btn") |> render_click()
    assert_receive {:fixture_waiting, handler, :single, 3, body}, 5_000
    assert_payload(body, Fixture.objective())
    assert File.read!(Path.join(ctx.root, "fixture.txt")) == Fixture.updated()
    send(handler, :release)
    assert_receive {:execution_finished, {:ok, _}}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^task, :normal}, 5_000
    final = Sessions.get_run_final_message(run)
    assert final.content =~ "answer=42"
    refute has_element?(view, "#execution-preview-0")
    assert length(MockLLMServer.get_requests(ctx.provider)) == 4
    assert Enum.count(Sessions.list_messages(ctx.session.id), &(&1.id == final.id)) == 1
    assert length(:sys.get_state(view.pid).socket.assigns.message_previews) <= 50

    {:ok, reconnected, _} = live(ctx.conn, ~p"/sessions/#{ctx.session.id}?tab=chat")
    assert has_element?(reconnected, "#chat-msg-#{final.id}")
    reconnected |> element("#chat-history-older") |> render_click()
    reconnected |> element("#chat-history-latest") |> render_click()
    assert has_element?(reconnected, "#chat-msg-#{final.id}")
    assert File.read!(Path.join(ctx.root, "fixture.txt")) == Fixture.updated()
  end

  test "explicit workspace swarm retains planner and coder previews with one scoped final", ctx do
    File.write!(Path.join(ctx.root, "fixture.txt"), Fixture.updated())
    {:ok, view, _} = live(ctx.conn, ~p"/sessions/#{ctx.session.id}?tab=chat")

    view
    |> form("#prompt-form", %{"prompt" => "/swarm Report the synthetic fixture answer."})
    |> render_submit()

    [queued] = Runs.list_runs(session_id: ctx.session.id)
    assert queued.mode == "swarm"
    assert queued.kind == "coding_swarm"
    assert {:ok, run} = Runs.claim_next_run("integrated-worker", lease_ms: 60_000)
    on_exit(fn -> FleetSupervisor.stop(run.id) end)
    task = execute(run)
    monitor = Process.monitor(task)

    for role <- [:planner, :coder] do
      assert_receive {:fixture_waiting, handler, ^role, 0, body}, 5_000
      assert_payload(body, "Report the synthetic fixture answer.")

      assert_receive {:execution_stream, %{status: :streaming, identity: %{role: stream_role}}},
                     5_000

      assert stream_role == Atom.to_string(role)
      assert has_element?(view, "#execution-previews", Atom.to_string(role))
      send(handler, :release)
    end

    assert_receive {:execution_finished, {:ok, _}}, 10_000
    assert_receive {:DOWN, ^monitor, :process, ^task, :normal}, 5_000
    finals = Enum.filter(Sessions.list_messages(ctx.session.id), &(&1.role == "assistant"))
    assert [final] = finals
    assert final.metadata["stream_scope"]["execution_id"] == run.id
    assert final.content =~ "42"
    refute has_element?(view, "#execution-preview-0")
    assert length(MockLLMServer.get_requests(ctx.provider)) == 2
  end

  defp execute(run) do
    receiver = self()

    start_supervised!(
      {Task,
       fn ->
         result =
           Executor.execute(run, fn _, _ -> :ok end,
             run_lease_owner: run.lease_owner,
             run_attempt: run.attempt,
             run_lease_generation: run.lease_generation,
             run_lease_ms: 60_000
           )

         send(receiver, {:execution_finished, result})
       end}
    )
  end

  defp assert_payload(body, objective) do
    encoded = Jason.encode!(body)
    assert encoded =~ objective
    assert byte_size(encoded) <= (8_000 - 256 - 128) * 3
    assert div(byte_size(encoded) * 5 + 15, 16) + 128 + 256 <= 8_000
    assert body["max_tokens"] == 256
  end
end
