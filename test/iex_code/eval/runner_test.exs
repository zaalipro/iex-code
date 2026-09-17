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
  end
end
