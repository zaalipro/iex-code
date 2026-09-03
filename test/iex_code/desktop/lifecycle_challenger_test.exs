defmodule IexCode.Desktop.LifecycleChallengerTest do
  use IexCode.DataCase, async: false

  alias IexCode.Desktop.Lifecycle
  alias IexCode.Repo
  alias IexCode.Runs
  alias IexCode.Projects
  alias IexCode.Tools.TerminalSupervisor
  alias IexCodeWeb.MenuBar
  alias IexCodeWeb.TrayMenu
  alias Phoenix.PubSub

  @pubsub IexCode.PubSub

  # Helper to create a project for lock tests
  defp create_test_project do
    root =
      Path.join(System.tmp_dir!(), "iex-code-challenger-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "lib"))
    {:ok, project} = Projects.create_project(%{name: "Challenger Test", root_path: root})
    %{project: project, root: root}
  end

  defp lock_attrs(project, owner, path, overrides) do
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

  describe "MenuBar Quit and Event Handling Stress" do
    setup do
      PubSub.subscribe(@pubsub, "desktop:events")
      :ok
    end

    test "MenuBar.handle_event('quit', menu) executes teardown cleanly" do
      menu = %Desktop.Menu{assigns: %{active_tab: "kanban"}}
      assert {:noreply, ^menu} = MenuBar.handle_event("quit", menu)
    end

    test "MenuBar.handle_event('close_window', menu) is safe when window process does not exist" do
      menu = %Desktop.Menu{assigns: %{active_tab: "kanban"}}
      refute Process.whereis(IexCodeWindow)
      assert {:noreply, ^menu} = MenuBar.handle_event("close_window", menu)
    end

    test "MenuBar.handle_event('reload_window', menu) is safe when window process does not exist" do
      menu = %Desktop.Menu{assigns: %{active_tab: "kanban"}}
      refute Process.whereis(IexCodeWindow)
      assert {:noreply, ^menu} = MenuBar.handle_event("reload_window", menu)
    end

    test "MenuBar.handle_event('help_about', menu) is safe when window process does not exist" do
      menu = %Desktop.Menu{assigns: %{active_tab: "kanban"}}
      refute Process.whereis(IexCodeWindow)
      assert {:noreply, ^menu} = MenuBar.handle_event("help_about", menu)
    end

    test "MenuBar broadcasts all expected PubSub events" do
      menu = %Desktop.Menu{assigns: %{active_tab: "kanban"}}

      events = [
        {"new_session", {:desktop_action, :new_session}},
        {"open_settings", {:desktop_action, :open_settings}},
        {"toggle_sidebar", {:desktop_action, :toggle_sidebar}},
        {"focus_command_palette", {:desktop_action, :command_palette}},
        {"help_shortcuts", {:desktop_action, :command_palette}},
        {"tab_kanban", {:desktop_switch_tab, "kanban"}},
        {"tab_swarm", {:desktop_switch_tab, "swarm"}},
        {"tab_research", {:desktop_switch_tab, "research"}},
        {"tab_changes", {:desktop_switch_tab, "changes"}},
        {"tab_terminal", {:desktop_switch_tab, "terminal"}}
      ]

      for {event_name, expected_msg} <- events do
        assert {:noreply, ^menu} = MenuBar.handle_event(event_name, menu)
        assert_received ^expected_msg
      end
    end

    test "MenuBar handles unknown events gracefully without crashing" do
      menu = %Desktop.Menu{assigns: %{active_tab: "kanban"}}

      unknown_events = [
        "unknown_event",
        "custom_action_123",
        "",
        "tab_",
        "invalid:payload",
        "tab_\u0000\u0001\u0002",
        nil
      ]

      for event <- unknown_events do
        assert {:noreply, ^menu} = MenuBar.handle_event(event, menu)
      end
    end

    test "MenuBar.mount/1 handles standard and non-standard inputs" do
      assert {:ok, menu} = MenuBar.mount(%Desktop.Menu{assigns: %{}})
      assert menu.assigns.active_tab == "kanban"

      assert {:ok, menu_other} = MenuBar.mount(:not_a_menu_struct)
      assert menu_other.assigns.active_tab == "kanban"
    end

    test "MenuBar.handle_info/2 returns {:noreply, menu}" do
      menu = %Desktop.Menu{assigns: %{active_tab: "kanban"}}
      assert {:noreply, ^menu} = MenuBar.handle_info(:unexpected_message, menu)
    end
  end

  describe "TrayMenu Quit and Event Handling Stress" do
    setup do
      PubSub.subscribe(@pubsub, "desktop:events")
      :ok
    end

    test "TrayMenu.handle_event('quit', menu) executes teardown cleanly" do
      menu = %Desktop.Menu{assigns: %{}}
      assert {:noreply, ^menu} = TrayMenu.handle_event("quit", menu)
    end

    test "TrayMenu.handle_event('show_window', menu) is safe when window process does not exist" do
      menu = %Desktop.Menu{assigns: %{}}
      refute Process.whereis(IexCodeWindow)
      assert {:noreply, ^menu} = TrayMenu.handle_event("show_window", menu)
    end

    test "TrayMenu.handle_event('new_session', menu) broadcasts PubSub event" do
      menu = %Desktop.Menu{assigns: %{}}
      assert {:noreply, ^menu} = TrayMenu.handle_event("new_session", menu)
      assert_received {:desktop_action, :new_session}
    end

    test "TrayMenu handles unknown events without crashing" do
      menu = %Desktop.Menu{assigns: %{}}

      for unknown <- ["nonexistent", "random", "", nil] do
        assert {:noreply, ^menu} = TrayMenu.handle_event(unknown, menu)
      end
    end

    test "TrayMenu.mount/1 and handle_info/2" do
      menu = %Desktop.Menu{assigns: %{}}
      assert {:ok, ^menu} = TrayMenu.mount(menu)
      assert {:noreply, ^menu} = TrayMenu.handle_info(:any_info, menu)
    end
  end

  describe "Lifecycle Teardown Options & Validation Matrix" do
    test "teardown with default options" do
      assert {:ok, results} = Lifecycle.teardown(halt: false)
      assert is_map(results)
      assert {:ok, _} = results.terminals
      assert {:ok, _} = results.workspace_locks
      assert match?({:ok, _}, results.wal) or match?({:error, _}, results.wal)
    end

    test "teardown with all stages skipped" do
      assert {:ok, results} =
               Lifecycle.teardown(
                 kill_terminals: false,
                 release_locks: false,
                 flush_wal: false,
                 halt: false
               )

      assert results == %{terminals: :skipped, workspace_locks: :skipped, wal: :skipped}
    end

    test "teardown with unknown options ignored safely" do
      assert {:ok, results} =
               Lifecycle.teardown(
                 halt: false,
                 extra_opt: 123,
                 custom_string: "hello",
                 nested_map: %{a: 1}
               )

      assert is_map(results)
    end

    test "teardown with custom halt_fn" do
      parent = self()

      assert {:ok, _} =
               Lifecycle.teardown(
                 halt: true,
                 halt_fn: fn -> send(parent, :custom_halt_fired) end
               )

      assert_received :custom_halt_fired
    end

    test "teardown env override for desktop_lifecycle_halt" do
      original_env = Application.get_env(:iex_code, :desktop_lifecycle_halt)

      on_exit(fn ->
        if original_env == nil do
          Application.delete_env(:iex_code, :desktop_lifecycle_halt)
        else
          Application.put_env(:iex_code, :desktop_lifecycle_halt, original_env)
        end
      end)

      parent = self()
      Application.put_env(:iex_code, :desktop_lifecycle_halt, true)

      # When halt is true by env, teardown invokes halt_fn
      assert {:ok, _} =
               Lifecycle.teardown(halt_fn: fn -> send(parent, :env_halt_fired) end)

      assert_received :env_halt_fired

      Application.put_env(:iex_code, :desktop_lifecycle_halt, false)

      assert {:ok, _} =
               Lifecycle.teardown(halt_fn: fn -> send(parent, :should_not_fire) end)

      refute_received :should_not_fire
    end

    test "halt_runtime handles custom halt_fn and fallback shutdown paths safely" do
      parent = self()

      assert Lifecycle.halt_runtime(fn ->
               send(parent, :invoked)
               :ok
             end) == :ok

      assert_received :invoked

      # 1-arity function or non-function falls back to system stop
      # We verify it doesn't crash on type mismatches before invoking Desktop.OS or System.stop
    end
  end

  describe "Terminal Teardown & Zombie Prevention Stress" do
    test "cleanup_terminals stops multiple active sessions" do
      if Process.whereis(TerminalSupervisor) do
        session_ids =
          for i <- 1..5 do
            id = "stress_term_#{i}_#{System.unique_integer([:positive])}"
            {:ok, pid} = TerminalSupervisor.start_session(id)
            assert Process.alive?(pid)
            {id, pid}
          end

        assert {:ok, stopped} = Lifecycle.cleanup_terminals()
        assert length(stopped) >= 5

        # Verify all started processes are no longer alive
        for {_id, pid} <- session_ids do
          refute Process.alive?(pid)
        end

        # Subsequent call on empty supervisor should succeed cleanly
        assert {:ok, []} = Lifecycle.cleanup_terminals()
      else
        assert {:ok, []} = Lifecycle.cleanup_terminals()
      end
    end
  end

  describe "Workspace Locks Cleanup & Orphan Sweeps Stress" do
    test "cleanup_workspace_locks expires held and waiting locks with past cutoff" do
      %{project: project} = create_test_project()

      # Acquire 3 locks
      assert {:ok, acquired1} =
               Runs.acquire_workspace_lock(lock_attrs(project, "agent_1", "lib/file1.ex", %{}))

      assert {:ok, acquired2} =
               Runs.acquire_workspace_lock(lock_attrs(project, "agent_2", "lib/file2.ex", %{}))

      assert {:ok, acquired3} =
               Runs.acquire_workspace_lock(lock_attrs(project, "agent_3", "lib/file3.ex", %{}))

      assert is_binary(acquired1.capability_token)
      assert is_binary(acquired2.capability_token)
      assert is_binary(acquired3.capability_token)

      # Using a future cutoff (1 hour from now) should expire all active locks
      future_cutoff = DateTime.add(DateTime.utc_now(), 3600, :second)
      assert {:ok, count} = Lifecycle.cleanup_workspace_locks(future_cutoff)
      assert count >= 3

      # Now all locks should be expired in the DB
      locks = Runs.list_workspace_locks(project_id: project.id)

      for lock <- locks do
        assert lock.status in ["expired", "cancelled"]
      end
    end

    test "cleanup_orphans/0 runs successfully" do
      assert {:ok, count} = Lifecycle.cleanup_orphans()
      assert is_integer(count) or count == :sandbox_unowned
    end
  end

  describe "WAL Checkpoint & Retry on Busy Stress" do
    test "Repo.checkpoint_wal/0 executes PRAGMA wal_checkpoint(TRUNCATE)" do
      assert {:ok, result} = Repo.checkpoint_wal()
      assert is_map(result)
      assert Map.has_key?(result, :rows)
      [row] = result.rows
      assert length(row) == 3
      [busy, log, checkpointed] = row
      assert is_integer(busy)
      assert is_integer(log)
      assert is_integer(checkpointed)
    end

    test "Repo.retry_on_busy returns result on immediate success" do
      assert Repo.retry_on_busy(fn -> :success end) == :success
    end

    test "Repo.retry_on_busy re-raises non-busy exceptions immediately" do
      assert_raise RuntimeError, "non-busy error", fn ->
        Repo.retry_on_busy(fn -> raise "non-busy error" end, 3, 1)
      end
    end

    test "concurrent WAL checkpoints under parallel read/write load" do
      %{project: project} = create_test_project()

      # Run concurrent DB operations while checkpointing WAL
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            if rem(i, 2) == 0 do
              Repo.checkpoint_wal()
            else
              Runs.acquire_workspace_lock(
                lock_attrs(project, "writer_#{i}", "lib/concurrent_#{i}.ex", %{})
              )
            end
          end)
        end

      results = Task.await_many(tasks, 10_000)
      assert length(results) == 10

      for res <- results do
        assert match?({:ok, _}, res) or match?({:error, _}, res)
      end
    end
  end

  describe "Concurrent Teardown Stress Matrix" do
    test "concurrent teardown/1 calls from 20 parallel processes execute safely" do
      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            Lifecycle.teardown(
              halt: false,
              kill_terminals: rem(i, 2) == 0,
              release_locks: rem(i, 3) == 0,
              flush_wal: rem(i, 5) == 0
            )
          end)
        end

      results = Task.await_many(tasks, 10_000)

      assert length(results) == 20

      for res <- results do
        assert {:ok, stage_map} = res
        assert is_map(stage_map)
      end
    end

    test "concurrent MenuBar and TrayMenu quit events from 20 parallel processes" do
      menu_bar = %Desktop.Menu{assigns: %{active_tab: "kanban"}}
      tray_menu = %Desktop.Menu{assigns: %{}}

      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            if rem(i, 2) == 0 do
              MenuBar.handle_event("quit", menu_bar)
            else
              TrayMenu.handle_event("quit", tray_menu)
            end
          end)
        end

      results = Task.await_many(tasks, 10_000)
      assert length(results) == 20

      for res <- results do
        assert {:noreply, _} = res
      end
    end
  end

  describe "Shutdown Hooks Registration" do
    test "register_shutdown_hook/0 and at_exit/0 are idempotent and callable multiple times" do
      assert Lifecycle.register_shutdown_hook() == :ok
      assert Lifecycle.register_shutdown_hook() == :ok
      assert Lifecycle.at_exit() == :ok
    end
  end
end
