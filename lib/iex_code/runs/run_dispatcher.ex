defmodule IexCode.Runs.RunDispatcher do
  @moduledoc """
  Supervised dispatcher for durable asynchronous coding runs.

  Runs are claimed atomically through `IexCode.Runs`, are bounded by a global
  concurrency limit, and are exclusive per project. Workers are monitored and
  all observable state is persisted before PubSub notifications are emitted.
  A dispatcher restart marks abandoned work interrupted; it never replays a
  partially executed coding run automatically.
  """

  use GenServer

  require Logger

  alias IexCode.{Kanban, Projects, Runs, Sessions, WorkspaceLocks}
  alias IexCode.Engine.{AgentRegistry, FleetManager, FleetSupervisor}
  alias IexCode.Runs.Run
  alias IexCode.Runs.ExecutionEngine

  @default_poll_interval 1_000
  @default_heartbeat_interval 5_000
  @default_lease_ms 15_000
  @default_cancel_grace_ms 1_500
  @default_workspace_lock_retry_interval 1_000
  @default_workspace_lock_lease_seconds 60

  defstruct [
    :name,
    :worker_id,
    :executor,
    :task_supervisor,
    :max_concurrency,
    :poll_interval,
    :heartbeat_interval,
    :lease_ms,
    :cancel_grace_ms,
    :workspace_lock_retry_interval,
    :workspace_lock_lease_seconds,
    workers: %{},
    lock_waiters: %{},
    run_refs: %{},
    cancelling: MapSet.new()
  ]

  @type server :: GenServer.server()

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Persists and schedules a typed run."
  def enqueue(attrs, server \\ __MODULE__) when is_map(attrs) do
    steps = initial_steps(attrs)

    with :ok <- validate_typed_attrs(attrs),
         :ok <- ExecutionEngine.validate_manifest(attrs, steps),
         {:ok, run} <- Runs.create_run_with_steps(attrs, steps) do
      dispatch(server)
      {:ok, run}
    end
  end

  @doc "Wakes the dispatcher without blocking the caller."
  def dispatch(server \\ __MODULE__) do
    GenServer.cast(server, :dispatch)
  end

  @doc "Cancels a queued, paused, or active run."
  def cancel(run_or_id, server \\ __MODULE__) do
    GenServer.call(server, {:cancel, run_id(run_or_id)}, 30_000)
  end

  @doc "Requeues an eligible terminal/interrupted run as a new attempt."
  def retry(run_or_id, server \\ __MODULE__) do
    GenServer.call(server, {:retry, run_id(run_or_id)}, 30_000)
  end

  @doc "Pauses an active worker without discarding its process or context."
  def pause(run_or_id, server \\ __MODULE__) do
    GenServer.call(server, {:pause, run_id(run_or_id)})
  end

  @doc "Resumes a paused active worker."
  def resume(run_or_id, server \\ __MODULE__) do
    GenServer.call(server, {:resume, run_id(run_or_id)})
  end

  @doc "Persists run-scoped guidance and delivers it only to the selected worker."
  def steer(run_or_id, guidance, server \\ __MODULE__) when is_binary(guidance) do
    GenServer.call(server, {:steer, run_id(run_or_id), guidance})
  end

  def get_stats(server \\ __MODULE__), do: GenServer.call(server, :get_stats)
  def active_runs(server \\ __MODULE__), do: GenServer.call(server, :active_runs)
  def subscribe(run_or_id), do: Runs.subscribe(run_or_id)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    process_name = Keyword.get(opts, :name, __MODULE__)

    state = %__MODULE__{
      name: process_name,
      worker_id: Keyword.get(opts, :worker_id, default_worker_id()),
      executor:
        Keyword.get(
          opts,
          :executor,
          Application.get_env(:iex_code, :run_executor, IexCode.Runs.Executor)
        ),
      task_supervisor: Keyword.get(opts, :task_supervisor, IexCode.TaskSupervisor),
      max_concurrency:
        positive(
          Keyword.get(
            opts,
            :max_concurrency,
            Application.get_env(:iex_code, :run_dispatcher_max_concurrency, 2)
          ),
          2
        ),
      poll_interval: positive(Keyword.get(opts, :poll_interval, @default_poll_interval), 1_000),
      heartbeat_interval:
        positive(Keyword.get(opts, :heartbeat_interval, @default_heartbeat_interval), 5_000),
      lease_ms: positive(Keyword.get(opts, :lease_ms, @default_lease_ms), 15_000),
      cancel_grace_ms:
        positive(Keyword.get(opts, :cancel_grace_ms, @default_cancel_grace_ms), 1_500),
      workspace_lock_retry_interval:
        positive(
          Keyword.get(
            opts,
            :workspace_lock_retry_interval,
            @default_workspace_lock_retry_interval
          ),
          @default_workspace_lock_retry_interval
        ),
      workspace_lock_lease_seconds:
        positive(
          Keyword.get(
            opts,
            :workspace_lock_lease_seconds,
            @default_workspace_lock_lease_seconds
          ),
          @default_workspace_lock_lease_seconds
        )
    }

    # A new dispatcher identity cannot safely resume writes abandoned by an old
    # worker. Reconciliation deliberately ends at `interrupted`.
    owned_cutoff =
      DateTime.utc_now()
      |> DateTime.add(state.lease_ms, :millisecond)
      |> DateTime.truncate(:second)

    interrupted =
      Runs.reconcile_orphaned_runs(
        lease_owner: state.worker_id,
        expired_before: owned_cutoff
      ) ++ Runs.reconcile_orphaned_runs([])

    _ = Runs.supersede_claimed_controls(state.worker_id, "dispatcher_restarted")
    Enum.each(interrupted, &terminalize_interrupted_steps/1)
    Enum.each(interrupted, &project_terminal_task/1)
    schedule_poll(state.poll_interval)
    schedule_heartbeat(state.heartbeat_interval)
    send(self(), :drain)
    {:ok, state}
  end

  @impl true
  def handle_cast(:dispatch, state) do
    send(self(), :drain)
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    active = active_count(state)
    queued = state |> queued_count()

    {:reply,
     %{
       queued: queued,
       active: active,
       capacity: max(state.max_concurrency - active, 0),
       max_concurrency: state.max_concurrency,
       projects: active_project_ids(state),
       worker_id: state.worker_id
     }, state}
  end

  def handle_call(:active_runs, _from, state) do
    runs =
      (Map.values(state.workers) ++ Map.values(state.lock_waiters))
      |> Enum.map(&Runs.get_run(&1.run_id))
      |> Enum.reject(&is_nil/1)

    {:reply, runs, state}
  end

  def handle_call({:cancel, nil}, _from, state), do: {:reply, {:error, :not_found}, state}

  def handle_call({:cancel, run_id}, _from, state) do
    case Runs.get_run(run_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %Run{status: status} when status in ~w(completed failed cancelled) ->
        {:reply, {:error, {:invalid_transition, status, "cancelled"}}, state}

      %Run{} = run ->
        active? = Map.has_key?(state.run_refs, run_id)

        case persist_and_claim_control(run, "cancel", %{}, state.worker_id) do
          {:ok, control} ->
            case apply_cancellation(run, active?, control) do
              {:ok, cancelled} ->
                if active?, do: stop_durable_fleet(cancelled.id, "cancelled")
                cancel_open_steps(cancelled)
                project_terminal_task(cancelled)

                new_state =
                  state
                  |> remove_lock_waiter(run_id)
                  |> begin_worker_cancellation(run_id)

                send(self(), :drain)
                {:reply, {:ok, cancelled}, new_state}

              {:error, reason} = error ->
                _ = resolve_owned_control(control, "rejected", %{"reason" => inspect(reason)})
                {:reply, error, state}
            end

          {:error, _} = error ->
            {:reply, error, state}
        end
    end
  end

  def handle_call({:retry, nil}, _from, state), do: {:reply, {:error, :not_found}, state}

  def handle_call({:retry, run_id}, _from, state) do
    result =
      with %Run{} = run <- Runs.get_run(run_id) do
        steps = retry_attempt_steps(run)

        with :ok <- ExecutionEngine.validate_manifest(run, steps) do
          Runs.retry_run(run, steps: steps)
        end
      else
        nil -> {:error, :not_found}
      end

    if match?({:ok, _}, result), do: send(self(), :drain)
    {:reply, result, state}
  end

  def handle_call({:pause, run_id}, _from, state) do
    result = transition_controlled_run(state, run_id, "paused", :pause)
    {:reply, result, state}
  end

  def handle_call({:resume, run_id}, _from, state) do
    result = transition_controlled_run(state, run_id, "running", :resume)
    {:reply, result, state}
  end

  def handle_call({:steer, run_id, guidance}, _from, state) do
    guidance = String.trim(guidance)

    result =
      with %Run{} = run <- Runs.get_run(run_id),
           true <- Map.has_key?(state.run_refs, run_id),
           true <- run.status in ["running", "paused"],
           true <- guidance != "",
           {:ok, control} <-
             persist_and_claim_control(run, "steer", %{"guidance" => guidance}, state.worker_id),
           :ok <- broadcast_run_control(run, control, :steer, %{"guidance" => guidance}) do
        {:ok, Runs.get_run!(run.id)}
      else
        nil -> {:error, :not_found}
        false -> {:error, :not_active}
        {:error, _} = error -> error
      end

    {:reply, result, state}
  end

  @impl true
  def handle_info(:drain, state) do
    {:noreply, drain_capacity(state)}
  end

  def handle_info(:poll, state) do
    schedule_poll(state.poll_interval)
    interrupted = Runs.reconcile_orphaned_runs([])
    Enum.each(interrupted, &terminalize_interrupted_steps/1)
    Enum.each(interrupted, &project_terminal_task/1)
    {:noreply, drain_capacity(state)}
  end

  def handle_info(:heartbeat, state) do
    schedule_heartbeat(state.heartbeat_interval)

    Enum.each(state.workers, fn {_ref, worker} ->
      unless MapSet.member?(state.cancelling, worker.run_id) do
        case Runs.renew_lease(worker.run_id, state.worker_id, state.lease_ms) do
          {:ok, _run} -> :ok
          {:error, reason} -> send(self(), {:run_lease_heartbeat_failed, worker.run_id, reason})
        end
      end
    end)

    Enum.each(state.lock_waiters, fn {run_id, _waiter} ->
      _ = Runs.renew_lease(run_id, state.worker_id, state.lease_ms)
    end)

    {:noreply, state}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.fetch(state.workers, ref) do
      {:ok, worker} ->
        # A Task sends its result immediately before it exits. Keep the workspace
        # lock until the corresponding DOWN arrives so cleanup cannot race the
        # next lock holder.
        if worker[:budget_timer], do: Process.cancel_timer(worker.budget_timer)
        worker = worker |> Map.put(:result, result) |> Map.put(:budget_timer, nil)
        {:noreply, put_in(state.workers[ref], worker)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.fetch(state.workers, ref) do
      {:ok, worker} ->
        result =
          cond do
            Map.has_key?(worker, :result) ->
              worker.result

            Map.has_key?(worker, :lock_failure) ->
              {:worker_exit, {:workspace_lock_heartbeat_failed, worker.lock_failure}}

            true ->
              {:worker_exit, reason}
          end

        state = finish_worker(state, ref, worker, result)
        send(self(), :drain)
        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:force_cancel, run_id, pid}, state) do
    if Map.has_key?(state.run_refs, run_id) and Process.alive?(pid) do
      _ = Task.Supervisor.terminate_child(state.task_supervisor, pid)
    end

    {:noreply, state}
  end

  def handle_info({:retry_workspace_lock, run_id}, state) do
    case Map.fetch(state.lock_waiters, run_id) do
      {:ok, waiter} ->
        state = retry_workspace_lock(state, waiter)
        send(self(), :drain)
        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:workspace_lock_heartbeat_failed, lock_id, reason}, state) do
    case Enum.find(state.workers, fn {_ref, worker} -> worker.lock_id == lock_id end) do
      {ref, worker} ->
        Logger.error(
          "Coding run #{worker.run_id} lost its workspace lock heartbeat: #{inspect(reason)}"
        )

        if Process.alive?(worker.pid) do
          _ = Task.Supervisor.terminate_child(state.task_supervisor, worker.pid)
        end

        {:noreply, put_in(state.workers[ref], Map.put(worker, :lock_failure, reason))}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:run_lease_heartbeat_failed, run_id, reason}, state) do
    case Map.get(state.run_refs, run_id) do
      nil ->
        {:noreply, state}

      ref ->
        worker = Map.fetch!(state.workers, ref)

        if Process.alive?(worker.pid) do
          _ = Task.Supervisor.terminate_child(state.task_supervisor, worker.pid)
        end

        {:noreply,
         put_in(state.workers[ref], Map.put(worker, :lock_failure, {:run_lease_lost, reason}))}
    end
  end

  def handle_info({:run_time_budget_exceeded, run_id, pid}, state) do
    ref = Map.get(state.run_refs, run_id)

    case {ref && Map.get(state.workers, ref), Runs.get_run(run_id)} do
      {%{pid: ^pid}, %Run{status: status} = run} when status in ["running", "paused"] ->
        _ =
          Runs.append_event(
            run,
            "run.budget_exhausted",
            %{"budget" => "time", "limit_ms" => run.time_budget_ms},
            "dispatcher"
          )

        case Runs.transition_run(run, "failed", %{
               error_message: "Run exceeded its #{run.time_budget_ms}ms time budget",
               error_details: %{
                 "reason" => "budget_exhausted",
                 "budget" => "time",
                 "limit_ms" => run.time_budget_ms
               },
               lease_owner: run.lease_owner,
               lease_expires_at: run.lease_expires_at
             }) do
          {:ok, failed} ->
            stop_durable_fleet(failed.id, "failed")
            fail_open_steps(failed)
            project_terminal_task(failed)
            broadcast_run_control(failed, :cancel, %{"reason" => "time_budget_exhausted"})

          _ ->
            :ok
        end

        new_state = begin_worker_cancellation(state, run_id)
        {:noreply, new_state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp drain_capacity(state) do
    if active_count(state) < state.max_concurrency do
      opts = [
        lease_ms: state.lease_ms,
        exclude_project_ids: active_project_ids(state),
        execution_engines: ExecutionEngine.available_ids()
      ]

      case Runs.claim_next_run(state.worker_id, opts) do
        {:ok, %Run{} = run} ->
          state |> start_validated_claimed_run(run) |> drain_capacity()

        :none ->
          state

        {:error, reason} ->
          Logger.warning("RunDispatcher claim failed: #{inspect(reason)}")
          state
      end
    else
      state
    end
  end

  defp start_validated_claimed_run(state, %Run{} = run) do
    case ExecutionEngine.validate_manifest(run, Runs.list_steps(run)) do
      :ok ->
        start_claimed_run(state, run)

      {:error, reason} ->
        fail_claimed_run(state, run, {:invalid_execution_manifest, reason})
    end
  end

  defp start_claimed_run(state, %Run{kind: "coding_swarm"} = run) do
    case acquire_coding_lock(state, run) do
      {:ok, handle} -> start_worker(state, run, handle)
      {:waiting, handle} -> wait_for_workspace_lock(state, run, handle)
      {:error, reason} -> fail_claimed_run(state, run, reason)
    end
  end

  defp start_claimed_run(state, %Run{} = run), do: start_worker(state, run, nil)

  defp start_worker(state, run, lock_handle) do
    case prepare_claimed_run(run) do
      {:ok, execute_step} ->
        executor = state.executor
        delegation = workspace_lock_delegation(lock_handle)

        task =
          Task.Supervisor.async(state.task_supervisor, fn ->
            progress = fn percent, message ->
              report_progress(run.id, state.worker_id, state.lease_ms, percent, message)
            end

            with_workspace_lock_delegation(delegation, fn ->
              case assert_workspace_lock(lock_handle) do
                :ok -> execute(executor, run, progress, delegation)
                {:error, reason} -> {:error, {:workspace_lock_lost_before_execute, reason}}
              end
            end)
          end)

        worker = %{
          run_id: run.id,
          project_id: run.project_id,
          pid: task.pid,
          execute_step_id: execute_step.id,
          budget_timer: schedule_time_budget(run, task.pid),
          lock_handle: lock_handle,
          lock_delegation: delegation,
          lock_id: WorkspaceLocks.handle_id(lock_handle)
        }

        workers = Map.put(state.workers, task.ref, worker)
        run_refs = Map.put(state.run_refs, run.id, task.ref)

        broadcast_session(run, {:async_run_started, run, task.pid})
        %{state | workers: workers, run_refs: run_refs}

      {:error, reason} ->
        release_workspace_lock(lock_handle)

        case Runs.transition_run(run, "failed", error_attrs(reason)) do
          {:ok, failed} -> project_terminal_task(failed)
          _ -> :ok
        end

        state
    end
  end

  defp acquire_coding_lock(state, run) do
    project = Projects.get_project!(run.project_id)

    WorkspaceLocks.acquire_or_wait(project, [:project],
      owner_id: "run:#{run.id}",
      run_id: run.id,
      session_id: run.session_id,
      project_id: run.project_id,
      lease_seconds: coding_lock_lease_seconds(state, run),
      heartbeat_interval_ms: coding_lock_heartbeat_interval(state, run),
      heartbeat_failure: :notify
    )
  rescue
    error -> {:error, {:workspace_lock_acquire_failed, error}}
  catch
    kind, reason -> {:error, {:workspace_lock_acquire_failed, kind, reason}}
  end

  defp wait_for_workspace_lock(state, run, handle) do
    mark_execute_step_blocked(run)

    timer =
      Process.send_after(
        self(),
        {:retry_workspace_lock, run.id},
        state.workspace_lock_retry_interval
      )

    waiter = %{
      run_id: run.id,
      project_id: run.project_id,
      lock_handle: handle,
      lock_id: WorkspaceLocks.handle_id(handle),
      retry_timer: timer
    }

    %{state | lock_waiters: Map.put(state.lock_waiters, run.id, waiter)}
  end

  defp retry_workspace_lock(state, waiter) do
    case Runs.get_run(waiter.run_id) do
      %Run{status: status} = run when status in ["running", "paused"] ->
        case WorkspaceLocks.retry(waiter.lock_handle) do
          {:ok, handle} ->
            state
            |> remove_lock_waiter(run.id, release?: false)
            |> start_worker(run, handle)

          {:waiting, handle} ->
            wait_for_workspace_lock(
              remove_lock_waiter(state, run.id, release?: false),
              run,
              handle
            )

          {:error, reason} ->
            state
            |> remove_lock_waiter(run.id)
            |> fail_claimed_run(run, reason)
        end

      _ ->
        remove_lock_waiter(state, waiter.run_id)
    end
  end

  defp fail_claimed_run(state, run, reason) do
    case Runs.transition_run(run, "failed", error_attrs(reason)) do
      {:ok, failed} ->
        fail_open_steps(failed)
        project_terminal_task(failed)
        broadcast_session(failed, {:async_run_updated, failed})

      _ ->
        :ok
    end

    state
  end

  defp execute(executor, run, progress, delegation) do
    if Code.ensure_loaded?(executor) and function_exported?(executor, :execute, 3) do
      executor.execute(run, progress, workspace_lock_delegation: delegation)
    else
      executor.execute(run, progress)
    end
  rescue
    error -> {:error, {error, __STACKTRACE__}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp report_progress(run_id, worker_id, lease_ms, percent, message) do
    percent = percent |> max(0) |> min(100)

    with {:ok, _leased_run} <- Runs.renew_lease(run_id, worker_id, lease_ms),
         {:ok, run} <- Runs.record_progress(run_id, percent, message, "worker") do
      broadcast_session(run, {:async_run_updated, run})
      :ok
    else
      error -> exit({:run_lease_lost, error})
    end
  end

  defp finish_worker(state, ref, worker, result) do
    if worker[:budget_timer], do: Process.cancel_timer(worker.budget_timer)
    run = Runs.get_run(worker.run_id)
    cancelling? = MapSet.member?(state.cancelling, worker.run_id)

    cond do
      is_nil(run) or cancelling? or run.status == "cancelled" ->
        :ok

      run.status == "failed" ->
        finish_execute_step(worker.execute_step_id, "failed", %{
          error_message: run.error_message,
          error_details: run.error_details
        })

        project_terminal_task(run)
        broadcast_session(run, {:async_run_updated, run})

      true ->
        {status, attrs} = terminal_result(result)
        finish_execute_step(worker.execute_step_id, status, attrs)
        if status == "failed", do: fail_open_steps(run)
        if status == "interrupted", do: terminalize_interrupted_steps(run)

        attrs =
          case attrs do
            %{metadata: result_metadata} ->
              %{attrs | metadata: Map.merge(run.metadata || %{}, result_metadata)}

            _ ->
              attrs
          end

        case Runs.transition_run(run, status, attrs) do
          {:ok, updated} ->
            project_terminal_task(updated)
            broadcast_session(updated, {:async_run_updated, updated})

          {:error, {:invalid_transition, _, _}} ->
            :ok

          {:error, reason} ->
            Logger.warning("RunDispatcher finalization failed: #{inspect(reason)}")
        end
    end

    if run && run.lease_owner == state.worker_id do
      _ = Runs.release_lease(run.id, state.worker_id)
    end

    if run, do: reject_unapplied_controls(run)
    if run, do: stop_durable_fleet(run.id, status_for_fleet(run, result))
    release_workspace_lock(worker.lock_handle)

    %{
      state
      | workers: Map.delete(state.workers, ref),
        run_refs: Map.delete(state.run_refs, worker.run_id),
        cancelling: MapSet.delete(state.cancelling, worker.run_id)
    }
  end

  defp status_for_fleet(%Run{status: status}, _result)
       when status in ["completed", "failed", "cancelled", "interrupted"],
       do: status

  defp status_for_fleet(_run, {:ok, _}), do: "completed"
  defp status_for_fleet(_run, _result), do: "interrupted"

  defp stop_durable_fleet(run_id, status) do
    if AgentRegistry.whereis_fleet(run_id, :manager) do
      _ = FleetManager.stop(run_id, status)
    end

    FleetSupervisor.stop(run_id)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp signal_fleet_control(run_id, kind) when kind in [:pause, :resume] do
    if AgentRegistry.whereis_fleet(run_id, :manager) do
      _ = FleetManager.control_all(run_id, kind)
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp signal_fleet_control(_run_id, _kind), do: :ok

  defp terminal_result({:ok, result}),
    do: {"completed", %{metadata: %{"result" => inspect(result)}}}

  defp terminal_result(:ok), do: {"completed", %{}}

  defp terminal_result({:error, reason}),
    do: {"failed", error_attrs(reason)}

  defp terminal_result({:worker_exit, reason}),
    do: {"interrupted", error_attrs(reason)}

  defp terminal_result(other), do: {"completed", %{metadata: %{"result" => inspect(other)}}}

  defp error_attrs(reason) do
    %{error_message: format_reason(reason), error_details: %{"reason" => inspect(reason)}}
  end

  defp format_reason({exception, stacktrace}) when is_exception(exception),
    do: Exception.format(:error, exception, stacktrace)

  defp format_reason({kind, reason}) when kind in [:exit, :throw],
    do: "#{kind}: #{inspect(reason)}"

  defp format_reason(reason), do: inspect(reason)

  defp begin_worker_cancellation(state, run_id) do
    case Map.fetch(state.run_refs, run_id) do
      {:ok, ref} ->
        worker = Map.fetch!(state.workers, ref)
        Process.send_after(self(), {:force_cancel, run_id, worker.pid}, state.cancel_grace_ms)
        %{state | cancelling: MapSet.put(state.cancelling, run_id)}

      :error ->
        state
    end
  end

  defp transition_controlled_run(state, run_id, status, kind) do
    with %Run{} = run <- Runs.get_run(run_id),
         true <- Map.has_key?(state.run_refs, run_id),
         {:ok, control} <-
           persist_and_claim_control(run, Atom.to_string(kind), %{}, state.worker_id) do
      case Runs.transition_run(run, status) do
        {:ok, updated} ->
          :ok = broadcast_run_control(updated, control, kind, %{})
          signal_fleet_control(updated.id, kind)
          transition_active_step(updated, status)
          broadcast_session(updated, {:async_run_updated, updated})
          {:ok, updated}

        {:error, reason} = error ->
          _ = resolve_owned_control(control, "rejected", %{"reason" => inspect(reason)})
          error
      end
    else
      nil -> {:error, :not_found}
      false -> {:error, :not_active}
      {:error, _} = error -> error
    end
  end

  defp queued_count(_state) do
    Runs.list_runs(status: "queued", limit: 1_000) |> length()
  rescue
    _ -> 0
  end

  defp active_project_ids(state) do
    (Map.values(state.workers) ++ Map.values(state.lock_waiters))
    |> Enum.map(& &1.project_id)
    |> Enum.uniq()
  end

  defp active_count(state), do: map_size(state.workers) + map_size(state.lock_waiters)

  defp remove_lock_waiter(state, run_id, opts \\ []) do
    case Map.pop(state.lock_waiters, run_id) do
      {nil, _waiters} ->
        state

      {waiter, waiters} ->
        if waiter.retry_timer, do: Process.cancel_timer(waiter.retry_timer)
        if Keyword.get(opts, :release?, true), do: release_workspace_lock(waiter.lock_handle)
        %{state | lock_waiters: waiters}
    end
  end

  defp release_workspace_lock(nil), do: :ok

  defp release_workspace_lock(handle) do
    case WorkspaceLocks.release(handle) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Workspace lock release failed: #{inspect(reason)}")
    end
  end

  defp assert_workspace_lock(nil), do: :ok
  defp assert_workspace_lock(handle), do: WorkspaceLocks.assert(handle)

  defp workspace_lock_delegation(nil), do: nil

  defp workspace_lock_delegation(handle) do
    case WorkspaceLocks.delegate(handle) do
      {:ok, delegation} -> delegation
      {:error, reason} -> {:workspace_lock_delegation_error, reason}
    end
  end

  defp with_workspace_lock_delegation(nil, fun), do: fun.()

  defp with_workspace_lock_delegation({:workspace_lock_delegation_error, reason}, _fun) do
    {:error, {:workspace_lock_delegation_failed, reason}}
  end

  defp with_workspace_lock_delegation(delegation, fun) do
    WorkspaceLocks.with_delegation(delegation, fun)
  end

  defp mark_execute_step_blocked(run) do
    run
    |> current_attempt_steps()
    |> Enum.find(&(&1.kind == "execute" and &1.status in ["pending", "ready"]))
    |> case do
      nil ->
        :ok

      step ->
        _ =
          Runs.transition_step(step, "blocked", %{
            error_message: "Waiting for exclusive project workspace access"
          })

        :ok
    end
  end

  defp coding_lock_lease_seconds(state, %Run{time_budget_ms: budget_ms})
       when is_integer(budget_ms) and budget_ms > 0 do
    budget_seconds = div(budget_ms + 999, 1_000) + 5
    max(state.workspace_lock_lease_seconds, budget_seconds) |> min(86_400)
  end

  defp coding_lock_lease_seconds(state, _run), do: state.workspace_lock_lease_seconds

  defp coding_lock_heartbeat_interval(state, run) do
    state
    |> coding_lock_lease_seconds(run)
    |> Kernel.*(1_000)
    |> div(3)
    |> max(250)
  end

  defp validate_typed_attrs(attrs) do
    kind = Map.get(attrs, :kind) || Map.get(attrs, "kind")
    mode = Map.get(attrs, :mode) || Map.get(attrs, "mode")
    objective = Map.get(attrs, :objective) || Map.get(attrs, "objective")
    project_id = Map.get(attrs, :project_id) || Map.get(attrs, "project_id")
    session_id = Map.get(attrs, :session_id) || Map.get(attrs, "session_id")

    if Enum.all?([kind, mode, objective, project_id, session_id], &(is_binary(&1) and &1 != "")) do
      :ok
    else
      {:error, :invalid_typed_run}
    end
  end

  defp metadata_kind(attrs) do
    metadata = Map.get(attrs, :metadata) || Map.get(attrs, "metadata") || %{}
    Map.get(metadata, :kind) || Map.get(metadata, "kind")
  end

  defp run_id(%Run{id: id}), do: id
  defp run_id(id) when is_binary(id), do: id
  defp run_id(_), do: nil

  defp maybe_broadcast_cancel(true, %Run{} = run) do
    broadcast_run_control(run, :cancel, %{"action" => "rollback"})
  end

  defp maybe_broadcast_cancel(false, %Run{}), do: :ok

  defp apply_cancellation(run, active?, control) do
    with {:ok, requested} <- Runs.request_cancellation(run),
         :ok <- maybe_broadcast_cancel(active?, requested),
         {:ok, cancelled} <- Runs.transition_run(requested, "cancelled"),
         {:ok, _control} <-
           resolve_owned_control(control, "applied", %{
             "run_status" => "cancelled",
             "worker_active" => active?
           }) do
      {:ok, cancelled}
    end
  end

  defp broadcast_run_control(%Run{} = run, kind, payload) do
    Phoenix.PubSub.broadcast(
      IexCode.PubSub,
      "run:#{run.id}:control",
      {:run_control, run.id, kind, payload}
    )
  end

  defp broadcast_run_control(%Run{} = run, control, kind, payload) do
    Phoenix.PubSub.broadcast(
      IexCode.PubSub,
      "run:#{run.id}:control",
      {:run_control, run.id, control.id, kind, payload}
    )
  end

  defp persist_and_claim_control(%Run{} = run, kind, payload, worker_id) do
    idempotency_key =
      "dispatcher:#{kind}:#{System.unique_integer([:positive, :monotonic])}"

    with {:ok, pending} <-
           Runs.enqueue_control(run, idempotency_key, %{
             kind: kind,
             payload: payload,
             requested_by: "local-user"
           }),
         {:ok, claimed} <- Runs.claim_control(pending, worker_id) do
      {:ok, claimed}
    end
  end

  defp reject_unapplied_controls(run) do
    run
    |> Runs.list_controls(status: "claimed")
    |> Enum.each(fn control ->
      _ =
        resolve_owned_control(control, "rejected", %{
          "reason" => "run_terminated_before_ack"
        })
    end)
  end

  defp resolve_owned_control(control, status, result) do
    Runs.resolve_control(control, status, result,
      run_id: control.run_id,
      worker_id: control.worker_id,
      kind: control.kind
    )
  end

  defp broadcast_session(%Run{} = run, event) do
    Phoenix.PubSub.broadcast(IexCode.PubSub, "session:#{run.session_id}", event)
    Phoenix.PubSub.broadcast(IexCode.PubSub, "runs:session:#{run.session_id}", event)
  rescue
    _ -> :ok
  end

  defp schedule_poll(interval), do: Process.send_after(self(), :poll, interval)
  defp schedule_heartbeat(interval), do: Process.send_after(self(), :heartbeat, interval)

  defp schedule_time_budget(%Run{id: run_id, time_budget_ms: budget_ms}, pid)
       when is_integer(budget_ms) and budget_ms >= 0 do
    Process.send_after(self(), {:run_time_budget_exceeded, run_id, pid}, budget_ms)
  end

  defp schedule_time_budget(_run, _pid), do: nil

  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default

  defp default_worker_id do
    incarnation = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    "#{node()}:run-dispatcher:#{incarnation}"
  end

  defp project_terminal_task(%Run{status: status} = run)
       when status in ["completed", "failed", "cancelled", "interrupted"] do
    _ = Kanban.project_run_terminal(run.id, status, run.error_message)
    :ok
  end

  defp project_terminal_task(_run), do: :ok

  defp retry_attempt_steps(%Run{} = run) do
    {prepare_key, execute_key} = attempt_step_keys(run)
    attempt_width = if run.kind == "deep_research", do: 6, else: 2
    base_position = run.attempt * attempt_width

    base_steps = [
      %{
        key: prepare_key,
        kind: "prepare",
        title: "Validate durable run inputs",
        status: "ready",
        position: base_position
      },
      %{
        key: execute_key,
        kind: "execute",
        title: "Execute #{run.kind}",
        status: "pending",
        position: base_position + 1,
        depends_on: [prepare_key]
      }
    ]

    if run.kind == "deep_research" do
      base_steps ++ research_steps(run.attempt + 1, prepare_key, base_position + 2)
    else
      base_steps
    end
  end

  defp initial_steps(attrs) do
    kind = Map.get(attrs, :kind) || Map.get(attrs, "kind") || metadata_kind(attrs)

    base_steps = [
      %{
        key: "prepare",
        kind: "prepare",
        title: "Validate durable run inputs",
        status: "ready",
        position: 0
      },
      %{
        key: "execute",
        kind: "execute",
        title: "Execute #{kind}",
        status: "pending",
        position: 1,
        depends_on: ["prepare"]
      }
    ]

    if kind == "deep_research" do
      base_steps ++ research_steps(1, "prepare", 2)
    else
      base_steps
    end
  end

  defp research_steps(attempt, prepare_key, position) do
    suffix = if attempt > 1, do: ".#{attempt}", else: ""
    plan = "research.plan#{suffix}"
    search = "research.search#{suffix}"
    fetch = "research.fetch#{suffix}"

    [
      %{
        key: plan,
        kind: "research_plan",
        title: "Plan research strategy",
        status: "pending",
        position: position,
        depends_on: [prepare_key]
      },
      %{
        key: search,
        kind: "research_search",
        title: "Federate evidence search",
        status: "pending",
        position: position + 1,
        depends_on: [plan]
      },
      %{
        key: fetch,
        kind: "research_fetch",
        title: "Fetch public sources safely",
        status: "pending",
        position: position + 2,
        depends_on: [search]
      },
      %{
        key: "research.synthesize#{suffix}",
        kind: "research_synthesize",
        title: "Synthesize cited report",
        status: "pending",
        position: position + 3,
        depends_on: [fetch]
      }
    ]
  end

  defp attempt_step_keys(%Run{attempt: 0}), do: {"prepare", "execute"}

  defp attempt_step_keys(%Run{attempt: attempt}) do
    next_attempt = attempt + 1
    {"prepare.#{next_attempt}", "execute.#{next_attempt}"}
  end

  defp current_attempt_steps(%Run{} = run) do
    keys =
      if run.attempt <= 1 do
        ["prepare", "execute"]
      else
        ["prepare.#{run.attempt}", "execute.#{run.attempt}"]
      end

    run
    |> Runs.list_steps()
    |> Enum.filter(&(&1.key in keys))
  end

  defp prepare_claimed_run(%Run{} = run) do
    steps = current_attempt_steps(run)
    prepare = Enum.find(steps, &(&1.kind == "prepare"))
    execute = Enum.find(steps, &(&1.kind == "execute"))

    cond do
      is_nil(prepare) ->
        {:error, :missing_prepare_step}

      is_nil(execute) ->
        fail_prepare(prepare, execute, :missing_execute_step)

      true ->
        with {:ok, running_prepare} <- Runs.transition_step(prepare, "running"),
             :ok <- validate_relationships(run),
             {:ok, _completed_prepare} <- Runs.transition_step(running_prepare, "completed"),
             {:ok, running_execute} <- Runs.transition_step(execute, "running") do
          {:ok, running_execute}
        else
          {:error, reason} -> fail_prepare(prepare, execute, reason)
        end
    end
  end

  defp fail_prepare(prepare, execute, reason) do
    prepare = Runs.get_step(prepare.id) || prepare

    if prepare.status not in ~w(completed failed cancelled) do
      _ = Runs.transition_step(prepare, "failed", error_attrs(reason))
    end

    if execute && execute.status not in ~w(completed failed cancelled skipped) do
      _ = Runs.transition_step(execute, "skipped")
    end

    {:error, reason}
  end

  defp validate_relationships(%Run{} = run) do
    project = Projects.get_project!(run.project_id)
    session = Sessions.get_session!(run.session_id)

    cond do
      session.project_id != project.id -> {:error, :session_project_mismatch}
      not File.dir?(project.root_path) -> {:error, :project_root_not_found}
      true -> :ok
    end
  rescue
    Ecto.NoResultsError -> {:error, :invalid_project_or_session}
  end

  defp finish_execute_step(step_id, run_status, attrs) do
    step_status =
      case run_status do
        "completed" -> "completed"
        "interrupted" -> "interrupted"
        "cancelled" -> "cancelled"
        _ -> "failed"
      end

    step_attrs = Map.drop(attrs, [:metadata])
    _ = Runs.transition_step(step_id, step_status, step_attrs)
    :ok
  end

  defp cancel_open_steps(run) do
    run
    |> Runs.list_steps()
    |> Enum.filter(&(&1.status not in ~w(completed failed cancelled skipped interrupted)))
    |> Enum.each(&Runs.transition_step(&1, "cancelled"))
  end

  defp fail_open_steps(run) do
    run
    |> Runs.list_steps()
    |> Enum.filter(&(&1.status not in ~w(completed failed cancelled skipped interrupted)))
    |> Enum.each(fn step ->
      status =
        cond do
          step.status == "running" -> "failed"
          step.status in ["paused", "waiting_approval"] -> "cancelled"
          true -> "skipped"
        end

      _ = Runs.transition_step(step, status, %{error_message: "Upstream run failed"})
    end)
  end

  defp terminalize_interrupted_steps(run) do
    run
    |> Runs.list_steps()
    |> Enum.filter(&(&1.status not in ~w(completed failed cancelled skipped interrupted)))
    |> Enum.each(fn step ->
      status =
        if step.status in ["running", "paused", "waiting_approval"],
          do: "interrupted",
          else: "skipped"

      _ = Runs.transition_step(step, status, %{error_message: "Run interrupted"})
    end)
  end

  defp transition_active_step(run, status) do
    step_status = if status == "paused", do: "paused", else: "running"

    run
    |> current_attempt_steps()
    |> Enum.find(&(&1.kind == "execute" and &1.status in ~w(running paused)))
    |> case do
      nil -> :ok
      step -> Runs.transition_step(step, step_status)
    end
  end
end
