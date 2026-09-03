defmodule IexCode.Desktop.LifecycleTest do
  use IexCode.DataCase, async: false

  alias IexCode.Desktop.Lifecycle
  alias IexCode.Repo
  alias IexCode.Tools.TerminalSupervisor
  alias IexCodeWeb.MenuBar
  alias IexCodeWeb.TrayMenu

  describe "IexCode.Repo.checkpoint_wal/0" do
    test "executes PRAGMA wal_checkpoint(TRUNCATE) successfully" do
      assert {:ok, result} = Repo.checkpoint_wal()
      assert is_map(result)
      assert Map.has_key?(result, :rows)
      assert is_list(result.rows)
      assert length(result.rows) == 1
      [row] = result.rows
      assert length(row) == 3
      # [busy, log, checkpointed] should all be integers
      assert Enum.all?(row, &is_integer/1)
    end
  end

  describe "IexCode.Desktop.Lifecycle.teardown/1" do
    test "executes all 4 stages without crashing when halt: false" do
      assert {:ok, results} = Lifecycle.teardown(halt: false)

      assert is_map(results)
      assert Map.has_key?(results, :terminals)
      assert Map.has_key?(results, :workspace_locks)
      assert Map.has_key?(results, :wal)

      assert {:ok, _terminals} = results.terminals
      assert {:ok, _count} = results.workspace_locks
      assert match?({:ok, _}, results.wal) or match?({:error, _}, results.wal)
    end

    test "respects stage skip options" do
      assert {:ok, results} =
               Lifecycle.teardown(
                 kill_terminals: false,
                 release_locks: false,
                 flush_wal: false,
                 halt: false
               )

      assert results.terminals == :skipped
      assert results.workspace_locks == :skipped
      assert results.wal == :skipped
    end

    test "invokes custom halt_fn when halt: true" do
      test_pid = self()

      assert {:ok, _results} =
               Lifecycle.teardown(
                 halt: true,
                 halt_fn: fn -> send(test_pid, :shutdown_invoked) end
               )

      assert_received :shutdown_invoked
    end

    test "cleanup_terminals/0 terminates active sessions" do
      session_id = "lifecycle_test_terminal_#{System.unique_integer([:positive])}"

      if Process.whereis(TerminalSupervisor) do
        {:ok, pid} = TerminalSupervisor.start_session(session_id)
        assert Process.alive?(pid)

        assert {:ok, stopped} = Lifecycle.cleanup_terminals()
        assert is_list(stopped)
        refute Process.alive?(pid)
      else
        assert {:ok, []} = Lifecycle.cleanup_terminals()
      end
    end

    test "cleanup_workspace_locks/1 expires active locks" do
      assert {:ok, count} = Lifecycle.cleanup_workspace_locks(DateTime.utc_now())
      assert is_integer(count)
    end

    test "cleanup_orphans/0 runs startup cleanup" do
      assert {:ok, count} = Lifecycle.cleanup_orphans()
      assert is_integer(count)
    end

    test "checkpoint_wal/0 delegates to Repo.checkpoint_wal/0" do
      result = Lifecycle.checkpoint_wal()
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "register_shutdown_hook/0 and at_exit/0 register exit callbacks without error" do
      assert Lifecycle.register_shutdown_hook() == :ok
      assert Lifecycle.at_exit() == :ok
    end

    test "halt_runtime/1 executes fallback shutdown paths safely" do
      test_pid = self()
      assert Lifecycle.halt_runtime(fn -> send(test_pid, :custom_halt) end) == :custom_halt
      assert_received :custom_halt
    end
  end

  describe "MenuBar and TrayMenu Quit Event Integration" do
    test "MenuBar.handle_event('quit', menu) invokes Lifecycle.teardown" do
      menu = %Desktop.Menu{assigns: %{active_tab: "kanban"}}

      # In test environment, default_halt? is false so calling handle_event("quit", menu)
      # runs teardown cleanly without terminating the test runner.
      assert {:noreply, ^menu} = MenuBar.handle_event("quit", menu)
    end

    test "TrayMenu.handle_event('quit', menu) invokes Lifecycle.teardown" do
      menu = %Desktop.Menu{assigns: %{}}

      assert {:noreply, ^menu} = TrayMenu.handle_event("quit", menu)
    end
  end
end
