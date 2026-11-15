defmodule IexCode.Eval.RunnerTest do
  use ExUnit.Case, async: true

  alias IexCode.Eval.Runner

  setup do
    dir = Path.join(System.tmp_dir!(), "eval-run-#{System.unique_integer([:positive])}")
    fixture = Path.join(dir, "fixtures/pass")
    File.mkdir_p!(fixture)
    File.write!(Path.join(fixture, "marker.txt"), "hello\n")

    File.write!(
      Path.join(dir, "pass.eval.json"),
      ~s({"id":"pass","prompt":"p","repo":"fixtures/pass","test_cmd":["test","-f","marker.txt"]})
    )

    File.write!(
      Path.join(dir, "fail.eval.json"),
      ~s({"id":"fail","prompt":"p","repo":"fixtures/pass","test_cmd":["test","-f","missing.txt"]})
    )

    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  test "grades samples and aggregates pass@k", %{dir: dir} do
    loop_fn = fn _prompt, workdir, _task ->
      assert File.dir?(workdir)
      assert File.exists?(Path.join(workdir, "marker.txt"))
      {:ok, %{turns: 1}}
    end

    assert {:ok, results} = Runner.run(dir, samples: 2, ks: [1, 2], loop_fn: loop_fn)
    assert length(results.tasks) == 2

    pass = Enum.find(results.tasks, &(&1.id == "pass"))
    assert pass.summary.passed == 2
    assert pass.summary.pass_at_k == %{1 => 1.0, 2 => 1.0}

    fail = Enum.find(results.tasks, &(&1.id == "fail"))
    assert fail.summary.passed == 0

    assert results.aggregate.samples == 4
    assert results.aggregate.passed == 2
    assert results.aggregate.pass_rate == 0.5
  end

  test "loop errors count as failures", %{dir: dir} do
    assert {:ok, results} =
             Runner.run(dir,
               samples: 1,
               loop_fn: fn _prompt, _workdir, _task -> {:error, :blew_up} end
             )

    assert results.aggregate.passed == 0
  end

  test "missing fixtures fail gracefully", %{dir: dir} do
    File.write!(
      Path.join(dir, "ghost.eval.json"),
      ~s({"id":"ghost","prompt":"p","repo":"fixtures/nope","test_cmd":["true"]})
    )

    assert {:ok, results} =
             Runner.run(dir, samples: 1, loop_fn: fn _, _, _ -> {:ok, %{}} end)

    ghost = Enum.find(results.tasks, &(&1.id == "ghost"))
    assert ghost.summary.passed == 0
    assert {:eval_fixture_missing, _} = hd(ghost.samples).error
  end

  test "format_report renders tasks and aggregate", %{dir: dir} do
    {:ok, results} = Runner.run(dir, samples: 1, loop_fn: fn _, _, _ -> {:ok, %{}} end)
    report = Runner.format_report(results)

    assert report =~ "eval: 2 task(s) x 1 sample(s)"
    assert report =~ "pass: 1/1 passed"
    assert report =~ "fail: 0/1 passed"
    assert report =~ "aggregate: 1/2 passed"
  end

  test "rejects bad options", %{dir: dir} do
    assert {:error, :eval_bad_samples} =
             Runner.run(dir, samples: 0, loop_fn: fn _, _, _ -> {:ok, %{}} end)

    assert {:error, :eval_bad_ks} =
             Runner.run(dir, ks: [], loop_fn: fn _, _, _ -> {:ok, %{}} end)

    assert {:error, :eval_bad_only} =
             Runner.run(dir, only: "pass", loop_fn: fn _, _, _ -> {:ok, %{}} end)
  end

  test "records duration_ms, efficiency metrics, and cleans up temp workdirs by default", %{
    dir: dir
  } do
    assert {:ok, results} =
             Runner.run(dir,
               samples: 1,
               only: ["pass"],
               loop_fn: fn _prompt, workdir, _task ->
                 assert File.dir?(workdir)

                 {:ok,
                  %{
                    turns: 3,
                    tool_calls: 2,
                    usage: %{input_tokens: 120, output_tokens: 45, cost_cents: 0}
                  }}
               end
             )

    assert [task] = results.tasks
    assert task.id == "pass"
    assert [sample] = task.samples
    assert sample.passed
    assert is_integer(sample.duration_ms) and sample.duration_ms >= 0
    assert sample.turns == 3
    assert sample.tool_calls == 2
    assert sample.input_tokens == 120
    assert sample.output_tokens == 45
    assert sample.cost_cents == 0
    refute File.exists?(sample.workdir)
  end

  test "keep_workdir preserves workdir and filters work by category and tag", %{dir: dir} do
    File.write!(
      Path.join(dir, "tagged.eval.json"),
      ~s({"id":"tagged","prompt":"p","repo":"fixtures/pass","test_cmd":["test","-f","marker.txt"],"category":"bugfix","tags":["otp"]})
    )

    assert {:ok, results} =
             Runner.run(dir,
               category: "bugfix",
               tag: "otp",
               keep_workdir: true,
               loop_fn: fn _prompt, _workdir, _task -> {:ok, %{turns: 1}} end
             )

    assert [%{id: "tagged", samples: [sample]}] = results.tasks
    on_exit(fn -> File.rm_rf(sample.workdir) end)
    assert File.dir?(sample.workdir)
    assert results.by_category["bugfix"].passed == 1
  end

  test "to_json_report serializes results including error tuples cleanly", %{dir: dir} do
    {:ok, results} =
      Runner.run(dir,
        samples: 1,
        loop_fn: fn _prompt, _workdir, task ->
          if task.id == "pass",
            do:
              {:ok, %{turns: 2, tool_calls: 1, input_tokens: 10, output_tokens: 5, cost_cents: 1}},
            else: {:error, :simulated_failure}
        end
      )

    json = Runner.to_json_report(results)
    decoded = Jason.decode!(json)

    assert decoded["samples"] == 1
    assert decoded["aggregate"]["passed"] == 1
    assert decoded["aggregate"]["telemetry"]["total_turns"] == 2
    assert decoded["by_category"]["general"]["samples"] == 2
    assert length(decoded["tasks"]) == 2
  end

  test "grade timeout kills the entire child OS process group including grandchildren", %{
    dir: dir
  } do
    pid_file =
      Path.join(System.tmp_dir!(), "eval-grandchild-#{System.unique_integer([:positive])}.pid")

    on_exit(fn -> File.rm_rf(pid_file) end)

    File.write!(
      Path.join(dir, "timeout.eval.json"),
      Jason.encode!(%{
        "id" => "timeout",
        "prompt" => "p",
        "repo" => "fixtures/pass",
        "test_cmd" => [
          "sh",
          "-c",
          "sleep 30 & echo $! > #{pid_file}; wait"
        ],
        "timeout_ms" => 150
      })
    )

    assert {:ok, results} =
             Runner.run(dir,
               only: ["timeout"],
               loop_fn: fn _prompt, _workdir, _task -> {:ok, %{turns: 1}} end
             )

    assert [%{samples: [sample]}] = results.tasks
    refute sample.passed
    assert sample.grade == :eval_grade_timeout

    assert File.exists?(pid_file)
    grandchild_pid = pid_file |> File.read!() |> String.trim()
    assert grandchild_pid =~ ~r/^\d+$/

    {_out, exit_code} = System.cmd("kill", ["-0", grandchild_pid], stderr_to_stdout: true)
    assert exit_code != 0
  end
end
