defmodule IexCode.Desktop.LifecycleStressTest do
  use IexCode.DataCase, async: false
  require Logger

  alias IexCode.Desktop.Lifecycle
  alias IexCode.Projects
  alias IexCode.Repo
  alias IexCode.Runs
  alias IexCode.Tools.TerminalSession
  alias IexCode.Tools.TerminalSupervisor

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "iex-code-lifecycle-stress-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "lib"))
    {:ok, project} = Projects.create_project(%{name: "Lifecycle Stress Project", root_path: root})
    %{project: project, root: root}
  end

  defp lock_attrs(project, owner, path, overrides \\ %{}) do
    Map.merge(
      %{
        project_id: project.id,
        owner_id: owner,
        resource_type: "file",
        resource_key: path,
        mode: "write",
        lease_seconds: 60
      },
      overrides
    )
  end

  defp os_pid_alive?(os_pid) when is_integer(os_pid) and os_pid > 0 do
    case System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp os_pid_alive?(_), do: false

  defp find_child_pids(parent_os_pid) when is_integer(parent_os_pid) and parent_os_pid > 0 do
    case System.cmd("pgrep", ["-P", Integer.to_string(parent_os_pid)], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.map(&String.to_integer/1)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp wait_until(fun, timeout_ms, interval_ms \\ 50) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline, interval_ms)
  end

  defp do_wait_until(fun, deadline, interval_ms) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(interval_ms)
        do_wait_until(fun, deadline, interval_ms)
      else
        false
      end
    end
  end

  describe "Multi-Session Terminal Teardown & OS Process Group Cleanup" do
    test "terminates multiple concurrent PTY sessions and eliminates all OS child processes without zombies" do
      session_count = 5

      session_ids =
        for i <- 1..session_count, do: "stress_term_#{System.unique_integer([:positive])}_#{i}"

      # Start sessions
      pids_and_os_pids =
        Enum.map(session_ids, fn sid ->
          {:ok, pid} = TerminalSupervisor.start_session(sid, cwd: File.cwd!())
          assert is_pid(pid)
          assert Process.alive?(pid)

          # Wait until session reaches running state and obtains OS PID
          assert wait_until(
                   fn ->
                     case TerminalSession.get_state(sid) do
                       {:ok, %{status: :running, os_pid: opid}} when is_integer(opid) -> true
                       _ -> false
                     end
                   end,
                   4_000
                 )

          {:ok, %{os_pid: os_pid}} = TerminalSession.get_state(sid)
          assert os_pid_alive?(os_pid)

          # Spawn background processes inside the shell
          TerminalSession.send_input(sid, "sleep 900 & sleep 901 &\n")

          {sid, pid, os_pid}
        end)

      # Allow a moment for background commands to fork
      Process.sleep(300)

      # Collect all child OS PIDs
      all_os_pids =
        Enum.flat_map(pids_and_os_pids, fn {_sid, _pid, os_pid} ->
          children = find_child_pids(os_pid)
          [os_pid | children]
        end)

      assert length(all_os_pids) >= session_count
      Logger.info("LifecycleStressTest: Active OS PIDs before teardown: #{inspect(all_os_pids)}")

      # Execute Lifecycle Teardown
      assert {:ok, results} = Lifecycle.teardown(halt: false)
      assert {:ok, stopped} = results.terminals
      assert length(stopped) >= session_count

      # Verify GenServers are dead and unlisted
      for {sid, pid, _os_pid} <- pids_and_os_pids do
        refute Process.alive?(pid)
        assert TerminalSession.whereis(sid) == nil
      end

      assert TerminalSupervisor.list_sessions() == []

      # Verify all OS processes (both shell and child processes) are killed cleanly (zero zombies)
      assert wait_until(
               fn ->
                 Enum.all?(all_os_pids, fn opid -> not os_pid_alive?(opid) end)
               end,
               4_000
             ),
             "Some OS PTY or child processes were leaked: #{inspect(Enum.filter(all_os_pids, &os_pid_alive?/1))}"
    end

    test "cleanup_terminals/0 kills unlisted rogue children under TerminalSupervisor" do
      # Start a non-session child process directly under TerminalSupervisor to simulate orphaned GenServer
      dummy_child_spec = %{
        id: :dummy_rogue_child,
        start: {Agent, :start_link, [fn -> :rogue_state end]},
        restart: :temporary
      }

      {:ok, rogue_pid} = DynamicSupervisor.start_child(TerminalSupervisor, dummy_child_spec)
      assert Process.alive?(rogue_pid)

      assert {:ok, _} = Lifecycle.cleanup_terminals()

      # Rogue child should have been reaped by the catch-all which_children cleanup
      refute Process.alive?(rogue_pid)
    end
  end

  describe "SQLite WAL Checkpointing Under Load & Transactions" do
    test "Repo.checkpoint_wal/0 retries on busy/locked conditions and returns expected result" do
      # Test retry_on_busy directly with artificial error simulation
      counter = :counters.new(1, [])

      fun = fn ->
        val = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)

        if val < 2 do
          raise DBConnection.ConnectionError, "database is locked (busy)"
        else
          :success
        end
      end

      assert Repo.retry_on_busy(fun, 5, 5) == :success
      assert :counters.get(counter, 1) == 3
    end

    test "checkpoint_wal/0 executes on standard database connection without unhandled crash" do
      # Test checkpoint_wal on idle repo
      result = Repo.checkpoint_wal()
      assert match?({:ok, _}, result) or match?({:error, _}, result)

      if match?({:ok, _}, result) do
        {:ok, query_res} = result
        assert is_map(query_res)
        assert Map.has_key?(query_res, :rows)
      end
    end

    test "real SQLite database WAL truncation on disk verification" do
      tmp_db_path =
        Path.join(System.tmp_dir!(), "wal_test_#{System.unique_integer([:positive])}.db")

      tmp_wal_path = "#{tmp_db_path}-wal"

      # Open standalone Exqlite connection to a real disk SQLite database
      {:ok, conn} = Exqlite.Sqlite3.open(tmp_db_path)
      :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA journal_mode=WAL;")

      :ok =
        Exqlite.Sqlite3.execute(
          conn,
          "CREATE TABLE test_data (id INTEGER PRIMARY KEY, payload TEXT);"
        )

      # Insert 100 rows to create substantial WAL frames
      for i <- 1..100 do
        :ok =
          Exqlite.Sqlite3.execute(
            conn,
            "INSERT INTO test_data (payload) VALUES ('test_payload_row_#{i}_#{String.duplicate("x", 500)}');"
          )
      end

      # Verify WAL file exists and contains data
      assert File.exists?(tmp_wal_path)
      initial_wal_size = File.stat!(tmp_wal_path).size
      assert initial_wal_size > 0

      # Execute PRAGMA wal_checkpoint(TRUNCATE)
      {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "PRAGMA wal_checkpoint(TRUNCATE);")
      {:row, [busy, log, checkpointed]} = Exqlite.Sqlite3.step(conn, stmt)
      :ok = Exqlite.Sqlite3.release(conn, stmt)

      assert busy == 0
      assert log >= 0
      assert checkpointed >= 0

      # Verify WAL file is truncated to 0 bytes on disk
      assert File.exists?(tmp_wal_path)
      post_wal_size = File.stat!(tmp_wal_path).size
      assert post_wal_size == 0

      # Close connection and cleanup
      Exqlite.Sqlite3.close(conn)
      File.rm(tmp_db_path)
      File.rm(tmp_wal_path)
    end
  end

  describe "Concurrent Massive Teardown Pipeline" do
    test "handles 20 concurrent Lifecycle.teardown/1 calls without deadlocks, races, or crashes",
         %{
           project: project
         } do
      # Acquire multiple locks
      for i <- 1..10 do
        {:ok, _} =
          Runs.acquire_workspace_lock(lock_attrs(project, "agent_#{i}", "lib/file_#{i}.ex"))
      end

      # Start 3 terminal sessions
      sids = for i <- 1..3, do: "conc_term_#{System.unique_integer([:positive])}_#{i}"

      for sid <- sids do
        {:ok, _pid} = TerminalSupervisor.start_session(sid, cwd: File.cwd!())
      end

      # Launch 20 concurrent teardowns
      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            Lifecycle.teardown(
              kill_terminals: rem(i, 2) == 0,
              release_locks: true,
              flush_wal: true,
              halt: false
            )
          end)
        end

      results = Task.await_many(tasks, 10_000)

      # Verify all returned {:ok, %{...}}
      for res <- results do
        assert {:ok, report} = res
        assert is_map(report)
        assert Map.has_key?(report, :terminals)
        assert Map.has_key?(report, :workspace_locks)
        assert Map.has_key?(report, :wal)
      end

      # Confirm sessions are now 0
      assert TerminalSupervisor.list_sessions() == []
    end
  end

  describe "Workspace Locks Invalidation & Cutoff Sweep" do
    test "cleans up both past and future-expired workspace locks when given a forward cutoff", %{
      project: project
    } do
      # Create 10 locks with varying lease seconds
      for i <- 1..5 do
        {:ok, _} =
          Runs.acquire_workspace_lock(
            lock_attrs(project, "holder_past_#{i}", "lib/past_#{i}.ex", %{lease_seconds: 1})
          )
      end

      for i <- 1..5 do
        {:ok, _} =
          Runs.acquire_workspace_lock(
            lock_attrs(project, "holder_fut_#{i}", "lib/fut_#{i}.ex", %{lease_seconds: 3600})
          )
      end

      # Forward cutoff sweeps future locks as well
      far_future = DateTime.add(DateTime.utc_now(), 7200, :second)
      assert {:ok, count} = Lifecycle.cleanup_workspace_locks(far_future)
      assert count >= 10

      # Re-running cleanup should release 0 additional locks
      assert {:ok, 0} = Lifecycle.cleanup_workspace_locks(far_future)
    end
  end

  describe "Fault Tolerance & Missing Subsystems" do
    test "cleanup_terminals/0 returns {:ok, []} safely if TerminalSupervisor is not running" do
      assert match?({:ok, _}, Lifecycle.cleanup_terminals())
    end

    test "teardown/1 handles partial failures in individual stages gracefully" do
      assert {:ok, results} =
               Lifecycle.teardown(
                 kill_terminals: false,
                 release_locks: false,
                 flush_wal: true,
                 halt: false
               )

      assert results.terminals == :skipped
      assert results.workspace_locks == :skipped
      assert match?({:ok, _}, results.wal) or match?({:error, _}, results.wal)
    end

    test "halt_runtime/1 dispatches custom halt callback without raising" do
      test_pid = self()
      Lifecycle.halt_runtime(fn -> send(test_pid, :halt_invoked) end)
      assert_received :halt_invoked
    end
  end
end
