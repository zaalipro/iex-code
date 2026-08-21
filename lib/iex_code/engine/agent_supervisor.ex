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
    do_start_agent(session_id, agent_type, opts, 3)
  end

  defp do_start_agent(_session_id, _agent_type, _opts, 0),
    do: {:error, :agent_start_retries_exhausted}

  defp do_start_agent(session_id, agent_type, opts, attempts) do
    module = resolve_agent_module(agent_type)
    child_spec = {module, Keyword.merge(opts, session_id: session_id)}

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} ->
        allow_sandbox(pid)
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        # Race: the registered process may have already died; verify before reusing it.
        if is_pid(pid) and Process.alive?(pid) do
          allow_sandbox(pid)
          {:ok, pid}
        else
          Logger.warning(
            "AgentSupervisor: stale already_started pid #{inspect(pid)} for " <>
              "#{inspect(agent_type)} in session #{inspect(session_id)}; retrying start"
          )

          do_start_agent(session_id, agent_type, opts, attempts - 1)
        end

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

  @stop_all_deadline_ms 5_000

  @doc """
  Terminates all running subagents for a session.

  Agents are shut down in parallel with an overall deadline of #{@stop_all_deadline_ms}ms;
  any stragglers still alive past the deadline are killed outright.
  """
  def stop_all_agents(session_id) do
    _ = :sys.get_state(AgentRegistry)

    agents = AgentRegistry.list_agents(session_id)
    deadline = System.monotonic_time(:millisecond) + @stop_all_deadline_ms

    tasks =
      for {_type, pid} <- agents do
        Task.async(fn -> DynamicSupervisor.terminate_child(__MODULE__, pid) end)
      end

    Enum.each(tasks, fn task ->
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      case Task.yield(task, remaining) do
        {:ok, _result} ->
          :ok

        {:exit, _reason} ->
          :ok

        nil ->
          _ = Task.shutdown(task, :brutal_kill)
          :ok
      end
    end)

    # Guarantee no stragglers survive past the overall deadline.
    for {_type, pid} <- agents do
      if Process.alive?(pid), do: Process.exit(pid, :kill)
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

  Raises `ArgumentError` for unknown/junk types instead of returning a module
  that would crash later during `start_child`.
  """
  def resolve_agent_module(type) do
    case AgentRegistry.normalize_type(type) do
      :planner ->
        IexCode.Engine.Agents.PlannerAgent

      :explorer ->
        IexCode.Engine.Agents.ExplorerAgent

      :coder ->
        IexCode.Engine.Agents.CoderAgent

      :verifier ->
        IexCode.Engine.Agents.VerifierAgent

      mod when is_atom(mod) ->
        if Code.ensure_loaded?(mod) and function_exported?(mod, :start_link, 1) do
          mod
        else
          raise ArgumentError, "unknown agent type: #{inspect(type)}"
        end

      other ->
        raise ArgumentError, "unknown agent type: #{inspect(other)}"
    end
  end
end
