defmodule IexCode.Eval.TaskTest do
  use ExUnit.Case, async: true

  alias IexCode.Eval.Task

  test "parses a valid task with defaults" do
    assert {:ok, task} =
             Task.from_map(%{
               "id" => "t1",
               "prompt" => "Do it",
               "repo" => "fixtures/t1",
               "test_cmd" => ["sh", "grade.sh"]
             })

    assert task.id == "t1"
    assert task.timeout_ms == 120_000
    assert task.max_turns == 8
  end

  test "rejects missing or blank fields" do
    assert {:error, {:eval_task_field, "id"}} = Task.from_map(%{})
    assert {:error, {:eval_task_field, "prompt"}} = Task.from_map(%{"id" => "x"})

    assert {:error, {:eval_task_field, "test_cmd"}} =
             Task.from_map(%{"id" => "x", "prompt" => "p", "repo" => "r", "test_cmd" => []})
  end

  test "rejects invalid integers" do
    base = %{"id" => "x", "prompt" => "p", "repo" => "r", "test_cmd" => ["true"]}

    assert {:error, {:eval_task_field, "timeout_ms"}} =
             Task.from_map(Map.put(base, "timeout_ms", -1))

    assert {:error, {:eval_task_field, "max_turns"}} =
             Task.from_map(Map.put(base, "max_turns", "many"))
  end

  test "load_dir reads sorted tasks and rejects bad files" do
    dir = Path.join(System.tmp_dir!(), "eval-tasks-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    File.write!(
      Path.join(dir, "b.eval.json"),
      ~s({"id":"b","prompt":"p","repo":"r","test_cmd":["true"]})
    )

    File.write!(
      Path.join(dir, "a.eval.json"),
      ~s({"id":"a","prompt":"p","repo":"r","test_cmd":["true"]})
    )

    File.write!(Path.join(dir, "notes.txt"), "ignored")

    assert {:ok, [first, second]} = Task.load_dir(dir)
    assert [first.id, second.id] == ["a", "b"]

    File.write!(Path.join(dir, "bad.eval.json"), "{broken")
    assert {:error, {:eval_task_json, _, _}} = Task.load_dir(dir)
  end

  test "load_dir rejects a missing directory" do
    assert {:error, {:eval_tasks_dir_missing, _}} = Task.load_dir("/nope/eval-tasks")
  end
end
