defmodule IexCode.Runs.ExecutionEngineTest do
  use ExUnit.Case, async: true

  alias IexCode.Runs.ExecutionEngine

  test "legacy_v1 validates structure without scheduling dependency metadata" do
    steps = [
      %{key: "prepare", kind: "prepare", depends_on: []},
      %{key: "execute", kind: "execute", depends_on: ["prepare"]}
    ]

    assert :ok = ExecutionEngine.validate_manifest(%{execution_engine: "legacy_v1"}, steps)
  end

  test "legacy_v1 rejects duplicate identities" do
    steps = [%{key: "same", kind: "prepare"}, %{key: "same", kind: "execute"}]

    assert {:error, :duplicate_step_key} =
             ExecutionEngine.validate_manifest(%{execution_engine: "legacy_v1"}, steps)
  end

  test "dag_v1 fails closed until its scheduler exists" do
    assert {:error, {:execution_engine_unavailable, "dag_v1"}} =
             ExecutionEngine.validate_manifest(%{execution_engine: "dag_v1"}, [])
  end

  test "unknown engines never fall back to legacy" do
    assert {:error, {:unknown_execution_engine, "invented"}} =
             ExecutionEngine.validate_manifest(%{execution_engine: "invented"}, [])
  end

  test "descriptors truthfully expose availability" do
    assert %{id: "legacy_v1", available: true} in ExecutionEngine.descriptors()
    assert %{id: "dag_v1", available: false} in ExecutionEngine.descriptors()
  end
end
