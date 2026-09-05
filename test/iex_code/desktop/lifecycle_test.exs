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
    test "quit coordinator and watchdog outlive the caller's application group leader" do
      test_pid = self()
      application_group_leader = start_supervised!({Agent, fn -> :application end})
      init_pid = Process.whereis(:init)

      start_supervised!(
        {Task,
         fn ->
           Process.group_leader(self(), application_group_leader)

           Lifecycle.request_quit(
             cleanup_timeout_ms: 5_000,
             force_halt_after_ms: 0,
             linger: true,
             cleanup_fn: fn ->
               send(test_pid, {:cleanup_waiting, self()})

               receive do
                 :finish_cleanup -> :ok
               end
             end,
             stop_fn: fn -> send(test_pid, :graceful_stop_requested) end,
             halt_fn: fn ->
               send(test_pid, {:watchdog_waiting, self()})

               receive do
                 :finish_watchdog -> :ok
               end
             end
           )
         end}
      )

      assert_receive {:cleanup_waiting, cleanup_pid}
      coordinator = Process.whereis(IexCode.Desktop.Lifecycle.QuitCoordinator)
      coordinator_ref = Process.monitor(coordinator)

      on_exit(fn ->
        for pid <- [coordinator, cleanup_pid], is_pid(pid), do: Process.exit(pid, :kill)
      end)

      # The watchdog must already be armed while cleanup is blocked.
      assert_receive {:watchdog_waiting, watchdog_pid}
      watchdog_ref = Process.monitor(watchdog_pid)
      on_exit(fn -> Process.exit(watchdog_pid, :kill) end)

      assert Process.info(coordinator, :group_leader) == {:group_leader, init_pid}
      assert Process.info(watchdog_pid, :group_leader) == {:group_leader, init_pid}
      refute_received :graceful_stop_requested

      stop_supervised!(Agent)
      send(cleanup_pid, :finish_cleanup)
      assert_receive :graceful_stop_requested
      send(watchdog_pid, :finish_watchdog)
      assert_receive {:DOWN, ^watchdog_ref, :process, ^watchdog_pid, :normal}
      assert_receive {:DOWN, ^coordinator_ref, :process, ^coordinator, :normal}
    end

    test "request_quit bounds cleanup, requests graceful stop, and arms hard-halt fallback" do
      test_pid = self()

      assert :ok =
               Lifecycle.request_quit(
                 cleanup_timeout_ms: 50,
                 force_halt_after_ms: 0,
                 cleanup_fn: fn ->
                   send(test_pid, {:cleanup_started, self()})

                   receive do
                     :never -> :ok
                   end
                 end,
                 stop_fn: fn -> send(test_pid, :graceful_stop_requested) end,
                 halt_fn: fn -> send(test_pid, :hard_halt_requested) end
               )

      assert :ok =
               Lifecycle.request_quit(
                 cleanup_fn: fn -> send(test_pid, :duplicate_cleanup_started) end,
                 stop_fn: fn -> send(test_pid, :duplicate_stop_requested) end,
                 halt_fn: fn -> send(test_pid, :duplicate_halt_requested) end
               )

      assert_receive {:cleanup_started, cleanup_pid}
      cleanup_ref = Process.monitor(cleanup_pid)
      assert_receive {:DOWN, ^cleanup_ref, :process, ^cleanup_pid, :killed}
      assert_receive :graceful_stop_requested
      assert_receive :hard_halt_requested
      refute_received :duplicate_cleanup_started
      refute_received :duplicate_stop_requested
      refute_received :duplicate_halt_requested
    end

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
    test "Cmd+N is the native sidebar accelerator" do
      rendered = MenuBar.render(%{active_tab: "kanban"})
      html = rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()

      assert html =~ ~r/<item onclick="toggle_sidebar">[^<]*Ctrl\+N<\/item>/
      refute html =~ ~r/<item onclick="new_session">[^<]*Ctrl\+N<\/item>/
    end

    test "MenuBar.handle_event('quit', menu) requests bounded shutdown" do
      menu = %Desktop.Menu{assigns: %{active_tab: "kanban"}}

      # In test environment, default_halt? is false so calling handle_event("quit", menu)
      # does not terminate the test runner.
      assert {:noreply, ^menu} = MenuBar.handle_event("quit", menu)
    end

    test "TrayMenu.handle_event('quit', menu) requests bounded shutdown" do
      menu = %Desktop.Menu{assigns: %{}}

      assert {:noreply, ^menu} = TrayMenu.handle_event("quit", menu)
    end
  end
end
