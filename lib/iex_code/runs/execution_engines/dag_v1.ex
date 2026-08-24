defmodule IexCode.Runs.ExecutionEngines.DagV1 do
  @moduledoc """
  Reserved, fail-closed adapter for the future dependency-aware scheduler.

  `dag_v1` is intentionally unavailable until ready-node claims, per-step
  attempts, leases, fencing, typed executors, and checkpoint policy are all
  implemented. Persisting or dispatching it must return an explicit error rather
  than silently falling back to legacy execution.
  """

  @behaviour IexCode.Runs.ExecutionEngine

  @impl true
  def id, do: "dag_v1"

  @impl true
  def available?, do: false

  @impl true
  def validate_manifest(_run_or_attrs, _steps),
    do: {:error, {:execution_engine_unavailable, "dag_v1"}}
end
