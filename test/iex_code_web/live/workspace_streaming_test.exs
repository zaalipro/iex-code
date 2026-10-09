defmodule IexCodeWeb.WorkspaceStreamingTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true

  alias IexCode.{Repo, Runs, Sessions}
  alias IexCode.Engine.ExecutionStream
  alias IexCode.Engine.AgentLoop
  alias IexCode.Engine.Agents.{PlannerAgent, CoderAgent}

  setup ctx do
    project = create_project_fixture(%{root_path: ctx.workspace_path})
    session = create_session_fixture(project, %{swarm_mode: false})
    user = create_message_fixture(session, %{role: "user", content: "Fixture objective"})
    identity = ExecutionStream.scope(session.id, :assistant, execution_id: user.id)
    {:ok, view, _} = live(ctx.conn, ~p"/sessions/#{session.id}?tab=chat")

    %{
      project: project,
      session: session,
      user: user,
      identity: Map.put(identity, :retry_epoch, 0),
      view: view
    }
  end

  test "transient escaped bounded snapshots stay outside persisted chat and reasoning", ctx do
    emit(ctx.view, ctx.identity, 1, :started, "")
    text = "<script>window.fixture = true</script> **not Markdown** λ"
    emit(ctx.view, ctx.identity, 2, :streaming, text, reasoning: "private reasoning")
    assert has_element?(ctx.view, "#execution-preview-text-0", text)
    refute has_element?(ctx.view, "#execution-previews script")
    refute has_element?(ctx.view, "#execution-previews strong")
    refute has_element?(ctx.view, "#execution-previews", "private reasoning")
    assert has_element?(ctx.view, "#execution-preview-0", "Transient")
    assert length(Sessions.list_messages(ctx.session.id)) == 1
    emit(ctx.view, ctx.identity, 3, :streaming, String.duplicate("λ", 30_000))
    assert has_element?(ctx.view, "#execution-preview-0", "Truncated")
    [preview] = assigns(ctx.view).execution_previews
    assert byte_size(preview.text) <= 16_384
    assert :binary.referenced_byte_size(preview.text) <= 16_384
    refute Map.has_key?(preview, :reasoning)
  end

  test "retry epochs and duplicate older sequences do not mix abandoned answers", ctx do
    emit(ctx.view, ctx.identity, 1, :started, "")
    emit(ctx.view, ctx.identity, 2, :streaming, "abandoned")
    next = %{ctx.identity | retry_epoch: 1}
    emit(ctx.view, next, 3, :reset, "")
    emit(ctx.view, next, 4, :streaming, "replacement")
    emit(ctx.view, next, 4, :streaming, "duplicate")
    emit(ctx.view, ctx.identity, 5, :streaming, "old epoch")
    emit(ctx.view, next, 2, :streaming, "out of order")
    assert has_element?(ctx.view, "#execution-preview-text-0", "replacement")
    refute has_element?(ctx.view, "#execution-previews", "abandoned")
    refute has_element?(ctx.view, "#execution-previews", "old epoch")
  end

  test "turn and invocation replacements fence earlier output and keep roles separate", ctx do
    emit(ctx.view, ctx.identity, 1, :started, "")
    emit(ctx.view, ctx.identity, 2, :complete, "tool turn")
    assert has_element?(ctx.view, "#execution-preview-0", "Awaiting saved result")
    next = %{ctx.identity | invocation_id: Ecto.UUID.generate(), turn: 2}
    emit(ctx.view, next, 3, :started, "")
    emit(ctx.view, next, 4, :streaming, "final turn")
    emit(ctx.view, ctx.identity, 5, :streaming, "late tool turn")
    emit(ctx.view, %{next | role: "foreign"}, 6, :streaming, "foreign role")
    emit(ctx.view, %{next | session_id: Ecto.UUID.generate()}, 7, :streaming, "foreign session")
    assert has_element?(ctx.view, "#execution-preview-text-0", "final turn")
    refute has_element?(ctx.view, "#execution-previews", "late tool turn")
    refute has_element?(ctx.view, "#execution-previews", "foreign")
    assert length(assigns(ctx.view).execution_previews) == 1
  end

  test "a fresh role invocation may restart turn numbering but earlier invocations stay retired",
       ctx do
    {:ok, op} =
      Sessions.create_operation(%{
        session_id: ctx.session.id,
        title: "role restart",
        agent_name: "SwarmCoordinator",
        op_type: "swarm",
        status: "running"
      })

    first = %{ctx.identity | execution_id: op.id, role: "coder", turn: 2}
    emit(ctx.view, first, 10, :complete, "first role result")
    next = %{first | invocation_id: Ecto.UUID.generate(), turn: 1}
    emit(ctx.view, next, 1, :started, "")
    emit(ctx.view, next, 2, :streaming, "replacement role")
    emit(ctx.view, first, 11, :streaming, "late first role")
    assert has_element?(ctx.view, "#execution-previews", "replacement role")
    refute has_element?(ctx.view, "#execution-previews", "late first role")
  end

  test "an invocation-local planner failure does not block a current replanning helper", ctx do
    {:ok, op} =
      Sessions.create_operation(%{
        session_id: ctx.session.id,
        title: "replanning",
        agent_name: "SwarmCoordinator",
        op_type: "swarm",
        status: "running"
      })

    first = %{ctx.identity | execution_id: op.id, role: "planner"}
    emit(ctx.view, first, 1, :started, "")
    emit(ctx.view, first, 2, :failed, "abandoned plan")
    next = %{first | invocation_id: Ecto.UUID.generate()}
    emit(ctx.view, next, 1, :started, "")
    emit(ctx.view, next, 2, :streaming, "new plan")
    emit(ctx.view, first, 3, :streaming, "late abandoned plan")
    assert has_element?(ctx.view, "#execution-previews", "new plan")
    refute has_element?(ctx.view, "#execution-previews", "abandoned plan")
  end

  test "the supported twenty turns across eleven swarm passes remain bounded and live", ctx do
    {:ok, op} =
      Sessions.create_operation(%{
        session_id: ctx.session.id,
        title: "long swarm",
        agent_name: "SwarmCoordinator",
        op_type: "swarm",
        status: "running"
      })

    first = %{ctx.identity | execution_id: op.id, role: "coder"}

    for n <- 1..220 do
      i = %{
        first
        | invocation_id: if(n == 1, do: first.invocation_id, else: Ecto.UUID.generate()),
          turn: rem(n - 1, 20) + 1
      }

      emit(ctx.view, i, n * 2, :started, "")
      emit(ctx.view, i, n * 2 + 1, :complete, "coder invocation #{n}")
    end

    emit(ctx.view, first, 1000, :started, "stale first coder")
    assert has_element?(ctx.view, "#execution-previews", "coder invocation 220")
    refute has_element?(ctx.view, "#execution-previews", "stale first coder")
    [stream] = assigns(ctx.view).execution_streams
    assert length(stream.retired) <= 256
    assert length(assigns(ctx.view).execution_previews) == 1
  end

  test "reconnect after session cancellation rejects unseen late interactive snapshots", ctx do
    {:ok, _} = Sessions.update_session(ctx.session, %{status: "stopped"})
    {:ok, reconnected, _} = live(ctx.conn, ~p"/sessions/#{ctx.session.id}?tab=chat")
    emit(reconnected, ctx.identity, 9, :streaming, "cancelled continuation")
    refute has_element?(reconnected, "#execution-preview-0")
  end

  test "agent generation notification closes the old role before its late delta", ctx do
    {:ok, _} =
      Runs.create_run(%{
        project_id: ctx.project.id,
        session_id: ctx.session.id,
        objective: "Fleet fixture",
        kind: "coding_swarm",
        mode: "swarm"
      })

    {:ok, run} = Runs.claim_next_run("fleet-preview", lease_ms: 60_000)

    {:ok, [agent]} =
      Runs.ensure_run_agents(run, [
        %{key: "coder", role: "coder", adapter: "coder", display_name: "Coder"}
      ])

    {:ok, agent} = Runs.claim_run_agent(agent, String.duplicate("a", 64))

    identity = %{
      ctx.identity
      | execution_id: run.id,
        role: "coder",
        attempt: run.attempt,
        generation: run.lease_generation,
        agent_id: agent.id,
        agent_generation: agent.lease_generation
    }

    emit(ctx.view, identity, 1, :started, "")
    emit(ctx.view, identity, 2, :streaming, "old agent")

    {:ok, stopped} =
      Runs.release_run_agent_lease(agent, String.duplicate("a", 64), agent.lease_generation)

    send(ctx.view.pid, {:run_agent_updated, stopped})
    emit(ctx.view, identity, 3, :streaming, "late agent")
    refute has_element?(ctx.view, "#execution-previews", "late agent")
  end

  test "terminal session notification fences only its interactive work, not another durable run",
       ctx do
    emit(ctx.view, ctx.identity, 1, :started, "")
    emit(ctx.view, ctx.identity, 2, :streaming, "interactive text")

    {:ok, _} =
      Runs.create_run(%{
        project_id: ctx.project.id,
        session_id: ctx.session.id,
        objective: "Independent",
        kind: "coding_agent",
        mode: "single"
      })

    {:ok, run} = Runs.claim_next_run("independent-worker", lease_ms: 60_000)

    i = %{
      ctx.identity
      | execution_id: run.id,
        attempt: run.attempt,
        generation: run.lease_generation
    }

    emit(ctx.view, i, 1, :started, "")
    emit(ctx.view, i, 2, :streaming, "durable text")
    {:ok, _} = Sessions.update_session(ctx.session, %{status: "stopped"})
    send(ctx.view.pid, {:session_cancelled, %{action: "stop"}})
    render(ctx.view)
    emit(ctx.view, ctx.identity, 3, :streaming, "late interactive")
    emit(ctx.view, i, 3, :streaming, "durable continues")
    refute has_element?(ctx.view, "#execution-previews", "late interactive")
    assert has_element?(ctx.view, "#execution-previews", "durable continues")
  end

  test "committed final before or after deltas replaces previews once and preserves Markdown",
       ctx do
    emit(ctx.view, ctx.identity, 1, :started, "")
    emit(ctx.view, ctx.identity, 2, :streaming, "partial")

    final =
      final(
        ctx.session,
        ctx.identity,
        "Saved answer with the unflushed tail\n```elixir\n:complete\n```"
      )

    send(ctx.view.pid, {:message_created, final})
    send(ctx.view.pid, {:message_created, final})
    emit(ctx.view, ctx.identity, 3, :settled, final.content)
    emit(ctx.view, ctx.identity, 4, :streaming, "late")
    refute has_element?(ctx.view, "#execution-preview-0")
    assert has_element?(ctx.view, "#msg-content-#{final.id} pre code", ":complete")
    assert length(ids(ctx.view)) == 2
    {:ok, reconnected, _} = live(ctx.conn, ~p"/sessions/#{ctx.session.id}?tab=chat")
    emit(reconnected, ctx.identity, 99, :streaming, "late after reconnect")
    refute has_element?(reconnected, "#execution-preview-0")
    assert Enum.count(ids(reconnected), &(&1 == final.id)) == 1
  end

  for status <- [:failed, :cancelled, :owner_down, :paused] do
    test "#{status} is partial, not success, and late snapshots cannot revive it", ctx do
      emit(ctx.view, ctx.identity, 1, :started, "")
      emit(ctx.view, ctx.identity, 2, :streaming, "unfinished")
      emit(ctx.view, ctx.identity, 3, unquote(status), "unfinished")
      assert has_element?(ctx.view, "#execution-preview-0[data-terminal='true']", "Partial")
      emit(ctx.view, ctx.identity, 4, :streaming, "resurrected")
      refute has_element?(ctx.view, "#execution-previews", "resurrected")
      final = final(ctx.session, ctx.identity, "Committed despite terminal notification order")
      send(ctx.view.pid, {:message_created, final})
      refute has_element?(ctx.view, "#execution-preview-0")
      assert has_element?(ctx.view, "#chat-msg-#{final.id}")
    end
  end

  test "HTTP complete and settled notifications alone never invent a saved answer", ctx do
    emit(ctx.view, ctx.identity, 1, :started, "")
    emit(ctx.view, ctx.identity, 2, :complete, "HTTP answer")
    assert has_element?(ctx.view, "#execution-preview-0", "Awaiting saved result")
    assert length(Sessions.list_messages(ctx.session.id)) == 1
    emit(ctx.view, ctx.identity, 3, :settled, "unconfirmed saved answer")
    assert has_element?(ctx.view, "#execution-preview-0", "Awaiting saved result")
    emit(ctx.view, ctx.identity, 4, :failed, "HTTP answer")
    assert has_element?(ctx.view, "#execution-preview-0[data-terminal='true']", "Failed")
    refute has_element?(ctx.view, "#execution-previews", "Success")
  end

  test "only eight preview bodies are retained even in the hidden fencing ledger", ctx do
    for _ <- 1..12 do
      user = create_message_fixture(ctx.session, %{role: "user", content: "another objective"})
      identity = %{ctx.identity | execution_id: user.id, invocation_id: Ecto.UUID.generate()}
      emit(ctx.view, identity, 1, :started, "")
      emit(ctx.view, identity, 2, :streaming, String.duplicate("x", 16_384))
    end

    state = assigns(ctx.view)
    assert length(state.execution_previews) == 8
    assert Enum.sum(Enum.map(state.execution_streams, &byte_size(&1.text))) <= 8 * 16_384
  end

  test "many settled executions do not suppress future previews or resurrect saved ones", ctx do
    for _ <- 1..70 do
      user = create_message_fixture(ctx.session, %{role: "user", content: "next objective"})
      identity = %{ctx.identity | execution_id: user.id, invocation_id: Ecto.UUID.generate()}
      emit(ctx.view, identity, 1, :started, "")
      emit(ctx.view, identity, 2, :streaming, "new output")
      final = final(ctx.session, identity, "saved")
      send(ctx.view.pid, {:message_created, final})
      render(ctx.view)
    end

    emit(ctx.view, ctx.identity, 1, :started, "")
    emit(ctx.view, ctx.identity, 2, :streaming, "still available")
    assert has_element?(ctx.view, "#execution-previews", "still available")
    assert length(assigns(ctx.view).execution_streams) <= 64
  end

  test "fleet role and agent generation are scoped to the current durable lease", ctx do
    {:ok, _} =
      Runs.create_run(%{
        project_id: ctx.project.id,
        session_id: ctx.session.id,
        objective: "Fleet fixture",
        kind: "coding_swarm",
        mode: "swarm"
      })

    {:ok, run} = Runs.claim_next_run("fleet-preview", lease_ms: 60_000)

    {:ok, [agent]} =
      Runs.ensure_run_agents(run, [
        %{key: "coder", role: "coder", adapter: "coder", display_name: "Coder"}
      ])

    {:ok, agent} = Runs.claim_run_agent(agent, String.duplicate("a", 64))

    identity = %{
      ctx.identity
      | execution_id: run.id,
        role: "coder",
        attempt: run.attempt,
        generation: run.lease_generation,
        agent_id: agent.id,
        agent_generation: agent.lease_generation
    }

    emit(ctx.view, identity, 1, :started, "")
    emit(ctx.view, identity, 2, :streaming, "current fleet output")
    assert has_element?(ctx.view, "#execution-previews", "current fleet output")
    emit(ctx.view, %{identity | role: "planner"}, 3, :streaming, "foreign fleet role")

    emit(
      ctx.view,
      %{identity | agent_generation: max(agent.lease_generation - 1, 0)},
      4,
      :streaming,
      "stale fleet generation"
    )

    refute has_element?(ctx.view, "#execution-previews", "foreign fleet role")
    refute has_element?(ctx.view, "#execution-previews", "stale fleet generation")
  end

  test "reconnect labels an unobserved continuation partial and session switch drops previews",
       ctx do
    emit(ctx.view, ctx.identity, 8, :streaming, "continued text")
    assert has_element?(ctx.view, "#execution-preview-0", "Partial continuation")
    {:ok, reconnected, _} = live(ctx.conn, ~p"/sessions/#{ctx.session.id}?tab=chat")
    refute has_element?(reconnected, "#execution-preview-0")
    emit(reconnected, ctx.identity, 9, :streaming, "next snapshot")
    assert has_element?(reconnected, "#execution-preview-0", "Partial continuation")
    other = create_session_fixture(ctx.project)
    render_patch(reconnected, ~p"/sessions/#{other.id}?tab=chat")
    emit(reconnected, ctx.identity, 10, :streaming, "foreign late snapshot")
    refute has_element?(reconnected, "#execution-preview-0")
    assert ids(reconnected) == []
  end

  test "paging keeps previews separate and recovers a committed final from latest", ctx do
    for n <- 1..120, do: create_message_fixture(ctx.session, %{content: "history #{n}"})
    render_click(ctx.view, "chat_history", %{"direction" => "latest"})
    render_click(ctx.view, "chat_history", %{"direction" => "older"})
    older = ids(ctx.view)
    emit(ctx.view, ctx.identity, 1, :started, "")
    emit(ctx.view, ctx.identity, 2, :streaming, "active while paging")
    assert ids(ctx.view) == older
    final = final(ctx.session, ctx.identity, "saved while paging")

    final =
      final
      |> Ecto.Changeset.change(
        inserted_at: DateTime.add(DateTime.utc_now(), 2, :second) |> DateTime.truncate(:second)
      )
      |> Repo.update!()

    send(ctx.view.pid, {:message_created, final})
    refute has_element?(ctx.view, "#execution-preview-0")
    assert ids(ctx.view) == older
    render_click(ctx.view, "chat_history", %{"direction" => "latest"})
    assert length(ids(ctx.view)) == 50
    assert final.id in ids(ctx.view)
  end

  test "durable generations and terminal state fence previews without losing committed results",
       ctx do
    {:ok, _} =
      Runs.create_run(%{
        project_id: ctx.project.id,
        session_id: ctx.session.id,
        objective: "Fixture",
        kind: "coding_agent",
        mode: "single"
      })

    {:ok, run} = Runs.claim_next_run("preview-worker", lease_ms: 60_000)

    identity =
      ExecutionStream.scope(ctx.session.id, :assistant,
        execution_id: run.id,
        run_attempt: run.attempt,
        run_lease_generation: run.lease_generation
      )
      |> Map.put(:retry_epoch, 0)

    emit(ctx.view, identity, 1, :started, "")
    emit(ctx.view, identity, 2, :streaming, "current generation")

    emit(
      ctx.view,
      %{identity | generation: identity.generation - 1},
      99,
      :streaming,
      "stale generation"
    )

    assert has_element?(ctx.view, "#execution-previews", "current generation")
    refute has_element?(ctx.view, "#execution-previews", "stale generation")

    {:ok, terminal} =
      Runs.finalize_run_worker(run, "failed", %{error_message: "final persistence failed"},
        lease_owner: run.lease_owner,
        lease_generation: run.lease_generation,
        run_attempt: run.attempt
      )

    send(ctx.view.pid, {:run_updated, terminal})
    emit(ctx.view, identity, 3, :streaming, "false success")
    refute has_element?(ctx.view, "#execution-previews", "false success")
    final = final(ctx.session, identity, "committed final")
    send(ctx.view.pid, {:message_created, final})
    refute has_element?(ctx.view, "#execution-preview-0")
    assert Runs.get_run(run.id).status == "failed"
    assert has_element?(ctx.view, "#chat-msg-#{final.id}")
  end

  test "swarm final scope replaces all role previews and bounded ledger never grows with events",
       ctx do
    {:ok, op} =
      Sessions.create_operation(%{
        session_id: ctx.session.id,
        title: "swarm",
        agent_name: "SwarmCoordinator",
        op_type: "swarm",
        status: "running"
      })

    scope =
      ExecutionStream.scope(ctx.session.id, :planner, execution_id: op.id)
      |> Map.put(:retry_epoch, 0)

    coder = %{scope | role: "coder", invocation_id: Ecto.UUID.generate()}
    emit(ctx.view, scope, 1, :started, "")
    emit(ctx.view, scope, 2, :streaming, "planner output")
    emit(ctx.view, coder, 1, :started, "")
    emit(ctx.view, coder, 2, :streaming, "coder output")
    assert length(assigns(ctx.view).execution_previews) == 2

    final =
      create_message_fixture(ctx.session, %{
        role: "assistant",
        content: "swarm final",
        metadata: %{
          "stream_scope" =>
            Jason.decode!(
              Jason.encode!(
                Map.take(scope, [:session_id, :execution_id, :attempt, :attempt_id, :generation])
              )
            )
        }
      })

    send(ctx.view.pid, {:message_created, final})
    emit(ctx.view, coder, 3, :streaming, "late role")
    refute has_element?(ctx.view, "#execution-preview-0")

    for n <- 1..150 do
      identity = %{ctx.identity | invocation_id: Ecto.UUID.generate(), turn: n}
      emit(ctx.view, identity, n * 2, :started, "")
      emit(ctx.view, identity, n * 2 + 1, :streaming, "turn #{n}")
    end

    state = assigns(ctx.view)
    assert length(state.execution_previews) <= 8
    assert length(state.execution_streams) <= 64
  end

  for path <- [:interactive, :durable, :planner, :coder] do
    test "#{path} real Req stream appears before completion and saves its unflushed tail", ctx do
      receiver = self()

      scenario = fn conn ->
        conn =
          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_chunked(200)

        for text <- ["<thi", "nk>hidden", " reasoning</think>"] ++ List.duplicate("x", 100) do
          {:ok, _} = Plug.Conn.chunk(conn, frame(text))
        end

        send(receiver, {:provider_waiting, self()})

        receive do
          :complete -> :ok
        after
          10_000 -> raise "fixture not released"
        end

        {:ok, conn} = Plug.Conn.chunk(conn, frame(" final-tail\n```elixir\n:done\n```"))
        {:ok, conn} = Plug.Conn.chunk(conn, "data: [DONE]\n\n")
        conn
      end

      MockLLMServer.set_scenario(ctx.mock_llm_pid, scenario)
      {:ok, _} = Settings.update_settings(%{max_tokens: 100, context_window_tokens: 8_000})
      subscribe_session(ctx.session.id)

      task = start_path(ctx, unquote(path), receiver)
      monitor = Process.monitor(task)
      assert_receive {:provider_waiting, provider}, 5000
      assert_receive {:execution_stream, %{status: :streaming, text: preview}}, 5000
      assert preview == String.duplicate("x", 100)
      assert has_element?(ctx.view, "#execution-previews", preview)
      refute has_element?(ctx.view, "#execution-previews", "hidden reasoning")
      assert Enum.all?(Sessions.list_messages(ctx.session.id), &(&1.role != "assistant"))
      refute_receive {:execution_stream, %{status: :streaming}}, 0
      send(provider, :complete)
      assert_receive {:DOWN, ^monitor, :process, ^task, _}, 5000

      if unquote(path) in [:interactive, :durable] do
        final = Enum.find(Sessions.list_messages(ctx.session.id), &(&1.role == "assistant"))
        assert final.content =~ " final-tail\n```elixir\n:done\n```"
        assert has_element?(ctx.view, "#msg-content-#{final.id} pre code", ":done")
        refute has_element?(ctx.view, "#execution-preview-0")
      else
        assert_receive {:fixture_result, {:ok, content}}, 5000
        assert content =~ " final-tail\n```elixir\n:done\n```"
        assert has_element?(ctx.view, "#execution-previews", "Awaiting saved result")
      end
    end
  end

  test "actual interactive provider continuation after LiveView reconnect is labeled partial",
       ctx do
    receiver = self()

    MockLLMServer.set_scenario(ctx.mock_llm_pid, fn conn ->
      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

      {:ok, conn} = Plug.Conn.chunk(conn, frame("before reconnect"))
      send(receiver, {:first_provider_gate, self()})

      receive do
        :continue -> :ok
      after
        5000 -> raise "continuation not released"
      end

      {:ok, conn} = Plug.Conn.chunk(conn, frame(" after reconnect"))
      send(receiver, {:second_provider_gate, self()})

      receive do
        :complete -> :ok
      after
        5000 -> raise "completion not released"
      end

      {:ok, conn} = Plug.Conn.chunk(conn, "data: [DONE]\n\n")
      conn
    end)

    subscribe_session(ctx.session.id)
    task = start_path(ctx, :interactive, receiver)
    monitor = Process.monitor(task)
    assert_receive {:first_provider_gate, provider}, 5000
    assert_receive {:execution_stream, %{status: :streaming}}, 5000
    {:ok, reconnected, _} = live(ctx.conn, ~p"/sessions/#{ctx.session.id}?tab=chat")
    refute has_element?(reconnected, "#execution-preview-0")
    send(provider, :continue)
    assert_receive {:second_provider_gate, ^provider}, 5000

    assert_receive {:execution_stream,
                    %{status: :streaming, text: "before reconnect after reconnect"}},
                   5000

    assert has_element?(reconnected, "#execution-previews", "Partial continuation")
    send(provider, :complete)
    assert_receive {:DOWN, ^monitor, :process, ^task, _}, 5000
    refute has_element?(reconnected, "#execution-preview-0")
  end

  defp frame(text),
    do: "data: " <> Jason.encode!(%{"choices" => [%{"delta" => %{"content" => text}}]}) <> "\n\n"

  defp start_path(ctx, :interactive, _receiver) do
    {:ok, server} = SessionServer.ensure_started(ctx.session.id)
    :ok = SessionServer.send_prompt(ctx.session.id, "Controlled fixture", allowed_tools: [])
    :sys.get_state(server).current_task
  end

  defp start_path(ctx, :durable, receiver) do
    {:ok, _} =
      Runs.create_run(%{
        project_id: ctx.project.id,
        session_id: ctx.session.id,
        objective: "Controlled fixture",
        kind: "coding_agent",
        mode: "single",
        metadata: %{"execution_policy" => %{"allowed_tools" => [], "max_tokens" => 100}}
      })

    {:ok, run} = Runs.claim_next_run("fixture-worker", lease_ms: 60_000)

    start_supervised!(
      {Task,
       fn ->
         send(
           receiver,
           {:fixture_result, AgentLoop.execute(run, ctx.workspace_path, fn _, _ -> :ok end)}
         )
       end}
    )
  end

  defp start_path(ctx, role, receiver) do
    module = if role == :planner, do: PlannerAgent, else: CoderAgent

    agent =
      start_supervised!(
        {module,
         session_id: ctx.session.id, session: ctx.session, project_root: ctx.workspace_path}
      )

    {:ok, op} =
      Sessions.create_operation(%{
        session_id: ctx.session.id,
        title: "role fixture",
        agent_name: "SwarmCoordinator",
        op_type: "swarm",
        status: "running"
      })

    call = if role == :planner, do: &PlannerAgent.plan/3, else: &CoderAgent.code/3

    start_supervised!(
      {Task,
       fn ->
         send(
           receiver,
           {:fixture_result,
            call.(agent, "Controlled fixture", allowed_tools: [], execution_id: op.id)}
         )
       end}
    )
  end

  defp emit(view, identity, sequence, status, text, opts \\ []) do
    send(
      view.pid,
      {:execution_stream,
       %{
         identity: identity,
         sequence: sequence,
         status: status,
         text: text,
         reasoning: opts[:reasoning] || "",
         truncated?: false
       }}
    )

    render(view)
  end

  defp final(session, identity, content) do
    create_message_fixture(session, %{
      role: "assistant",
      content: content,
      metadata: %{"stream_identity" => Jason.decode!(Jason.encode!(identity))}
    })
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp ids(view),
    do:
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-chat-msg-id]")
      |> LazyHTML.attribute("data-chat-msg-id")
end
