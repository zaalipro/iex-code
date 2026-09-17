defmodule IexCode.Engine.AgentCancellation do
  @moduledoc """
  Prompt, mailbox-independent cancellation flags for legacy subagents.

  Legacy agents (`CoderAgent`, `ExplorerAgent`, `PlannerAgent`,
  `VerifierAgent`) perform provider and tool work synchronously inside
  `handle_call`, so a `{:cancel, ...}` message sent to the agent process
  cannot be handled until that work finishes. These agents already poll a
  cooperative flag; this module owns that flag so cancellation *senders*
  can set it directly instead of routing the write through the blocked
  agent mailbox.

  Keys stay per-agent (`{agent_module, :cancelled?, session_id}`) so one
  agent restarting or starting new work can never clear another agent's
  in-flight cancellation. All key construction lives here; agents must
  delegate rather than building persistent_term keys themselves.
  """

  alias IexCode.Engine.Agents.{CoderAgent, ExplorerAgent, PlannerAgent, VerifierAgent}

  @agents [CoderAgent, ExplorerAgent, PlannerAgent, VerifierAgent]

  @doc "Returns the agent modules covered by session-wide cancellation."
  def agents, do: @agents

  @doc """
  Marks every legacy agent of `session_id` cancelled.

  The write lands immediately, even while an agent is blocked inside a
  long `handle_call`. Callers must still broadcast on the steer topic so
  mailbox-based subscribers (coordinators, fleet owners) observe the
  transition.
  """
  def cancel(session_id) when is_binary(session_id) do
    Enum.each(@agents, &set(&1, session_id, true))
    :ok
  end

  @doc "Clears cancellation for every legacy agent of `session_id`."
  def resume(session_id) when is_binary(session_id) do
    Enum.each(@agents, &set(&1, session_id, false))
    :ok
  end

  @doc "Sets the cancellation flag for one agent module and session."
  def set(agent_module, session_id, value)
      when is_atom(agent_module) and is_binary(session_id) and is_boolean(value) do
    :persistent_term.put({agent_module, :cancelled?, session_id}, value)
    :ok
  end

  @doc "Reads the cancellation flag for one agent module and session."
  def cancelled?(session_id, agent_module)
      when is_binary(session_id) and is_atom(agent_module) do
    :persistent_term.get({agent_module, :cancelled?, session_id}, false)
  end
end
