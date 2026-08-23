defmodule IexCode.RunsTest do
  use IexCode.DataCase, async: false

  alias IexCode.{Projects, Runs, Sessions}

  setup do
    root = Path.join(System.tmp_dir!(), "iex-code-runs-#{System.unique_integer([:positive])}")
    {:ok, project} = Projects.create_project(%{name: "Runs Test", root_path: root})
    {:ok, session} = Sessions.create_session(%{project_id: project.id, title: "Durable run"})

    %{project: project, session: session}
  end

  defp create_run(project, session, attrs \\ %{}) do
    base = %{
      project_id: project.id,
      session_id: session.id,
      objective: "Implement a durable async executor"
    }

    Runs.create_run(Map.merge(base, attrs))
  end

  test "creation commits a sequence-one event before broadcasting on run and session topics", %{
    project: project,
    session: session
  } do
    :ok = Runs.subscribe_session(session.id)
    {:ok, run} = create_run(project, session)
    :ok = Runs.subscribe(run.id)

    assert run.status == "queued"
    assert run.event_sequence == 1
    assert [%{sequence: 1, type: "run.created"}] = Runs.list_events(run.id)
    assert %{sequence: 1} = Runs.latest_event(run)
    run_id = run.id
    assert_receive {:run_created, %{id: ^run_id}}
    assert_receive {:run_event, %{run_id: ^run_id, sequence: 1}}
  end

  test "run and initial steps become visible atomically", %{project: project, session: session} do
    attrs = %{
      project_id: project.id,
      session_id: session.id,
      objective: "Atomic graph"
    }

    assert {:ok, run} =
             Runs.create_run_with_steps(attrs, [
               %{key: "prepare-0", kind: "prepare", title: "Prepare", position: 0},
               %{
                 key: "execute-0",
                 kind: "execute",
                 title: "Execute",
                 position: 1,
                 depends_on: ["prepare-0"]
               }
             ])

    assert Enum.map(Runs.list_steps(run), & &1.key) == ["prepare-0", "execute-0"]

    assert Enum.map(Runs.list_events(run), & &1.type) == [
             "run.created",
             "run.step_created",
             "run.step_created"
           ]

    assert Runs.get_run!(run.id).event_sequence == 3
  end

  test "strict changesets reject malformed runs and invalid transitions", %{
    project: project,
    session: session
  } do
    assert {:error, %Ecto.Changeset{} = changeset} =
             create_run(project, session, %{objective: "", status: "invented", progress: 101})

    refute changeset.valid?
    assert {:ok, run} = create_run(project, session)

    assert {:error, {:invalid_transition, "queued", "unknown"}} =
             Runs.transition_run(run, "unknown")

    assert {:ok, completed} = Runs.transition_run(run, "completed")
    assert completed.progress == 100
    assert completed.completed_at

    assert {:error, {:invalid_transition, "completed", "running"}} =
             Runs.transition_run(completed, "running")
  end

  test "events are monotonic, bounded, filterable and replayable", %{
    project: project,
    session: session
  } do
    {:ok, run} = create_run(project, session)

    assert {:ok, %{sequence: 2}} = Runs.append_event(run, "planner.started", %{"n" => 1})
    assert {:ok, %{sequence: 3}} = Runs.append_event(run, "planner.finished", %{"n" => 2})

    assert [2, 3] ==
             run.id
             |> Runs.list_events(after_sequence: 1)
             |> Enum.map(& &1.sequence)

    assert [2] ==
             run.id
             |> Runs.list_events(after_sequence: 1, type: "planner.started")
             |> Enum.map(& &1.sequence)

    assert [2, 3] == run.id |> Runs.replay_events(2, to_sequence: 3) |> Enum.map(& &1.sequence)

    oversized = %{"value" => String.duplicate("x", 256_001)}
    assert {:error, :payload_too_large} = Runs.append_event(run, "payload.large", oversized)
    assert Runs.latest_event(run).sequence == 3
  end

  test "latest event window keeps new events visible after the journal exceeds 500 entries", %{
    project: project,
    session: session
  } do
    {:ok, run} = create_run(project, session)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      for sequence <- 2..511 do
        %{
          id: Ecto.UUID.generate(),
          run_id: run.id,
          sequence: sequence,
          type: "worker.tick",
          source: "worker",
          payload: %{"sequence" => sequence},
          occurred_at: now,
          inserted_at: now
        }
      end

    assert {510, nil} = Repo.insert_all(IexCode.Runs.RunEvent, rows)

    # Forward traversal retains its original oldest-first cursor semantics.
    assert [1, 2, 3] =
             run.id
             |> Runs.list_events(limit: 3)
             |> Enum.map(& &1.sequence)

    tail = Runs.list_latest_events(run, limit: 500)
    assert length(tail) == 500
    assert List.first(tail).sequence == 12
    assert List.last(tail).sequence == 511
    assert Enum.map(tail, & &1.sequence) == Enum.to_list(12..511)
  end

  test "concurrent event writers allocate a gap-free unique sequence", %{
    project: project,
    session: session
  } do
    {:ok, run} = create_run(project, session)

    results =
      1..20
      |> Task.async_stream(
        fn n -> Runs.append_event(run.id, "worker.tick", %{"writer" => n}, "worker") end,
        max_concurrency: 8,
        timeout: :infinity
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, _event}}, &1))
    assert Enum.to_list(1..21) == Enum.map(Runs.list_events(run.id), & &1.sequence)
    assert 21 == Runs.get_run!(run.id).event_sequence
  end

  test "steps are ordered, unique by run key, and enforce status transitions", %{
    project: project,
    session: session
  } do
    {:ok, run} = create_run(project, session)

    assert {:ok, second} =
             Runs.create_step(run, %{key: "verify", kind: "verify", title: "Verify", position: 2})

    assert {:ok, first} =
             Runs.create_step(run, %{key: "plan", kind: "plan", title: "Plan", position: 1})

    assert [^first, ^second] = Runs.list_steps(run)

    assert {:error, %Ecto.Changeset{}} =
             Runs.create_step(run, %{key: "plan", kind: "plan", title: "Duplicate"})

    assert {:ok, running} = Runs.transition_step(first, "running", %{attempt: 1})
    assert running.started_at
    assert {:ok, completed} = Runs.transition_step(running, "completed")
    assert completed.progress == 100

    assert {:error, {:invalid_transition, "completed", "running"}} =
             Runs.transition_step(completed, "running")
  end

  test "commands are idempotent and approvals and artifacts are durable", %{
    project: project,
    session: session
  } do
    {:ok, run} = create_run(project, session)

    assert {:ok, command} =
             Runs.enqueue_command(run, "write:lib/example.ex", %{
               tool_name: "write_file",
               arguments: %{"path" => "lib/example.ex"}
             })

    assert {:ok, same_command} =
             Runs.enqueue_command(run, "write:lib/example.ex", %{
               tool_name: "run_command",
               arguments: %{"command" => "rm -rf /"}
             })

    assert same_command.id == command.id
    assert same_command.tool_name == "write_file"
    assert Runs.get_command_by_idempotency_key(run, "write:lib/example.ex").id == command.id

    assert {:ok, approval} =
             Runs.request_approval(run, %{
               key: "approve-write",
               run_command_id: command.id,
               action: "workspace_write",
               resource: "lib/example.ex",
               reason: "The command changes source code"
             })

    assert {:ok, decided} =
             Runs.decide_approval(approval, "approved", %{
               decided_by: "user@example.test",
               decision_note: "Approved"
             })

    assert decided.status == "approved"
    assert decided.decided_at

    assert {:error, {:invalid_transition, "approved", "denied"}} =
             Runs.decide_approval(decided, "denied")

    assert {:ok, artifact} =
             Runs.create_artifact(run, %{
               kind: "patch",
               name: "changes.diff",
               uri: "file:///tmp/changes.diff",
               byte_size: 42
             })

    assert [^artifact] = Runs.list_artifacts(run, kind: "patch")
  end

  test "cancelled run keeps project lease until its worker exits", %{
    project: project,
    session: session
  } do
    {:ok, first} = create_run(project, session, %{priority: "critical"})

    {:ok, second} =
      create_run(project, session, %{objective: "Next project mutation", priority: "low"})

    assert {:ok, claimed} = Runs.claim_next_run("dispatcher-a", lease_ms: 30_000)
    assert claimed.id == first.id

    assert {:ok, requested} = Runs.request_cancellation(claimed)
    assert {:ok, cancelled} = Runs.transition_run(requested, "cancelled")
    assert cancelled.lease_owner == "dispatcher-a"
    assert :none = Runs.claim_next_run("dispatcher-b")
    assert {:error, :run_still_leased} = Runs.retry_run(cancelled)

    assert {:ok, released} = Runs.release_lease(cancelled.id, "dispatcher-a")
    assert is_nil(released.lease_owner)
    assert {:ok, next} = Runs.claim_next_run("dispatcher-b")
    assert next.id == second.id
  end

  test "retry clears an expired lease left by a crashed cancelled worker", %{
    project: project,
    session: session
  } do
    {:ok, run} = create_run(project, session)
    assert {:ok, claimed} = Runs.claim_next_run("crashed-dispatcher", lease_ms: 30_000)
    assert {:ok, requested} = Runs.request_cancellation(claimed)
    assert {:ok, cancelled} = Runs.transition_run(requested, "cancelled")
    assert {:error, :run_still_leased} = Runs.retry_run(cancelled)

    expired_at = DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:second)

    Repo.update_all(from(r in IexCode.Runs.Run, where: r.id == ^run.id),
      set: [lease_expires_at: expired_at]
    )

    assert {:ok, retried} = Runs.retry_run(cancelled)
    assert retried.status == "queued"
    assert is_nil(retried.lease_owner)
    assert is_nil(retried.lease_expires_at)
  end

  test "retry and next-attempt steps commit atomically", %{project: project, session: session} do
    {:ok, _run} = create_run(project, session, %{max_attempts: 2})
    {:ok, claimed} = Runs.claim_next_run("dispatcher-a")
    {:ok, failed} = Runs.transition_run(claimed, "failed")

    assert {:ok, queued} =
             Runs.retry_run(failed,
               steps: [
                 %{key: "prepare.1", kind: "prepare", title: "Prepare retry", status: "ready"},
                 %{
                   key: "execute.1",
                   kind: "execute",
                   title: "Execute retry",
                   depends_on: ["prepare.1"]
                 }
               ]
             )

    assert queued.status == "queued"
    assert Enum.map(Runs.list_steps(queued), & &1.key) == ["prepare.1", "execute.1"]

    assert Enum.take(Enum.map(Runs.list_events(queued), & &1.type), -3) == [
             "run.retried",
             "run.step_created",
             "run.step_created"
           ]
  end

  test "claiming enforces per-project exclusivity, leases, reconciliation, and retry budgets", %{
    project: project,
    session: session
  } do
    {:ok, first} = create_run(project, session, %{priority: "high", max_attempts: 2})
    {:ok, second} = create_run(project, session, %{priority: "low"})

    assert {:ok, claimed} = Runs.claim_next_run("dispatcher-a", lease_ms: 30_000)
    assert claimed.id == first.id
    assert claimed.status == "running"
    assert claimed.lease_owner == "dispatcher-a"
    assert claimed.attempt == 1
    assert :none = Runs.claim_next_run("dispatcher-b", lease_ms: 30_000)
    assert {:error, :lease_not_owned} = Runs.renew_lease(claimed.id, "dispatcher-b", 30_000)
    assert {:ok, renewed} = Runs.renew_lease(claimed.id, "dispatcher-a", 30_000)
    assert renewed.lease_expires_at

    expired = DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:second)

    Repo.update_all(from(r in IexCode.Runs.Run, where: r.id == ^claimed.id),
      set: [lease_expires_at: expired]
    )

    assert [%{id: id, status: "interrupted"}] = Runs.reconcile_orphaned_runs()
    assert id == claimed.id
    assert {:ok, retried} = Runs.retry_run(claimed.id)
    assert retried.status == "queued"
    assert is_nil(retried.lease_owner)

    assert {:ok, reclaimed} = Runs.claim_next_run("dispatcher-b")
    assert reclaimed.id == first.id
    assert reclaimed.attempt == 2
    assert {:ok, failed} = Runs.transition_run(reclaimed, "failed")
    assert {:error, :attempts_exhausted} = Runs.retry_run(failed)

    assert {:ok, next_project_run} = Runs.claim_next_run("dispatcher-c")
    assert next_project_run.id == second.id
  end
end
