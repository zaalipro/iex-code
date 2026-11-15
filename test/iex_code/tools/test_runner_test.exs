defmodule IexCode.Tools.TestRunnerTest do
  use ExUnit.Case, async: false
  alias IexCode.Tools.TestRunner
  alias IexCode.Tools.TestRunner.Result

  describe "run/1 and run_file/3" do
    @tag :tmp_dir
    test "executes live test suite on a temporary mix project", %{tmp_dir: tmp_dir} do
      setup_temp_project(tmp_dir)

      assert {:ok, %Result{} = result} =
               TestRunner.run(project_root: tmp_dir, paths: ["test/sample_test.exs"])

      assert result.status == :passed
      assert result.total == 1
      assert result.failures_count == 0
    end

    @tag :tmp_dir
    test "executes with progress callback", %{tmp_dir: tmp_dir} do
      setup_temp_project(tmp_dir)
      {:ok, agent} = Agent.start_link(fn -> [] end)

      on_progress = fn pct, msg ->
        Agent.update(agent, fn list -> [{pct, msg} | list] end)
      end

      assert {:ok, %Result{}} =
               TestRunner.run(
                 project_root: tmp_dir,
                 paths: ["test/sample_test.exs"],
                 on_progress: on_progress
               )

      progress_events = Agent.get(agent, & &1)
      Agent.stop(agent)

      assert length(progress_events) >= 2
      assert Enum.any?(progress_events, fn {pct, _} -> pct == 100 end)
    end

    test "handles execution timeout gracefully" do
      # Run with 1ms timeout to force timeout
      assert {:error, :timeout} =
               TestRunner.run(
                 paths: ["test/sample_test.exs"],
                 timeout_ms: 1
               )
    end

    @tag :tmp_dir
    test "reaps entire POSIX process group on timeout with zero orphan grandchildren", %{
      tmp_dir: tmp_dir
    } do
      setup_temp_project(tmp_dir)

      # 1. Real mix test BEAM OS process is reaped on timeout
      beam_pid_file = Path.join(tmp_dir, "beam.pid")

      File.write!(Path.join(tmp_dir, "test/slow_beam_test.exs"), """
      defmodule SlowBeamTest do
        use ExUnit.Case

        test "blocks indefinitely inside BEAM" do
          File.write!(#{inspect(beam_pid_file)}, to_string(:os.getpid()))
          Process.sleep(30_000)
        end
      end
      """)

      assert {:error, :timeout} =
               TestRunner.run(
                 project_root: tmp_dir,
                 paths: ["test/slow_beam_test.exs"],
                 timeout_ms: 1_500
               )

      if File.exists?(beam_pid_file) do
        beam_pid = beam_pid_file |> File.read!() |> String.trim()
        assert beam_pid =~ ~r/^\d+$/
        refute pid_alive?(beam_pid, 500), "Expected BEAM pid #{beam_pid} to be reaped"
      end

      # 2. Subshell background grandchild spawned in the mix process group is also reaped
      fake_bin = Path.join(tmp_dir, "fake_bin")
      File.mkdir_p!(fake_bin)
      grandchild_pid_file = Path.join(tmp_dir, "grandchild.pid")
      fake_mix = Path.join(fake_bin, "mix")

      File.write!(fake_mix, """
      #!/bin/sh
      sh -c 'sleep 30 & echo $! > "#{grandchild_pid_file}"; wait'
      """)

      File.chmod!(fake_mix, 0o755)

      with_temp_path(fake_bin, fn ->
        assert {:error, :timeout} =
                 TestRunner.run(
                   project_root: tmp_dir,
                   paths: ["test/sample_test.exs"],
                   timeout_ms: 800
                 )
      end)

      assert File.exists?(grandchild_pid_file)
      grandchild_pid = grandchild_pid_file |> File.read!() |> String.trim()
      assert grandchild_pid =~ ~r/^\d+$/

      refute pid_alive?(grandchild_pid, 500),
             "Expected grandchild pid #{grandchild_pid} to be reaped"
    end

    @tag :tmp_dir
    test "supports changed: true / changed_files and fallback modes", %{tmp_dir: tmp_dir} do
      setup_temp_project(tmp_dir)

      File.mkdir_p!(Path.join(tmp_dir, "lib"))

      File.write!(Path.join(tmp_dir, "lib/math_ops.ex"), """
      defmodule MathOps do
        def add(a, b), do: a + b
      end
      """)

      File.write!(Path.join(tmp_dir, "test/math_ops_test.exs"), """
      defmodule MathOpsTest do
        use ExUnit.Case
        test "adds" do
          assert MathOps.add(2, 3) == 5
        end
      end
      """)

      # Explicit changed_files runs only matching test(s)
      assert {:ok, %Result{} = res} =
               TestRunner.run(
                 project_root: tmp_dir,
                 changed: true,
                 changed_files: ["lib/math_ops.ex"]
               )

      assert res.status == :passed
      assert res.total == 1

      # No matching tests + fallback: :none returns clean 0-test passed result
      assert {:ok, %Result{} = empty_res} =
               TestRunner.run(
                 project_root: tmp_dir,
                 changed: true,
                 changed_files: ["README.md"],
                 fallback: :none
               )

      assert empty_res.status == :passed
      assert empty_res.total == 0
      assert empty_res.passed == 0
      assert empty_res.failures_count == 0
      assert empty_res.exit_code == 0

      # No matching tests + fallback: :stale executes mix test --stale
      assert {:ok, %Result{} = stale_res} =
               TestRunner.run(
                 project_root: tmp_dir,
                 changed: true,
                 changed_files: ["README.md"],
                 fallback: :stale
               )

      assert stale_res.status == :passed
      assert stale_res.total >= 1
    end

    @tag :tmp_dir
    test "injects MIX_TEST_PARTITION and cleans temporary *_test<partition>.db* files in after",
         %{
           tmp_dir: tmp_dir
         } do
      setup_temp_project(tmp_dir)

      unpartitioned_db = Path.join(tmp_dir, "temp_app_test.db")
      File.write!(unpartitioned_db, "keep me")

      File.write!(Path.join(tmp_dir, "test/partition_test.exs"), """
      defmodule PartitionTest do
        use ExUnit.Case

        test "writes partition db artifacts" do
          part = System.get_env("MIX_TEST_PARTITION")
          assert is_binary(part) and part != ""
          File.write!("temp_app_test\#{part}.db", "db")
          File.write!("temp_app_test\#{part}.db-wal", "wal")
          File.write!("temp_app_test\#{part}.db-shm", "shm")
        end
      end
      """)

      assert {:ok, %Result{status: :passed, total: 1}} =
               TestRunner.run(
                 project_root: tmp_dir,
                 paths: ["test/partition_test.exs"],
                 partition: "_p_test"
               )

      refute File.exists?(Path.join(tmp_dir, "temp_app_test_p_test.db"))
      refute File.exists?(Path.join(tmp_dir, "temp_app_test_p_test.db-wal"))
      refute File.exists?(Path.join(tmp_dir, "temp_app_test_p_test.db-shm"))
      assert File.exists?(unpartitioned_db)

      assert {:ok, %Result{status: :passed, total: 1}} =
               TestRunner.run(
                 project_root: tmp_dir,
                 paths: ["test/partition_test.exs"],
                 partition: :auto
               )

      assert Path.wildcard(Path.join(tmp_dir, "*_test_tr_*.db*")) == []
      assert File.exists?(unpartitioned_db)
    end
  end

  defp setup_temp_project(tmp_dir) do
    File.write!(Path.join(tmp_dir, "mix.exs"), """
    defmodule TempApp.MixProject do
      use Mix.Project
      def project do
        [app: :temp_app, version: "0.1.0", elixirc_paths: elixirc_paths(Mix.env())]
      end

      defp elixirc_paths(_), do: ["lib"]
    end
    """)

    test_dir = Path.join(tmp_dir, "test")
    File.mkdir_p!(test_dir)
    File.write!(Path.join(test_dir, "test_helper.exs"), "ExUnit.start()")

    File.write!(Path.join(test_dir, "sample_test.exs"), """
    defmodule SampleTest do
      use ExUnit.Case
      test "truth" do
        assert 1 + 1 == 2
      end
    end
    """)
  end

  defp with_temp_path(bin_dir, fun) do
    orig = System.get_env("PATH") || ""
    System.put_env("PATH", "#{bin_dir}:#{orig}")

    try do
      fun.()
    after
      System.put_env("PATH", orig)
    end
  end

  defp pid_alive?(pid_str, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_pid_alive?(pid_str, deadline)
  end

  defp do_pid_alive?(pid_str, deadline) do
    case System.cmd("kill", ["-0", pid_str], stderr_to_stdout: true) do
      {_, 0} ->
        if System.monotonic_time(:millisecond) >= deadline do
          true
        else
          Process.sleep(20)
          do_pid_alive?(pid_str, deadline)
        end

      _ ->
        false
    end
  end
end
