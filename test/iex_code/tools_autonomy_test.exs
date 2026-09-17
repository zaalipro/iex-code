defmodule IexCode.ToolsAutonomyTest do
  use ExUnit.Case, async: false

  alias IexCode.Engine.PlanStore
  alias IexCode.Tools

  setup do
    run_id = "autonomy-#{System.unique_integer([:positive])}"
    on_exit(fn -> PlanStore.clear(run_id) end)
    %{run_id: run_id}
  end

  test "update_plan persists normalized steps", %{run_id: run_id} do
    args = %{
      "run_id" => run_id,
      "steps" => [%{"title" => "Explore"}, %{"title" => "Implement", "status" => "done"}]
    }

    assert {:ok, %{"steps" => 2, "run_id" => ^run_id}} =
             Tools.execute("update_plan", args, System.tmp_dir!())

    assert [%{"title" => "Explore", "status" => "pending"}, %{"title" => "Implement"}] =
             PlanStore.get_plan(run_id)
  end

  test "update_plan requires run context and steps", %{run_id: run_id} do
    assert {:error, :missing_run_context} =
             Tools.execute("update_plan", %{"steps" => []}, System.tmp_dir!())

    assert {:error, :plan_steps_must_be_a_list} =
             Tools.execute("update_plan", %{"run_id" => run_id}, System.tmp_dir!())
  end

  test "request_input pauses and records the question", %{run_id: run_id} do
    args = %{"run_id" => run_id, "question" => "Ship it?", "options" => ["yes", "no"]}

    assert {:pause, request} = Tools.execute("request_input", args, System.tmp_dir!())
    assert request["type"] == "input_request"
    assert request["question"] == "Ship it?"
    assert request["options"] == ["yes", "no"]
    assert PlanStore.take_input_request(run_id) == request
  end

  test "request_input requires a question", %{run_id: run_id} do
    assert {:error, :input_question_required} =
             Tools.execute("request_input", %{"run_id" => run_id}, System.tmp_dir!())
  end

  test "spawn_agent outside the loop is rejected", %{run_id: run_id} do
    assert {:error, :requires_agent_loop} =
             Tools.execute(
               "spawn_agent",
               %{"run_id" => run_id, "objective" => "do things"},
               System.tmp_dir!()
             )
  end

  test "spawn_agent requires an objective", %{run_id: run_id} do
    assert {:error, :spawn_objective_required} =
             Tools.execute("spawn_agent", %{"run_id" => run_id}, System.tmp_dir!())
  end

  test "autonomy tools are advertised with definitions" do
    names = Tools.tool_definitions() |> Enum.map(& &1.name)
    assert "update_plan" in names
    assert "request_input" in names
    assert "spawn_agent" in names
  end
end
