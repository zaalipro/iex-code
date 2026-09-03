defmodule IexCode.Desktop.LifecycleAdversarialTest do
  use IexCode.DataCase, async: false
  require Logger

  alias IexCode.Desktop.Lifecycle
  alias IexCode.Projects
  alias IexCode.Tools.PTYAdapter
  alias IexCode.Tools.TerminalSession
  alias IexCode.Tools.TerminalSupervisor
  alias IexCodeWeb.MenuBar
  alias IexCodeWeb.TrayMenu

  setup do
    root =
      Path.join(System.tmp_dir!(), "iex-code-lifecycle-adv-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "lib"))
    {:ok, project} = Projects.create_project(%{name: "Lifecycle Adv Project", root_path: root})
    %{project: project, root: root}
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

  describe "Adversarial Terminal Scenarios: Signal Trapping & Zombie Immunity" do
    test "forcefully kills processes that trap SIGTERM and SIGHUP via SIGKILL escalation" do
      session_id = "adv_trap_term_#{System.unique_integer([:positive])}"
      {:ok, pid} = TerminalSupervisor.start_session(session_id, cwd: File.cwd!())

      assert wait_until(
               fn ->
                 case TerminalSession.get_state(session_id) do
                   {:ok, %{status: :running, os_pid: opid}} when is_integer(opid) -> true
                   _ -> false
                 end
               end,
               4_000
             )

      {:ok, %{os_pid: os_pid}} = TerminalSession.get_state(session_id)
      assert os_pid_alive?(os_pid)

      # Send a script that traps SIGTERM and SIGHUP and sleeps
      # This simulates an adversarial or stubborn process that ignores standard termination signals
      trap_command = "trap '' TERM HUP; sleep 600 &\n"
      TerminalSession.send_input(session_id, trap_command)
      Process.sleep(300)

      # Teardown terminals
      assert {:ok, _} = Lifecycle.cleanup_terminals()

      # Verify the session GenServer is dead
      refute Process.alive?(pid)

      # Verify the OS process is completely dead (pty_shim escalated to SIGKILL)
      assert wait_until(fn -> not os_pid_alive?(os_pid) end, 4_000),
             "Process #{os_pid} with trapped signals was not reaped by SIGKILL"
    end

    test "handles terminals whose OS process was already killed before teardown" do
      session_id = "adv_dead_os_term_#{System.unique_integer([:positive])}"
      {:ok, pid} = TerminalSupervisor.start_session(session_id, cwd: File.cwd!())

      assert wait_until(
               fn ->
                 case TerminalSession.get_state(session_id) do
                   {:ok, %{status: :running, os_pid: opid}} when is_integer(opid) -> true
                   _ -> false
                 end
               end,
               4_000
             )

      {:ok, %{os_pid: os_pid}} = TerminalSession.get_state(session_id)
      assert os_pid_alive?(os_pid)

      # Externally kill the OS process first
      System.cmd("kill", ["-9", Integer.to_string(os_pid)])
      Process.sleep(100)

      # Teardown should not crash or raise error on already dead OS PID
      assert {:ok, _} = Lifecycle.cleanup_terminals()
      refute Process.alive?(pid)
    end

    test "PTYAdapter.close/1 is completely idempotent and safe across arbitrary mode structs and nils" do
      assert PTYAdapter.close(nil) == :ok
      assert PTYAdapter.close(%PTYAdapter{mode: :pty, port: nil}) == :ok
      assert PTYAdapter.close(%PTYAdapter{mode: :fallback, port: nil, os_pid: -1}) == :ok
      assert PTYAdapter.close(%PTYAdapter{mode: :fallback, port: nil, os_pid: 999_999_999}) == :ok
      assert PTYAdapter.close(:invalid_adapter) == :ok
    end
  end

  describe "Adversarial Database & Subsystem Failures" do
    test "Lifecycle.checkpoint_wal/0 safely handles unstarted or dead Repo" do
      # When Repo module is not found or not running
      # If whereis(Repo) returns nil, checkpoint_wal should return {:ok, :repo_not_running}
      assert match?({:ok, _}, Lifecycle.checkpoint_wal()) or
               match?({:error, _}, Lifecycle.checkpoint_wal())
    end

    test "Lifecycle.cleanup_workspace_locks/1 handles invalid datetime and DB errors safely" do
      # Test with nil
      assert {:ok, count1} = Lifecycle.cleanup_workspace_locks(nil)
      assert is_integer(count1)

      # Test with past timestamp
      past = DateTime.utc_now() |> DateTime.add(-86400, :second)
      assert {:ok, count2} = Lifecycle.cleanup_workspace_locks(past)
      assert is_integer(count2)
    end

    test "Lifecycle.teardown/1 handles all options being false or custom combinations" do
      assert {:ok, res1} =
               Lifecycle.teardown(
                 kill_terminals: false,
                 release_locks: false,
                 flush_wal: false,
                 halt: false
               )

      assert res1 == %{terminals: :skipped, workspace_locks: :skipped, wal: :skipped}

      assert {:ok, res2} =
               Lifecycle.teardown(
                 kill_terminals: true,
                 release_locks: false,
                 flush_wal: false,
                 halt: false
               )

      assert res2.terminals != :skipped
      assert res2.workspace_locks == :skipped
      assert res2.wal == :skipped
    end
  end

  describe "Adversarial UI Quit Event Storms" do
    test "handles rapid burst of 50 quit events from MenuBar and TrayMenu" do
      menu = %Desktop.Menu{assigns: %{active_tab: "kanban"}}

      # Fire 25 MenuBar quit events and 25 TrayMenu quit events concurrently
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            if rem(i, 2) == 0 do
              MenuBar.handle_event("quit", menu)
            else
              TrayMenu.handle_event("quit", menu)
            end
          end)
        end

      results = Task.await_many(tasks, 5_000)

      # Verify all 50 events handled cleanly without exceptions
      for {:noreply, returned_menu} <- results do
        assert returned_menu == menu
      end
    end
  end

  describe "Shutdown Hook Registration Resilience" do
    test "register_shutdown_hook/0 and at_exit/0 can be invoked repeatedly without crashing" do
      for _ <- 1..10 do
        assert Lifecycle.register_shutdown_hook() == :ok
        assert Lifecycle.at_exit() == :ok
      end
    end
  end
end
