defmodule IexCode.Engine.AttemptControlTest do
  use IexCode.DataCase, async: false

  alias IexCode.Engine.{AgentLoop, AttemptControl, FleetControlToken, SessionServer}
  alias IexCode.{Projects, Runs, Sessions, Settings, WorkspaceLocks}
  alias IexCode.Runs.RunDispatcher
  alias IexCode.Test.{LeanHarnessCollector, LeanHarnessLLM, LeanHarnessProvider}

  setup do
    {:ok, project} = Projects.create_project(%{name: "Control", root_path: "/tmp"})
    {:ok, session} = Sessions.create_session(%{project_id: project.id, title: "Control"})

    {:ok, _} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Report",
        kind: "coding_agent",
        mode: "single"
      })

    {:ok, run} = Runs.claim_next_run("control-test", lease_ms: 30_000)
    %{run: run, session: session, project: project}
  end

  test "direct loop callbacks do no SQLite work as chunk counts increase", %{run: run} do
    Process.put(:agent_loop_receiver, self())
    Process.put(:agent_loop_responses, [{:ok, %{text: "Done", tool_calls: [], usage: %{}}}])

    Process.put(:agent_loop_before_chat, fn opts ->
      for count <- [4, 400] do
        {checks, metrics} =
          LeanHarnessCollector.measure(fn ->
            for _ <- 1..count, do: opts[:cancelled?].()
          end)

        assert checks == List.duplicate(false, count)
        assert metrics.run_select_count == 0
      end
    end)

    assert {:ok, _} =
             AgentLoop.execute(run, "/tmp", fn _, _ -> :ok end, llm: IexCode.AgentLoopLLMStub)
  end

  test "blocked refresh cannot extend authority or prevent silent owner cleanup", %{run: run} do
    receiver = self()

    reader = fn id ->
      send(receiver, {:read, self()})

      receive do
        :read -> Runs.get_run!(id)
      end
    end

    {owner, owner_ref} =
      guarded_owner(run,
        run_reader: reader,
        control_refresh_ms: 10,
        control_refresh_timeout_ms: 50,
        control_cancel_grace_ms: 40
      )

    assert_receive {:read, initial}, 1_000
    send(initial, :read)
    assert_receive {:guarded, guard, token}, 1_000
    guard_ref = Process.monitor(guard)
    assert_receive {:read, blocked}, 1_000
    blocked_ref = Process.monitor(blocked)
    assert_receive {:attempt_control_invalid, _, :run_control_unavailable}, 1_000
    assert FleetControlToken.cancelled?(token)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 1_000
    assert_receive {:DOWN, ^blocked_ref, :process, ^blocked, _}, 1_000
    assert_receive {:DOWN, ^guard_ref, :process, ^guard, _}, 1_000
  end

  test "expiry is local even when refresh is stalled", %{run: run} do
    run =
      run
      |> Ecto.Changeset.change(
        lease_expires_at:
          DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(2, :second)
      )
      |> Repo.update!()

    receiver = self()

    reader = fn id ->
      send(receiver, {:read, self()})

      receive do
        :read -> Runs.get_run!(id)
      end
    end

    {owner, owner_ref} =
      guarded_owner(run,
        run_reader: reader,
        control_refresh_ms: 10,
        control_refresh_timeout_ms: 5_000,
        control_cancel_grace_ms: 40
      )

    assert_receive {:read, initial}, 1_000
    send(initial, :read)
    assert_receive {:guarded, guard, token}, 1_000
    assert_receive {:read, blocked}, 1_000
    assert_receive {:attempt_control_invalid, _, :run_lease_expired}, 3_000
    assert FleetControlToken.cancelled?(token)
    send(blocked, :read)
    _ = :sys.get_state(guard)
    assert FleetControlToken.cancelled?(token)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 1_000
  end

  test "local deadline rejects checks even before a suspended guard handles expiry", %{run: run} do
    run =
      run
      |> Ecto.Changeset.change(
        lease_expires_at:
          DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(2, :second)
      )
      |> Repo.update!()

    {owner, owner_ref} =
      guarded_owner(run, control_refresh_ms: 30_000, control_cancel_grace_ms: 40)

    assert_receive {:guarded, guard, token}, 1_000
    :sys.suspend(guard)
    remaining = :atomics.get(token.expiry, 1) - System.monotonic_time(:millisecond)
    Process.send_after(self(), :deadline_elapsed, max(remaining, 0) + 10)
    assert_receive :deadline_elapsed, 3_000
    assert FleetControlToken.cancelled?(token)
    :sys.resume(guard)
    assert_receive {:attempt_control_invalid, _, :run_lease_expired}, 1_000
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 1_000
  end

  test "owner death cleans guard and blocked refresh", %{run: run} do
    {owner, owner_ref} = guarded_owner(run, control_refresh_ms: 30_000)
    assert_receive {:guarded, guard, token}, 1_000
    guard_ref = Process.monitor(guard)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 1_000
    assert_receive {:DOWN, ^guard_ref, :process, ^guard, _}, 1_000
    assert FleetControlToken.cancelled?(token)
  end

  test "unexpected guard shutdown stops even a trapping owner", %{run: run} do
    {owner, owner_ref} = guarded_owner(run, control_refresh_ms: 30_000)
    assert_receive {:guarded, guard, token}, 1_000
    guard_ref = Process.monitor(guard)
    DynamicSupervisor.terminate_child(IexCode.Engine.AttemptControlSupervisor, guard)
    assert_receive {:DOWN, ^guard_ref, :process, ^guard, _}, 1_000
    assert FleetControlToken.cancelled?(token)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 1_000
  end

  test "untrappable guard loss stops a trapping owner without waiting for chunks", %{run: run} do
    receiver = self()

    reader = fn id ->
      send(receiver, {:read, self()})

      receive do
        :read -> Runs.get_run!(id)
      end
    end

    {owner, owner_ref} = guarded_owner(run, run_reader: reader, control_refresh_ms: 10)
    assert_receive {:read, initial}, 1_000
    send(initial, :read)
    assert_receive {:guarded, guard, token}, 1_000
    guard_ref = Process.monitor(guard)
    watchdog = :sys.get_state(guard).watchdog
    watchdog_ref = Process.monitor(watchdog)
    assert_receive {:read, blocked}, 1_000
    blocked_ref = Process.monitor(blocked)
    Process.exit(guard, :kill)
    assert_receive {:DOWN, ^guard_ref, :process, ^guard, :killed}, 1_000
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 1_000
    assert_receive {:DOWN, ^watchdog_ref, :process, ^watchdog, _}, 1_000
    assert_receive {:DOWN, ^blocked_ref, :process, ^blocked, _}, 1_000
    assert FleetControlToken.cancelled?(token)
  end

  test "late successful refresh cannot restore cancelled authority", %{run: run} do
    receiver = self()

    reader = fn id ->
      send(receiver, {:read, self()})

      receive do
        :read -> Runs.get_run!(id)
      end
    end

    {owner, owner_ref} =
      guarded_owner(run, run_reader: reader, control_refresh_ms: 10, control_cancel_grace_ms: 500)

    assert_receive {:read, initial}, 1_000
    send(initial, :read)
    assert_receive {:guarded, guard, token}, 1_000
    assert_receive {:read, _blocked}, 1_000
    ref = :sys.get_state(guard).refresh.ref
    assert {:ok, _} = Runs.request_cancellation(run)
    assert_receive {:attempt_control_invalid, _, :cancelled}, 1_000
    deadline = :atomics.get(token.expiry, 1)
    send(guard, {ref, {:ok, run, System.monotonic_time(:millisecond), DateTime.utc_now()}})
    _ = :sys.get_state(guard)
    assert :atomics.get(token.expiry, 1) == deadline
    assert FleetControlToken.cancelled?(token)
    send(owner, :finish)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}, 1_000
  end

  test "provider retries are durably fenced even while local authority is fresh", %{run: run} do
    server =
      start_supervised!(
        {Bandit,
         plug: {IexCode.Test.LeanHarnessProvider, receiver: self(), status: 503},
         port: 0,
         ip: :loopback,
         startup_log: false}
      )

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)
    Process.put(:agent_loop_receiver, self())

    Process.put(:agent_loop_before_chat, fn opts ->
      result =
        IexCode.LLM.chat(
          [%{role: "user", content: "Synthetic retry"}],
          "Synthetic instructions",
          nil,
          fn _ -> :ok end,
          Keyword.merge(opts,
            resolved_route: %{
              provider: "openai",
              model: "fixture-model",
              api_key: "synthetic-local-only",
              base_url: "http://127.0.0.1:#{port}",
              max_tokens: 128
            },
            on_retry: fn _, _, _ ->
              run
              |> Ecto.Changeset.change(
                lease_expires_at:
                  DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)
              )
              |> Repo.update!()

              refute opts[:cancelled?].()
            end
          )
        )

      Process.put(:agent_loop_responses, [result])
    end)

    assert {:error, :run_lease_expired} =
             AgentLoop.execute(run, "/tmp", fn _, _ -> :ok end,
               llm: IexCode.AgentLoopLLMStub,
               control_refresh_ms: 30_000
             )

    assert_receive {:lean_request, _}
    refute_receive {:lean_request, _}
    assert Sessions.get_run_final_message(run) == nil
  end

  test "a local invalidation during the durable read still rejects the effect fence", %{run: run} do
    Process.put(:agent_loop_before_chat, fn opts ->
      token = :sys.get_state(guard_for(self())).token
      refute FleetControlToken.cancelled?(token)
      handler = make_ref()

      :telemetry.attach(
        handler,
        [:iex_code, :repo, :query],
        fn _, _, metadata, _ ->
          if metadata.query =~ ~s(FROM "runs") do
            FleetControlToken.cancel(token)
          end
        end,
        nil
      )

      try do
        result = opts[:before_request].()
        assert {:error, :cancelled} = result
        Process.put(:agent_loop_responses, [result])
      after
        :telemetry.detach(handler)
      end
    end)

    assert {:error, :cancelled} =
             AgentLoop.execute(run, "/tmp", fn _, _ -> :ok end, llm: IexCode.AgentLoopLLMStub)
  end

  test "unchanged durable expiry cannot gain authority after a backward wall-clock shift",
       %{run: run} do
    receiver = self()

    reader = fn id ->
      send(receiver, {:read, self()})

      receive do
        :read -> Runs.get_run!(id)
      end
    end

    {owner, owner_ref} =
      guarded_owner(run, run_reader: reader, control_refresh_ms: 10)

    assert_receive {:read, initial}, 1_000
    send(initial, :read)
    assert_receive {:guarded, guard, token}, 1_000
    original = :atomics.get(token.expiry, 1)
    assert_receive {:read, blocked}, 1_000
    ref = :sys.get_state(guard).refresh.ref

    send(
      guard,
      {ref,
       {:ok, run, System.monotonic_time(:millisecond),
        DateTime.utc_now() |> DateTime.add(-10, :second)}}
    )

    _ = :sys.get_state(guard)
    assert :atomics.get(token.expiry, 1) <= original
    blocked_ref = Process.monitor(blocked)
    send(blocked, :read)
    assert_receive {:DOWN, ^blocked_ref, :process, ^blocked, :normal}, 1_000
    send(owner, :finish)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}, 1_000
  end

  test "a confirmed durable renewal advances the local deadline", %{run: run} do
    receiver = self()

    reader = fn id ->
      send(receiver, {:read, self()})

      receive do
        :read -> Runs.get_run!(id)
      end
    end

    {owner, owner_ref} = guarded_owner(run, run_reader: reader, control_refresh_ms: 10)
    assert_receive {:read, initial}, 1_000
    send(initial, :read)
    assert_receive {:guarded, guard, token}, 1_000
    original = :atomics.get(token.expiry, 1)
    assert_receive {:read, refresh}, 1_000
    refresh_ref = Process.monitor(refresh)

    run
    |> Ecto.Changeset.change(lease_expires_at: DateTime.add(run.lease_expires_at, 10, :second))
    |> Repo.update!()

    send(refresh, :read)
    assert_receive {:DOWN, ^refresh_ref, :process, ^refresh, :normal}, 1_000
    _ = :sys.get_state(guard)
    renewed = :atomics.get(token.expiry, 1)
    assert renewed > original
    assert renewed <= original + 10_000
    refute FleetControlToken.cancelled?(token)
    watchdog = :sys.get_state(guard).watchdog
    watchdog_ref = Process.monitor(watchdog)
    guard_ref = Process.monitor(guard)
    send(owner, :finish)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}, 1_000
    assert_receive {:DOWN, ^guard_ref, :process, ^guard, :normal}, 1_000
    assert_receive {:DOWN, ^watchdog_ref, :process, ^watchdog, :normal}, 1_000
    assert FleetControlToken.cancelled?(token)
  end

  test "storage exceptions in a provider fence are not provider outages", %{run: _run} do
    fixture = provider(chunks: 1)

    opts = [
      resolved_route: %{
        provider: "openai",
        model: "fixture-model",
        api_key: "synthetic-local-only",
        base_url: fixture.url,
        max_tokens: 128
      },
      before_request: fn -> raise DBConnection.ConnectionError, "Synthetic storage failure" end
    ]

    for _ <- 1..3 do
      assert {:error, :run_control_unavailable} =
               IexCode.LLM.chat(
                 [%{role: "user", content: "Synthetic"}],
                 "Synthetic",
                 nil,
                 fn _ -> :ok end,
                 opts
               )
    end

    refute_receive {:lean_request, _}

    callback = fn _ -> send(Agent.get(fixture.sync, & &1), :ack) end

    assert {:ok, %{text: "fixture "}} =
             IexCode.LLM.chat(
               [%{role: "user", content: "Synthetic"}],
               "Synthetic",
               nil,
               callback,
               Keyword.delete(opts, :before_request)
             )

    assert_receive {:lean_request, _}
  end

  test "cancelled token cannot be renewed and replacement uses a distinct identity", %{run: run} do
    {owner, owner_ref} = guarded_owner(run, control_refresh_ms: 30_000)
    assert_receive {:guarded, guard, token}, 1_000
    assert {:ok, _} = Runs.request_cancellation(run)
    assert_receive {:attempt_control_invalid, _, :cancelled}, 1_000
    assert FleetControlToken.cancelled?(token)
    send(owner, :finish)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}, 1_000

    assert {:ok, cancelled} =
             Runs.finalize_run_worker(run, "cancelled", %{}, Map.to_list(authority(run)))

    assert {:ok, _} = Runs.retry_run(cancelled)
    assert {:ok, replacement} = Runs.claim_next_run("replacement", lease_ms: 30_000)
    {next, next_ref} = guarded_owner(replacement, control_refresh_ms: 30_000)
    assert_receive {:guarded, next_guard, next_token}, 1_000
    refute guard == next_guard
    refute token.identity == next_token.identity
    FleetControlToken.resume(token)
    assert FleetControlToken.cancelled?(token)
    refute FleetControlToken.cancelled?(next_token)
    send(next_guard, {:run_updated, run})
    _ = :sys.get_state(next_guard)
    refute FleetControlToken.cancelled?(next_token)
    send(next, :finish)
    assert_receive {:DOWN, ^next_ref, :process, ^next, :normal}, 1_000
  end

  test "failed refresh invalidates silent work after confirmed authority", %{run: run} do
    receiver = self()

    reader = fn id ->
      send(receiver, {:read, self()})

      receive do
        :read -> Runs.get_run!(id)
        :fail -> raise DBConnection.ConnectionError, "Synthetic read failure"
      end
    end

    {owner, owner_ref} =
      guarded_owner(run,
        run_reader: reader,
        control_refresh_ms: 10,
        control_cancel_grace_ms: 40
      )

    assert_receive {:read, initial}, 1_000
    send(initial, :read)
    assert_receive {:guarded, guard, token}, 1_000
    guard_ref = Process.monitor(guard)
    assert_receive {:read, refresh}, 1_000
    send(refresh, :fail)
    assert_receive {:attempt_control_invalid, _, :run_control_unavailable}, 1_000
    assert FleetControlToken.cancelled?(token)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 1_000
    assert_receive {:DOWN, ^guard_ref, :process, ^guard, _}, 1_000
  end

  test "owner death terminates an outstanding refresh", %{run: run} do
    receiver = self()

    reader = fn id ->
      send(receiver, {:read, self()})

      receive do
        :read -> Runs.get_run!(id)
      end
    end

    {owner, owner_ref} = guarded_owner(run, run_reader: reader, control_refresh_ms: 10)
    assert_receive {:read, initial}, 1_000
    send(initial, :read)
    assert_receive {:guarded, guard, _}, 1_000
    guard_ref = Process.monitor(guard)
    assert_receive {:read, blocked}, 1_000
    blocked_ref = Process.monitor(blocked)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 1_000
    assert_receive {:DOWN, ^blocked_ref, :process, ^blocked, _}, 1_000
    assert_receive {:DOWN, ^guard_ref, :process, ^guard, _}, 1_000
  end

  test "silent Req transport is stopped without releasing another data chunk", %{run: run} do
    fixture = provider(chunks: 1, silent: true)
    receiver = self()
    supervisor = start_supervised!({Task.Supervisor, []})

    {:ok, owner} =
      Task.Supervisor.start_child(supervisor, fn ->
        Process.put(:lean_fixture, Map.put(fixture, :receiver, receiver))

        AgentLoop.execute(run, "/tmp", fn _, _ -> :ok end,
          llm: LeanHarnessLLM,
          control_cancel_grace_ms: 40
        )
      end)

    owner_ref = Process.monitor(owner)
    assert_receive {:lean_silent_ready, server}, 1_000
    guard = guard_for(owner)
    guard_ref = Process.monitor(guard)
    assert {:ok, _} = Runs.request_cancellation(run)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 1_000
    assert_receive {:DOWN, ^guard_ref, :process, ^guard, _}, 1_000
    assert Sessions.get_run_final_message(run) == nil
    send(server, :halt)
    send(server, :release)
  end

  test "late approval cannot execute after storage revocation in the refresh window",
       %{run: run, session: session} do
    approval_settings()
    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")
    {task, owner_ref} = approving_owner(run, control_refresh_ms: 30_000)
    assert_receive {:tool_approval_requested, _, request}, 1_000
    guard = guard_for(task.pid)
    assert {:ok, token} = GenServer.call(guard, :token)
    refute FleetControlToken.cancelled?(token)
    expire_run(run)
    refute FleetControlToken.cancelled?(token)
    SessionServer.decide_tool_approval(session.id, request.id, :approve_once)
    assert {:error, :run_lease_expired} = Task.await(task, 1_000)
    assert_receive {:DOWN, ^owner_ref, :process, _, :normal}, 1_000
    refute_receive {:agent_loop_tool_call, _, _, _}
    assert Sessions.get_run_final_message(run) == nil
  end

  test "approval silence expires and cancellation rejects a late approval",
       %{run: run, session: session} do
    approval_settings()
    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")
    {task, owner_ref} = approving_owner(run, control_cancel_grace_ms: 40)
    assert_receive {:tool_approval_requested, _, request}, 1_000
    guard = guard_for(task.pid)
    guard_ref = Process.monitor(guard)
    assert {:ok, token} = GenServer.call(guard, :token)
    assert {:ok, _} = Runs.request_cancellation(run)
    assert_receive {:DOWN, ^owner_ref, :process, _, :killed}, 1_000
    assert_receive {:DOWN, ^guard_ref, :process, ^guard, _}, 1_000
    assert FleetControlToken.cancelled?(token)
    SessionServer.decide_tool_approval(session.id, request.id, :approve_once)
    refute_receive {:agent_loop_tool_call, _, _, _}
    assert Sessions.get_run_final_message(run) == nil
  end

  test "approval wait cannot outlive its confirmed lease", %{run: run, session: session} do
    approval_settings()

    run =
      run
      |> Ecto.Changeset.change(
        lease_expires_at:
          DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(2, :second)
      )
      |> Repo.update!()

    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")

    {task, owner_ref} =
      approving_owner(run, control_refresh_ms: 30_000, control_cancel_grace_ms: 40)

    assert_receive {:tool_approval_requested, _, _}, 1_000
    guard = guard_for(task.pid)
    assert {:ok, token} = GenServer.call(guard, :token)
    assert_receive {:DOWN, ^owner_ref, :process, _, :killed}, 3_000
    assert FleetControlToken.cancelled?(token)
    refute_receive {:agent_loop_tool_call, _, _, _}
    assert Sessions.get_run_final_message(run) == nil
  end

  test "dispatcher holds the reservation until guarded single work exits",
       %{run: run, project: project, session: session} do
    # The setup claim is unrelated to this dispatch, so settle only that fixture.
    assert {:ok, _} =
             Runs.finalize_run_worker(run, "interrupted", %{}, Map.to_list(authority(run)))

    Process.register(self(), IexCode.AttemptControlTestReceiver)

    dispatcher =
      start_supervised!(
        {RunDispatcher,
         name: nil,
         worker_id: "guarded-dispatch",
         executor: IexCode.AttemptControlExecutorStub,
         poll_interval: 30_000,
         heartbeat_interval: 30_000,
         lease_ms: 30_000,
         cancel_grace_ms: 5_000}
      )

    Runs.subscribe_session(session.id)
    Runs.subscribe_workspace_locks(project.id)

    assert {:ok, queued} =
             RunDispatcher.enqueue(
               %{
                 project_id: project.id,
                 session_id: session.id,
                 objective: "Silent guarded execution",
                 kind: "coding_agent",
                 mode: "single"
               },
               dispatcher
             )

    assert_receive {:guarded_effect_ready, owner}, 1_000
    owner_ref = Process.monitor(owner)
    guard = guard_for(owner)
    assert {:ok, _} = RunDispatcher.cancel(queued.id, dispatcher)
    _ = :sys.get_state(guard)

    assert {:error, {:workspace_lock_waiting, _}} =
             WorkspaceLocks.acquire(project, [:project],
               owner_id: "conflict",
               project_id: project.id
             )

    assert [%{status: "held"}] = Runs.list_workspace_locks(run_id: queued.id, active: true)
    assert :none = Runs.claim_next_run("replacement-owner")
    # A custom dispatcher grace must not be shortened to the guard's 1500ms default.
    Process.send_after(owner, :effect_probe, 2_500)
    assert_receive {:effect_probe, ^owner}, 3_000
    refute_receive {:DOWN, ^owner_ref, :process, ^owner, _}, 0
    assert [%{status: "held"}] = Runs.list_workspace_locks(run_id: queued.id, active: true)
    send(owner, :finish_effect)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}, 1_000
    assert_receive {:workspace_locks_updated, locks}, 1_000
    await_released(queued.id, locks)
    assert Runs.get_run!(queued.id).status == "cancelled"
    assert Sessions.get_run_final_message(queued) == nil

    assert {:ok, handle} =
             WorkspaceLocks.acquire(project, [:project],
               owner_id: "after",
               project_id: project.id
             )

    WorkspaceLocks.release(handle)
  end

  for chunks <- [4, 400] do
    test "authority queries follow cadence across #{chunks} real SSE chunks", %{run: run} do
      chunks = unquote(chunks)
      fixture = provider(chunks: chunks, batches: 4)
      receiver = self()
      supervisor = start_supervised!({Task.Supervisor, []})

      reader = fn id ->
        result = Runs.get_run!(id)
        send(receiver, :authority_read)
        result
      end

      task =
        Task.Supervisor.async_nolink(supervisor, fn ->
          Process.put(:lean_fixture, Map.put(fixture, :receiver, receiver))

          LeanHarnessCollector.measure(fn ->
            AgentLoop.execute(run, "/tmp", fn _, _ -> :ok end,
              llm: LeanHarnessLLM,
              run_reader: reader,
              control_refresh_ms: 100
            )
          end)
        end)

      for _ <- 1..4 do
        assert_receive :authority_read, 1_000
        assert_receive {:lean_batch_ready, server}, 1_000
        send(server, :next)
      end

      assert {{:ok, _}, metrics} = Task.await(task, 2_000)
      assert_receive {:lean_callbacks, callbacks}, 1_000
      assert callbacks.text_callback_count == chunks
      assert callbacks.cancellation_check_count == chunks + 1
      # Four scheduled reads plus finite effect/settlement fences, not 400 reads.
      assert metrics.run_select_count < 40

      LeanHarnessCollector.emit(
        "authority_cadence",
        %{sse_text_events: chunks, batches: 4, control_refresh_ms: 100},
        Map.merge(metrics, callbacks)
      )
    end
  end

  defp await_released(id, locks) do
    unless Enum.any?(locks, &(&1.run_id == id and &1.status == "released")) do
      assert_receive {:workspace_locks_updated, next}, 1_000
      await_released(id, next)
    end
  end

  defp approval_settings do
    assert {:ok, _} =
             Settings.update_settings(%{
               tool_approval_mode: "prompt_dangerous",
               tool_category_overrides: %{"read_only" => "prompt"}
             })
  end

  defp approving_owner(run, opts) do
    receiver = self()
    supervisor = start_supervised!({Task.Supervisor, []})

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Process.put(:agent_loop_receiver, receiver)

        Process.put(:agent_loop_responses, [
          {:ok,
           %{
             text: "Inspect",
             tool_calls: [%{id: "read", name: "read_file", args: %{"path" => "x"}}],
             usage: %{}
           }}
        ])

        AgentLoop.execute(
          run,
          "/tmp",
          fn _, _ -> :ok end,
          Keyword.merge(opts,
            llm: IexCode.AgentLoopLLMStub,
            tool_executor: IexCode.AgentLoopToolStub
          )
        )
      end)

    {task, Process.monitor(task.pid)}
  end

  defp expire_run(run) do
    run
    |> Ecto.Changeset.change(
      lease_expires_at:
        DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)
    )
    |> Repo.update!()
  end

  defp guard_for(owner) do
    IexCode.Engine.AttemptControlSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.find_value(fn {_, pid, _, _} ->
      if :sys.get_state(pid).owner == owner, do: pid
    end)
  end

  defp provider(opts) do
    sync = start_supervised!({Agent, fn -> nil end})

    server =
      start_supervised!(
        {Bandit,
         plug: {LeanHarnessProvider, opts ++ [receiver: self(), sync: sync]},
         port: 0,
         ip: :loopback,
         startup_log: false}
      )

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)
    %{url: "http://127.0.0.1:#{port}", sync: sync}
  end

  defp guarded_owner(run, opts) do
    receiver = self()
    supervisor = start_supervised!({Task.Supervisor, []}, id: make_ref())

    {:ok, owner} =
      Task.Supervisor.start_child(supervisor, fn ->
        Process.flag(:trap_exit, true)

        AttemptControl.with_control(run, authority(run), opts, fn guard, token ->
          send(receiver, {:guarded, guard, token})

          receive do
            {:attempt_control_invalid, identity, reason} ->
              send(receiver, {:attempt_control_invalid, identity, reason})

              receive do
                :finish -> :ok
              end

            :finish ->
              :ok
          end
        end)
      end)

    {owner, Process.monitor(owner)}
  end

  defp authority(run),
    do: %{
      lease_owner: run.lease_owner,
      run_attempt: run.attempt,
      lease_generation: run.lease_generation
    }
end
