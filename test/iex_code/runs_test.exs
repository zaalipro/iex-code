defmodule IexCode.RunsTest do
  use IexCode.DataCase, async: false

  import Ecto.Query

  alias IexCode.{Projects, Repo, Runs, Sessions}
  alias IexCode.Runs.Run

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

  defp insert_forged_dag(project, session, objective) do
    %Run{project_id: project.id, session_id: session.id}
    |> Run.create_changeset(%{
      objective: objective,
      kind: "analysis",
      mode: "single",
      execution_engine: "dag_v1",
      manifest_hash: String.duplicate("0", 64)
    })
    |> Repo.insert()
  end

  defp dag_steps do
    [
      %{key: "inventory", kind: "project_inventory", title: "Inventory"},
      %{
        key: "join",
        kind: "aggregate",
        title: "Join",
        depends_on: ["inventory"]
      }
    ]
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

  test "durable DAG creation rejects empty graphs and persists a canonical hash", %{
    project: project,
    session: session
  } do
    assert {:error, :empty_dag_manifest} =
             create_run(project, session, %{execution_engine: "dag_v1"})

    assert Runs.list_runs(session_id: session.id) == []

    attrs = %{
      project_id: project.id,
      session_id: session.id,
      objective: "Canonical DAG",
      kind: "analysis",
      mode: "workflow",
      execution_engine: "dag_v1"
    }

    assert {:ok, run} = Runs.create_run_with_steps(attrs, Enum.reverse(dag_steps()))
    assert byte_size(run.manifest_hash) == 64
    assert Enum.map(Runs.list_steps(run), & &1.key) == ["inventory", "join"]
    assert Enum.map(Runs.list_steps(run), & &1.status) == ["ready", "pending"]
  end

  test "durable creation validates the legacy manifest before any insert", %{
    project: project,
    session: session
  } do
    attrs = %{
      project_id: project.id,
      session_id: session.id,
      objective: "Duplicate graph"
    }

    assert {:error, :duplicate_step_key} =
             Runs.create_run_with_steps(attrs, [
               %{key: "duplicate", kind: "prepare", title: "First"},
               %{key: "duplicate", kind: "execute", title: "Second"}
             ])

    assert Runs.list_runs(session_id: session.id) == []
  end

  test "run execution manifest is immutable through lifecycle and heartbeat updates", %{
    project: project,
    session: session
  } do
    {:ok, run} = create_run(project, session)

    assert {:error, %Ecto.Changeset{} = transition_changeset} =
             Runs.transition_run(run, "running", %{execution_engine: "dag_v1"})

    assert {"cannot be changed after creation", _} =
             transition_changeset.errors[:execution_engine]

    assert {:error, %Ecto.Changeset{} = heartbeat_changeset} =
             Runs.heartbeat_run(run, %{"execution_engine" => "dag_v1"})

    assert {"cannot be changed after creation", _} =
             heartbeat_changeset.errors[:execution_engine]

    assert {:error, %Ecto.Changeset{} = direct_changeset} =
             run
             |> Run.create_changeset(%{execution_engine: "dag_v1"})
             |> Repo.update()

    assert {"cannot be changed after creation", _} = direct_changeset.errors[:execution_engine]

    for {field, changed} <- [
          {:objective, "Reinterpreted objective"},
          {:kind, "deep_research"},
          {:mode, "research"}
        ] do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Runs.heartbeat_run(run, %{field => changed})

      assert {"cannot be changed after creation", _} = changeset.errors[field]
    end

    persisted = Runs.get_run!(run.id)
    assert persisted.status == "queued"
    assert persisted.objective == run.objective
    assert persisted.kind == run.kind
    assert persisted.mode == run.mode
    assert persisted.execution_engine == "legacy_v1"
    assert persisted.event_sequence == 1
  end

  test "generic step creation cannot mutate a persisted dag manifest", %{
    project: project,
    session: session
  } do
    {:ok, run} = insert_forged_dag(project, session, "immutable graph")

    assert {:error, :dag_manifest_immutable} =
             Runs.create_step(run, %{key: "late", kind: "analysis", title: "Late node"})

    forged_legacy = %{run | execution_engine: "legacy_v1"}

    assert {:error, :dag_manifest_immutable} =
             Runs.create_step(forged_legacy, %{
               key: "forged",
               kind: "analysis",
               title: "Forged node"
             })

    assert Runs.list_steps(run) == []
  end

  test "run claims include canonical dag_v1 work", %{
    project: project,
    session: session
  } do
    attrs = %{
      project_id: project.id,
      session_id: session.id,
      objective: "higher priority dag",
      kind: "analysis",
      mode: "workflow",
      execution_engine: "dag_v1",
      priority: "high"
    }

    {:ok, dag} = Runs.create_run_with_steps(attrs, dag_steps())

    {:ok, legacy} =
      create_run(project, session, %{objective: "dispatchable legacy", priority: "low"})

    assert {:ok, claimed} = Runs.claim_next_run("engine-aware-dispatcher")
    assert claimed.id == dag.id
    assert claimed.execution_engine == "dag_v1"
    assert claimed.lease_generation == 1
    assert Runs.get_run!(legacy.id).status == "queued"

    assert :none = Runs.claim_next_run("second-dispatcher", execution_engines: ["dag_v1"])
  end

  test "DAG retry rejects forged manifest hash drift at the durable boundary", %{
    project: project,
    session: session
  } do
    attrs = %{
      project_id: project.id,
      session_id: session.id,
      objective: "forged retry",
      kind: "analysis",
      mode: "workflow",
      execution_engine: "dag_v1"
    }

    {:ok, run} = Runs.create_run_with_steps(attrs, dag_steps())

    {1, _} =
      from(current in Run, where: current.id == ^run.id)
      |> Repo.update_all(
        set: [
          status: "failed",
          completed_at: DateTime.utc_now(),
          manifest_hash: String.duplicate("0", 64)
        ]
      )

    assert {:error, :manifest_drift} = Runs.retry_run(run)

    assert Runs.get_run!(run.id).status == "failed"
  end

  test "retry rejects an invalid next-attempt manifest before changing the run", %{
    project: project,
    session: session
  } do
    {:ok, run} = create_run(project, session)
    {:ok, failed} = Runs.transition_run(run, "failed")

    assert {:error, :duplicate_step_key} =
             Runs.retry_run(failed,
               steps: [
                 %{key: "retry", kind: "prepare", title: "First"},
                 %{key: "retry", kind: "execute", title: "Second"}
               ]
             )

    persisted = Runs.get_run!(run.id)
    assert persisted.status == "failed"
    assert persisted.event_sequence == 2
    assert Runs.list_steps(run) == []
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

  test "provider-reported usage accumulates and emits token-budget exhaustion", %{
    project: project,
    session: session
  } do
    {:ok, run} = create_run(project, session, %{token_budget: 100})

    assert {:ok, updated} =
             Runs.record_usage(run, %{prompt_tokens: 30, completion_tokens: 20}, "planner.llm")

    assert updated.input_tokens == 30
    assert updated.output_tokens == 20

    assert {:error, {:token_budget_exhausted, exhausted}} =
             Runs.record_usage(
               run,
               %{"input_tokens" => 40, "output_tokens" => 20},
               "coder.llm"
             )

    assert exhausted.input_tokens == 70
    assert exhausted.output_tokens == 40

    assert Enum.map(Runs.list_events(run), & &1.type) |> Enum.take(-3) == [
             "run.usage_recorded",
             "run.usage_recorded",
             "run.budget_exhausted"
           ]
  end

  test "records total-only provider usage without double counting detailed usage", %{
    project: project,
    session: session
  } do
    {:ok, bounded} = create_run(project, session, %{token_budget: 40})

    assert {:error, {:token_budget_exhausted, exhausted}} =
             Runs.record_usage(bounded, %{"total_tokens" => 50})

    assert exhausted.input_tokens == 50
    assert exhausted.output_tokens == 0

    {:ok, run} = create_run(project, session, %{token_budget: 1_000})

    assert {:ok, total_only} = Runs.record_usage(run, %{"total_tokens" => 50})
    assert total_only.input_tokens == 50
    assert total_only.output_tokens == 0

    assert {:ok, detailed} =
             Runs.record_usage(run, %{
               "prompt_tokens" => 10,
               "completion_tokens" => 5,
               "total_tokens" => 15
             })

    assert detailed.input_tokens == 60
    assert detailed.output_tokens == 5
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
               arguments: %{"path" => "lib/example.ex"},
               status: "completed",
               attempt: 9,
               output: "forged output",
               error_message: "forged error",
               error_details: %{"credential" => "must not persist"},
               claimed_at: DateTime.utc_now(),
               heartbeat_at: DateTime.utc_now(),
               completed_at: DateTime.utc_now()
             })

    assert command.status == "queued"
    assert command.attempt == 0
    assert is_nil(command.output)
    assert is_nil(command.error_message)
    assert is_nil(command.error_details)
    assert is_nil(command.claimed_at)
    assert is_nil(command.heartbeat_at)
    assert is_nil(command.completed_at)

    assert {:ok, same_command} =
             Runs.enqueue_command(run, "write:lib/example.ex", %{
               tool_name: "write_file",
               arguments: %{"path" => "lib/example.ex"},
               status: "failed",
               attempt: 100,
               error_message: "different ignored lifecycle"
             })

    assert same_command.id == command.id

    assert {:error, :idempotency_conflict} =
             Runs.enqueue_command(run, "write:lib/example.ex", %{
               tool_name: "run_command",
               arguments: %{"command" => "rm -rf /"}
             })

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

  test "run controls are ordered, idempotent, claimed, resolved, and journaled", %{
    project: project,
    session: session
  } do
    {:ok, run} = create_run(project, session)
    :ok = Runs.subscribe(run)

    attrs = %{kind: "steer", payload: %{"guidance" => "Prefer primary sources"}}
    assert {:ok, pending} = Runs.enqueue_control(run, "ui:steer:one", attrs)
    assert pending.sequence == 1
    assert pending.status == "pending"

    assert {:ok, duplicate} = Runs.enqueue_control(run, "ui:steer:one", attrs)
    assert duplicate.id == pending.id

    assert {:error, :idempotency_conflict} =
             Runs.enqueue_control(run, "ui:steer:one", %{
               kind: "cancel",
               payload: %{"unsafe" => true}
             })

    assert_receive {:run_control_enqueued, %{id: control_id}}
    assert control_id == pending.id

    assert {:ok, claimed} = Runs.claim_next_control(run, "dispatcher:test")
    assert claimed.status == "claimed"
    assert claimed.worker_id == "dispatcher:test"
    assert claimed.claimed_at

    assert {:ok, applied} =
             Runs.resolve_control(claimed, "applied", %{"phase" => "research.search"},
               run_id: run.id,
               worker_id: "dispatcher:test",
               kind: "steer"
             )

    assert applied.status == "applied"
    assert applied.result == %{"phase" => "research.search"}
    assert applied.applied_at
    assert [^applied] = Runs.list_controls(run)
    assert :none = Runs.claim_next_control(run, "dispatcher:test")

    assert Enum.map(Runs.list_events(run), & &1.type) |> Enum.take(-3) == [
             "run.control_enqueued",
             "run.control_claimed",
             "run.control_applied"
           ]
  end

  test "run controls reject secret payloads and terminal targets", %{
    project: project,
    session: session
  } do
    {:ok, run} = create_run(project, session)

    assert {:error, :secret_payload_forbidden} =
             Runs.enqueue_control(run, "secret-steer", %{
               kind: "steer",
               payload: %{"nested" => [%{"access_token" => "do-not-store"}]}
             })

    assert Runs.list_controls(run) == []
    assert {:ok, completed} = Runs.transition_run(run, "completed")

    assert {:error, {:run_not_controllable, "completed"}} =
             Runs.enqueue_control(completed, "late-pause", %{kind: "pause"})
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

  test "retry supersedes controls claimed by a prior attempt", %{
    project: project,
    session: session
  } do
    {:ok, _run} = create_run(project, session, %{max_attempts: 2})
    {:ok, claimed_run} = Runs.claim_next_run("dispatcher-a")
    {:ok, pending} = Runs.enqueue_control(claimed_run, "old:pause", %{kind: "pause"})
    assert {:ok, claimed_control} = Runs.claim_control(pending, "dispatcher-a")
    assert {:ok, failed} = Runs.transition_run(claimed_run, "failed")

    assert {:ok, _queued} = Runs.retry_run(failed)

    superseded = Runs.get_control(claimed_control.id)
    assert superseded.status == "superseded"
    assert superseded.result == %{"reason" => "run_retried"}
    assert Enum.any?(Runs.list_events(failed), &(&1.type == "run.control_superseded"))
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

    assert {:ok, first_control} =
             Runs.enqueue_control(claimed, "orphan:pause", %{kind: "pause"})

    assert {:ok, claimed_control} = Runs.claim_control(first_control, "dispatcher-a")

    assert {:ok, pending_control} =
             Runs.enqueue_control(claimed, "orphan:steer", %{
               kind: "steer",
               payload: %{"guidance" => "still pending"}
             })

    expired = DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:second)

    Repo.update_all(from(r in IexCode.Runs.Run, where: r.id == ^claimed.id),
      set: [lease_expires_at: expired]
    )

    assert [%{id: id, status: "interrupted"}] = Runs.reconcile_orphaned_runs()
    assert id == claimed.id
    assert Runs.get_control(claimed_control.id).status == "superseded"
    assert Runs.get_control(pending_control.id).status == "superseded"
    assert Runs.get_control(pending_control.id).result == %{"reason" => "run_interrupted"}
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
