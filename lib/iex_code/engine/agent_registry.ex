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
end
