Code.require_file("lib/job_coordinator.ex", __DIR__)

ExUnit.start(autorun: false)

defmodule OtpTimeoutLeakGradeTest do
  use ExUnit.Case

  setup do
    {:ok, server} = JobCoordinator.start_link()

    on_exit(fn ->
      if Process.alive?(server), do: GenServer.stop(server)
    end)

    {:ok, server: server}
  end

  test "completes fast jobs cleanly with zero lingering active jobs", %{server: server} do
    assert {:ok, 42} = JobCoordinator.run_with_timeout(server, fn -> 21 * 2 end, 500)
    assert JobCoordinator.active_count(server) == 0
    assert JobCoordinator.stats(server) == %{completed: 1, timed_out: 0, failed: 0}
  end

  test "kills worker process and cleans active job state on timeout", %{server: server} do
    test_pid = self()

    result =
      JobCoordinator.run_with_timeout(
        server,
        fn ->
          send(test_pid, {:worker_started, self()})

          receive do
            :never_arrives -> :ok
          end
        end,
        60
      )

    assert result == {:error, :timeout}
    assert_receive {:worker_started, worker_pid}, 200
    ref = Process.monitor(worker_pid)
    assert_receive {:DOWN, ^ref, :process, ^worker_pid, _reason}, 300

    assert JobCoordinator.active_count(server) == 0
    assert JobCoordinator.stats(server) == %{completed: 0, timed_out: 1, failed: 0}
  end

  test "handles worker crashes gracefully without hanging or crashing coordinator", %{
    server: server
  } do
    Process.flag(:trap_exit, true)
    coord_ref = Process.monitor(server)

    result =
      JobCoordinator.run_with_timeout(
        server,
        fn ->
          exit(:boom)
        end,
        500
      )

    assert {:error, {:worker_exit, :boom}} = result
    refute_receive {:DOWN, ^coord_ref, :process, ^server, _}, 50
    assert Process.alive?(server)
    assert JobCoordinator.active_count(server) == 0
    assert JobCoordinator.stats(server) == %{completed: 0, timed_out: 0, failed: 1}
  end

  test "executes concurrent jobs without blocking fast jobs behind slow ones", %{server: server} do
    test_pid = self()

    slow_task =
      Task.async(fn ->
        JobCoordinator.run_with_timeout(
          server,
          fn ->
            send(test_pid, {:slow_worker, self()})

            receive do
              :release -> :slow_done
            end
          end,
          120
        )
      end)

    assert_receive {:slow_worker, slow_worker_pid}, 300
    slow_ref = Process.monitor(slow_worker_pid)

    fast_task =
      Task.async(fn ->
        JobCoordinator.run_with_timeout(server, fn -> :fast_ok end, 500)
      end)

    assert {:ok, :fast_ok} == Task.await(fast_task, 500)
    assert {:error, :timeout} == Task.await(slow_task, 1_000)
    assert_receive {:DOWN, ^slow_ref, :process, ^slow_worker_pid, _}, 300

    assert JobCoordinator.active_count(server) == 0
    assert JobCoordinator.stats(server) == %{completed: 1, timed_out: 1, failed: 0}
  end
end

case ExUnit.run() do
  %{failures: 0} -> System.halt(0)
  _ -> System.halt(1)
end
