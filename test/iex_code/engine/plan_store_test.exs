defmodule IexCode.Engine.PlanStoreTest do
  use ExUnit.Case, async: true

  alias IexCode.Engine.PlanStore

  setup do
    name = :"plan_store_#{System.unique_integer([:positive])}"
    server = start_supervised!({PlanStore, name: name})
    %{server: server}
  end

  test "stores and normalizes plan steps", %{server: server} do
    run_id = "run-#{System.unique_integer([:positive])}"

    assert {:ok, steps} =
             PlanStore.update_plan(server, run_id, [
               %{"title" => "Inspect", "status" => "in_progress"},
               %{"title" => "Fix", "status" => "bogus", "detail" => "x"}
             ])

    assert steps == [
             %{"title" => "Inspect", "status" => "in_progress", "detail" => ""},
             %{"title" => "Fix", "status" => "pending", "detail" => "x"}
           ]

    assert PlanStore.get_plan(server, run_id) == steps
  end

  test "rejects steps without titles", %{server: server} do
    run_id = "run-#{System.unique_integer([:positive])}"

    assert {:error, {:plan_step_missing_title, 2}} =
             PlanStore.update_plan(server, run_id, [
               %{"title" => "ok"},
               %{"detail" => "no title"},
               %{"title" => "  "}
             ])

    assert PlanStore.get_plan(server, run_id) == []
  end

  test "rejects non-list steps", %{server: server} do
    assert {:error, :plan_steps_must_be_a_list} =
             PlanStore.update_plan(server, "run-x", "not-a-list")
  end

  test "input requests are take-once", %{server: server} do
    run_id = "run-#{System.unique_integer([:positive])}"
    assert PlanStore.take_input_request(server, run_id) == nil

    :ok = PlanStore.put_input_request(server, run_id, %{"question" => "Which?"})
    assert PlanStore.take_input_request(server, run_id) == %{"question" => "Which?"}
    assert PlanStore.take_input_request(server, run_id) == nil
  end

  test "pause bundles are take-once", %{server: server} do
    run_id = "run-#{System.unique_integer([:positive])}"
    assert PlanStore.take_pause(server, run_id) == nil

    :ok = PlanStore.put_pause(server, run_id, %{turn: 3})
    assert PlanStore.take_pause(server, run_id) == %{turn: 3}
    assert PlanStore.take_pause(server, run_id) == nil
  end

  test "clear drops everything for a run", %{server: server} do
    run_id = "run-#{System.unique_integer([:positive])}"

    {:ok, _} = PlanStore.update_plan(server, run_id, [%{"title" => "t"}])
    :ok = PlanStore.put_pause(server, run_id, %{turn: 1})
    :ok = PlanStore.clear(server, run_id)

    assert PlanStore.get_plan(server, run_id) == []
    assert PlanStore.take_pause(server, run_id) == nil
  end

  test "runs are isolated from each other", %{server: server} do
    {:ok, _} = PlanStore.update_plan(server, "run-a", [%{"title" => "a"}])
    {:ok, _} = PlanStore.update_plan(server, "run-b", [%{"title" => "b"}])

    assert [%{"title" => "a"}] = PlanStore.get_plan(server, "run-a")
    assert [%{"title" => "b"}] = PlanStore.get_plan(server, "run-b")
  end
end
