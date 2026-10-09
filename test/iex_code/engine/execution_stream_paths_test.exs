defmodule IexCode.Engine.ExecutionStreamPathsTest do
  use IexCode.DataCase, async: false

  alias IexCode.{Projects, Runs, Sessions, Settings}
  alias IexCode.Engine.{AgentLoop, SessionServer}
  alias IexCode.Engine.Agents.{CoderAgent, PlannerAgent}
  alias IexCode.E2E.MockLLMServer

  setup do
    provider = start_supervised!({MockLLMServer, scenario: :sse_chunks})
    root = Path.join(System.tmp_dir!(), "stream-paths-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    url = GenServer.call(provider, :get_info).url

    {:ok, _} =
      Settings.update_settings(%{
        openai_api_key: "fixture",
        openai_base_url: url <> "/v1",
        max_tokens: 100,
        context_window_tokens: 8_000
      })

    {:ok, project} = Projects.create_project(%{name: "Stream", root_path: root})

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Stream",
        swarm_mode: false,
        model_provider: "openai",
        model_name: "fixture"
      })

    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")
    %{provider: provider, project: project, session: session, root: root}
  end

  for role <- [:planner, :coder] do
    test "#{role} forwards actual Req chunks with explicit execution identity", ctx do
      module = if unquote(role) == :planner, do: PlannerAgent, else: CoderAgent

      agent =
        start_supervised!(
          {module, session_id: ctx.session.id, session: ctx.session, project_root: ctx.root}
        )

      call = if unquote(role) == :planner, do: &PlannerAgent.plan/3, else: &CoderAgent.code/3

      assert {:ok, text} =
               call.(agent, "Check fixture",
                 allowed_tools: [],
                 execution_id: "swarm-operation",
                 run_attempt: 2,
                 run_lease_generation: 3
               )

      assert text == "Analyzing codebase...\nTask completed!"
      assert_receive {:execution_stream, %{status: :started, identity: identity}}, 1000
      assert identity.execution_id == "swarm-operation"
      assert identity.attempt == 2
      assert identity.generation == 3
      assert identity.role == Atom.to_string(unquote(role))

      assert_receive {:execution_stream, %{status: :complete, text: ^text, identity: ^identity}},
                     1000

      assert Sessions.list_messages(ctx.session.id) == []
    end
  end

  test "durable final carries exact invocation identity and replay creates no new stream", ctx do
    {:ok, _} =
      Runs.create_run(%{
        project_id: ctx.project.id,
        session_id: ctx.session.id,
        objective: "Check fixture",
        kind: "coding_agent",
        mode: "single",
        metadata: %{"execution_policy" => %{"allowed_tools" => [], "max_tokens" => 100}}
      })

    {:ok, run} = Runs.claim_next_run("stream-worker", lease_ms: 60_000)
    assert {:ok, result} = AgentLoop.execute(run, ctx.root, fn _, _ -> :ok end)
    assert_receive {:execution_stream, %{status: :started, identity: identity}}, 1000
    assert_receive {:execution_stream, %{status: :settled, text: text, identity: ^identity}}, 1000
    assert result.content == text
    final = Sessions.get_run_final_message(run)
    assert final.metadata["stream_identity"] == Jason.decode!(Jason.encode!(identity))
    assert identity.execution_id == run.id
    assert identity.attempt == run.attempt
    assert identity.generation == run.lease_generation
    assert {:ok, %{replayed?: true}} = AgentLoop.execute(run, ctx.root, fn _, _ -> :ok end)
    refute_receive {:execution_stream, %{status: :started}}, 0
    assert length(MockLLMServer.get_requests(ctx.provider)) == 1
    assert length(Sessions.list_messages(ctx.session.id)) == 2
  end

  test "interactive final reconciles the stream and preserves answer content", ctx do
    server = start_supervised!({SessionServer, ctx.session.id})
    assert :ok = SessionServer.send_prompt(ctx.session.id, "Check fixture", allowed_tools: [])
    task = :sys.get_state(server).current_task
    monitor = Process.monitor(task)
    assert_receive {:execution_stream, %{status: :started, identity: identity}}, 5000
    assert_receive {:message_created, %{role: "assistant"} = message}, 5000
    assert message.metadata["stream_identity"] == Jason.decode!(Jason.encode!(identity))
    assert message.content == "Analyzing codebase...\nTask completed!"
    assert_receive {:execution_stream, %{status: :settled, text: text}}, 1000
    assert text == message.content
    assert_receive {:DOWN, ^monitor, :process, ^task, _}, 5000
    _ = :sys.get_state(server)
    assert length(Sessions.list_messages(ctx.session.id)) == 2
  end

  for path <- [:interactive, :durable, :planner, :coder] do
    test "#{path} publishes batched preview before controlled SSE completion", ctx do
      receiver = self()

      scenario = fn conn ->
        conn =
          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_chunked(200)

        for _ <- 1..100 do
          frame = Jason.encode!(%{"choices" => [%{"delta" => %{"content" => "x"}}]})
          {:ok, _} = Plug.Conn.chunk(conn, "data: " <> frame <> "\n\n")
        end

        send(receiver, {:provider_waiting, self()})

        receive do
          :complete -> :ok
        after
          10_000 -> raise "fixture completion not released"
        end

        {:ok, conn} = Plug.Conn.chunk(conn, "data: [DONE]\n\n")
        conn
      end

      MockLLMServer.set_scenario(ctx.provider, scenario)

      task =
        case unquote(path) do
          :interactive ->
            server = start_supervised!({SessionServer, ctx.session.id})
            :ok = SessionServer.send_prompt(ctx.session.id, "Fixture", allowed_tools: [])
            :sys.get_state(server).current_task

          :durable ->
            {:ok, _} =
              Runs.create_run(%{
                project_id: ctx.project.id,
                session_id: ctx.session.id,
                objective: "Fixture",
                kind: "coding_agent",
                mode: "single",
                metadata: %{"execution_policy" => %{"allowed_tools" => [], "max_tokens" => 100}}
              })

            {:ok, run} = Runs.claim_next_run("stream-worker", lease_ms: 60_000)

            start_supervised!(
              {Task, fn -> AgentLoop.execute(run, ctx.root, fn _, _ -> :ok end) end}
            )

          :planner ->
            module = PlannerAgent

            agent =
              start_supervised!(
                {module, session_id: ctx.session.id, session: ctx.session, project_root: ctx.root}
              )

            call = &PlannerAgent.plan/3
            start_supervised!({Task, fn -> call.(agent, "Fixture", allowed_tools: []) end})

          :coder ->
            module = CoderAgent

            agent =
              start_supervised!(
                {module, session_id: ctx.session.id, session: ctx.session, project_root: ctx.root}
              )

            call = &CoderAgent.code/3
            start_supervised!({Task, fn -> call.(agent, "Fixture", allowed_tools: []) end})
        end

      ref = Process.monitor(task)
      assert_receive {:provider_waiting, provider_task}, 5000
      assert_receive {:execution_stream, %{status: :streaming, text: preview}}, 5000
      assert preview == String.duplicate("x", 100)
      assert Enum.all?(Sessions.list_messages(ctx.session.id), &(&1.role != "assistant"))
      send(provider_task, :complete)
      assert_receive {:execution_stream, %{status: status, text: ^preview}}, 5000

      assert status ==
               if(unquote(path) in [:interactive, :durable], do: :settled, else: :complete)

      assert_receive {:DOWN, ^ref, :process, ^task, :normal}, 5000
    end
  end

  test "a durable final persistence failure marks preview failed, not settled", ctx do
    Ecto.Adapters.SQL.query!(
      Repo,
      """
      CREATE TEMP TRIGGER reject_stream_final BEFORE INSERT ON messages
      WHEN NEW.role = 'assistant' AND NEW.content = 'Analyzing codebase...\nTask completed!'
      BEGIN SELECT RAISE(ABORT, 'fixture final failure'); END
      """,
      []
    )

    {:ok, _} =
      Runs.create_run(%{
        project_id: ctx.project.id,
        session_id: ctx.session.id,
        objective: "Fixture",
        kind: "coding_agent",
        mode: "single",
        metadata: %{"execution_policy" => %{"allowed_tools" => [], "max_tokens" => 100}}
      })

    {:ok, run} = Runs.claim_next_run("stream-worker", lease_ms: 60_000)
    assert {:error, _} = AgentLoop.execute(run, ctx.root, fn _, _ -> :ok end)
    assert_receive {:execution_stream, %{status: :failed}}, 1000
    refute_receive {:execution_stream, %{status: :settled}}, 0
    assert Sessions.get_run_final_message(run) == nil
  end

  for path <- [:durable, :coder] do
    test "#{path} tool turns have distinct invocation identities and preserve final content",
         ctx do
      File.write!(Path.join(ctx.root, "fixture.txt"), "grounded")
      provider = ctx.provider

      scenario = fn conn ->
        turn = MockLLMServer.increment_attempt(provider, "turn")

        message =
          if turn == 1 do
            %{
              "content" => "Inspecting",
              "tool_calls" => [
                %{
                  "id" => "call_fixture",
                  "type" => "function",
                  "function" => %{
                    "name" => "read_file",
                    "arguments" => Jason.encode!(%{"path" => "fixture.txt"})
                  }
                }
              ]
            }
          else
            %{"content" => "Final answer"}
          end

        body = %{"choices" => [%{"delta" => message, "index" => 0}]}

        conn =
          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_chunked(200)

        {:ok, conn} = Plug.Conn.chunk(conn, "data: " <> Jason.encode!(body) <> "\n\n")
        {:ok, conn} = Plug.Conn.chunk(conn, "data: [DONE]\n\n")
        conn
      end

      MockLLMServer.set_scenario(ctx.provider, scenario)

      case unquote(path) do
        :durable ->
          {:ok, _} =
            Runs.create_run(%{
              project_id: ctx.project.id,
              session_id: ctx.session.id,
              objective: "Fixture",
              kind: "coding_agent",
              mode: "single",
              metadata: %{
                "execution_policy" => %{"allowed_tools" => ["read_file"], "max_tokens" => 100}
              }
            })

          {:ok, run} = Runs.claim_next_run("stream-worker", lease_ms: 60_000)
          assert {:ok, result} = AgentLoop.execute(run, ctx.root, fn _, _ -> :ok end)
          assert result.content == "Final answer"

        :coder ->
          agent =
            start_supervised!(
              {CoderAgent,
               session_id: ctx.session.id, session: ctx.session, project_root: ctx.root}
            )

          assert {:ok, "Final answer"} =
                   CoderAgent.code(agent, "Fixture", allowed_tools: ["read_file"])
      end

      assert_receive {:execution_stream,
                      %{status: :complete, text: "Inspecting", identity: first}}

      assert_receive {:execution_stream,
                      %{text: "Final answer", status: last_status, identity: last}}

      assert last_status in [:settled, :complete]
      assert first.turn == 1
      assert last.turn == 2
      refute first.invocation_id == last.invocation_id
      assert first.execution_id == last.execution_id
    end
  end

  for role <- [:planner, :coder] do
    test "#{role} partial HTTP success after cancellation cannot settle the invocation", ctx do
      receiver = self()

      scenario = fn conn ->
        conn =
          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_chunked(200)

        frame = Jason.encode!(%{"choices" => [%{"delta" => %{"content" => "partial"}}]})
        {:ok, _} = Plug.Conn.chunk(conn, "data: " <> frame <> "\n\n")
        send(receiver, {:provider_waiting, self()})

        receive do
          :complete -> :ok
        after
          5000 -> raise "fixture not released"
        end

        {:ok, conn} = Plug.Conn.chunk(conn, "data: [DONE]\n\n")
        conn
      end

      MockLLMServer.set_scenario(ctx.provider, scenario)
      module = if unquote(role) == :planner, do: PlannerAgent, else: CoderAgent
      call = if unquote(role) == :planner, do: &PlannerAgent.plan/3, else: &CoderAgent.code/3

      agent =
        start_supervised!(
          {module, session_id: ctx.session.id, session: ctx.session, project_root: ctx.root}
        )

      task =
        start_supervised!(
          {Task,
           fn ->
             send(receiver, {:role_result, call.(agent, "Fixture", allowed_tools: [])})
           end}
        )

      ref = Process.monitor(task)
      assert_receive {:provider_waiting, provider_task}, 5000
      assert_receive {:execution_stream, %{status: :streaming, text: "partial"}}, 1000
      IexCode.Engine.AgentCancellation.cancel(ctx.session.id)
      send(provider_task, :complete)
      assert_receive {:role_result, {:error, :cancelled}}, 5000
      assert_receive {:execution_stream, %{status: :cancelled}}, 1000
      refute_receive {:execution_stream, %{status: :complete}}, 0
      assert_receive {:DOWN, ^ref, :process, ^task, :normal}, 1000
    end
  end

  test "interactive stream cancellation remains latched through HTTP completion", ctx do
    receiver = self()

    scenario = fn conn ->
      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

      frame = Jason.encode!(%{"choices" => [%{"delta" => %{"content" => "partial"}}]})
      {:ok, _} = Plug.Conn.chunk(conn, "data: " <> frame <> "\n\n")
      send(receiver, {:provider_waiting, self()})

      receive do
        :complete -> :ok
      after
        5000 -> raise "fixture not released"
      end

      {:ok, conn} = Plug.Conn.chunk(conn, "data: [DONE]\n\n")
      conn
    end

    MockLLMServer.set_scenario(ctx.provider, scenario)
    server = start_supervised!({SessionServer, ctx.session.id})
    :ok = SessionServer.send_prompt(ctx.session.id, "Fixture", allowed_tools: [])
    task = :sys.get_state(server).current_task
    ref = Process.monitor(task)
    assert_receive {:provider_waiting, provider_task}, 5000
    assert_receive {:execution_stream, %{status: :streaming, text: "partial"}}, 1000

    Phoenix.PubSub.broadcast(
      IexCode.PubSub,
      "session:#{ctx.session.id}:steer",
      {:cancel, ctx.session.id, []}
    )

    # Synchronize delivery to this owner before releasing the final HTTP chunk.
    assert {:messages, messages} = Process.info(task, :messages)
    assert Enum.any?(messages, &match?({:cancel, _, _}, &1))
    send(provider_task, :complete)
    assert_receive {:execution_stream, %{status: :cancelled}}, 5000
    assert_receive {:DOWN, ^ref, :process, ^task, _}, 5000
    refute Enum.any?(Sessions.list_messages(ctx.session.id), &(&1.role == "assistant"))
    assert Sessions.get_session(ctx.session.id).status == "stopped"
  end

  test "interactive persistence exception marks failed and never settles", ctx do
    Ecto.Adapters.SQL.query!(
      Repo,
      """
      CREATE TEMP TRIGGER reject_stream_final BEFORE INSERT ON messages
      WHEN NEW.role = 'assistant' AND NEW.content = 'Analyzing codebase...\nTask completed!'
      BEGIN SELECT RAISE(ABORT, 'fixture final failure'); END
      """,
      []
    )

    server = start_supervised!({SessionServer, ctx.session.id})

    ExUnit.CaptureLog.capture_log(fn ->
      :ok = SessionServer.send_prompt(ctx.session.id, "Fixture", allowed_tools: [])
      task = :sys.get_state(server).current_task
      ref = Process.monitor(task)
      assert_receive {:execution_stream, %{status: :failed}}, 5000
      assert_receive {:DOWN, ^ref, :process, ^task, _}, 5000
      assert_receive {:session_status_changed, "failed"}, 5000
      assert_receive {:session_status_changed, "failed"}, 5000
    end)

    refute_receive {:execution_stream, %{status: :settled}}, 0
    assert Sessions.get_session(ctx.session.id).status == "failed"

    assert Enum.all?(
             Sessions.list_messages(ctx.session.id),
             &(&1.role != "assistant" or String.starts_with?(&1.content, "❌ **Run Failed**"))
           )
  end

  test "swarm synthesized final scopes both planner and coder previews", ctx do
    assert {:ok, final} =
             IexCode.Engine.SwarmCoordinator.run(ctx.session.id, "Fixture",
               project_root: ctx.root,
               allowed_tools: [],
               max_retries: 0
             )

    assert_receive {:execution_stream, %{identity: %{role: "planner"} = planner}}, 1000
    assert_receive {:execution_stream, %{identity: %{role: "coder"} = coder}}, 1000
    final_id = final.id
    assert_receive {:message_created, %{id: ^final_id} = notification}, 1000
    assert notification.metadata["stream_scope"]["execution_id"] == planner.execution_id
    final = Sessions.get_message(ctx.session.id, final.id)
    scope = final.metadata["stream_scope"]
    assert scope["execution_id"] == planner.execution_id
    assert scope["execution_id"] == coder.execution_id
    assert scope["attempt"] == planner.attempt
    assert scope["generation"] == planner.generation
    assert scope["session_id"] == ctx.session.id

    assert length(Enum.filter(Sessions.list_messages(ctx.session.id), &(&1.role == "assistant"))) ==
             1
  end

  test "swarm final insert failure cannot report a successful synthetic final", ctx do
    Ecto.Adapters.SQL.query!(
      Repo,
      """
      CREATE TEMP TRIGGER remove_final_parent BEFORE INSERT ON messages
      WHEN NEW.role = 'assistant'
      BEGIN DELETE FROM sessions WHERE id = NEW.session_id; END
      """,
      []
    )

    ExUnit.CaptureLog.capture_log(fn ->
      assert_raise Ecto.ConstraintError, fn ->
        IexCode.Engine.SwarmCoordinator.run(ctx.session.id, "Fixture",
          project_root: ctx.root,
          allowed_tools: [],
          max_retries: 0
        )
      end
    end)

    refute_receive {:session_status_changed, "idle"}, 0
    assert_receive {:session_status_changed, "failed"}
  end
end
