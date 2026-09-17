defmodule IexCode.Engine.SubAgent do
  @moduledoc """
  Runs a bounded child agent loop on behalf of a parent run (`spawn_agent`).

  The child gets its own run row (delegating the parent lease), its own
  command history, and a capped turn budget. Spawn depth is capped so a
  confused model cannot fork recursively.
  """

  alias IexCode.Engine.AgentLoop
  alias IexCode.Runs
  alias IexCode.Runs.Run

  @max_depth 2
  @max_child_turns 10
  @default_child_turns 5

  @type context :: %{
          required(:llm) => module(),
          required(:tool_executor) => module(),
          required(:lease_owner) => String.t(),
          required(:run_attempt) => pos_integer(),
          required(:run_lease_generation) => pos_integer()
        }

  @doc """
  Spawns a child run for `objective` under `parent_run_id`.

  `context` carries the loop adapters and lease delegated by the parent
  agent loop. Returns `{:ok, summary}` with the child outcome.
  """
  @spec run(String.t(), String.t(), String.t(), context(), (non_neg_integer(), String.t() ->
                                                              any())) ::
          {:ok, map()} | {:error, term()}
  def run(parent_run_id, objective, project_root, context, progress \\ fn _p, _m -> :ok end)

  def run(parent_run_id, objective, project_root, context, progress)
      when is_binary(parent_run_id) and is_binary(objective) and is_binary(project_root) and
             is_map(context) and is_function(progress, 2) do
    max_turns = child_turns(Map.get(context, :max_turns))

    with {:ok, parent} <- fetch_parent(parent_run_id),
         {:ok, depth} <- spawn_depth(parent),
         :ok <- validate_context(context),
         {:ok, child} <- create_child(parent, objective, depth, context),
         {:ok, outcome} <-
           AgentLoop.execute(child, project_root, progress,
             llm: context.llm,
             tool_executor: context.tool_executor,
             run_lease_owner: context.lease_owner,
             run_attempt: context.run_attempt,
             run_lease_generation: context.run_lease_generation
           ) do
      {:ok,
       %{
         "child_run_id" => child.id,
         "depth" => depth + 1,
         "max_turns" => max_turns,
         "turns" => Map.get(outcome, :turns, Map.get(outcome, "turns")),
         "tool_calls" => Map.get(outcome, :tool_calls, Map.get(outcome, "tool_calls")),
         "usage" => Map.get(outcome, :usage, Map.get(outcome, "usage"))
       }}
    end
  end

  def run(_parent_run_id, _objective, _project_root, _context, _progress),
    do: {:error, :invalid_sub_agent}

  defp fetch_parent(parent_run_id) do
    case Runs.get_run(parent_run_id) do
      %Run{} = run -> {:ok, run}
      _missing -> {:error, :parent_run_not_found}
    end
  end

  defp spawn_depth(%Run{metadata: %{"spawn_depth" => depth}}) when is_integer(depth) do
    if depth >= @max_depth, do: {:error, :max_spawn_depth_exceeded}, else: {:ok, depth}
  end

  defp spawn_depth(%Run{}), do: {:ok, 0}

  defp validate_context(%{llm: llm, tool_executor: tool_executor})
       when is_atom(llm) and is_atom(tool_executor) do
    cond do
      not adapter?(llm, :chat, 5) -> {:error, :invalid_sub_agent_llm}
      not adapter?(tool_executor, :execute, 4) -> {:error, :invalid_sub_agent_tools}
      true -> :ok
    end
  end

  defp validate_context(_context), do: {:error, :invalid_sub_agent_context}

  defp adapter?(module, function, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end

  defp child_lease_expiry(%{lease_expires_at: %DateTime{} = expires_at}) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt,
      do: expires_at,
      else: DateTime.add(DateTime.utc_now(), 300, :second)
  end

  defp child_lease_expiry(_parent), do: DateTime.add(DateTime.utc_now(), 300, :second)

  defp create_child(parent, objective, depth, context) do
    Runs.create_run(%{
      project_id: parent.project_id,
      session_id: parent.session_id,
      objective: objective,
      kind: "coding_agent",
      mode: "single",
      status: "running",
      lease_owner: context.lease_owner,
      attempt: context.run_attempt,
      lease_generation: context.run_lease_generation,
      lease_expires_at: child_lease_expiry(parent),
      metadata: %{
        "sub_agent" => true,
        "parent_run_id" => parent.id,
        "spawn_depth" => depth + 1,
        "execution_policy" => %{"agent_max_turns" => child_turns(Map.get(context, :max_turns))}
      }
    })
  end

  defp child_turns(nil), do: @default_child_turns
  defp child_turns(turns) when is_integer(turns) and turns > 0, do: min(turns, @max_child_turns)
  defp child_turns(_turns), do: @default_child_turns
end
