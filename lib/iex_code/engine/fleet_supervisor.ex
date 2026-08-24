defmodule IexCode.Engine.FleetSupervisor do
  @moduledoc "Dynamic supervisor owning one isolated supervision tree per durable run."
  use DynamicSupervisor

  alias IexCode.Engine.{AgentRegistry, FleetManager, FleetTopology, RunFleetSupervisor}

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  def ensure_started(run, opts \\ []) do
    persisted = IexCode.Runs.get_run(run.id)

    with %IexCode.Runs.Run{} = persisted <- persisted,
         true <-
           persisted.session_id == run.session_id and persisted.project_id == run.project_id,
         :ok <- validate_execution_engine(persisted) do
      do_ensure_started(persisted, opts)
    else
      nil -> {:error, :run_not_found}
      false -> {:error, :run_scope_mismatch}
      {:error, {:execution_engine_unavailable, _engine}} = error -> error
    end
  end

  defp do_ensure_started(run, opts) do
    case AgentRegistry.whereis_fleet(run.id, :supervisor) do
      nil ->
        case DynamicSupervisor.start_child(__MODULE__, {RunFleetSupervisor, [run: run] ++ opts}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end

      pid ->
        {:ok, pid}
    end
  end

  def stop(run_id) when is_binary(run_id) do
    case AgentRegistry.whereis_fleet(run_id, :supervisor) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(__MODULE__, pid)
    end
  end

  def attach(run, opts \\ []) do
    persisted = IexCode.Runs.get_run(run.id)

    with %IexCode.Runs.Run{} = persisted <- persisted,
         true <-
           persisted.session_id == run.session_id and persisted.project_id == run.project_id,
         :ok <- validate_execution_engine(persisted),
         :ok <- validate_delegation(persisted, opts[:workspace_lock_delegation]),
         %IexCode.Sessions.Session{} = session <-
           IexCode.Sessions.get_session(persisted.session_id),
         project <- IexCode.Projects.get_project!(persisted.project_id) do
      count = Keyword.get(opts, :agent_count, IexCode.Settings.get_settings().swarm_agent_count)
      manifest = FleetTopology.manifest(count)

      trusted_opts =
        opts
        |> Keyword.put(:session, session)
        |> Keyword.put(:project_root, project.root_path)

      with {:ok, _pid} <- ensure_started(persisted, trusted_opts),
           {:ok, rows} <- IexCode.Runs.ensure_run_agents(persisted, manifest, max_agents: 32),
           {:ok, agents} <- FleetManager.activate(persisted.id, rows, trusted_opts) do
        {:ok, agents}
      end
    else
      nil -> {:error, :run_not_found}
      false -> {:error, :run_scope_mismatch}
      {:error, {:execution_engine_unavailable, _engine}} = error -> error
      _ -> {:error, :run_scope_mismatch}
    end
  end

  defp validate_execution_engine(%IexCode.Runs.Run{execution_engine: "legacy_v1"}), do: :ok

  defp validate_execution_engine(%IexCode.Runs.Run{execution_engine: engine}),
    do: {:error, {:execution_engine_unavailable, engine}}

  defp validate_delegation(_run, nil), do: :ok

  defp validate_delegation(run, %IexCode.WorkspaceLocks{} = delegation) do
    if delegation.run_id == run.id and delegation.session_id == run.session_id and
         delegation.project_id == run.project_id do
      IexCode.WorkspaceLocks.assert(delegation)
    else
      {:error, :workspace_delegation_scope_mismatch}
    end
  end

  defp validate_delegation(_run, _delegation), do: {:error, :invalid_workspace_delegation}
end
