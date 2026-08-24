defmodule IexCode.Runs do
  @moduledoc """
  Durable persistence boundary for asynchronous coding runs.

  Status changes and events are committed before they are published. Event sequence
  allocation is performed by an atomic update of the parent run inside the same
  database transaction as the event insert, making `(run_id, sequence)` monotonic
  and unique even with concurrent SQLite writers.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias IexCode.Repo

  alias IexCode.Runs.{
    Run,
    RunApproval,
    RunArtifact,
    RunCommand,
    RunControl,
    RunEvent,
    RunStep,
    WorkspaceLock
  }

  @max_event_payload_bytes 256_000
  @max_replay_events 10_000

  @run_transitions %{
    "queued" => ~w(running paused completed failed cancelled interrupted),
    "running" => ~w(paused completed failed cancelled interrupted),
    "paused" => ~w(running completed failed cancelled interrupted),
    "interrupted" => ~w(queued running paused failed cancelled),
    "completed" => [],
    "failed" => [],
    "cancelled" => []
  }

  @step_transitions %{
    "pending" =>
      ~w(ready running paused waiting_approval blocked completed failed cancelled skipped interrupted),
    "ready" =>
      ~w(running paused waiting_approval blocked completed failed cancelled skipped interrupted),
    "running" => ~w(paused waiting_approval blocked completed failed cancelled interrupted),
    "paused" => ~w(ready running blocked completed failed cancelled interrupted),
    "waiting_approval" => ~w(ready running blocked failed cancelled interrupted),
    "blocked" => ~w(ready running failed cancelled skipped interrupted),
    "interrupted" => ~w(pending ready running paused blocked failed cancelled skipped),
    "completed" => [],
    "failed" => [],
    "cancelled" => [],
    "skipped" => []
  }

  @command_transitions %{
    "queued" => ~w(claimed running waiting_approval completed failed cancelled interrupted),
    "claimed" => ~w(running queued waiting_approval completed failed cancelled interrupted),
    "running" => ~w(waiting_approval completed failed cancelled interrupted),
    "waiting_approval" => ~w(queued claimed running failed cancelled interrupted),
    "interrupted" => ~w(queued claimed running failed cancelled),
    "completed" => [],
    "failed" => [],
    "cancelled" => []
  }

  # Runs

  def create_run(attrs) when is_map(attrs), do: create_run_with_steps(attrs, [])

  @doc "Creates a run and its initial graph nodes in one transaction."
  def create_run_with_steps(attrs, steps) when is_map(attrs) and is_list(steps) do
    with {:ok, project_id} <- required_id(attrs, :project_id),
         {:ok, session_id} <- required_id(attrs, :session_id),
         :ok <- validate_session_project(session_id, project_id),
         {:ok, payload} <- bounded_payload(%{"objective" => attr(attrs, :objective)}) do
      attrs = drop_keys(attrs, [:project_id, :session_id])

      result =
        Repo.retry_on_busy(fn ->
          Repo.transaction(fn ->
            run =
              case %Run{project_id: project_id, session_id: session_id}
                   |> Run.changeset(attrs)
                   |> Repo.insert() do
                {:ok, run} -> run
                {:error, changeset} -> Repo.rollback(changeset)
              end

            created_event = insert_event_in_transaction!(run.id, "run.created", "system", payload)

            {initial_steps, step_events} =
              steps
              |> Enum.with_index()
              |> Enum.map_reduce([], fn {step_attrs, position}, events ->
                step_attrs =
                  step_attrs
                  |> drop_keys([:run_id])
                  |> put_attr_new(:position, position)

                step =
                  case %RunStep{run_id: run.id}
                       |> RunStep.changeset(step_attrs)
                       |> Repo.insert() do
                    {:ok, step} -> step
                    {:error, changeset} -> Repo.rollback(changeset)
                  end

                event =
                  insert_event_in_transaction!(run.id, "run.step_created", "system", %{
                    "step_id" => step.id,
                    "key" => step.key,
                    "status" => step.status
                  })

                {step, [event | events]}
              end)

            {Repo.get!(Run, run.id), initial_steps, [created_event | Enum.reverse(step_events)]}
          end)
        end)

      case result do
        {:ok, {run, initial_steps, events}} ->
          broadcast(run.id, {:run_created, run})
          Enum.each(initial_steps, &broadcast(run.id, {:run_step_created, &1}))
          Enum.each(events, &broadcast(run.id, {:run_event, &1}))
          {:ok, run}

        {:error, %Changeset{} = changeset} ->
          {:error, changeset}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def get_run(id) when is_binary(id), do: Repo.get(Run, id)
  def get_run(_id), do: nil
  def get_run!(id), do: Repo.get!(Run, id)

  def list_runs(opts \\ [])

  def list_runs(session_id) when is_binary(session_id), do: list_runs(session_id: session_id)

  def list_runs(opts) when is_list(opts) do
    Run
    |> maybe_where(:project_id, opts[:project_id])
    |> maybe_where(:session_id, opts[:session_id])
    |> maybe_where(:status, opts[:status])
    |> order_by([r], desc: r.inserted_at, desc: r.id)
    |> limit(^bounded_limit(opts[:limit], 100, 1_000))
    |> Repo.all()
  end

  def latest_run(filter \\ [])

  def latest_run(session_id) when is_binary(session_id), do: latest_run(session_id: session_id)

  def latest_run(opts) when is_list(opts) do
    opts |> Keyword.put(:limit, 1) |> list_runs() |> List.first()
  end

  def transition_run(run_or_id, new_status, attrs \\ %{})

  def transition_run(%Run{} = run, new_status, attrs),
    do: do_transition_run(run, to_string(new_status), attrs)

  def transition_run(id, new_status, attrs) when is_binary(id) do
    case get_run(id) do
      nil -> {:error, :not_found}
      run -> do_transition_run(run, to_string(new_status), attrs)
    end
  end

  def heartbeat_run(run_or_id, attrs \\ %{}) do
    now = now()
    attrs = Map.merge(normalize_attrs(attrs), %{heartbeat_at: now})

    update_run_with_event(run_or_id, attrs, "run.heartbeat", "worker", %{})
  end

  @doc "Persists bounded progress and its journal event in one transaction."
  def record_progress(run_or_id, percent, message, source \\ "worker")

  def record_progress(run_or_id, percent, message, source)
      when is_integer(percent) and percent >= 0 and percent <= 100 do
    case resolve_run(run_or_id) do
      %Run{status: status} = run when status in ["running", "paused"] ->
        update_run_with_event(
          run,
          %{progress: percent, heartbeat_at: now()},
          "run.progress",
          to_string(source),
          %{"percent" => percent, "message" => to_string(message)}
        )

      %Run{status: status} ->
        {:error, {:run_not_active, status}}

      nil ->
        {:error, :not_found}
    end
  end

  def record_progress(_run_or_id, _percent, _message, _source),
    do: {:error, :invalid_progress}

  @doc "Atomically records provider-reported token usage and checks the run token budget."
  def record_usage(run_or_id, usage, source \\ "llm")

  def record_usage(run_or_id, usage, source) when is_map(usage) do
    with %Run{} = run <- resolve_run(run_or_id) do
      input = usage_integer(usage, [:prompt_tokens, :input_tokens])
      output = usage_integer(usage, [:completion_tokens, :output_tokens])
      total_only = usage_integer(usage, [:total_tokens])

      {input, output} =
        if input + output == 0 and total_only > 0, do: {total_only, 0}, else: {input, output}

      result =
        Repo.retry_on_busy(fn ->
          Repo.transaction(fn ->
            current = Repo.get!(Run, run.id)
            new_input = current.input_tokens + input
            new_output = current.output_tokens + output
            total = new_input + new_output
            exhausted? = is_integer(current.token_budget) and total > current.token_budget

            usage_attrs = %{input_tokens: new_input, output_tokens: new_output}

            usage_attrs =
              if exhausted? and current.status in ["running", "paused"] do
                Map.merge(usage_attrs, %{
                  status: "failed",
                  completed_at: now(),
                  error_message:
                    "Run exceeded its #{current.token_budget}-token provider-reported budget",
                  error_details: %{
                    "reason" => "budget_exhausted",
                    "budget" => "tokens",
                    "limit" => current.token_budget,
                    "actual" => total
                  }
                })
              else
                usage_attrs
              end

            updated = current |> Run.changeset(usage_attrs) |> Repo.update!()

            usage_event =
              insert_event_in_transaction!(run.id, "run.usage_recorded", to_string(source), %{
                "input_tokens" => input,
                "output_tokens" => output,
                "total_tokens" => total,
                "token_budget" => current.token_budget
              })

            budget_event =
              if exhausted? do
                insert_event_in_transaction!(run.id, "run.budget_exhausted", "budget", %{
                  "budget" => "tokens",
                  "limit" => current.token_budget,
                  "actual" => total
                })
              end

            status_event =
              if updated.status != current.status do
                insert_event_in_transaction!(run.id, "run.status_changed", "budget", %{
                  "from" => current.status,
                  "to" => updated.status
                })
              end

            {updated, usage_event, budget_event, status_event, exhausted?}
          end)
        end)

      case result do
        {:ok, {updated, usage_event, budget_event, status_event, exhausted?}} ->
          broadcast(updated.id, {:run_updated, updated})
          broadcast(updated.id, {:run_event, usage_event})
          if budget_event, do: broadcast(updated.id, {:run_event, budget_event})
          if status_event, do: broadcast(updated.id, {:run_event, status_event})

          if exhausted? do
            {:error, {:token_budget_exhausted, updated}}
          else
            {:ok, updated}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
    end
  end

  def record_usage(_run_or_id, _usage, _source), do: {:error, :invalid_usage}

  @doc """
  Atomically claims the highest-priority due run for `lease_owner`.

  A project may have at most one active (`running` or `paused`) run. The
  exclusivity predicate is part of the conditional update, so competing
  dispatchers cannot both claim runs for the same project.
  """
  def claim_next_run(lease_owner, opts \\ [])

  def claim_next_run(lease_owner, opts) when is_binary(lease_owner) and is_list(opts) do
    lease_ms = positive_integer(opts[:lease_ms], 30_000)
    excluded_project_ids = Enum.filter(opts[:exclude_project_ids] || [], &is_binary/1)
    now = now()
    lease_expires_at = DateTime.add(now, lease_ms, :millisecond)

    result =
      Repo.retry_on_busy(fn ->
        Repo.transaction(fn ->
          active_projects =
            from(active in Run,
              where:
                active.status in ["running", "paused"] or
                  (not is_nil(active.lease_owner) and
                     (is_nil(active.lease_expires_at) or active.lease_expires_at > ^now)),
              select: active.project_id
            )

          candidate_query =
            from(run in Run,
              where: run.status == "queued",
              where: run.attempt < run.max_attempts,
              where: is_nil(run.cancellation_requested_at),
              where: is_nil(run.not_before) or run.not_before <= ^now,
              where: run.project_id not in subquery(active_projects),
              order_by: [
                asc:
                  fragment(
                    "CASE WHEN ? = 'critical' THEN 0 WHEN ? = 'high' THEN 1 WHEN ? = 'normal' THEN 2 ELSE 3 END",
                    run.priority,
                    run.priority,
                    run.priority
                  ),
                asc: run.inserted_at,
                asc: run.id
              ],
              limit: 1
            )

          candidate_query =
            if excluded_project_ids == [] do
              candidate_query
            else
              from(run in candidate_query, where: run.project_id not in ^excluded_project_ids)
            end

          case Repo.one(candidate_query) do
            nil ->
              nil

            candidate ->
              {updated_count, _} =
                from(run in Run,
                  where: run.id == ^candidate.id,
                  where: run.status == "queued",
                  where: run.attempt < run.max_attempts,
                  where: is_nil(run.cancellation_requested_at),
                  where: run.project_id not in subquery(active_projects)
                )
                |> Repo.update_all(
                  set: [
                    status: "running",
                    lease_owner: lease_owner,
                    lease_expires_at: lease_expires_at,
                    heartbeat_at: now,
                    started_at: candidate.started_at || now,
                    updated_at: now
                  ],
                  inc: [attempt: 1]
                )

              if updated_count == 1 do
                claimed = Repo.get!(Run, candidate.id)

                event =
                  insert_event_in_transaction!(claimed.id, "run.claimed", lease_owner, %{
                    "attempt" => claimed.attempt,
                    "lease_expires_at" => DateTime.to_iso8601(lease_expires_at)
                  })

                {claimed, event}
              else
                nil
              end
          end
        end)
      end)

    case result do
      {:ok, nil} ->
        :none

      {:ok, {run, event}} ->
        broadcast(run.id, {:run_updated, run})
        broadcast(run.id, {:run_event, event})
        {:ok, run}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def claim_next_run(_lease_owner, _opts), do: {:error, :invalid_lease_owner}

  @doc "Renews a live run lease only when the caller still owns it."
  def renew_lease(run_id, lease_owner, lease_ms \\ 30_000)
      when is_binary(run_id) and is_binary(lease_owner) do
    now = now()
    lease_expires_at = DateTime.add(now, positive_integer(lease_ms, 30_000), :millisecond)

    {count, _} =
      from(run in Run,
        where: run.id == ^run_id,
        where: run.status in ["running", "paused"],
        where: run.lease_owner == ^lease_owner,
        where: is_nil(run.cancellation_requested_at)
      )
      |> Repo.update_all(
        set: [heartbeat_at: now, lease_expires_at: lease_expires_at, updated_at: now]
      )

    case count do
      1 ->
        run = Repo.get!(Run, run_id)
        broadcast(run.id, {:run_updated, run})
        {:ok, run}

      0 ->
        {:error, :lease_not_owned}
    end
  end

  @doc "Releases a run lease only when the caller owns it."
  def release_lease(run_id, lease_owner) when is_binary(run_id) and is_binary(lease_owner) do
    now = now()

    {count, _} =
      from(run in Run,
        where: run.id == ^run_id,
        where: run.lease_owner == ^lease_owner
      )
      |> Repo.update_all(
        set: [lease_owner: nil, lease_expires_at: nil, heartbeat_at: now, updated_at: now]
      )

    case count do
      1 ->
        run = Repo.get!(Run, run_id)
        broadcast(run.id, {:run_updated, run})
        {:ok, run}

      0 ->
        {:error, :lease_not_owned}
    end
  end

  @doc "Marks active runs with missing/expired leases interrupted and emits events."
  def reconcile_orphaned_runs(opts \\ []) when is_list(opts) do
    before = opts[:expired_before] || now()
    lease_owner = opts[:lease_owner]

    query =
      from(run in Run,
        where: run.status in ["running", "paused"],
        where: is_nil(run.lease_expires_at) or run.lease_expires_at <= ^before,
        order_by: [asc: run.inserted_at]
      )

    query =
      if is_binary(lease_owner) do
        from(run in query, where: run.lease_owner == ^lease_owner)
      else
        query
      end

    query
    |> Repo.all()
    |> Enum.reduce([], fn run, interrupted ->
      case interrupt_if_orphaned(run.id, before) do
        {:ok, updated} -> [updated | interrupted]
        _ -> interrupted
      end
    end)
    |> Enum.reverse()
  end

  @doc "Retries a terminal/interrupted run and optionally appends next-attempt steps atomically."
  def retry_run(run_or_id, opts \\ []) when is_list(opts) do
    with %Run{} = run <- resolve_run(run_or_id) do
      steps = opts[:steps] || []

      result =
        Repo.retry_on_busy(fn ->
          Repo.transaction(fn ->
            current = Repo.get!(Run, run.id)

            cond do
              active_lease?(current, now()) ->
                Repo.rollback(:run_still_leased)

              current.status not in ["failed", "cancelled", "interrupted"] ->
                Repo.rollback({:invalid_transition, current.status, "queued"})

              current.attempt >= current.max_attempts ->
                Repo.rollback(:attempts_exhausted)

              true ->
                {superseded_controls, control_events} =
                  supersede_controls_in_transaction!(current.id, %{}, "run_retried")

                retry_attrs = %{
                  status: "queued",
                  progress: 0,
                  lease_owner: nil,
                  lease_expires_at: nil,
                  heartbeat_at: nil,
                  completed_at: nil,
                  cancellation_requested_at: nil,
                  error_message: nil,
                  error_details: nil
                }

                updated =
                  case current |> Run.changeset(retry_attrs) |> Repo.update() do
                    {:ok, updated} -> updated
                    {:error, changeset} -> Repo.rollback(changeset)
                  end

                retry_event =
                  insert_event_in_transaction!(updated.id, "run.retried", "system", %{
                    "attempt" => updated.attempt,
                    "max_attempts" => updated.max_attempts
                  })

                {initial_steps, step_events} = insert_initial_steps!(updated.id, steps)

                {Repo.get!(Run, updated.id), initial_steps, superseded_controls,
                 control_events ++ [retry_event | step_events]}
            end
          end)
        end)

      case result do
        {:ok, {updated, initial_steps, superseded_controls, events}} ->
          broadcast(updated.id, {:run_updated, updated})
          Enum.each(initial_steps, &broadcast(updated.id, {:run_step_created, &1}))
          Enum.each(superseded_controls, &broadcast(updated.id, {:run_control_updated, &1}))
          Enum.each(events, &broadcast(updated.id, {:run_event, &1}))
          {:ok, updated}

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
    end
  end

  @doc "Persists cooperative cancellation intent without racing the dispatcher."
  def request_cancellation(run_or_id, source \\ "user") do
    with %Run{} = run <- resolve_run(run_or_id) do
      if run.status in ["completed", "failed", "cancelled"] do
        {:error, {:invalid_transition, run.status, "cancellation_requested"}}
      else
        update_run_with_event(
          run,
          %{cancellation_requested_at: now()},
          "run.cancellation_requested",
          source,
          %{}
        )
      end
    else
      nil -> {:error, :not_found}
    end
  end

  def subscribe_session(session_id) when is_binary(session_id) do
    Phoenix.PubSub.subscribe(IexCode.PubSub, session_topic(session_id))
  end

  # Steps

  def create_step(run_or_id, attrs) when is_map(attrs) do
    with %Run{} = run <- resolve_run(run_or_id) do
      attrs = drop_keys(attrs, [:run_id])

      result =
        Repo.retry_on_busy(fn ->
          Repo.transaction(fn ->
            step =
              case %RunStep{run_id: run.id} |> RunStep.changeset(attrs) |> Repo.insert() do
                {:ok, step} -> step
                {:error, changeset} -> Repo.rollback(changeset)
              end

            event =
              insert_event_in_transaction!(run.id, "run.step_created", "system", %{
                "step_id" => step.id,
                "key" => step.key,
                "status" => step.status
              })

            {step, event}
          end)
        end)

      case result do
        {:ok, {step, event}} ->
          broadcast(run.id, {:run_step_created, step})
          broadcast(run.id, {:run_event, event})
          {:ok, step}

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
    end
  end

  def get_step(id) when is_binary(id), do: Repo.get(RunStep, id)
  def get_step(_id), do: nil
  def get_step!(id), do: Repo.get!(RunStep, id)

  def list_steps(run_or_id) do
    with %Run{} = run <- resolve_run(run_or_id) do
      RunStep
      |> where([s], s.run_id == ^run.id)
      |> order_by([s], asc: s.position, asc: s.inserted_at, asc: s.id)
      |> Repo.all()
    else
      nil -> []
    end
  end

  def transition_step(step_or_id, new_status, attrs \\ %{})

  def transition_step(%RunStep{} = step, new_status, attrs),
    do: do_transition_step(step, to_string(new_status), attrs)

  def transition_step(id, new_status, attrs) when is_binary(id) do
    case get_step(id) do
      nil -> {:error, :not_found}
      step -> do_transition_step(step, to_string(new_status), attrs)
    end
  end

  # Events

  def append_event(run_or_id, type, payload \\ %{}, source \\ "system") do
    with %Run{} = run <- resolve_run(run_or_id),
         {:ok, payload} <- bounded_payload(payload),
         :ok <- validate_event_label(type, source) do
      transaction_result =
        Repo.retry_on_busy(fn ->
          Repo.transaction(fn ->
            {1, _} =
              from(r in Run, where: r.id == ^run.id)
              |> Repo.update_all(inc: [event_sequence: 1])

            sequence =
              from(r in Run, where: r.id == ^run.id, select: r.event_sequence)
              |> Repo.one!()

            %RunEvent{run_id: run.id}
            |> RunEvent.changeset(%{
              sequence: sequence,
              type: to_string(type),
              source: to_string(source),
              payload: payload,
              occurred_at: now()
            })
            |> Repo.insert!()
          end)
        end)

      case transaction_result do
        {:ok, event} ->
          broadcast(run.id, {:run_event, event})
          {:ok, event}

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def list_events(run_or_id, opts \\ []) when is_list(opts) do
    with %Run{} = run <- resolve_run(run_or_id) do
      after_sequence = nonnegative(opts[:after_sequence], 0)
      limit = bounded_limit(opts[:limit], 500, @max_replay_events)

      RunEvent
      |> where([e], e.run_id == ^run.id and e.sequence > ^after_sequence)
      |> maybe_where(:type, opts[:type])
      |> order_by([e], asc: e.sequence)
      |> limit(^limit)
      |> Repo.all()
    else
      nil -> []
    end
  end

  @doc """
  Returns the newest bounded window of a run journal in chronological order.

  The database query orders newest-first so the limit applies to the tail,
  then the result is reversed for rendering and replay consumers. Use
  `list_events/2` or `replay_events/3` for forward cursor traversal.
  """
  def list_latest_events(run_or_id, opts \\ []) when is_list(opts) do
    with %Run{} = run <- resolve_run(run_or_id) do
      limit = bounded_limit(opts[:limit], 500, @max_replay_events)

      RunEvent
      |> where([e], e.run_id == ^run.id)
      |> maybe_where(:type, opts[:type])
      |> order_by([e], desc: e.sequence)
      |> limit(^limit)
      |> Repo.all()
      |> Enum.reverse()
    else
      nil -> []
    end
  end

  def latest_event(run_or_id) do
    with %Run{} = run <- resolve_run(run_or_id) do
      RunEvent
      |> where([e], e.run_id == ^run.id)
      |> order_by([e], desc: e.sequence)
      |> limit(1)
      |> Repo.one()
    else
      nil -> nil
    end
  end

  def replay_events(run_or_id, from_sequence \\ 1, opts \\ []) when is_list(opts) do
    with %Run{} = run <- resolve_run(run_or_id) do
      from_sequence = max(nonnegative(from_sequence, 1), 1)
      to_sequence = opts[:to_sequence]
      limit = bounded_limit(opts[:limit], @max_replay_events, @max_replay_events)

      query =
        from(e in RunEvent,
          where: e.run_id == ^run.id and e.sequence >= ^from_sequence,
          order_by: [asc: e.sequence],
          limit: ^limit
        )

      query =
        if is_integer(to_sequence) and to_sequence >= from_sequence do
          from(e in query, where: e.sequence <= ^to_sequence)
        else
          query
        end

      Repo.all(query)
    else
      nil -> []
    end
  end

  def subscribe(run_or_id) do
    with %Run{} = run <- resolve_run(run_or_id) do
      Phoenix.PubSub.subscribe(IexCode.PubSub, topic(run.id))
    else
      nil -> {:error, :not_found}
    end
  end

  # Durable run controls

  @doc "Enqueues a run-scoped control exactly once and appends its journal event atomically."
  def enqueue_control(run_or_id, idempotency_key, attrs) when is_map(attrs) do
    with %Run{} = run <- resolve_run(run_or_id),
         {:ok, payload} <- bounded_payload(attr(attrs, :payload) || %{}) do
      idempotency_key = to_string(idempotency_key)

      result =
        Repo.retry_on_busy(fn ->
          Repo.transaction(fn ->
            case Repo.get_by(RunControl,
                   run_id: run.id,
                   idempotency_key: idempotency_key
                 ) do
              %RunControl{} = existing ->
                {existing, nil}

              nil ->
                {1, _} =
                  from(current in Run, where: current.id == ^run.id)
                  |> Repo.update_all(inc: [control_sequence: 1])

                sequence =
                  from(current in Run,
                    where: current.id == ^run.id,
                    select: current.control_sequence
                  )
                  |> Repo.one!()

                control_attrs =
                  attrs
                  |> drop_keys([:run_id, :idempotency_key, :sequence, :status, :payload])
                  |> put_attr(:idempotency_key, idempotency_key)
                  |> put_attr(:sequence, sequence)
                  |> put_attr(:status, "pending")
                  |> put_attr(:payload, payload)

                control =
                  case %RunControl{run_id: run.id}
                       |> RunControl.changeset(control_attrs)
                       |> Repo.insert() do
                    {:ok, control} -> control
                    {:error, changeset} -> Repo.rollback(changeset)
                  end

                event =
                  insert_event_in_transaction!(run.id, "run.control_enqueued", "control", %{
                    "control_id" => control.id,
                    "control_sequence" => control.sequence,
                    "kind" => control.kind,
                    "requested_by" => control.requested_by
                  })

                {control, event}
            end
          end)
        end)

      case result do
        {:ok, {control, nil}} ->
          {:ok, control}

        {:ok, {control, event}} ->
          broadcast(run.id, {:run_control_enqueued, control})
          broadcast(run.id, {:run_event, event})
          {:ok, control}

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def get_control(id) when is_binary(id), do: Repo.get(RunControl, id)
  def get_control(_id), do: nil

  def get_control_by_idempotency_key(run_or_id, key) do
    with %Run{} = run <- resolve_run(run_or_id) do
      Repo.get_by(RunControl, run_id: run.id, idempotency_key: to_string(key))
    else
      nil -> nil
    end
  end

  def list_controls(run_or_id, opts \\ []) when is_list(opts) do
    with %Run{} = run <- resolve_run(run_or_id) do
      RunControl
      |> where([control], control.run_id == ^run.id)
      |> maybe_where(:status, opts[:status])
      |> maybe_where(:kind, opts[:kind])
      |> order_by([control], asc: control.sequence)
      |> limit(^bounded_limit(opts[:limit], 200, 1_000))
      |> Repo.all()
    else
      nil -> []
    end
  end

  @doc "Supersedes every pending/claimed control owned by a dispatcher identity."
  def supersede_claimed_controls(worker_id, reason)
      when is_binary(worker_id) and worker_id != "" and is_binary(reason) do
    supersede_controls(%{status: "claimed", worker_id: worker_id}, reason)
  end

  @doc "Supersedes every non-terminal control for one run."
  def supersede_open_controls(run_or_id, reason) when is_binary(reason) do
    with %Run{} = run <- resolve_run(run_or_id) do
      supersede_controls(%{run_id: run.id}, reason)
    else
      nil -> {:error, :not_found}
    end
  end

  @doc "Claims the next pending control for a run using a conditional state update."
  def claim_next_control(run_or_id, worker_id) when is_binary(worker_id) and worker_id != "" do
    with %Run{} = run <- resolve_run(run_or_id) do
      result =
        Repo.retry_on_busy(fn ->
          Repo.transaction(fn ->
            candidate =
              RunControl
              |> where([control], control.run_id == ^run.id and control.status == "pending")
              |> order_by([control], asc: control.sequence)
              |> limit(1)
              |> Repo.one()

            case candidate do
              nil ->
                nil

              candidate ->
                claimed_at = now()

                {count, _} =
                  from(control in RunControl,
                    where: control.id == ^candidate.id and control.status == "pending"
                  )
                  |> Repo.update_all(
                    set: [
                      status: "claimed",
                      worker_id: worker_id,
                      claimed_at: claimed_at,
                      updated_at: claimed_at
                    ]
                  )

                if count == 1 do
                  claimed = Repo.get!(RunControl, candidate.id)

                  event =
                    insert_event_in_transaction!(run.id, "run.control_claimed", "control", %{
                      "control_id" => claimed.id,
                      "control_sequence" => claimed.sequence,
                      "kind" => claimed.kind,
                      "worker_id" => worker_id
                    })

                  {claimed, event}
                else
                  Repo.rollback(:claim_race)
                end
            end
          end)
        end)

      case result do
        {:ok, nil} ->
          :none

        {:ok, {control, event}} ->
          broadcast(run.id, {:run_control_updated, control})
          broadcast(run.id, {:run_event, event})
          {:ok, control}

        {:error, :claim_race} ->
          claim_next_control(run, worker_id)

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
    end
  end

  def claim_next_control(_run_or_id, _worker_id), do: {:error, :invalid_worker_id}

  @doc "Claims one exact pending control without consuming another caller's request."
  def claim_control(control_or_id, worker_id) when is_binary(worker_id) and worker_id != "" do
    control_id =
      if match?(%RunControl{}, control_or_id), do: control_or_id.id, else: control_or_id

    result =
      Repo.retry_on_busy(fn ->
        Repo.transaction(fn ->
          case Repo.get(RunControl, control_id) do
            nil ->
              Repo.rollback(:not_found)

            %RunControl{status: "pending"} = current ->
              claimed_at = now()

              {count, _} =
                from(control in RunControl,
                  where: control.id == ^current.id and control.status == "pending"
                )
                |> Repo.update_all(
                  set: [
                    status: "claimed",
                    worker_id: worker_id,
                    claimed_at: claimed_at,
                    updated_at: claimed_at
                  ]
                )

              if count == 1 do
                claimed = Repo.get!(RunControl, current.id)

                event =
                  insert_event_in_transaction!(
                    claimed.run_id,
                    "run.control_claimed",
                    "control",
                    %{
                      "control_id" => claimed.id,
                      "control_sequence" => claimed.sequence,
                      "kind" => claimed.kind,
                      "worker_id" => worker_id
                    }
                  )

                {claimed, event}
              else
                Repo.rollback(:claim_race)
              end

            %RunControl{} = current ->
              Repo.rollback({:invalid_transition, current.status, "claimed"})
          end
        end)
      end)

    case result do
      {:ok, {control, event}} ->
        broadcast(control.run_id, {:run_control_updated, control})
        broadcast(control.run_id, {:run_event, event})
        {:ok, control}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def claim_control(_control_or_id, _worker_id), do: {:error, :invalid_worker_id}

  @doc "Records the durable outcome of a claimed control."
  def resolve_control(control_or_id, status, result \\ %{})

  def resolve_control(control_or_id, status, result)
      when status in ["applied", "rejected", "superseded"] and is_map(result) do
    control_id =
      if match?(%RunControl{}, control_or_id), do: control_or_id.id, else: control_or_id

    transaction =
      Repo.retry_on_busy(fn ->
        Repo.transaction(fn ->
          case Repo.get(RunControl, control_id) do
            nil ->
              Repo.rollback(:not_found)

            %RunControl{status: current_status} = current
            when current_status == "claimed" or
                   (status == "superseded" and current_status == "pending") ->
              attrs = %{status: status, applied_at: now(), result: result}

              updated =
                case current |> RunControl.changeset(attrs) |> Repo.update() do
                  {:ok, updated} -> updated
                  {:error, changeset} -> Repo.rollback(changeset)
                end

              event =
                insert_event_in_transaction!(
                  updated.run_id,
                  "run.control_#{status}",
                  "control",
                  %{
                    "control_id" => updated.id,
                    "control_sequence" => updated.sequence,
                    "kind" => updated.kind,
                    "result" => result
                  }
                )

              {updated, event}

            %RunControl{} = current ->
              Repo.rollback({:invalid_transition, current.status, status})
          end
        end)
      end)

    case transaction do
      {:ok, {control, event}} ->
        broadcast(control.run_id, {:run_control_updated, control})
        broadcast(control.run_id, {:run_event, event})
        {:ok, control}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def resolve_control(_control_or_id, status, _result),
    do: {:error, {:invalid_control_status, status}}

  defp supersede_controls(filters, reason) do
    result =
      Repo.retry_on_busy(fn ->
        Repo.transaction(fn ->
          supersede_controls_in_transaction!(filters[:run_id], filters, reason)
        end)
      end)

    case result do
      {:ok, {controls, events}} ->
        Enum.each(controls, &broadcast(&1.run_id, {:run_control_updated, &1}))
        Enum.each(events, &broadcast(&1.run_id, {:run_event, &1}))
        {:ok, controls}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp supersede_controls_in_transaction!(run_id, filters, reason) do
    query =
      RunControl
      |> where([control], control.status in ["pending", "claimed"])
      |> maybe_where(:run_id, run_id)
      |> maybe_where(:status, filters[:status])
      |> maybe_where(:worker_id, filters[:worker_id])
      |> order_by([control], asc: control.run_id, asc: control.sequence)

    Enum.map_reduce(Repo.all(query), [], fn control, events ->
      updated =
        control
        |> RunControl.changeset(%{
          status: "superseded",
          applied_at: now(),
          result: %{"reason" => reason}
        })
        |> Repo.update!()

      event =
        insert_event_in_transaction!(updated.run_id, "run.control_superseded", "control", %{
          "control_id" => updated.id,
          "control_sequence" => updated.sequence,
          "kind" => updated.kind,
          "result" => updated.result
        })

      {updated, [event | events]}
    end)
    |> then(fn {controls, reversed_events} -> {controls, Enum.reverse(reversed_events)} end)
  end

  # Commands

  def enqueue_command(run_or_id, idempotency_key, attrs) when is_map(attrs) do
    with %Run{} = run <- resolve_run(run_or_id) do
      attrs =
        attrs
        |> drop_keys([:run_id, :idempotency_key])
        |> put_attr(:idempotency_key, idempotency_key)

      candidate = %RunCommand{run_id: run.id}
      changeset = RunCommand.changeset(candidate, attrs)

      if changeset.valid? do
        result =
          Repo.retry_on_busy(fn ->
            Repo.transaction(fn ->
              case Repo.get_by(RunCommand,
                     run_id: run.id,
                     idempotency_key: to_string(idempotency_key)
                   ) do
                %RunCommand{} = existing ->
                  {existing, false, nil}

                nil ->
                  case Repo.insert(changeset,
                         on_conflict: :nothing,
                         conflict_target: [:run_id, :idempotency_key]
                       ) do
                    {:ok, inserted} ->
                      canonical =
                        Repo.get_by!(RunCommand,
                          run_id: run.id,
                          idempotency_key: to_string(idempotency_key)
                        )

                      created? = canonical.id == inserted.id

                      event =
                        if created? do
                          insert_event_in_transaction!(
                            run.id,
                            "run.command_enqueued",
                            "system",
                            %{
                              "command_id" => canonical.id,
                              "idempotency_key" => canonical.idempotency_key,
                              "tool_name" => canonical.tool_name
                            }
                          )
                        end

                      {canonical, created?, event}

                    {:error, insert_changeset} ->
                      Repo.rollback(insert_changeset)
                  end
              end
            end)
          end)

        case result do
          {:ok, {command, created?, event}} ->
            if created? do
              broadcast(run.id, {:run_command_enqueued, command})
              broadcast(run.id, {:run_event, event})
            end

            {:ok, command}

          {:error, reason} ->
            {:error, reason}
        end
      else
        {:error, changeset}
      end
    else
      nil -> {:error, :not_found}
    end
  end

  def get_command_by_idempotency_key(run_or_id, key) do
    with %Run{} = run <- resolve_run(run_or_id) do
      Repo.get_by(RunCommand, run_id: run.id, idempotency_key: to_string(key))
    else
      nil -> nil
    end
  end

  def get_command(id) when is_binary(id), do: Repo.get(RunCommand, id)
  def get_command(_id), do: nil
  def get_command!(id), do: Repo.get!(RunCommand, id)

  def list_commands(run_or_id, opts \\ []) when is_list(opts) do
    with %Run{} = run <- resolve_run(run_or_id) do
      RunCommand
      |> where([c], c.run_id == ^run.id)
      |> maybe_where(:status, opts[:status])
      |> order_by([c], asc: c.inserted_at, asc: c.id)
      |> limit(^bounded_limit(opts[:limit], 500, 1_000))
      |> Repo.all()
    else
      nil -> []
    end
  end

  def transition_command(command_or_id, new_status, attrs \\ %{})

  def transition_command(%RunCommand{} = command, new_status, attrs),
    do: do_transition_command(command, to_string(new_status), attrs)

  def transition_command(id, new_status, attrs) when is_binary(id) do
    case get_command(id) do
      nil -> {:error, :not_found}
      command -> do_transition_command(command, to_string(new_status), attrs)
    end
  end

  # Approvals

  def request_approval(run_or_id, attrs) when is_map(attrs) do
    with %Run{} = run <- resolve_run(run_or_id) do
      attrs = drop_keys(attrs, [:run_id])

      result =
        Repo.retry_on_busy(fn ->
          Repo.transaction(fn ->
            approval =
              case %RunApproval{run_id: run.id}
                   |> RunApproval.changeset(attrs)
                   |> Repo.insert() do
                {:ok, approval} -> approval
                {:error, changeset} -> Repo.rollback(changeset)
              end

            event =
              insert_event_in_transaction!(run.id, "run.approval_requested", "system", %{
                "approval_id" => approval.id,
                "key" => approval.key,
                "action" => approval.action
              })

            {approval, event}
          end)
        end)

      case result do
        {:ok, {approval, event}} ->
          broadcast(run.id, {:run_approval_requested, approval})
          broadcast(run.id, {:run_event, event})
          {:ok, approval}

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
    end
  end

  def get_approval(id) when is_binary(id), do: Repo.get(RunApproval, id)
  def get_approval(_id), do: nil

  def list_approvals(run_or_id, opts \\ []) when is_list(opts) do
    with %Run{} = run <- resolve_run(run_or_id) do
      RunApproval
      |> where([a], a.run_id == ^run.id)
      |> maybe_where(:status, opts[:status])
      |> order_by([a], asc: a.inserted_at, asc: a.id)
      |> Repo.all()
    else
      nil -> []
    end
  end

  @doc "Counts pending approval gates across every run in a session."
  def count_pending_approvals(session_id) when is_binary(session_id) do
    RunApproval
    |> join(:inner, [approval], run in Run, on: run.id == approval.run_id)
    |> where([approval, run], run.session_id == ^session_id and approval.status == "pending")
    |> Repo.aggregate(:count, :id)
  end

  def count_pending_approvals(_session_id), do: 0

  def decide_approval(approval_or_id, decision, attrs \\ %{}) do
    approval_id =
      case approval_or_id do
        %RunApproval{id: id} -> id
        id when is_binary(id) -> id
        _ -> nil
      end

    decision = to_string(decision)

    cond do
      is_nil(approval_id) ->
        {:error, :not_found}

      decision not in ~w(approved denied expired cancelled) ->
        {:error, {:invalid_transition, "pending", decision}}

      true ->
        result =
          Repo.retry_on_busy(fn ->
            Repo.transaction(fn ->
              case Repo.get(RunApproval, approval_id) do
                nil ->
                  Repo.rollback(:not_found)

                %RunApproval{status: "pending"} = current ->
                  decision_attrs =
                    attrs
                    |> normalize_attrs()
                    |> Map.put(:status, decision)
                    |> Map.put(:decided_at, now())

                  updated =
                    case current |> RunApproval.changeset(decision_attrs) |> Repo.update() do
                      {:ok, updated} -> updated
                      {:error, changeset} -> Repo.rollback(changeset)
                    end

                  event =
                    insert_event_in_transaction!(
                      updated.run_id,
                      "run.approval_decided",
                      "system",
                      %{
                        "approval_id" => updated.id,
                        "decision" => decision,
                        "decided_by" => updated.decided_by
                      }
                    )

                  {updated, event}

                %RunApproval{} = current ->
                  Repo.rollback({:invalid_transition, current.status, decision})
              end
            end)
          end)

        case result do
          {:ok, {updated, event}} ->
            broadcast(updated.run_id, {:run_approval_decided, updated})
            broadcast(updated.run_id, {:run_event, event})
            {:ok, updated}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # Artifacts

  def create_artifact(run_or_id, attrs) when is_map(attrs) do
    with %Run{} = run <- resolve_run(run_or_id) do
      attrs = drop_keys(attrs, [:run_id])

      result =
        Repo.retry_on_busy(fn ->
          Repo.transaction(fn ->
            artifact =
              case %RunArtifact{run_id: run.id}
                   |> RunArtifact.changeset(attrs)
                   |> Repo.insert() do
                {:ok, artifact} -> artifact
                {:error, changeset} -> Repo.rollback(changeset)
              end

            event =
              insert_event_in_transaction!(run.id, "run.artifact_created", "system", %{
                "artifact_id" => artifact.id,
                "kind" => artifact.kind,
                "name" => artifact.name
              })

            {artifact, event}
          end)
        end)

      case result do
        {:ok, {artifact, event}} ->
          broadcast(run.id, {:run_artifact_created, artifact})
          broadcast(run.id, {:run_event, event})
          {:ok, artifact}

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
    end
  end

  def list_artifacts(run_or_id, opts \\ []) when is_list(opts) do
    with %Run{} = run <- resolve_run(run_or_id) do
      RunArtifact
      |> where([a], a.run_id == ^run.id)
      |> maybe_where(:kind, opts[:kind])
      |> order_by([a], asc: a.inserted_at, asc: a.id)
      |> Repo.all()
    else
      nil -> []
    end
  end

  # Workspace locks

  @default_workspace_lock_lease_seconds 60
  @max_workspace_lock_lease_seconds 86_400

  @doc "Acquires or durably queues one workspace lock as a one-row atomic batch."
  def acquire_workspace_lock(attrs) when is_map(attrs), do: acquire_workspace_locks([attrs])
  def acquire_workspace_lock(_attrs), do: {:error, :invalid_lock_attrs}

  @doc """
  Atomically persists an all-or-none lock batch in deterministic resource order.

  If any requested resource conflicts with an external holder, every row is
  stored as waiting. Otherwise every row is held and receives a fencing token.
  A raw batch capability is returned once and is never exposed by read APIs.
  """
  def acquire_workspace_locks(attrs_list) when is_list(attrs_list) and attrs_list != [] do
    with {:ok, normalized} <- normalize_workspace_lock_batch(attrs_list) do
      do_acquire_workspace_lock_batch(normalized)
    end
  end

  def acquire_workspace_locks(_attrs_list), do: {:error, :invalid_lock_batch}

  def get_workspace_lock(id) when is_binary(id) do
    WorkspaceLock |> Repo.get(id) |> redact_workspace_lock()
  end

  def get_workspace_lock(_id), do: nil
  def get_workspace_lock!(id), do: WorkspaceLock |> Repo.get!(id) |> redact_workspace_lock()

  def list_workspace_locks(opts \\ []) when is_list(opts) do
    WorkspaceLock
    |> maybe_where(:project_id, opts[:project_id])
    |> maybe_where(:run_id, opts[:run_id])
    |> maybe_where(:session_id, opts[:session_id])
    |> maybe_where(:batch_id, opts[:batch_id])
    |> maybe_where(:owner_id, opts[:owner_id])
    |> maybe_where(:resource_type, opts[:resource_type])
    |> maybe_where(:resource_key, opts[:resource_key])
    |> maybe_where(:mode, opts[:mode])
    |> maybe_where(:status, opts[:status])
    |> maybe_active_lock_filter(opts[:active])
    |> order_by([lock], desc: lock.requested_at, desc: lock.id)
    |> limit(^bounded_limit(opts[:limit], 200, 1_000))
    |> Repo.all()
    |> Enum.map(&redact_workspace_lock/1)
  end

  def subscribe_workspace_locks(project_id) when is_binary(project_id) and project_id != "" do
    Phoenix.PubSub.subscribe(IexCode.PubSub, workspace_locks_topic(project_id))
  end

  def subscribe_workspace_locks(_project_id), do: {:error, :invalid_project_id}

  @doc "Verifies a complete held batch immediately before a protected effect, without renewal."
  def assert_workspace_lock(lock_or_id, capability_token)
      when is_binary(capability_token) and capability_token != "" do
    with %WorkspaceLock{} = lock <- resolve_workspace_lock(lock_or_id) do
      transact_workspace_lock_batch(lock.batch_id, capability_token, fn locks, now ->
        if Enum.all?(locks, fn current ->
             current.status == "held" and
               DateTime.compare(current.lease_expires_at, now) == :gt and
               is_integer(current.fencing_token)
           end) do
          locks
        else
          {:invalid, Enum.map(locks, & &1.status)}
        end
      end)
      |> case do
        {:ok, {:invalid, statuses}} -> {:error, {:lock_batch_not_held, statuses}}
        {:ok, locks} -> {:ok, lock_envelope(locks, nil)}
        {:error, reason} -> {:error, reason}
      end
    else
      nil -> {:error, :not_found}
    end
  end

  def assert_workspace_lock(_lock_or_id, _capability_token),
    do: {:error, :invalid_capability}

  def assert_workspace_locks(lock_or_id, capability_token),
    do: assert_workspace_lock(lock_or_id, capability_token)

  @doc "Renews every held lock in a batch using its opaque capability."
  def heartbeat_workspace_lock(lock_or_id, capability_token, lease_seconds \\ nil)

  def heartbeat_workspace_lock(lock_or_id, capability_token, lease_seconds)
      when is_binary(capability_token) and capability_token != "" do
    with {:ok, lease_seconds} <- lock_lease_seconds(lease_seconds),
         %WorkspaceLock{} = lock <- resolve_workspace_lock(lock_or_id) do
      transact_workspace_lock_batch(lock.batch_id, capability_token, fn locks, now ->
        cond do
          Enum.all?(locks, &(&1.status in WorkspaceLock.terminal_statuses())) ->
            {:expired, locks}

          Enum.any?(locks, &(&1.status != "held")) ->
            Repo.rollback({:lock_batch_not_held, Enum.map(locks, & &1.status)})

          Enum.any?(locks, &(DateTime.compare(&1.lease_expires_at, now) != :gt)) ->
            expired = Enum.map(locks, &expire_workspace_lock!(&1, now))
            {:expired, expired}

          true ->
            expires_at = DateTime.add(now, lease_seconds, :second)

            Enum.map(locks, fn held ->
              update_workspace_lock!(held, %{heartbeat_at: now, lease_expires_at: expires_at})
            end)
        end
      end)
      |> case do
        {:ok, {:expired, expired}} ->
          {:error, {:lock_expired, Enum.map(expired, &redact_workspace_lock/1)}}

        {:ok, locks} ->
          broadcast_workspace_locks(locks)
          # The caller already possesses the capability used to authorize this
          # renewal. Never echo that secret back after the initial acquire.
          {:ok, lock_envelope(locks, nil)}

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def heartbeat_workspace_lock(_lock_or_id, _capability_token, _lease_seconds),
    do: {:error, :invalid_capability}

  @doc "Rechecks and promotes a complete waiting batch, or renews a held batch."
  def retry_workspace_lock(lock_or_id, capability_token, lease_seconds \\ nil)

  def retry_workspace_lock(lock_or_id, capability_token, lease_seconds)
      when is_binary(capability_token) and capability_token != "" do
    with {:ok, lease_seconds} <- lock_lease_seconds(lease_seconds),
         %WorkspaceLock{} = lock <- resolve_workspace_lock(lock_or_id) do
      do_retry_workspace_lock_batch(lock.batch_id, capability_token, lease_seconds)
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def retry_workspace_lock(_lock_or_id, _capability_token, _lease_seconds),
    do: {:error, :invalid_capability}

  @doc "Releases or cancels a complete lock batch, retaining every row as history."
  def release_workspace_lock(lock_or_id, capability_token)
      when is_binary(capability_token) and capability_token != "" do
    case resolve_workspace_lock(lock_or_id) do
      nil ->
        :ok

      %WorkspaceLock{} = lock ->
        transact_workspace_lock_batch(lock.batch_id, capability_token, fn locks, now ->
          Enum.map(locks, fn current ->
            if current.status in WorkspaceLock.terminal_statuses() do
              current
            else
              status = if current.status == "waiting", do: "cancelled", else: "released"

              update_workspace_lock!(current, %{
                status: status,
                released_at: now,
                conflict_lock_id: nil,
                conflict_owner_id: nil,
                wait_reason: nil
              })
            end
          end)
        end)
        |> case do
          {:ok, locks} ->
            broadcast_workspace_locks(locks)
            {:ok, %{batch_id: lock.batch_id, locks: Enum.map(locks, &redact_workspace_lock/1)}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def release_workspace_lock(_lock_or_id, _capability_token),
    do: {:error, :invalid_capability}

  @doc "Expires held leases and cancels waiting leases at or before `before`."
  def release_expired_workspace_locks(before \\ nil) do
    before =
      if match?(%DateTime{}, before),
        do: DateTime.truncate(before, :microsecond),
        else: lock_now()

    Repo.retry_on_busy(fn ->
      Repo.transaction(
        fn -> expire_workspace_locks_in_transaction!(before) end,
        mode: :immediate
      )
    end)
    |> case do
      {:ok, expired} ->
        broadcast_workspace_locks(expired)
        {:ok, length(expired)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_acquire_workspace_lock_batch(normalized) do
    token = normalized.capability_token || generate_lock_capability()
    token_hash = hash_lock_capability(token)
    batch_id = Ecto.UUID.generate()

    result =
      Repo.retry_on_busy(fn ->
        Repo.transaction(
          fn ->
            now = lock_now()
            expired = expire_workspace_locks_in_transaction!(now)
            matching = active_identity_locks(normalized.locks)

            acquired =
              if matching == [] and not is_nil(normalized.capability_token) do
                :lock_batch_not_active
              else
                if matching == [] do
                  insert_workspace_lock_batch!(
                    normalized.locks,
                    batch_id,
                    token_hash,
                    now
                  )
                else
                  existing_batch_ids = matching |> Enum.map(& &1.batch_id) |> Enum.uniq()

                  existing =
                    case existing_batch_ids do
                      [existing_batch_id] -> workspace_lock_batch(existing_batch_id)
                      _batch_ids -> matching
                    end

                  cond do
                    length(existing_batch_ids) != 1 or
                        not same_lock_identities?(existing, normalized.locks) ->
                      Repo.rollback(:lock_already_requested)

                    is_nil(normalized.capability_token) or
                        not valid_lock_batch_capability?(existing, normalized.capability_token) ->
                      Repo.rollback(:invalid_capability)

                    true ->
                      recheck_workspace_lock_batch!(existing, now, normalized.lease_seconds)
                  end
                end
              end

            {acquired, expired}
          end,
          mode: :immediate
        )
      end)

    case result do
      {:ok, {:lock_batch_not_active, expired}} ->
        broadcast_workspace_locks(expired)
        {:error, :lock_batch_not_active}

      {:ok, {locks, expired}} ->
        broadcast_workspace_locks(expired)
        broadcast_workspace_locks(locks)

        returned_token =
          if is_nil(normalized.capability_token), do: token, else: nil

        {:ok, lock_envelope(locks, returned_token)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_retry_workspace_lock_batch(batch_id, capability_token, lease_seconds) do
    transact_workspace_lock_batch(batch_id, capability_token, fn locks, now ->
      if Enum.all?(locks, &(&1.status in WorkspaceLock.terminal_statuses())) do
        {:inactive, locks}
      else
        recheck_workspace_lock_batch!(locks, now, lease_seconds)
      end
    end)
    |> case do
      {:ok, {:inactive, locks}} ->
        {:error, {:lock_batch_not_active, Enum.map(locks, & &1.status)}}

      {:ok, locks} ->
        broadcast_workspace_locks(locks)
        # Retry is capability-authorized but must not become another secret
        # distribution channel. The gateway retains its original token.
        {:ok, lock_envelope(locks, nil)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp transact_workspace_lock_batch(batch_id, capability_token, callback) do
    Repo.retry_on_busy(fn ->
      Repo.transaction(
        fn ->
          now = lock_now()
          expired = expire_workspace_locks_in_transaction!(now)
          locks = workspace_lock_batch(batch_id)

          cond do
            locks == [] ->
              Repo.rollback(:not_found)

            not valid_lock_batch_capability?(locks, capability_token) ->
              Repo.rollback(:invalid_capability)

            true ->
              {callback.(locks, now), expired}
          end
        end,
        mode: :immediate
      )
    end)
    |> case do
      {:ok, {value, expired}} ->
        broadcast_workspace_locks(expired)
        {:ok, value}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp insert_workspace_lock_batch!(locks, batch_id, token_hash, now) do
    conflicts = batch_lock_conflicts(locks, [])
    first_conflict = conflicts |> Map.values() |> Enum.find(& &1)
    held? = is_nil(first_conflict)

    same_owner_conflict =
      conflicts
      |> Map.values()
      |> Enum.find(&(&1 && &1.owner_id == hd(locks).owner_id))

    if same_owner_conflict, do: Repo.rollback(:lock_upgrade_not_supported)

    fence_start = if held?, do: next_workspace_fencing_token(hd(locks).workspace_key), else: nil

    locks
    |> Enum.with_index()
    |> Enum.map(fn {attrs, index} ->
      direct_conflict = Map.get(conflicts, lock_identity(attrs))

      lifecycle_attrs =
        if held? do
          %{
            status: "held",
            acquired_at: now,
            heartbeat_at: now,
            lease_expires_at: DateTime.add(now, attrs.lease_seconds, :second),
            fencing_token: fence_start + index
          }
        else
          conflict = direct_conflict || first_conflict

          %{
            status: "waiting",
            lease_expires_at: DateTime.add(now, attrs.lease_seconds, :second),
            conflict_lock_id: conflict.id,
            conflict_owner_id: conflict.owner_id,
            wait_reason: conflict_wait_reason(direct_conflict, conflict)
          }
        end

      struct = %WorkspaceLock{
        project_id: attrs.project_id,
        run_id: attrs.run_id,
        session_id: attrs.session_id
      }

      changes =
        attrs
        |> Map.drop([:lease_seconds, :capability_token])
        |> Map.merge(lifecycle_attrs)
        |> Map.merge(%{
          batch_id: batch_id,
          capability_token_hash: token_hash,
          requested_at: now
        })

      case struct |> WorkspaceLock.changeset(changes) |> Repo.insert() do
        {:ok, inserted} -> inserted
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp recheck_workspace_lock_batch!(locks, now, lease_seconds) do
    cond do
      Enum.all?(locks, &(&1.status == "held")) ->
        expires_at = DateTime.add(now, lease_seconds, :second)

        Enum.map(
          locks,
          &update_workspace_lock!(&1, %{heartbeat_at: now, lease_expires_at: expires_at})
        )

      Enum.all?(locks, &(&1.status == "waiting")) ->
        conflicts = batch_lock_conflicts(locks, Enum.map(locks, & &1.id))
        first_conflict = conflicts |> Map.values() |> Enum.find(& &1)

        if first_conflict do
          Enum.map(locks, fn waiting ->
            direct_conflict = Map.get(conflicts, lock_identity(waiting))
            conflict = direct_conflict || first_conflict

            update_workspace_lock!(waiting, %{
              lease_expires_at: DateTime.add(now, lease_seconds, :second),
              conflict_lock_id: conflict.id,
              conflict_owner_id: conflict.owner_id,
              wait_reason: conflict_wait_reason(direct_conflict, conflict)
            })
          end)
        else
          fence_start = next_workspace_fencing_token(hd(locks).workspace_key)

          locks
          |> Enum.with_index()
          |> Enum.map(fn {waiting, index} ->
            update_workspace_lock!(waiting, %{
              status: "held",
              acquired_at: now,
              heartbeat_at: now,
              lease_expires_at: DateTime.add(now, lease_seconds, :second),
              fencing_token: fence_start + index,
              conflict_lock_id: nil,
              conflict_owner_id: nil,
              wait_reason: nil
            })
          end)
        end

      true ->
        Repo.rollback(:inconsistent_lock_batch)
    end
  end

  defp normalize_workspace_lock_batch(attrs_list) do
    with {:ok, locks} <- map_lock_attrs(attrs_list),
         [first | _] <- locks,
         true <-
           Enum.all?(locks, &(&1.project_id == first.project_id)) ||
             {:error, :mixed_lock_projects},
         true <-
           Enum.all?(locks, &(&1.owner_id == first.owner_id)) || {:error, :mixed_lock_owners},
         true <- Enum.all?(locks, &(&1.run_id == first.run_id)) || {:error, :mixed_lock_runs},
         true <-
           Enum.all?(locks, &(&1.session_id == first.session_id)) ||
             {:error, :mixed_lock_sessions},
         {:ok, capability_token} <- common_batch_capability(attrs_list) do
      locks =
        locks
        |> Enum.group_by(&{&1.resource_type, &1.resource_key})
        |> Enum.map(fn {_resource, duplicates} ->
          Enum.max_by(duplicates, &lock_mode_rank(&1.mode))
        end)
        |> Enum.sort_by(&{&1.project_id, &1.resource_type, &1.resource_key, &1.mode})

      lease_seconds = Enum.map(locks, & &1.lease_seconds) |> Enum.min()
      locks = Enum.map(locks, &Map.put(&1, :lease_seconds, lease_seconds))

      {:ok,
       %{
         locks: locks,
         capability_token: capability_token,
         lease_seconds: lease_seconds
       }}
    else
      [] -> {:error, :invalid_lock_batch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp map_lock_attrs(attrs_list) do
    Enum.reduce_while(attrs_list, {:ok, []}, fn attrs, {:ok, locks} ->
      case normalize_workspace_lock_attrs(attrs) do
        {:ok, lock} -> {:cont, {:ok, [lock | locks]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, locks} -> {:ok, Enum.reverse(locks)}
      error -> error
    end
  end

  defp normalize_workspace_lock_attrs(attrs) when is_map(attrs) do
    with {:ok, project_id} <- required_id(attrs, :project_id),
         {:ok, owner_id} <- required_id(attrs, :owner_id),
         {:ok, project} <- fetch_lock_project(project_id),
         {:ok, workspace_key} <- IexCode.WorkspacePath.resolve(project.root_path, ""),
         {:ok, resource_type} <- lock_label(attrs, :resource_type),
         {:ok, resource_key} <-
           canonical_lock_key(project, resource_type, attr(attrs, :resource_key)),
         {:ok, mode} <- lock_label(attrs, :mode),
         true <-
           resource_type in WorkspaceLock.resource_types() || {:error, :invalid_resource_type},
         true <- mode in WorkspaceLock.modes() || {:error, :invalid_lock_mode},
         {:ok, lease_seconds} <- lock_lease_seconds(attr(attrs, :lease_seconds)),
         {:ok, identities} <- validate_lock_identities(project_id, attrs) do
      {:ok,
       %{
         project_id: project_id,
         workspace_key: workspace_key,
         run_id: identities.run_id,
         session_id: identities.session_id,
         owner_id: owner_id,
         resource_type: resource_type,
         resource_key: resource_key,
         mode: mode,
         lease_seconds: lease_seconds
       }}
    end
  end

  defp normalize_workspace_lock_attrs(_attrs), do: {:error, :invalid_lock_attrs}

  defp common_batch_capability(attrs_list) do
    tokens =
      attrs_list
      |> Enum.map(&attr(&1, :capability_token))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case tokens do
      [] -> {:ok, nil}
      [token] when is_binary(token) and token != "" -> {:ok, token}
      _tokens -> {:error, :mixed_lock_capabilities}
    end
  end

  defp active_identity_locks(locks) do
    identities = MapSet.new(Enum.map(locks, &lock_identity/1))

    WorkspaceLock
    |> where([lock], lock.status in ["waiting", "held"])
    |> where([lock], lock.workspace_key == ^hd(locks).workspace_key)
    |> Repo.all()
    |> Enum.filter(&MapSet.member?(identities, lock_identity(&1)))
  end

  defp same_lock_identities?(existing, requested) do
    MapSet.new(Enum.map(existing, &lock_request_identity/1)) ==
      MapSet.new(Enum.map(requested, &lock_request_identity/1))
  end

  defp batch_lock_conflicts(candidates, excluded_ids) do
    batch_order =
      candidates
      |> Enum.map(&{Map.get(&1, :requested_at), Map.get(&1, :id) || ""})
      |> Enum.reject(fn {requested_at, _id} -> is_nil(requested_at) end)
      |> Enum.min_by(
        fn {requested_at, id} ->
          {DateTime.to_unix(requested_at, :microsecond), id}
        end,
        fn -> nil end
      )

    blockers =
      WorkspaceLock
      |> where([lock], lock.status in ["waiting", "held"])
      |> order_by([lock], asc: lock.requested_at, asc: lock.id)
      |> Repo.all()
      |> Enum.filter(&workspaces_overlap?(&1.workspace_key, hd(candidates).workspace_key))
      |> Enum.reject(&(&1.id in excluded_ids))
      |> Enum.filter(fn blocker ->
        blocker.status == "held" or is_nil(batch_order) or
          older_lock_request?({blocker.requested_at, blocker.id}, batch_order)
      end)

    Map.new(candidates, fn candidate ->
      {lock_identity(candidate), Enum.find(blockers, &workspace_locks_conflict?(candidate, &1))}
    end)
  end

  defp workspace_locks_conflict?(left, right) do
    cond do
      left.resource_type == "project" and left.mode in ["write", "exclusive"] ->
        true

      right.resource_type == "project" and right.mode in ["write", "exclusive"] ->
        true

      left.resource_type == "project" ->
        right.mode in ["write", "exclusive"]

      right.resource_type == "project" ->
        left.mode in ["write", "exclusive"]

      left.resource_type == "git" and left.mode in ["write", "exclusive"] ->
        true

      right.resource_type == "git" and right.mode in ["write", "exclusive"] ->
        true

      left.resource_type == "git" ->
        right.mode in ["write", "exclusive"]

      right.resource_type == "git" ->
        left.mode in ["write", "exclusive"]

      left.resource_type == right.resource_type and left.resource_key == right.resource_key ->
        not (left.mode == "read" and right.mode == "read")

      true ->
        false
    end
  end

  defp older_lock_request?({left_at, left_id}, {right_at, right_id}) do
    case DateTime.compare(left_at, right_at) do
      :lt -> true
      :gt -> false
      :eq -> left_id < right_id
    end
  end

  # Canonical exact roots are the durable identity. Ancestor/descendant roots
  # also coordinate, while hard-link identity remains outside this slice.
  defp workspaces_overlap?(left, right) do
    path_contains?(left, right) or path_contains?(right, left)
  end

  defp path_contains?(parent, child) do
    relative = Path.relative_to(child, parent)
    child == parent or (Path.type(relative) == :relative and ".." not in Path.split(relative))
  end

  defp lock_identity(lock),
    do: {lock.owner_id, lock.workspace_key, lock.resource_type, lock.resource_key, lock.mode}

  defp lock_request_identity(lock),
    do: {lock_identity(lock), Map.get(lock, :run_id), Map.get(lock, :session_id)}

  defp conflict_wait_reason(nil, _batch_conflict), do: "batch_blocked"
  defp conflict_wait_reason(%WorkspaceLock{status: "waiting"}, _conflict), do: "queue_predecessor"
  defp conflict_wait_reason(%WorkspaceLock{}, _conflict), do: "external_conflict"

  defp lock_mode_rank("read"), do: 1
  defp lock_mode_rank("write"), do: 2
  defp lock_mode_rank("exclusive"), do: 3

  defp next_workspace_fencing_token(_workspace_key) do
    from(lock in WorkspaceLock, select: max(lock.fencing_token))
    |> Repo.one()
    |> case do
      nil -> 1
      token -> token + 1
    end
  end

  defp expire_workspace_locks_in_transaction!(before) do
    WorkspaceLock
    |> where(
      [lock],
      lock.status in ["waiting", "held"] and lock.lease_expires_at <= ^before
    )
    |> order_by([lock], asc: lock.requested_at, asc: lock.id)
    |> Repo.all()
    |> Enum.map(fn lock ->
      update_workspace_lock!(lock, %{
        status: if(lock.status == "waiting", do: "cancelled", else: "expired"),
        released_at: before,
        conflict_lock_id: nil,
        conflict_owner_id: nil,
        wait_reason: nil
      })
    end)
  end

  defp expire_workspace_lock!(lock, at) do
    update_workspace_lock!(lock, %{
      status: "expired",
      released_at: at,
      conflict_lock_id: nil,
      conflict_owner_id: nil,
      wait_reason: nil
    })
  end

  defp update_workspace_lock!(lock, attrs) do
    case lock |> WorkspaceLock.changeset(attrs) |> Repo.update() do
      {:ok, updated} -> updated
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp workspace_lock_batch(batch_id) do
    WorkspaceLock
    |> where([lock], lock.batch_id == ^batch_id)
    |> order_by([lock], asc: lock.resource_type, asc: lock.resource_key, asc: lock.mode)
    |> Repo.all()
  end

  defp lock_envelope(locks, capability_token) do
    %{
      batch_id: hd(locks).batch_id,
      capability_token: capability_token,
      locks: Enum.map(locks, &redact_workspace_lock/1)
    }
  end

  defp redact_workspace_lock(nil), do: nil

  defp redact_workspace_lock(lock),
    do: %{lock | capability_token_hash: "[REDACTED]", capability_token: nil}

  defp generate_lock_capability do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp hash_lock_capability(token) do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  end

  defp valid_lock_capability?(lock, token) when is_binary(token) do
    Plug.Crypto.secure_compare(lock.capability_token_hash, hash_lock_capability(token))
  end

  defp valid_lock_capability?(_lock, _token), do: false

  defp valid_lock_batch_capability?([first | rest], token) do
    valid_lock_capability?(first, token) and
      Enum.all?(rest, fn lock ->
        lock.batch_id == first.batch_id and lock.project_id == first.project_id and
          lock.workspace_key == first.workspace_key and lock.owner_id == first.owner_id and
          lock.capability_token_hash == first.capability_token_hash and
          valid_lock_capability?(lock, token)
      end)
  end

  defp valid_lock_batch_capability?([], _token), do: false

  defp fetch_lock_project(project_id) do
    case Repo.get(IexCode.Projects.Project, project_id) do
      nil -> {:error, {:invalid, :project_id}}
      project -> {:ok, project}
    end
  end

  defp validate_lock_identities(project_id, attrs) do
    run_id = optional_id(attrs, :run_id)
    session_id = optional_id(attrs, :session_id)

    with :ok <- validate_lock_run(run_id, project_id, session_id),
         :ok <- validate_lock_session(session_id, project_id) do
      {:ok, %{run_id: run_id, session_id: session_id}}
    end
  end

  defp validate_lock_run(nil, _project_id, _session_id), do: :ok

  defp validate_lock_run(run_id, project_id, session_id) do
    case Repo.get(Run, run_id) do
      nil ->
        {:error, {:invalid, :run_id}}

      %Run{project_id: ^project_id, session_id: run_session_id}
      when is_nil(session_id) or run_session_id == session_id ->
        :ok

      %Run{project_id: ^project_id} ->
        {:error, :run_session_mismatch}

      %Run{} ->
        {:error, :run_project_mismatch}
    end
  end

  defp validate_lock_session(nil, _project_id), do: :ok

  defp validate_lock_session(session_id, project_id) do
    case Repo.get(IexCode.Sessions.Session, session_id) do
      nil -> {:error, {:invalid, :session_id}}
      %{project_id: ^project_id} -> :ok
      _session -> {:error, :session_project_mismatch}
    end
  end

  defp canonical_lock_key(project, "project", _resource_key) do
    IexCode.WorkspacePath.resolve(project.root_path, "")
  end

  defp canonical_lock_key(project, "file", resource_key) do
    IexCode.WorkspacePath.resolve(project.root_path, resource_key)
  end

  defp canonical_lock_key(project, "git", resource_key) when is_binary(resource_key) do
    with {:ok, root} <- IexCode.WorkspacePath.resolve(project.root_path, ""),
         {:ok, candidate} <- IexCode.WorkspacePath.resolve(project.root_path, resource_key) do
      if candidate == root, do: {:ok, root}, else: {:error, :invalid_git_resource}
    end
  end

  defp canonical_lock_key(_project, _resource_type, resource_key)
       when is_binary(resource_key) and resource_key != "",
       do: {:ok, resource_key}

  defp canonical_lock_key(_project, _resource_type, _resource_key),
    do: {:error, {:missing, :resource_key}}

  defp lock_label(attrs, key) do
    case attr(attrs, key) do
      value when key == :resource_type and value in [:workspace, "workspace"] -> {:ok, "project"}
      value when is_atom(value) or is_binary(value) -> {:ok, to_string(value)}
      _value -> {:error, {:missing, key}}
    end
  end

  defp lock_lease_seconds(nil), do: {:ok, @default_workspace_lock_lease_seconds}

  defp lock_lease_seconds(seconds)
       when is_integer(seconds) and seconds >= 1 and seconds <= @max_workspace_lock_lease_seconds,
       do: {:ok, seconds}

  defp lock_lease_seconds(_seconds), do: {:error, :invalid_lease_seconds}

  defp optional_id(attrs, key) do
    case attr(attrs, key) do
      value when is_binary(value) and value != "" -> value
      _value -> nil
    end
  end

  defp resolve_workspace_lock(%WorkspaceLock{id: id}), do: Repo.get(WorkspaceLock, id)
  defp resolve_workspace_lock(id) when is_binary(id), do: Repo.get(WorkspaceLock, id)
  defp resolve_workspace_lock(_lock_or_id), do: nil

  defp maybe_active_lock_filter(query, true),
    do: where(query, [lock], lock.status in ["waiting", "held"])

  defp maybe_active_lock_filter(query, false),
    do: where(query, [lock], lock.status in ["released", "expired", "cancelled"])

  defp maybe_active_lock_filter(query, _active), do: query

  defp broadcast_workspace_locks([]), do: :ok

  defp broadcast_workspace_locks(locks) do
    locks
    |> Enum.group_by(& &1.project_id)
    |> Enum.each(fn {project_id, project_locks} ->
      Phoenix.PubSub.broadcast(
        IexCode.PubSub,
        workspace_locks_topic(project_id),
        {:workspace_locks_updated, Enum.map(project_locks, &redact_workspace_lock/1)}
      )
    end)
  end

  defp workspace_locks_topic(project_id), do: "workspace_locks:project:#{project_id}"

  defp insert_initial_steps!(run_id, steps) do
    steps
    |> Enum.with_index()
    |> Enum.map_reduce([], fn {step_attrs, position}, events ->
      step_attrs =
        step_attrs
        |> drop_keys([:run_id])
        |> put_attr_new(:position, position)

      step =
        case %RunStep{run_id: run_id}
             |> RunStep.changeset(step_attrs)
             |> Repo.insert() do
          {:ok, step} -> step
          {:error, changeset} -> Repo.rollback(changeset)
        end

      event =
        insert_event_in_transaction!(run_id, "run.step_created", "system", %{
          "step_id" => step.id,
          "key" => step.key,
          "status" => step.status
        })

      {step, [event | events]}
    end)
    |> then(fn {steps, reversed_events} -> {steps, Enum.reverse(reversed_events)} end)
  end

  defp interrupt_if_orphaned(run_id, before) do
    result =
      Repo.retry_on_busy(fn ->
        Repo.transaction(fn ->
          {count, _} =
            from(run in Run,
              where: run.id == ^run_id,
              where: run.status in ["running", "paused"],
              where: is_nil(run.lease_expires_at) or run.lease_expires_at <= ^before
            )
            |> Repo.update_all(
              set: [
                status: "interrupted",
                lease_owner: nil,
                lease_expires_at: nil,
                completed_at: nil,
                updated_at: now()
              ]
            )

          if count == 1 do
            updated = Repo.get!(Run, run_id)
            event = insert_event_in_transaction!(run_id, "run.interrupted", "reconciler", %{})
            {updated, event}
          else
            Repo.rollback(:not_orphaned)
          end
        end)
      end)

    case result do
      {:ok, {run, event}} ->
        broadcast(run.id, {:run_updated, run})
        broadcast(run.id, {:run_event, event})
        {:ok, run}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Internal transition helpers

  defp do_transition_run(%Run{} = run, new_status, attrs) do
    result =
      Repo.retry_on_busy(fn ->
        Repo.transaction(fn ->
          current = Repo.get!(Run, run.id)

          if transition_allowed?(@run_transitions, current.status, new_status) do
            attrs = transition_attrs(new_status, attrs)

            updated =
              case current |> Run.changeset(attrs) |> Repo.update() do
                {:ok, updated} -> updated
                {:error, changeset} -> Repo.rollback(changeset)
              end

            event =
              insert_event_in_transaction!(updated.id, "run.status_changed", "system", %{
                "from" => current.status,
                "to" => new_status
              })

            {updated, event}
          else
            Repo.rollback({:invalid_transition, current.status, new_status})
          end
        end)
      end)

    case result do
      {:ok, {updated, event}} ->
        broadcast(updated.id, {:run_updated, updated})
        broadcast(updated.id, {:run_event, event})
        {:ok, updated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_run_with_event(run_or_id, attrs, event_type, source, payload) do
    with %Run{} = run <- resolve_run(run_or_id),
         {:ok, payload} <- bounded_payload(payload) do
      result =
        Repo.retry_on_busy(fn ->
          Repo.transaction(fn ->
            updated = run |> Run.changeset(attrs) |> Repo.update!()
            event = insert_event_in_transaction!(updated.id, event_type, source, payload)
            {updated, event}
          end)
        end)

      case result do
        {:ok, {updated, event}} ->
          broadcast(updated.id, {:run_updated, updated})
          broadcast(updated.id, {:run_event, event})
          {:ok, updated}

        {:error, %Changeset{} = changeset} ->
          {:error, changeset}

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp do_transition_step(%RunStep{} = step, new_status, attrs) do
    result =
      Repo.retry_on_busy(fn ->
        Repo.transaction(fn ->
          current = Repo.get!(RunStep, step.id)

          if transition_allowed?(@step_transitions, current.status, new_status) do
            case current
                 |> RunStep.changeset(transition_attrs(new_status, attrs))
                 |> Repo.update() do
              {:ok, updated} ->
                event =
                  insert_event_in_transaction!(
                    updated.run_id,
                    "run.step_status_changed",
                    "system",
                    %{
                      "step_id" => updated.id,
                      "from" => current.status,
                      "to" => new_status
                    }
                  )

                {updated, event}

              {:error, changeset} ->
                Repo.rollback(changeset)
            end
          else
            Repo.rollback({:invalid_transition, current.status, new_status})
          end
        end)
      end)

    case result do
      {:ok, {updated, event}} ->
        broadcast(updated.run_id, {:run_step_updated, updated})
        broadcast(updated.run_id, {:run_event, event})
        {:ok, updated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_transition_command(%RunCommand{} = command, new_status, attrs) do
    result =
      Repo.retry_on_busy(fn ->
        Repo.transaction(fn ->
          current = Repo.get!(RunCommand, command.id)

          if transition_allowed?(@command_transitions, current.status, new_status) do
            case current
                 |> RunCommand.changeset(transition_attrs(new_status, attrs))
                 |> Repo.update() do
              {:ok, updated} ->
                event =
                  insert_event_in_transaction!(
                    updated.run_id,
                    "run.command_status_changed",
                    "system",
                    %{
                      "command_id" => updated.id,
                      "from" => current.status,
                      "to" => new_status
                    }
                  )

                {updated, event}

              {:error, changeset} ->
                Repo.rollback(changeset)
            end
          else
            Repo.rollback({:invalid_transition, current.status, new_status})
          end
        end)
      end)

    case result do
      {:ok, {updated, event}} ->
        broadcast(updated.run_id, {:run_command_updated, updated})
        broadcast(updated.run_id, {:run_event, event})
        {:ok, updated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp insert_event_in_transaction!(run_id, type, source, payload) do
    {1, _} =
      from(r in Run, where: r.id == ^run_id)
      |> Repo.update_all(inc: [event_sequence: 1])

    sequence =
      from(r in Run, where: r.id == ^run_id, select: r.event_sequence)
      |> Repo.one!()

    %RunEvent{run_id: run_id}
    |> RunEvent.changeset(%{
      sequence: sequence,
      type: type,
      source: source,
      payload: payload,
      occurred_at: now()
    })
    |> Repo.insert!()
  end

  defp transition_attrs(status, attrs) do
    attrs = normalize_attrs(attrs)
    now = now()
    attrs = Map.put(attrs, :status, status)

    cond do
      status == "running" ->
        attrs
        |> Map.put_new(:started_at, now)
        |> Map.put(:heartbeat_at, now)
        |> Map.put(:completed_at, nil)

      status in ~w(completed failed skipped) ->
        attrs
        |> Map.put(:completed_at, now)
        |> maybe_clear_terminal_lease()
        |> maybe_complete_progress(status)

      status == "cancelled" ->
        attrs
        |> Map.put(:completed_at, now)
        |> maybe_complete_progress(status)

      status == "interrupted" ->
        Map.put(attrs, :heartbeat_at, now)

      true ->
        attrs
    end
  end

  defp maybe_complete_progress(attrs, "completed"), do: Map.put(attrs, :progress, 100)
  defp maybe_complete_progress(attrs, _status), do: attrs

  defp maybe_clear_terminal_lease(attrs) do
    if Map.has_key?(attrs, :lease_owner) do
      attrs
    else
      attrs |> Map.put(:lease_owner, nil) |> Map.put(:lease_expires_at, nil)
    end
  end

  defp active_lease?(%Run{lease_owner: nil}, _now), do: false
  defp active_lease?(%Run{lease_expires_at: nil}, _now), do: true

  defp active_lease?(%Run{lease_expires_at: lease_expires_at}, now) do
    DateTime.compare(lease_expires_at, now) == :gt
  end

  defp transition_allowed?(transitions, old, new) do
    new in Map.get(transitions, old, [])
  end

  defp resolve_run(%Run{} = run), do: run
  defp resolve_run(id) when is_binary(id), do: get_run(id)
  defp resolve_run(_), do: nil

  defp bounded_payload(payload) when is_map(payload) do
    payload = IexCode.Sessions.sanitize_utf8(payload)

    case Jason.encode(payload) do
      {:ok, encoded} when byte_size(encoded) <= @max_event_payload_bytes -> {:ok, payload}
      {:ok, _encoded} -> {:error, :payload_too_large}
      {:error, _reason} -> {:error, :invalid_payload}
    end
  end

  defp bounded_payload(_payload), do: {:error, :invalid_payload}

  defp validate_event_label(type, source) when is_atom(type) or is_binary(type) do
    type = to_string(type)
    source = to_string(source)

    cond do
      not Regex.match?(~r/^[a-z][a-z0-9_.:-]{0,119}$/, type) -> {:error, :invalid_event_type}
      byte_size(source) < 1 or byte_size(source) > 160 -> {:error, :invalid_event_source}
      true -> :ok
    end
  end

  defp validate_event_label(_type, _source), do: {:error, :invalid_event_type}

  defp validate_session_project(session_id, project_id) do
    case Repo.one(
           from(session in IexCode.Sessions.Session,
             where: session.id == ^session_id,
             select: session.project_id
           )
         ) do
      ^project_id -> :ok
      nil -> {:error, {:invalid, :session_id}}
      _other_project_id -> {:error, :session_project_mismatch}
    end
  end

  defp required_id(attrs, key) do
    case attr(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing, key}}
    end
  end

  defp attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp drop_keys(attrs, keys) do
    Enum.reduce(keys, attrs, fn key, acc ->
      acc |> Map.delete(key) |> Map.delete(Atom.to_string(key))
    end)
  end

  defp put_attr(attrs, key, value) do
    attrs |> Map.delete(Atom.to_string(key)) |> Map.put(key, value)
  end

  defp put_attr_new(attrs, key, value) do
    if Map.has_key?(attrs, key) or Map.has_key?(attrs, Atom.to_string(key)) do
      attrs
    else
      Map.put(attrs, key, value)
    end
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    allowed = %{
      "status" => :status,
      "progress" => :progress,
      "objective" => :objective,
      "kind" => :kind,
      "mode" => :mode,
      "priority" => :priority,
      "token_budget" => :token_budget,
      "cost_budget_cents" => :cost_budget_cents,
      "time_budget_ms" => :time_budget_ms,
      "input_tokens" => :input_tokens,
      "output_tokens" => :output_tokens,
      "cost_cents" => :cost_cents,
      "metadata" => :metadata,
      "error_message" => :error_message,
      "error_details" => :error_details,
      "started_at" => :started_at,
      "heartbeat_at" => :heartbeat_at,
      "completed_at" => :completed_at,
      "lease_owner" => :lease_owner,
      "lease_expires_at" => :lease_expires_at,
      "not_before" => :not_before,
      "cancellation_requested_at" => :cancellation_requested_at,
      "result" => :result,
      "output" => :output,
      "attempt" => :attempt,
      "max_attempts" => :max_attempts,
      "claimed_at" => :claimed_at,
      "decided_by" => :decided_by,
      "decision_note" => :decision_note,
      "decided_at" => :decided_at
    }

    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {key, value}
      {key, value} when is_binary(key) -> {Map.get(allowed, key, key), value}
    end)
  end

  defp maybe_where(query, _field, nil), do: query
  defp maybe_where(query, _field, ""), do: query
  defp maybe_where(query, field, value), do: where(query, [q], field(q, ^field) == ^value)

  defp bounded_limit(value, _default, maximum) when is_integer(value),
    do: value |> max(1) |> min(maximum)

  defp bounded_limit(_value, default, _maximum), do: default

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp nonnegative(value, _default) when is_integer(value) and value >= 0, do: value
  defp nonnegative(_value, default), do: default

  defp usage_integer(usage, keys) do
    Enum.find_value(keys, 0, fn key ->
      value = Map.get(usage, key) || Map.get(usage, Atom.to_string(key))
      if is_integer(value) and value >= 0, do: value
    end)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp lock_now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp topic(run_id), do: "run:#{run_id}"
  defp session_topic(session_id), do: "runs:session:#{session_id}"

  defp broadcast(run_id, event) do
    Phoenix.PubSub.broadcast(IexCode.PubSub, topic(run_id), event)

    case Repo.one(from(run in Run, where: run.id == ^run_id, select: run.session_id)) do
      nil -> :ok
      session_id -> Phoenix.PubSub.broadcast(IexCode.PubSub, session_topic(session_id), event)
    end
  rescue
    _ -> :ok
  end
end
