defmodule IexCode.Desktop.ActivityTracker do
  @moduledoc """
  Tracks active swarm workers, agents, and pending approvals across sessions.
  Updates `IexCode.Desktop.Dock` on state changes and synchronizes with
  supervisors and database queries.
  """
  use GenServer
  require Logger
  import Ecto.Query

  alias IexCode.Desktop.Dock
  alias Phoenix.PubSub

  @default_topics [
    "swarm:lifecycle",
    "desktop:events",
    "runs:events",
    "desktop:lifecycle"
  ]

  defstruct active_workers: MapSet.new(),
            pending_approvals: MapSet.new(),
            db_workers: 0,
            db_approvals: 0,
            current_running: 0,
            current_waiting: 0,
            dock_server: Dock

  # --- Client API ---

  @doc """
  Starts the ActivityTracker GenServer.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Tracks the start of an active worker or agent run.
  """
  @spec track_worker_start(GenServer.server() | term(), term() | nil) :: :ok
  def track_worker_start(server_or_id, id_or_nil \\ nil)

  def track_worker_start(server, id) when not is_nil(id) do
    if is_pid(server) or (is_atom(server) and Process.whereis(server)) do
      GenServer.call(server, {:track_worker_start, id})
    else
      :ok
    end
  end

  def track_worker_start(id, nil) do
    track_worker_start(__MODULE__, id)
  end

  @doc """
  Tracks the completion or termination of a worker or agent run.
  """
  @spec track_worker_finish(GenServer.server() | term(), term() | nil) :: :ok
  def track_worker_finish(server_or_id, id_or_nil \\ nil)

  def track_worker_finish(server, id) when not is_nil(id) do
    if is_pid(server) or (is_atom(server) and Process.whereis(server)) do
      GenServer.call(server, {:track_worker_finish, id})
    else
      :ok
    end
  end

  def track_worker_finish(id, nil) do
    track_worker_finish(__MODULE__, id)
  end

  @doc """
  Tracks a new pending human approval request.
  """
  @spec track_approval_request(GenServer.server() | term(), term() | nil) :: :ok
  def track_approval_request(server_or_id, id_or_nil \\ nil)

  def track_approval_request(server, id) when not is_nil(id) do
    if is_pid(server) or (is_atom(server) and Process.whereis(server)) do
      GenServer.call(server, {:track_approval_request, id})
    else
      :ok
    end
  end

  def track_approval_request(id, nil) do
    track_approval_request(__MODULE__, id)
  end

  @doc """
  Tracks the resolution (approval or rejection) of an approval gate.
  """
  @spec track_approval_resolve(GenServer.server() | term(), term() | nil) :: :ok
  def track_approval_resolve(server_or_id, id_or_nil \\ nil)

  def track_approval_resolve(server, id) when not is_nil(id) do
    if is_pid(server) or (is_atom(server) and Process.whereis(server)) do
      GenServer.call(server, {:track_approval_resolve, id})
    else
      :ok
    end
  end

  def track_approval_resolve(id, nil) do
    track_approval_resolve(__MODULE__, id)
  end

  @doc """
  Forces an immediate recalculation of activity counts from DB/supervisors
  and pushes them to `IexCode.Desktop.Dock`.
  """
  @spec sync_now(GenServer.server()) :: :ok
  def sync_now(server \\ __MODULE__) do
    if is_pid(server) or (is_atom(server) and Process.whereis(server)) do
      GenServer.call(server, :sync_now)
    else
      :ok
    end
  end

  @doc """
  Returns the current running and waiting counts tracked by the GenServer.
  """
  @spec get_counts(GenServer.server()) :: %{running: integer(), waiting: integer()}
  def get_counts(server \\ __MODULE__) do
    if is_pid(server) or (is_atom(server) and Process.whereis(server)) do
      GenServer.call(server, :get_counts)
    else
      %{running: 0, waiting: 0}
    end
  end

  @doc """
  Clears all tracked workers and approvals, resetting state to 0 running and 0 waiting.
  """
  @spec clear(GenServer.server()) :: :ok
  def clear(server \\ __MODULE__) do
    if is_pid(server) or (is_atom(server) and Process.whereis(server)) do
      GenServer.call(server, :clear)
    else
      :ok
    end
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    topics = Keyword.get(opts, :topics, @default_topics)
    dock_server = Keyword.get(opts, :dock_server, Dock)

    if Process.whereis(IexCode.PubSub) do
      Enum.each(topics, fn topic ->
        PubSub.subscribe(IexCode.PubSub, topic)
      end)
    end

    state = %__MODULE__{
      active_workers: MapSet.new(),
      pending_approvals: MapSet.new(),
      db_workers: 0,
      db_approvals: 0,
      current_running: 0,
      current_waiting: 0,
      dock_server: dock_server
    }

    # Recalculate and push initial state
    {:ok, recalculate_and_apply(state)}
  end

  @impl true
  def handle_call({:track_worker_start, id}, _from, state) do
    normalized = normalize_id(id)
    new_workers = MapSet.put(state.active_workers, normalized)
    new_state = %{state | active_workers: new_workers}
    new_state = recalculate_and_apply(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call({:track_worker_finish, id}, _from, state) do
    normalized = normalize_id(id)
    new_workers = MapSet.delete(state.active_workers, normalized)
    new_state = %{state | active_workers: new_workers}
    new_state = recalculate_and_apply(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call({:track_approval_request, id}, _from, state) do
    normalized = normalize_id(id)
    new_approvals = MapSet.put(state.pending_approvals, normalized)
    new_state = %{state | pending_approvals: new_approvals}
    new_state = recalculate_and_apply(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call({:track_approval_resolve, id}, _from, state) do
    normalized = normalize_id(id)
    new_approvals = MapSet.delete(state.pending_approvals, normalized)
    new_state = %{state | pending_approvals: new_approvals}
    new_state = recalculate_and_apply(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call(:sync_now, _from, state) do
    {db_w, db_a} = query_db_and_supervisors()
    new_state = %{state | db_workers: db_w, db_approvals: db_a}
    new_state = recalculate_and_apply(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call(:get_counts, _from, state) do
    counts = %{
      running: state.current_running,
      waiting: state.current_waiting
    }

    {:reply, counts, state}
  end

  def handle_call(:clear, _from, state) do
    new_state = %{
      state
      | active_workers: MapSet.new(),
        pending_approvals: MapSet.new(),
        db_workers: 0,
        db_approvals: 0,
        current_running: 0,
        current_waiting: 0
    }

    apply_to_dock(state.dock_server, 0, 0)
    {:reply, :ok, new_state}
  end

  # --- PubSub Event Handlers ---

  @impl true
  def handle_info({:run_updated, %{status: status} = run}, state) do
    run_id = Map.get(run, :id) || normalize_id(run)
    status_str = to_string(status)

    new_workers =
      cond do
        status_str in ["running", "started", "active"] ->
          MapSet.put(state.active_workers, run_id)

        status_str in ["completed", "failed", "cancelled", "stopped", "waiting_approval"] ->
          MapSet.delete(state.active_workers, run_id)

        true ->
          state.active_workers
      end

    new_state = %{state | active_workers: new_workers}
    {:noreply, recalculate_and_apply(new_state)}
  end

  def handle_info({:run_step_updated, %{status: status} = step}, state) do
    run_id = Map.get(step, :run_id)
    status_str = to_string(status)

    new_workers =
      if run_id && status_str in ["running", "active"] do
        MapSet.put(state.active_workers, run_id)
      else
        state.active_workers
      end

    new_state = %{state | active_workers: new_workers}
    {:noreply, recalculate_and_apply(new_state)}
  end

  def handle_info({:run_approval_requested, approval}, state) do
    approval_id = extract_approval_id(approval)
    new_approvals = MapSet.put(state.pending_approvals, approval_id)
    new_state = %{state | pending_approvals: new_approvals}
    {:noreply, recalculate_and_apply(new_state)}
  end

  def handle_info({:approval_requested, approval}, state) do
    handle_info({:run_approval_requested, approval}, state)
  end

  def handle_info({:approval_resolved, approval}, state) do
    approval_id = extract_approval_id(approval)
    new_approvals = MapSet.delete(state.pending_approvals, approval_id)
    new_state = %{state | pending_approvals: new_approvals}
    {:noreply, recalculate_and_apply(new_state)}
  end

  def handle_info({:run_approval_resolved, approval}, state) do
    handle_info({:approval_resolved, approval}, state)
  end

  def handle_info({:approval_decided, approval}, state) do
    handle_info({:approval_resolved, approval}, state)
  end

  def handle_info({:worker_started, %{id: id}}, state) do
    new_workers = MapSet.put(state.active_workers, normalize_id(id))
    new_state = %{state | active_workers: new_workers}
    {:noreply, recalculate_and_apply(new_state)}
  end

  def handle_info({:worker_finished, %{id: id}}, state) do
    new_workers = MapSet.delete(state.active_workers, normalize_id(id))
    new_state = %{state | active_workers: new_workers}
    {:noreply, recalculate_and_apply(new_state)}
  end

  def handle_info({:swarm_completed, _payload}, state) do
    {db_w, db_a} = query_db_and_supervisors()
    new_state = %{state | db_workers: db_w, db_approvals: db_a}
    {:noreply, recalculate_and_apply(new_state)}
  end

  def handle_info(:sync_now, state) do
    {db_w, db_a} = query_db_and_supervisors()
    new_state = %{state | db_workers: db_w, db_approvals: db_a}
    {:noreply, recalculate_and_apply(new_state)}
  end

  def handle_info(_other, state) do
    {:noreply, state}
  end

  # --- Calculation & Dock Dispatch ---

  defp recalculate_and_apply(state) do
    running_total = MapSet.size(state.active_workers) + state.db_workers
    waiting_total = MapSet.size(state.pending_approvals) + state.db_approvals

    running = max(0, running_total)
    waiting = max(0, waiting_total)

    apply_to_dock(state.dock_server, running, waiting)

    %{state | current_running: running, current_waiting: waiting}
  end

  defp apply_to_dock(dock_server, running, waiting) do
    if is_pid(dock_server) or (is_atom(dock_server) and Process.whereis(dock_server)) do
      Dock.set_activity(dock_server, running, waiting)
    else
      # If Dock process is not started, invoke pure client API with direct effects
      Dock.set_activity(running, waiting)
    end
  end

  # --- Database & Supervisor Queries ---

  defp query_db_and_supervisors do
    db_runs = query_running_runs()
    active_agents = query_agent_supervisor()
    db_approvals = query_pending_approvals()

    {db_runs + active_agents, db_approvals}
  end

  defp query_running_runs do
    if db_query_allowed?() do
      try do
        from(r in IexCode.Runs.Run, where: r.status in ["running", "started"])
        |> IexCode.Repo.aggregate(:count, :id)
      rescue
        _ -> 0
      end
    else
      0
    end
  end

  defp query_agent_supervisor do
    if Process.whereis(IexCode.Engine.AgentSupervisor) do
      try do
        DynamicSupervisor.count_children(IexCode.Engine.AgentSupervisor).active
      rescue
        _ -> 0
      end
    else
      0
    end
  end

  defp query_pending_approvals do
    if db_query_allowed?() do
      try do
        from(a in IexCode.Runs.RunApproval,
          join: r in IexCode.Runs.Run,
          on: r.id == a.run_id,
          where:
            a.status == "pending" and
              a.target_attempt == r.attempt and
              a.target_generation == r.lease_generation
        )
        |> IexCode.Repo.aggregate(:count, :id)
      rescue
        _ -> 0
      end
    else
      0
    end
  end

  defp db_query_allowed? do
    Process.whereis(IexCode.Repo) != nil and
      (Application.get_env(:iex_code, :desktop_activity_db_sync, false) or
         not (Application.get_env(:iex_code, :env) == :test or
                System.get_env("MIX_ENV") == "test"))
  end

  # --- Normalization Helpers ---

  defp extract_approval_id(%{id: id}) when not is_nil(id), do: normalize_id(id)
  defp extract_approval_id(%{"id" => id}) when not is_nil(id), do: normalize_id(id)

  defp extract_approval_id(id) when is_binary(id) or is_integer(id) or is_atom(id),
    do: normalize_id(id)

  defp extract_approval_id(_), do: "approval_#{System.unique_integer([:positive])}"

  defp normalize_id(id) when is_binary(id), do: id
  defp normalize_id(id) when is_atom(id), do: Atom.to_string(id)
  defp normalize_id(id) when is_integer(id), do: Integer.to_string(id)
  defp normalize_id(id), do: inspect(id)
end
