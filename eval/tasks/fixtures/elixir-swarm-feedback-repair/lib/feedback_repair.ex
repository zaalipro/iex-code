defmodule FeedbackRepair do
  @moduledoc """
  Bounded verifier feedback-repair loop state machine.
  """

  @type finding :: %{file: String.t(), line: non_neg_integer(), reason: String.t()}

  @spec new(keyword()) :: map()
  def new(opts \\ []) do
    max_rounds = Keyword.get(opts, :max_rounds, 3)

    %{
      round: 0,
      max_rounds: max_rounds,
      status: :pending,
      open_findings: [],
      resolved_findings: [],
      history: []
    }
  end

  @spec record_verdict(map(), map()) :: {:ok, map()} | {:error, term()}
  def record_verdict(state, %{status: status} = verdict)
      when status in [:approved, :changes_requested] do
    findings = Map.get(verdict, :findings, [])

    # BUG 1: accepts :approved even when findings are non-empty,
    # BUG 2: never increments round or deduplicates/sorts findings,
    # BUG 3: never updates resolved_findings or enforces max_rounds exhaustion.
    next_status = if status == :approved, do: :approved, else: :repairing

    {:ok,
     %{
       state
       | status: next_status,
         open_findings: findings,
         history: state.history ++ [%{round: state.round, status: status, findings: findings}]
     }}
  end

  def record_verdict(_state, _verdict), do: {:error, :invalid_verdict}

  @spec next_action(map()) ::
          {:halt, :approved | :max_rounds_exceeded} | {:repair, pos_integer(), [finding()]}
  def next_action(%{status: :approved}), do: {:halt, :approved}

  def next_action(state) do
    {:repair, state.round + 1, state.open_findings}
  end
end
