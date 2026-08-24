defmodule IexCode.Engine.DurableFleetTest do
  use IexCode.DataCase, async: false

  alias IexCode.{Projects, Runs, Sessions}
  alias IexCode.Runs.Executor

  alias IexCode.Engine.{
    AgentRegistry,
    AgentSupervisor,
    FleetManager,
    FleetRuntime,
    FleetControlToken,
    FleetSupervisor,
    FleetTopology,
    OperationManager,
    RunFleetSupervisor
  }

  setup do
    root = Path.join(System.tmp_dir!(), "iex-fleet-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    {:ok, project} =
      Projects.create_project(%{
        name: "fleet-#{System.unique_integer([:positive])}",
        root_path: root
      })

    {:ok, session} = Sessions.create_session(%{project_id: project.id, title: "Fleet runtime"})

    on_exit(fn -> File.rm_rf(root) end)
    %{project: project, session: session, root: root}
  end

  test "legacy topology is deterministic and bounded" do
    for requested <- 1..4 do
      specs = FleetTopology.manifest(requested)
      assert Enum.map(specs, & &1.role) == ["planner", "explorer", "coder", "verifier"]
      assert Enum.map(specs, & &1.position) == [0, 1, 2, 3]
    end

    assert length(FleetTopology.manifest(32)) == 32
    assert length(FleetTopology.manifest(33)) == 32
    assert Enum.count(FleetTopology.manifest(32), &(&1.role == "explorer")) == 29
  end

  test "two runs in one session have isolated registry identities and stopping one is scoped",
       ctx do
    run_a = running_run(ctx, "A")
    run_b = running_run(ctx, "B")

    on_exit(fn ->
      FleetSupervisor.stop(run_a.id)
      FleetSupervisor.stop(run_b.id)
    end)

    assert {:ok, agents_a} = FleetSupervisor.attach(run_a, agent_count: 4, project_root: ctx.root)
    assert {:ok, agents_b} = FleetSupervisor.attach(run_b, agent_count: 4, project_root: ctx.root)

    assert MapSet.disjoint?(
             MapSet.new(Enum.map(agents_a, & &1.pid)),
             MapSet.new(Enum.map(agents_b, & &1.pid))
           )

    assert length(AgentRegistry.list_run_agents(run_a.id)) == 4
    assert length(AgentRegistry.list_run_agents(run_b.id)) == 4

    b_pids = Enum.map(agents_b, & &1.pid)
    assert :ok = FleetManager.stop(run_a.id, "cancelled")
    assert Enum.all?(b_pids, &Process.alive?/1)
    assert length(AgentRegistry.list_run_agents(run_b.id)) == 4
  end

  test "targeted controls are durable, ordered, fenced, and isolated", ctx do
    run = running_run(ctx, "controls")
    on_exit(fn -> FleetSupervisor.stop(run.id) end)
    assert {:ok, agents} = FleetSupervisor.attach(run, agent_count: 4, project_root: ctx.root)
    planner = Enum.find(agents, &(&1.role == :planner))
    explorer = Enum.find(agents, &(&1.role == :explorer))
    explorer_pid = explorer.pid

    assert {:ok, :paused} =
             RunFleetSupervisor.control_agent(run, planner.agent_id, :pause, %{
               idempotency_key: "pause-1"
             })

    assert Runs.get_run_agent(planner.agent_id).status == "paused"
    assert Process.alive?(explorer_pid)

    assert {:ok, :steered} =
             RunFleetSupervisor.control_agent(run, planner.agent_id, :steer, %{
               idempotency_key: "steer-1",
               guidance: "Inspect only public APIs"
             })

    assert FleetManager.drain_steering(run.id, planner.agent_id) == ["Inspect only public APIs"]
    assert FleetManager.drain_steering(run.id, planner.agent_id) == []

    assert {:ok, :resumed} =
             RunFleetSupervisor.control_agent(run, planner.agent_id, :resume, %{
               idempotency_key: "resume-1"
             })

    before = Runs.get_run_agent(planner.agent_id)

    assert {:ok, restarted} =
             RunFleetSupervisor.control_agent(run, planner.agent_id, :restart, %{
               idempotency_key: "restart-1"
             })

    assert restarted.generation == before.lease_generation + 1
    assert Process.alive?(explorer_pid)

    stale =
      Runs.transition_run_agent(Runs.get_run_agent(planner.agent_id), "paused", %{},
        lease_owner: before.lease_owner,
        lease_generation: before.lease_generation
      )

    assert {:error, :lease_lost} = stale

    assert {:ok, :cancelled} =
             RunFleetSupervisor.control_agent(run, planner.agent_id, :cancel, %{
               idempotency_key: "cancel-1"
             })

    assert Runs.get_run_agent(planner.agent_id).status == "cancelled"
    assert Process.alive?(explorer_pid)

    assert Enum.map(Runs.list_run_agent_controls(planner.agent_id), & &1.kind) ==
             ~w(pause steer resume restart cancel)

    serialized =
      planner.agent_id
      |> Runs.list_run_agent_controls()
      |> Enum.map_join("\n", &Jason.encode!(&1.result || %{}))

    refute serialized =~ "#PID"
    refute serialized =~ (before.lease_owner || "never-present")
  end

  test "manager crash tears down children and rehydrates with higher generations", ctx do
    run = running_run(ctx, "recovery")
    on_exit(fn -> FleetSupervisor.stop(run.id) end)
    assert {:ok, agents} = FleetSupervisor.attach(run, agent_count: 4, project_root: ctx.root)
    generations = Map.new(agents, &{&1.agent_id, &1.generation})
    manager = AgentRegistry.whereis_fleet(run.id, :manager)
    old_pids = Enum.map(agents, & &1.pid)
    ref = Process.monitor(manager)

    Process.exit(manager, :kill)
    assert_receive {:DOWN, ^ref, :process, ^manager, :killed}, 2_000
    supervisor = AgentRegistry.whereis_fleet(run.id, :supervisor)
    _ = :sys.get_state(supervisor)

    new_manager = AgentRegistry.whereis_fleet(run.id, :manager)
    assert is_pid(new_manager)
    refute new_manager == manager
    _ = :sys.get_state(new_manager)

    recovered = FleetManager.list_agents(run.id)
    assert length(recovered) == 4
    assert Enum.all?(old_pids, &(not Process.alive?(&1)))
    assert Enum.all?(recovered, &(&1.generation > Map.fetch!(generations, &1.agent_id)))
  end

  test "paused state and queued steering recover without duplicate consumption", ctx do
    run = running_run(ctx, "paused recovery")
    on_exit(fn -> FleetSupervisor.stop(run.id) end)
    assert {:ok, agents} = FleetSupervisor.attach(run, agent_count: 4, project_root: ctx.root)
    planner = Enum.find(agents, &(&1.role == :planner))

    assert {:ok, :paused} =
             RunFleetSupervisor.control_agent(run, planner.agent_id, :pause, %{
               idempotency_key: "recovery-pause"
             })

    assert {:ok, :steered} =
             RunFleetSupervisor.control_agent(run, planner.agent_id, :steer, %{
               idempotency_key: "recovery-steer",
               guidance: "Preserve this guidance"
             })

    manager = AgentRegistry.whereis_fleet(run.id, :manager)
    ref = Process.monitor(manager)
    Process.exit(manager, :kill)
    assert_receive {:DOWN, ^ref, :process, ^manager, :killed}, 2_000

    supervisor = AgentRegistry.whereis_fleet(run.id, :supervisor)
    _ = :sys.get_state(supervisor)
    recovered_manager = AgentRegistry.whereis_fleet(run.id, :manager)
    _ = :sys.get_state(recovered_manager)

    [recovered] = Enum.filter(FleetManager.list_agents(run.id), &(&1.role == :planner))
    assert Runs.get_run_agent(recovered.agent_id).status == "paused"

    planner_state = IexCode.Engine.Agents.PlannerAgent.get_state(recovered.pid)
    assert FleetControlToken.paused?(planner_state.control_token)

    assert FleetManager.drain_steering(run.id, recovered.agent_id) == [
             "Preserve this guidance"
           ]

    assert FleetManager.drain_steering(run.id, recovered.agent_id) == []
  end

  test "abnormal fleet-agent exit cannot transiently restart a stale generation", ctx do
    run = running_run(ctx, "agent crash")
    on_exit(fn -> FleetSupervisor.stop(run.id) end)
    assert {:ok, agents} = FleetSupervisor.attach(run, agent_count: 4, project_root: ctx.root)
    explorer = Enum.find(agents, &(&1.role == :explorer))
    explorer_pid = explorer.pid
    ref = Process.monitor(explorer_pid)

    Process.exit(explorer_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^explorer_pid, :killed}, 2_000
    manager = AgentRegistry.whereis_fleet(run.id, :manager)
    _ = :sys.get_state(manager)

    assert AgentRegistry.whereis_agent(run.id, explorer.agent_id) == nil
    assert Runs.get_run_agent(explorer.agent_id).status == "interrupted"
  end

  test "strict allowlist fails closed on a spoofed registry occupant", ctx do
    run = running_run(ctx, "spoof")
    on_exit(fn -> FleetSupervisor.stop(run.id) end)
    assert {:ok, _agents} = FleetSupervisor.attach(run, agent_count: 4, project_root: ctx.root)
    supervisor = AgentRegistry.via_fleet(run.id, :agent_supervisor)
    spoof_id = Ecto.UUID.generate()

    assert {:ok, _} =
             Registry.register(AgentRegistry, {:run_agent, run.id, spoof_id}, %{role: :planner})

    assert {:error, :registration_conflict} =
             AgentSupervisor.start_run_agent(supervisor, run.id, spoof_id, :planner,
               session_id: ctx.session.id,
               project_root: ctx.root
             )

    assert_raise ArgumentError, fn ->
      AgentSupervisor.start_run_agent(supervisor, run.id, Ecto.UUID.generate(), :unknown,
        session_id: ctx.session.id
      )
    end
  end

  test "fleet-owned operation task is linked and dies with its owner", ctx do
    receiver = self()

    {:ok, owner} =
      Task.Supervisor.start_child(IexCode.TaskSupervisor, fn ->
        Process.put(:iex_code_fleet_owner, %{run_id: "run", agent_id: "agent"})

        OperationManager.run_sync_operation(
          ctx.session.id,
          nil,
          "TestAgent",
          "test",
          "blocked fleet operation",
          %{},
          fn _progress ->
            send(receiver, {:operation_child, self()})
            receive do: (:finish -> {:ok, :done})
          end,
          :infinity
        )
      end)

    assert_receive {:operation_child, child}, 2_000
    child_ref = Process.monitor(child)
    owner_ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 2_000
    assert_receive {:DOWN, ^child_ref, :process, ^child, _reason}, 2_000
  end

  test "direct dag_v1 ledger rows never fall through to the legacy executor", ctx do
    {:ok, run} =
      Runs.create_run(%{
        project_id: ctx.project.id,
        session_id: ctx.session.id,
        objective: "unavailable dag",
        kind: "coding_swarm",
        mode: "swarm",
        execution_engine: "dag_v1"
      })

    assert {:error, {:execution_engine_unavailable, "dag_v1"}} =
             Executor.execute(run, fn _, _ -> :ok end)

    assert AgentRegistry.whereis_fleet(run.id, :manager) == nil
  end

  test "durable attach rejects a crafted session or project scope", ctx do
    run = running_run(ctx, "scope")
    forged = %{run | session_id: Ecto.UUID.generate()}

    assert {:error, :run_scope_mismatch} =
             FleetSupervisor.attach(forged, agent_count: 4, project_root: ctx.root)

    assert AgentRegistry.whereis_fleet(run.id, :manager) == nil
  end

  test "fenced work lifecycle updates only the selected durable agent", ctx do
    run = running_run(ctx, "lifecycle")
    on_exit(fn -> FleetSupervisor.stop(run.id) end)
    assert {:ok, agents} = FleetSupervisor.attach(run, agent_count: 4, project_root: ctx.root)
    selected = Enum.find(agents, &(&1.role == :explorer))
    sibling = Enum.find(agents, &(&1.role == :planner))
    row = Runs.get_run_agent(selected.agent_id)
    receiver = self()

    owner = %{
      run_id: run.id,
      agent_id: row.id,
      generation: row.lease_generation
    }

    task =
      start_supervised!(
        {Task,
         fn ->
           send(receiver, {:fleet_task_ready, self()})
           receive do: (:go -> :ok)

           FleetRuntime.run(owner, "controlled exploration", fn ->
             :ok = FleetRuntime.progress(owner, 42, "reading symbols")
             send(receiver, :fleet_work_started)
             receive do: (:finish -> {:ok, :done})
           end)
         end}
      )

    assert_receive {:fleet_task_ready, ^task}, 2_000
    Ecto.Adapters.SQL.Sandbox.allow(IexCode.Repo, self(), task)
    send(task, :go)

    assert_receive :fleet_work_started, 2_000
    running = Runs.get_run_agent(selected.agent_id)
    assert running.status == "running"
    assert running.progress == 42
    assert running.current_task == "reading symbols"
    assert Runs.get_run_agent(sibling.agent_id).status == "idle"

    manager = AgentRegistry.whereis_fleet(run.id, :manager)
    send(manager, :heartbeat)
    _ = :sys.get_state(manager)
    assert Runs.get_run_agent(selected.agent_id).progress == 42
    assert Runs.get_run_agent(selected.agent_id).current_task == "reading symbols"

    ref = Process.monitor(task)
    send(task, :finish)
    assert_receive {:DOWN, ^ref, :process, ^task, :normal}, 2_000
    assert Runs.get_run_agent(selected.agent_id).status == "idle"
  end

  test "control token gates new work until resume and cancels without invoking it" do
    token = FleetControlToken.new()
    :ok = FleetControlToken.pause(token)
    receiver = self()

    task =
      start_supervised!(
        {Task,
         fn ->
           send(receiver, {:checkpoint_ready, self()})

           FleetRuntime.run(nil, token, "paused task", fn ->
             send(receiver, :work_invoked)
             {:ok, :done}
           end)
         end}
      )

    assert_receive {:checkpoint_ready, ^task}, 2_000
    refute_receive :work_invoked, 50
    :ok = FleetControlToken.resume(token)
    assert_receive :work_invoked, 2_000

    cancelled = FleetControlToken.new()
    :ok = FleetControlToken.cancel(cancelled)

    assert {:error, :cancelled} =
             FleetRuntime.run(nil, cancelled, "cancelled task", fn ->
               flunk("cancelled task must not execute")
             end)
  end

  test "operation manager checkpoints the fleet token before invoking an effect", ctx do
    token = FleetControlToken.new()
    :ok = FleetControlToken.pause(token)
    receiver = self()

    owner =
      start_supervised!(
        {Task,
         fn ->
           Process.put(:iex_code_fleet_owner, %{run_id: "isolated-run", agent_id: "agent"})
           Process.put(:iex_code_fleet_control_token, token)
           send(receiver, {:operation_owner_ready, self()})
           receive do: (:go -> :ok)

           OperationManager.run_sync_operation(
             ctx.session.id,
             nil,
             "FleetAgent",
             "checkpoint",
             "checkpoint operation",
             %{},
             fn _progress ->
               send(receiver, :operation_effect_invoked)
               {:ok, :done}
             end
           )
         end}
      )

    assert_receive {:operation_owner_ready, ^owner}, 2_000
    Ecto.Adapters.SQL.Sandbox.allow(IexCode.Repo, self(), owner)
    send(owner, :go)
    refute_receive :operation_effect_invoked, 50
    :ok = FleetControlToken.resume(token)
    assert_receive :operation_effect_invoked, 2_000
    ref = Process.monitor(owner)
    assert_receive {:DOWN, ^ref, :process, ^owner, :normal}, 2_000
  end

  defp running_run(ctx, suffix) do
    {:ok, run} =
      Runs.create_run(%{
        project_id: ctx.project.id,
        session_id: ctx.session.id,
        objective: "fleet #{suffix}",
        kind: "coding_swarm",
        mode: "swarm",
        execution_engine: "legacy_v1"
      })

    {:ok, run} = Runs.transition_run(run, "running")
    run
  end
end
