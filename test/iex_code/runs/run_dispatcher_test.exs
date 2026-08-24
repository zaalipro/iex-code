defmodule IexCode.Runs.RunDispatcherTest do
  use IexCode.DataCase, async: false

  import Ecto.Query

  alias IexCode.{Projects, Repo, Runs, Sessions, WorkspaceLocks}
  alias IexCode.Runs.{Run, RunDispatcher}

  @dispatcher IexCode.RunDispatcherUnderTest

  setup do
    Process.register(self(), IexCode.RunDispatcherTestReceiver)

    {:ok, project} =
      Projects.create_project(%{
        name: "dispatcher-#{System.unique_integer([:positive])}",
        root_path: File.cwd!()
      })

    {:ok, session} =
      Sessions.create_session(%{project_id: project.id, title: "Durable run dispatcher"})

    :ok = Runs.subscribe_session(session.id)
    :ok = IexCode.Kanban.subscribe(project.id)

    start_supervised!({RunDispatcher, dispatcher_options()})

    on_exit(fn ->
      if Process.whereis(IexCode.RunDispatcherTestReceiver) == self() do
        Process.unregister(IexCode.RunDispatcherTestReceiver)
      end
    end)

    %{project: project, session: session}
  end

  test "persists typed runs, executes durable prepare/execute steps, and completes", context do
    {:ok, queued} = enqueue(context, "complete run")
    assert queued.status == "queued"

    assert_receive {:test_run_started, run_id, worker_pid}, 2_000
    assert run_id == queued.id
    assert is_pid(worker_pid)

    running = Runs.get_run!(run_id)
    assert running.status == "running"
    assert running.attempt == 1
    assert running.lease_owner == "dispatcher-test"

    assert [prepare, execute] = Runs.list_steps(running)
    assert {prepare.key, prepare.status} == {"prepare", "completed"}
    assert {execute.key, execute.status} == {"execute", "running"}
    {:ok, task} = linked_task(context, running)

    send(worker_pid, {:finish, run_id, {:ok, %{summary: "done"}}})

    assert_receive {:async_run_updated, %Run{id: ^run_id, status: "completed"}}, 2_000
    assert Runs.get_run!(run_id).progress == 100
    assert Enum.at(Runs.list_steps(run_id), 1).status == "completed"
    projected = IexCode.Kanban.get_task!(task.id)
    assert projected.status == "done"
    assert projected.worker_pid == nil
    assert projected.claimed_at == nil
    assert projected.latest_summary =~ "completed successfully"
    assert :noop = IexCode.Kanban.project_run_terminal(run_id, "completed")
    assert IexCode.Kanban.get_task!(task.id) == projected
  end

  test "enforces global capacity and one active run per project", context do
    {:ok, first} = enqueue(context, "first project run")
    assert_receive {:test_run_started, first_id, first_pid}, 2_000
    assert first_id == first.id

    {:ok, second} = enqueue(context, "second same-project run")
    second_run_id = second.id
    refute_receive {:test_run_started, ^second_run_id, _pid}, 100

    {:ok, project_two} =
      Projects.create_project(%{
        name: "dispatcher-second-#{System.unique_integer([:positive])}",
        root_path: Path.join(File.cwd!(), "tmp")
      })

    {:ok, session_two} =
      Sessions.create_session(%{project_id: project_two.id, title: "Second project"})

    {:ok, third} = enqueue(%{project: project_two, session: session_two}, "parallel project run")
    assert_receive {:test_run_started, third_id, third_pid}, 2_000
    assert third_id == third.id

    stats = RunDispatcher.get_stats(@dispatcher)
    assert stats.active == 2
    assert stats.capacity == 0
    assert Enum.sort(stats.projects) == Enum.sort([context.project.id, project_two.id])

    send(first_pid, {:finish, first.id, {:ok, :done}})
    assert_receive {:test_run_started, second_id, second_pid}, 2_000
    assert second_id == second.id

    send(second_pid, {:finish, second.id, {:ok, :done}})
    send(third_pid, {:finish, third.id, {:ok, :done}})
  end

  test "pause and resume preserve the worker while cancel records intent before hard-stop",
       context do
    {:ok, run} = enqueue(context, "controlled run")
    run_id = run.id
    assert_receive {:test_run_started, ^run_id, worker_pid}, 2_000

    assert {:ok, paused} = RunDispatcher.pause(run, @dispatcher)
    assert paused.status == "paused"
    assert_receive {:test_run_paused, ^run_id}, 2_000
    assert Enum.at(Runs.list_steps(run), 1).status == "paused"
    assert Process.alive?(worker_pid)

    assert {:ok, steered} =
             RunDispatcher.steer(run, "Keep public APIs backwards compatible", @dispatcher)

    assert steered.id == run.id
    assert_receive {:test_run_steered, ^run_id, "Keep public APIs backwards compatible"}, 2_000

    assert {:ok, resumed} = RunDispatcher.resume(run, @dispatcher)
    assert resumed.status == "running"
    assert_receive {:test_run_resumed, ^run_id}, 2_000
    assert Enum.at(Runs.list_steps(run), 1).status == "running"

    assert [%{kind: "pause"}, %{kind: "steer"}, %{kind: "resume"}] =
             Runs.list_controls(run)

    {:ok, task} = linked_task(context, Runs.get_run!(run_id))

    assert {:ok, cancelled} = RunDispatcher.cancel(run, @dispatcher)
    assert cancelled.status == "cancelled"
    assert cancelled.cancellation_requested_at != nil
    assert_receive {:test_run_cancelled, ^run_id}, 2_000

    assert List.last(Runs.list_controls(run)).kind == "cancel"

    ref = Process.monitor(worker_pid)
    assert_receive {:DOWN, ^ref, :process, ^worker_pid, _reason}, 2_000
    assert Enum.at(Runs.list_steps(run), 1).status == "cancelled"
    projected = IexCode.Kanban.get_task!(task.id)
    assert projected.status == "blocked"
    assert projected.worker_pid == nil
    assert projected.latest_summary =~ "Cancelled by user"
  end

  test "cancelling an inactive queued run does not broadcast session rollback control", context do
    {:ok, active} = enqueue(context, "active run")
    active_id = active.id
    assert_receive {:test_run_started, ^active_id, active_worker}, 2_000

    {:ok, queued} = enqueue(context, "queued run")
    queued_id = queued.id
    refute_receive {:test_run_started, ^queued_id, _pid}, 100

    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{context.session.id}:steer")
    assert {:ok, cancelled} = RunDispatcher.cancel(queued, @dispatcher)
    assert cancelled.status == "cancelled"
    refute_receive {:cancel, _, _}, 100
    assert Process.alive?(active_worker)

    send(active_worker, {:finish, active_id, {:ok, :done}})
  end

  test "failed runs retry as a new durable attempt and are not auto-retried", context do
    {:ok, run} = enqueue(context, "retry run")
    run_id = run.id
    assert_receive {:test_run_started, ^run_id, first_pid}, 2_000
    send(first_pid, {:finish, run.id, {:error, :first_attempt_failed}})

    assert_receive {:async_run_updated, %Run{id: run_id, status: "failed"}}, 2_000
    assert run_id == run.id
    refute_receive {:test_run_started, ^run_id, _pid}, 100

    assert {:ok, retried} = RunDispatcher.retry(run, @dispatcher)
    assert retried.status == "queued"
    assert_receive {:test_run_started, ^run_id, second_pid}, 2_000

    running = Runs.get_run!(run.id)
    assert running.attempt == 2

    assert Enum.map(Runs.list_steps(run), & &1.key) ==
             ["prepare", "execute", "prepare.2", "execute.2"]

    send(second_pid, {:finish, run.id, {:ok, :recovered}})
    assert_receive {:async_run_updated, %Run{id: ^run_id, status: "completed"}}, 2_000
  end

  test "enforces the durable wall-clock budget and journals exhaustion", context do
    attrs = run_attrs(context, "bounded run") |> Map.put(:time_budget_ms, 30)
    assert {:ok, run} = RunDispatcher.enqueue(attrs, @dispatcher)
    run_id = run.id
    assert_receive {:test_run_started, ^run_id, worker_pid}, 2_000

    ref = Process.monitor(worker_pid)
    assert_receive {:run_updated, %Run{id: ^run_id, status: "failed"}}, 2_000
    assert_receive {:DOWN, ^ref, :process, ^worker_pid, _reason}, 2_000

    failed = Runs.get_run!(run_id)
    assert failed.error_details["reason"] == "budget_exhausted"
    assert failed.error_details["budget"] == "time"
    assert Enum.any?(Runs.list_events(run), &(&1.type == "run.budget_exhausted"))
  end

  test "an abnormal monitored worker exit is persisted as interrupted", context do
    {:ok, run} = enqueue(context, "crashing run")
    run_id = run.id
    assert_receive {:test_run_started, ^run_id, worker_pid}, 2_000
    {:ok, task} = linked_task(context, Runs.get_run!(run_id))

    ref = Process.monitor(worker_pid)
    Process.exit(worker_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker_pid, :killed}, 2_000

    assert_receive {:async_run_updated, %Run{id: ^run_id, status: "interrupted"}}, 2_000
    assert Runs.get_run!(run_id).status == "interrupted"
    assert Enum.at(Runs.list_steps(run_id), 1).status == "interrupted"
    projected = IexCode.Kanban.get_task!(task.id)
    assert projected.status == "blocked"
    assert projected.worker_pid == nil
    assert projected.latest_summary =~ "interrupted"
    assert projected.latest_summary =~ "killed"
    refute_receive {:test_run_started, ^run_id, _pid}, 100
  end

  test "a foreign interactive lock blocks coding execution until it is released", context do
    {:ok, blocker} =
      WorkspaceLocks.acquire(context.project, [:project],
        owner_id: "interactive:test",
        project_id: context.project.id,
        session_id: context.session.id,
        lease_seconds: 60,
        heartbeat_interval_ms: 20_000
      )

    attrs =
      context
      |> run_attrs("workspace-exclusive coding")
      |> Map.merge(%{kind: "coding_swarm", mode: "swarm"})

    assert {:ok, run} = RunDispatcher.enqueue(attrs, @dispatcher)
    run_id = run.id

    refute_receive {:test_run_started, ^run_id, _pid}, 150

    assert %Run{status: "running", attempt: 1} = Runs.get_run!(run_id)
    assert Enum.at(Runs.list_steps(run_id), 1).status == "blocked"

    assert [%{status: "waiting", owner_id: owner}] =
             Runs.list_workspace_locks(run_id: run_id, active: true)

    assert owner == "run:#{run_id}"
    assert :ok = WorkspaceLocks.release(blocker)

    assert_receive {:test_run_delegation, ^run_id, :present}, 2_000
    assert_receive {:test_run_started, ^run_id, worker_pid}, 2_000
    assert Enum.at(Runs.list_steps(run_id), 1).status == "running"

    send(worker_pid, {:finish, run_id, {:ok, :done}})
    assert_receive {:async_run_updated, %Run{id: ^run_id, status: "completed"}}, 2_000
    _ = RunDispatcher.get_stats(@dispatcher)

    assert [%{status: "released", capability_token_hash: "[REDACTED]"}] =
             Runs.list_workspace_locks(run_id: run_id)

    finished = Runs.get_run!(run_id)
    refute inspect(finished.metadata) =~ "capability"

    refute Enum.any?(Runs.list_events(run_id), fn event ->
             inspect(event.payload) =~ "capability"
           end)
  end

  test "cancelling a lock-waiting coding run cancels its opaque lock batch", context do
    {:ok, blocker} =
      WorkspaceLocks.acquire(context.project, [:project],
        owner_id: "interactive:cancel-test",
        project_id: context.project.id,
        lease_seconds: 60,
        heartbeat_interval_ms: 20_000
      )

    attrs =
      context
      |> run_attrs("cancel while waiting")
      |> Map.merge(%{kind: "coding_swarm", mode: "swarm"})

    assert {:ok, run} = RunDispatcher.enqueue(attrs, @dispatcher)
    run_id = run.id
    refute_receive {:test_run_started, ^run_id, _pid}, 100

    assert {:ok, %Run{status: "cancelled"}} = RunDispatcher.cancel(run_id, @dispatcher)

    assert [%{status: "cancelled"}] = Runs.list_workspace_locks(run_id: run_id)
    refute_receive {:test_run_started, ^run_id, _pid}, 100
    assert :ok = WorkspaceLocks.release(blocker)
  end

  test "a crashed coding worker releases its workspace lock after process exit", context do
    attrs =
      context
      |> run_attrs("crashing coding run")
      |> Map.merge(%{kind: "coding_swarm", mode: "swarm"})

    assert {:ok, run} = RunDispatcher.enqueue(attrs, @dispatcher)
    run_id = run.id
    assert_receive {:test_run_started, ^run_id, worker_pid}, 2_000

    assert [%{status: "held"}] = Runs.list_workspace_locks(run_id: run_id, active: true)

    ref = Process.monitor(worker_pid)
    Process.exit(worker_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker_pid, :killed}, 2_000
    assert_receive {:async_run_updated, %Run{id: ^run_id, status: "interrupted"}}, 2_000
    _ = RunDispatcher.get_stats(@dispatcher)

    assert [%{status: "released"}] = Runs.list_workspace_locks(run_id: run_id)

    assert {:ok, interactive} =
             WorkspaceLocks.acquire(context.project, [:project],
               owner_id: "interactive:after-crash",
               project_id: context.project.id,
               lease_seconds: 60,
               heartbeat_interval_ms: 20_000
             )

    assert :ok = WorkspaceLocks.release(interactive)
  end

  test "dispatcher shutdown cleans up a coding worker and its outer lock", context do
    attrs =
      context
      |> run_attrs("dispatcher shutdown coding run")
      |> Map.merge(%{kind: "coding_swarm", mode: "swarm"})

    assert {:ok, run} = RunDispatcher.enqueue(attrs, @dispatcher)
    run_id = run.id
    assert_receive {:test_run_started, ^run_id, worker_pid}, 2_000
    assert [%{status: "held"}] = Runs.list_workspace_locks(run_id: run_id, active: true)
    assert :ok = Runs.subscribe_workspace_locks(context.project.id)

    worker_ref = Process.monitor(worker_pid)
    stop_supervised!(RunDispatcher)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, _reason}, 2_000

    assert_receive {:workspace_locks_updated, locks}, 2_000
    assert Enum.any?(locks, &(&1.run_id == run_id and &1.status == "released"))
    assert [%{status: "released"}] = Runs.list_workspace_locks(run_id: run_id)
  end

  test "a coding run keeps its exclusive workspace lock while paused", context do
    attrs =
      context
      |> run_attrs("paused coding run")
      |> Map.merge(%{kind: "coding_swarm", mode: "swarm"})

    assert {:ok, run} = RunDispatcher.enqueue(attrs, @dispatcher)
    run_id = run.id
    assert_receive {:test_run_started, ^run_id, worker_pid}, 2_000

    assert {:ok, %Run{status: "paused"}} = RunDispatcher.pause(run_id, @dispatcher)
    assert_receive {:test_run_paused, ^run_id}, 2_000
    assert [%{status: "held"}] = Runs.list_workspace_locks(run_id: run_id, active: true)

    assert {:error, {:workspace_lock_waiting, _locks}} =
             WorkspaceLocks.acquire(context.project, [:project],
               owner_id: "interactive:while-paused",
               project_id: context.project.id,
               lease_seconds: 60,
               heartbeat_interval_ms: 20_000
             )

    assert {:ok, %Run{status: "running"}} = RunDispatcher.resume(run_id, @dispatcher)
    send(worker_pid, {:finish, run_id, {:ok, :done}})
    assert_receive {:async_run_updated, %Run{id: ^run_id, status: "completed"}}, 2_000
  end

  test "cancelling an active coding worker releases only after worker cleanup", context do
    attrs =
      context
      |> run_attrs("cancel active coding")
      |> Map.merge(%{kind: "coding_swarm", mode: "swarm"})

    assert {:ok, run} = RunDispatcher.enqueue(attrs, @dispatcher)
    run_id = run.id
    assert_receive {:test_run_started, ^run_id, worker_pid}, 2_000
    assert [%{status: "held"}] = Runs.list_workspace_locks(run_id: run_id, active: true)

    worker_ref = Process.monitor(worker_pid)
    assert {:ok, %Run{status: "cancelled"}} = RunDispatcher.cancel(run_id, @dispatcher)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, _reason}, 2_000
    _ = RunDispatcher.get_stats(@dispatcher)
    assert [%{status: "released"}] = Runs.list_workspace_locks(run_id: run_id)
  end

  test "an interrupted research worker terminalizes pending descendants", context do
    attrs =
      context
      |> run_attrs("interrupted research")
      |> Map.merge(%{kind: "deep_research", mode: "research"})

    assert {:ok, run} = RunDispatcher.enqueue(attrs, @dispatcher)
    run_id = run.id
    assert_receive {:test_run_started, ^run_id, worker_pid}, 2_000

    ref = Process.monitor(worker_pid)
    Process.exit(worker_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker_pid, :killed}, 2_000
    assert_receive {:async_run_updated, %Run{id: ^run_id, status: "interrupted"}}, 2_000

    refute Enum.any?(Runs.list_steps(run), fn step ->
             step.status in ~w(pending ready running paused waiting_approval blocked)
           end)
  end

  test "startup supersedes controls claimed by the previous dispatcher", context do
    stop_supervised!(RunDispatcher)
    {:ok, run} = create_run(context, "claimed before restart")
    {:ok, pending} = Runs.enqueue_control(run, "restart:steer", %{kind: "steer"})
    assert {:ok, claimed} = Runs.claim_control(pending, "dispatcher-test")

    start_supervised!({RunDispatcher, dispatcher_options()})

    superseded = Runs.get_control(claimed.id)
    assert superseded.status == "superseded"
    assert superseded.result == %{"reason" => "dispatcher_restarted"}
  end

  test "rejects untyped executable payloads before persistence", context do
    attrs = run_attrs(context, "invalid run") |> Map.delete(:kind)
    assert {:error, :invalid_typed_run} = RunDispatcher.enqueue(attrs, @dispatcher)
    assert Runs.list_runs(session_id: context.session.id) == []
  end

  test "startup reconciliation interrupts expired work and never executes it", context do
    stop_supervised!(RunDispatcher)

    {:ok, run} = create_run(context, "orphaned run")
    run_id = run.id
    :ok = create_steps(run)
    assert {:ok, claimed} = Runs.claim_next_run("dead-worker", lease_ms: 10)
    assert claimed.id == run.id

    [prepare, _execute] = Runs.list_steps(run)
    assert {:ok, _} = Runs.transition_step(prepare, "running")
    {:ok, task} = linked_task(context, claimed)

    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

    from(r in Run, where: r.id == ^run_id)
    |> Repo.update_all(set: [lease_expires_at: past])

    start_supervised!({RunDispatcher, dispatcher_options()})

    assert Runs.get_run!(run.id).status == "interrupted"
    assert hd(Runs.list_steps(run)).status == "interrupted"
    projected = IexCode.Kanban.get_task!(task.id)
    assert projected.status == "blocked"
    assert projected.worker_pid == nil
    refute_receive {:test_run_started, ^run_id, _pid}, 100
  end

  test "prepare failure blocks a linked one-off task", context do
    stop_supervised!(RunDispatcher)

    missing_root =
      Path.join(System.tmp_dir!(), "missing-dispatch-root-#{System.unique_integer([:positive])}")

    {:ok, project} = Projects.update_project(context.project, %{root_path: missing_root})
    failed_context = %{context | project: project}

    assert {:ok, run} =
             RunDispatcher.enqueue(run_attrs(failed_context, "invalid workspace"), self())

    assert_receive {:"$gen_cast", :dispatch}
    {:ok, task} = linked_task(failed_context, run)

    start_supervised!({RunDispatcher, dispatcher_options()})

    assert_receive {:run_updated, %Run{id: run_id, status: "failed"}}, 2_000
    assert run_id == run.id
    assert_receive {:task_updated, %{id: task_id, status: "blocked"}}, 2_000
    assert task_id == task.id
    projected = IexCode.Kanban.get_task!(task.id)
    assert projected.status == "blocked"
    assert projected.worker_pid == nil
    assert projected.claimed_at == nil
    assert projected.latest_summary =~ "project_root_not_found"
  end

  test "recurring rows and stale run links are never consumed", context do
    run_id = Ecto.UUID.generate()
    owner = "run:#{run_id}"

    {:ok, recurring} =
      IexCode.Kanban.create_task(%{
        project_id: context.project.id,
        session_id: context.session.id,
        title: "Next recurring occurrence",
        status: "scheduled",
        cron_expression: "0 9 * * 1-5",
        scheduled_at: DateTime.utc_now(),
        worker_pid: nil,
        latest_summary: "next occurrence scheduled"
      })

    {:ok, moved} = linked_task(context, %{id: run_id})
    {:ok, moved} = IexCode.Kanban.update_task(moved, %{status: "review"})

    assert :noop = IexCode.Kanban.project_run_terminal(run_id, "completed")
    assert IexCode.Kanban.get_task!(recurring.id).status == "scheduled"
    assert IexCode.Kanban.get_task!(recurring.id).latest_summary == "next occurrence scheduled"
    assert IexCode.Kanban.get_task!(moved.id).status == "review"
    assert IexCode.Kanban.get_task!(moved.id).worker_pid == owner
  end

  defp enqueue(context, objective) do
    RunDispatcher.enqueue(run_attrs(context, objective), @dispatcher)
  end

  defp create_run(context, objective), do: Runs.create_run(run_attrs(context, objective))

  defp run_attrs(context, objective) do
    %{
      project_id: context.project.id,
      session_id: context.session.id,
      objective: objective,
      kind: "analysis",
      mode: "single",
      max_attempts: 3
    }
  end

  defp create_steps(run) do
    with {:ok, _} <-
           Runs.create_step(run, %{
             key: "prepare",
             kind: "prepare",
             title: "Validate durable run inputs",
             status: "ready"
           }),
         {:ok, _} <-
           Runs.create_step(run, %{
             key: "execute",
             kind: "execute",
             title: "Execute analysis",
             status: "pending",
             position: 1,
             depends_on: ["prepare"]
           }) do
      :ok
    end
  end

  defp linked_task(context, run) do
    IexCode.Kanban.create_task(%{
      project_id: context.project.id,
      session_id: context.session.id,
      title: "Linked one-off run",
      status: "running",
      worker_pid: "run:#{run.id}",
      claimed_at: DateTime.utc_now(),
      latest_summary: "run active"
    })
  end

  defp dispatcher_options do
    [
      name: @dispatcher,
      worker_id: "dispatcher-test",
      executor: IexCode.RunDispatcherTestExecutor,
      max_concurrency: 2,
      poll_interval: 60_000,
      heartbeat_interval: 60_000,
      lease_ms: 120_000,
      cancel_grace_ms: 20,
      workspace_lock_retry_interval: 20,
      workspace_lock_lease_seconds: 60
    ]
  end
end
