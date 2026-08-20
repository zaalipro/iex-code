defmodule IexCode.Engine.AgentSupervisor do
  @moduledoc """
  DynamicSupervisor managing the lifecycles of dedicated subagent GenServers
  (PlannerAgent, ExplorerAgent, CoderAgent, VerifierAgent).
  """
  use DynamicSupervisor
  require Logger
  alias IexCode.Engine.AgentRegistry

  def start_link(init_arg \\ []) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts or retrieves a dedicated subagent GenServer process under supervision.
  Returns `{:ok, pid}` or `{:error, reason}`.
  """
  def start_agent(session_id, agent_type, opts \\ []) do
    module = resolve_agent_module(agent_type)
    child_spec = {module, Keyword.merge(opts, session_id: session_id)}

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} ->
        allow_sandbox(pid)
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        allow_sandbox(pid)
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp allow_sandbox(pid) do
    if Code.ensure_loaded?(Ecto.Adapters.SQL.Sandbox) do
      try do
        Ecto.Adapters.SQL.Sandbox.allow(IexCode.Repo, self(), pid)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end
  end

  @doc """
  Terminates a subagent process if running.
  """
  def stop_agent(session_id, agent_type) do
    _ = :sys.get_state(AgentRegistry)

    case AgentRegistry.whereis(session_id, agent_type) do
      nil ->
        {:error, :not_found}

      pid ->
        ref = Process.monitor(pid)
        res = DynamicSupervisor.terminate_child(__MODULE__, pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          1_000 -> :ok
        end

        _ = :sys.get_state(AgentRegistry)
        res
    end
  end

  @doc """
  Terminates all running subagents for a session.
  """
  def stop_all_agents(session_id) do
    _ = :sys.get_state(AgentRegistry)

    for {_type, pid} <- AgentRegistry.list_agents(session_id) do
      ref = Process.monitor(pid)
      DynamicSupervisor.terminate_child(__MODULE__, pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        1_000 -> :ok
      end
    end

    _ = :sys.get_state(AgentRegistry)
    :ok
  end

  @doc """
  Finds the PID of a subagent process for a given session and agent type.
  """
  def find_agent(session_id, agent_type) do
    AgentRegistry.whereis(session_id, agent_type)
  end

  @doc """
  Resolves the GenServer module corresponding to an agent type.
  """
  def resolve_agent_module(type) do
    case AgentRegistry.normalize_type(type) do
      :planner -> IexCode.Engine.Agents.PlannerAgent
      :explorer -> IexCode.Engine.Agents.ExplorerAgent
      :coder -> IexCode.Engine.Agents.CoderAgent
      :verifier -> IexCode.Engine.Agents.VerifierAgent
      mod when is_atom(mod) -> mod
    end
  end
end
