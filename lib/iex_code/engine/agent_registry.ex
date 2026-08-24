defmodule IexCode.Engine.AgentRegistry do
  @moduledoc """
  Registry for active subagent GenServer processes.
  Keys are `{session_id, agent_type}` tuples ensuring unique registration per session and agent type.
  """

  @doc """
  Returns a child specification for starting the Registry under a supervisor.
  """
  def child_spec(opts \\ []) do
    Registry.child_spec(
      keys: :unique,
      name: Keyword.get(opts, :name, __MODULE__)
    )
  end

  @doc """
  Generates a via-tuple for registering or calling a subagent process.
  """
  def via_tuple(session_id, agent_type) do
    {:via, Registry, {__MODULE__, {session_id, normalize_type(agent_type)}}}
  end

  @doc "Returns the run-scoped registration name for one durable fleet agent."
  def via_agent(run_id, agent_id) when is_binary(run_id) and is_binary(agent_id) do
    {:via, Registry, {__MODULE__, {:run_agent, run_id, agent_id}}}
  end

  @doc "Returns the registration name for a component owned by one durable run fleet."
  def via_fleet(run_id, component) when is_binary(run_id) and is_atom(component) do
    {:via, Registry, {__MODULE__, {:run_fleet, run_id, component}}}
  end

  @doc """
  Looks up the PID of a registered subagent by session ID and agent type.
  Returns `pid` or `nil` if not found.
  """
  def whereis(session_id, agent_type) do
    case Registry.lookup(__MODULE__, {session_id, normalize_type(agent_type)}) do
      [{pid, _value}] ->
        if Process.alive?(pid), do: pid, else: nil

      [] ->
        nil
    end
  end

  @doc "Looks up a durable agent without falling back to a session-scoped process."
  def whereis_agent(run_id, agent_id) when is_binary(run_id) and is_binary(agent_id) do
    lookup({:run_agent, run_id, agent_id})
  end

  def agent_registration(run_id, agent_id) when is_binary(run_id) and is_binary(agent_id) do
    case Registry.lookup(__MODULE__, {:run_agent, run_id, agent_id}) do
      [{pid, metadata}] when is_pid(pid) -> {:ok, pid, metadata}
      [] -> {:error, :not_registered}
    end
  end

  @doc "Looks up a component in a durable run's supervision tree."
  def whereis_fleet(run_id, component) when is_binary(run_id) and is_atom(component) do
    lookup({:run_fleet, run_id, component})
  end

  @doc "Lists live durable agents as `{agent_id, pid, metadata}` tuples."
  def list_run_agents(run_id) when is_binary(run_id) do
    __MODULE__
    |> Registry.select([
      {{{:run_agent, run_id, :"$1"}, :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}
    ])
    |> Enum.filter(fn {_agent_id, pid, _metadata} -> Process.alive?(pid) end)
  end

  @doc false
  def put_agent_metadata(run_id, agent_id, metadata)
      when is_binary(run_id) and is_binary(agent_id) and is_map(metadata) do
    case Registry.update_value(__MODULE__, {:run_agent, run_id, agent_id}, fn _ -> metadata end) do
      {new_value, old_value} -> {:ok, new_value, old_value}
      :error -> {:error, :not_registered}
    end
  end

  @doc """
  Returns a list of `{agent_type, pid}` tuples for all running subagents of a session.

  Enumerates the Registry directly so non-canonical agent types are visible too,
  not just the four canonical ones.
  """
  def list_agents(session_id) do
    __MODULE__
    |> Registry.select([{{{session_id, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.filter(fn {_type, pid} -> Process.alive?(pid) end)
  end

  @doc """
  Normalizes agent type to a canonical atom (`:planner`, `:explorer`, `:coder`, `:verifier`).
  """
  def normalize_type(:planner), do: :planner
  def normalize_type(:explorer), do: :explorer
  def normalize_type(:coder), do: :coder
  def normalize_type(:verifier), do: :verifier
  def normalize_type("planner"), do: :planner
  def normalize_type("explorer"), do: :explorer
  def normalize_type("coder"), do: :coder
  def normalize_type("verifier"), do: :verifier
  def normalize_type("PlannerAgent"), do: :planner
  def normalize_type("ExplorerAgent"), do: :explorer
  def normalize_type("CoderAgent"), do: :coder
  def normalize_type("VerifierAgent"), do: :verifier
  def normalize_type(type) when is_atom(type), do: type

  def normalize_type(type) when is_binary(type) do
    String.to_existing_atom(String.downcase(type))
  rescue
    # Unknown agent type: keep the binary so we never create atoms dynamically.
    # Registration and lookup both go through this function, so keys stay consistent.
    _ -> type
  end

  defp lookup(key) do
    case Registry.lookup(__MODULE__, key) do
      [{pid, _value}] -> if Process.alive?(pid), do: pid, else: nil
      [] -> nil
    end
  end
end
