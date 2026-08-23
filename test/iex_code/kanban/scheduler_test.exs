defmodule IexCode.Kanban.SchedulerTest do
  use IexCode.DataCase, async: false

  alias IexCode.{Kanban, Projects, Repo, Runs, Sessions}
  alias IexCode.Kanban.Scheduler

  setup do
    root =
      Path.join(System.tmp_dir!(), "iex-code-scheduler-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, project} = Projects.create_project(%{name: "Scheduled project", root_path: root})
    {:ok, session} = Sessions.create_session(%{project_id: project.id, title: "Scheduled"})
    {:ok, project: project, session: session}
  end

  test "claims each due occurrence once and enqueues a typed durable run", context do
    due = ~U[2026-08-23 10:00:00Z]

    {:ok, task} =
      scheduled_task(context, %{
        title: "Verify the release",
        description: "Run the full release verification",
        priority: "high",
        scheduled_at: due
      })

    result =
      Scheduler.dispatch_due(now: due, dispatcher: self(), worker_id: "scheduler-test")

    assert %{claimed: 1, enqueued: 1, errors: []} = result
    assert_receive {:"$gen_cast", :dispatch}

    [run] = Runs.list_runs(project_id: context.project.id)
    assert run.kind == "coding_swarm"
    assert run.mode == "swarm"
    assert run.priority == "high"
    assert run.metadata["source"] == "kanban_schedule"
    assert run.metadata["kanban_task_id"] == task.id

    dispatched = Kanban.get_task!(task.id)
    assert dispatched.status == "running"
    assert dispatched.worker_pid == "run:#{run.id}"

    assert %{claimed: 0, enqueued: 0} =
             Scheduler.dispatch_due(now: due, dispatcher: self(), worker_id: "scheduler-test-2")

    assert length(Runs.list_runs(project_id: context.project.id)) == 1
  end

  test "concurrent workers cannot both claim the same due occurrence", context do
    due = ~U[2026-08-23 10:00:00Z]
    assert {:ok, _task} = scheduled_task(context, %{title: "Claim once", scheduled_at: due})

    results =
      1..2
      |> Task.async_stream(
        fn worker -> Kanban.claim_due_scheduled_tasks("worker-#{worker}", now: due, limit: 1) end,
        ordered: false,
        max_concurrency: 2,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.sum(Enum.map(results, fn {:ok, tasks} -> length(tasks) end)) == 1
  end

  test "supervised worker dispatches due work without a LiveView", context do
    due = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
    assert {:ok, _task} = scheduled_task(context, %{title: "Background run", scheduled_at: due})

    name = :"kanban-scheduler-#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {Scheduler,
         name: name, dispatcher: self(), worker_id: "supervised-test", poll_interval: 60_000}
      )

    _ = :sys.get_state(pid)
    assert Process.alive?(pid)
    assert_receive {:"$gen_cast", :dispatch}
    assert [_run] = Runs.list_runs(project_id: context.project.id)
  end

  test "advances a recurring schedule only after its run is durable", context do
    due = ~U[2026-08-24 09:00:00Z]

    {:ok, task} =
      scheduled_task(context, %{
        title: "Weekday maintenance",
        scheduled_at: due,
        cron_expression: "0 9 * * 1-5"
      })

    assert %{claimed: 1, enqueued: 1, errors: []} =
             Scheduler.dispatch_due(now: due, dispatcher: self(), worker_id: "recurring")

    updated = Kanban.get_task!(task.id)
    assert updated.status == "scheduled"
    assert updated.worker_pid == nil
    assert updated.claimed_at == nil
    assert updated.scheduled_at == ~U[2026-08-25 09:00:00Z]
  end

  test "recovers only stale scheduler claims and reuses an already-created run", context do
    due = ~U[2026-08-23 10:00:00Z]

    {:ok, task} = scheduled_task(context, %{title: "Recover me", scheduled_at: due})
    assert {:ok, [claimed]} = Kanban.claim_due_scheduled_tasks("old", now: due)

    schedule_key = Kanban.schedule_occurrence_key(claimed)

    assert {:ok, existing} =
             IexCode.Runs.RunDispatcher.enqueue(
               %{
                 project_id: context.project.id,
                 session_id: context.session.id,
                 objective: claimed.title,
                 kind: "coding_swarm",
                 mode: "swarm",
                 priority: "normal",
                 metadata: %{"source" => "kanban_schedule", "schedule_key" => schedule_key}
               },
               self()
             )

    stale_time = DateTime.add(due, -600, :second)

    from(t in IexCode.Kanban.Task, where: t.id == ^task.id)
    |> Repo.update_all(set: [claimed_at: stale_time])

    assert 1 == Kanban.recover_stale_schedule_claims(now: due, stale_after: 300_000)

    assert %{recovered: 0, claimed: 1, enqueued: 1, errors: []} =
             Scheduler.dispatch_due(now: due, dispatcher: self(), worker_id: "new")

    assert [run] = Runs.list_runs(project_id: context.project.id)
    assert run.id == existing.id
    assert Kanban.get_task!(task.id).worker_pid == "run:#{existing.id}"
  end

  test "blocks an invalid recurring expression without creating a run", context do
    due = ~U[2026-08-23 10:00:00Z]

    {:ok, task} =
      scheduled_task(context, %{
        title: "Bad recurrence",
        scheduled_at: due,
        cron_expression: "@daily"
      })

    assert %{claimed: 1, enqueued: 0, errors: [:invalid_cron]} =
             Scheduler.dispatch_due(now: due, dispatcher: self(), worker_id: "invalid")

    assert Runs.list_runs(project_id: context.project.id) == []
    assert Kanban.get_task!(task.id).status == "blocked"
  end

  test "creates and durably attaches a session when a scheduled task has none", context do
    due = ~U[2026-08-23 10:00:00Z]

    assert {:ok, task} =
             Kanban.create_task(%{
               project_id: context.project.id,
               title: "Unattached schedule",
               status: "scheduled",
               scheduled_at: due
             })

    assert task.session_id == nil

    assert %{claimed: 1, enqueued: 1, errors: []} =
             Scheduler.dispatch_due(now: due, dispatcher: self(), worker_id: "session-maker")

    updated = Kanban.get_task!(task.id)
    assert is_binary(updated.session_id)
    assert Sessions.get_session!(updated.session_id).project_id == context.project.id
    assert [run] = Runs.list_runs(project_id: context.project.id)
    assert run.session_id == updated.session_id
  end

  test "stale recovery never releases ordinary agent task claims", context do
    due = ~U[2026-08-23 10:00:00Z]

    {:ok, task} =
      Kanban.create_task(%{
        project_id: context.project.id,
        session_id: context.session.id,
        title: "Agent-owned work",
        status: "ready"
      })

    assert {:ok, claimed} = Kanban.claim_task(task, "coder")

    from(t in IexCode.Kanban.Task, where: t.id == ^claimed.id)
    |> Repo.update_all(set: [claimed_at: DateTime.add(due, -600, :second)])

    assert 0 == Kanban.recover_stale_schedule_claims(now: due, stale_after: 300_000)
    assert Kanban.get_task!(task.id).status == "running"
  end

  defp scheduled_task(context, attrs) do
    Kanban.create_task(
      Map.merge(
        %{
          project_id: context.project.id,
          session_id: context.session.id,
          status: "scheduled",
          priority: "medium"
        },
        attrs
      )
    )
  end
end
