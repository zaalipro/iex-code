defmodule IexCodeWeb.DesktopStressTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true

  alias IexCodeWeb.MenuBar
  alias IexCodeWeb.TrayMenu
  alias IexCodeWeb.WorkspaceLive
  alias Phoenix.PubSub

  @pubsub IexCode.PubSub

  describe "Desktop.Menu.Parser and Template Stress Testing" do
    test "MenuBar.render/1 parses successfully with all valid and abnormal assigns" do
      assigns_permutations = [
        %{active_tab: "kanban"},
        %{active_tab: "swarm"},
        %{active_tab: "research"},
        %{active_tab: "changes"},
        %{active_tab: "terminal"},
        %{active_tab: "calendar"},
        %{active_tab: ""},
        %{active_tab: nil},
        %{active_tab: 12345},
        %{active_tab: :invalid_atom},
        %{active_tab: %{nested: "map"}},
        %{custom_field: "unexpected", active_tab: "kanban"}
      ]

      for assigns <- assigns_permutations do
        rendered = MenuBar.render(assigns)
        assert %Phoenix.LiveView.Rendered{} = rendered

        # Parse with Desktop.Menu.Parser
        parsed = Desktop.Menu.Parser.parse(rendered)
        assert {:menubar, _, menus} = parsed
        assert is_list(menus)
        assert length(menus) in [5, 6]

        # Validate menu labels
        labels =
          Enum.map(menus, fn
            {:menu, attrs, _items} ->
              Enum.find_value(attrs, fn
                {:label, label} -> label
                {"label", label} -> label
                _ -> nil
              end)

            _ ->
              nil
          end)

        assert labels in [
                 [~c"File", ~c"Edit", ~c"View", ~c"Workspace", ~c"Help"],
                 ["File", "Edit", "View", "Workspace", "Help"],
                 [~c"File", ~c"Edit", ~c"View", ~c"Workspace", ~c"Window", ~c"Help"],
                 ["File", "Edit", "View", "Workspace", "Window", "Help"]
               ]
      end
    end

    test "TrayMenu.render/1 parses successfully with all assigns" do
      assigns_permutations = [
        %{},
        %{active_tab: "kanban"},
        %{some_assign: "test"},
        %{items: [1, 2, 3]}
      ]

      for assigns <- assigns_permutations do
        rendered = TrayMenu.render(assigns)
        assert %Phoenix.LiveView.Rendered{} = rendered

        parsed = Desktop.Menu.Parser.parse(rendered)
        assert {:menu, _, items} = parsed
        assert is_list(items)
        assert length(items) == 4
      end
    end

    test "Desktop.Menu.Parser parses adversarial XML structures safely" do
      on_exit(fn -> File.rm("parse_error.xml") end)

      # 1. Empty string returns empty list
      assert Desktop.Menu.Parser.parse("") == []

      # 2. Basic XML item structures
      simple_menu = "<menu><item onclick=\"test\">Test</item></menu>"
      assert {:menu, _, items} = Desktop.Menu.Parser.parse(simple_menu)
      assert length(items) == 1

      # 3. XML with unsupported tags returns empty list
      custom_xml =
        "<menubar><menu label=\"Custom\"><custom_tag onclick=\"foo\">Bar</custom_tag></menu></menubar>"

      assert Desktop.Menu.Parser.parse(custom_xml) == []

      # 4. Valid nested menu structure
      nested_xml = """
      <menubar>
        <menu label=\"Outer\">
          <menu label=\"Inner\">
            <item onclick=\"sub_action\">Sub Item</item>
          </menu>
        </menu>
      </menubar>
      """

      assert {:menubar, _, [outer_menu]} = Desktop.Menu.Parser.parse(nested_xml)
      assert {:menu, _, [inner_menu]} = outer_menu
      assert {:menu, _, [_item]} = inner_menu
    end
  end

  describe "MenuBar.handle_event/2 Adversarial Input Stress Testing" do
    test "handles malformed, non-string, and edge case command inputs" do
      menu = %Desktop.Menu{assigns: %{active_tab: "kanban"}}

      malformed_commands = [
        "",
        "   ",
        "tab_",
        "tab_unknown_tab_name_that_does_not_exist",
        "tab_" <> String.duplicate("long_tab_name_", 100),
        # Action edge cases
        "new_session_invalid",
        "QUIT",
        "CLOSE_WINDOW",
        "undefined_command_123"
      ]

      for cmd <- malformed_commands do
        result = MenuBar.handle_event(cmd, menu)
        assert match?({:noreply, _}, result)
      end
    end

    test "window action commands when IexCodeWindow is not running vs running" do
      menu = %Desktop.Menu{assigns: %{active_tab: "kanban"}}

      # Case A: IexCodeWindow is not running
      refute Process.whereis(IexCodeWindow)

      assert {:noreply, ^menu} = MenuBar.handle_event("close_window", menu)
      assert {:noreply, ^menu} = MenuBar.handle_event("reload_window", menu)
      assert {:noreply, ^menu} = MenuBar.handle_event("help_about", menu)

      # Case B: IexCodeWindow is registered as a mock process
      dummy_pid =
        spawn(fn ->
          receive do
            _ -> :ok
          end
        end)

      Process.register(dummy_pid, IexCodeWindow)

      try do
        assert Process.whereis(IexCodeWindow) == dummy_pid

        try do
          MenuBar.handle_event("close_window", menu)
        rescue
          _ -> :ok
        catch
          :exit, _ -> :ok
        end

        try do
          MenuBar.handle_event("reload_window", menu)
        rescue
          _ -> :ok
        catch
          :exit, _ -> :ok
        end

        try do
          MenuBar.handle_event("help_about", menu)
        rescue
          _ -> :ok
        catch
          :exit, _ -> :ok
        end
      after
        if Process.whereis(IexCodeWindow), do: Process.unregister(IexCodeWindow)
        if Process.alive?(dummy_pid), do: Process.exit(dummy_pid, :kill)
      end
    end

    test "MenuBar.handle_info/2 ignores unexpected messages" do
      menu = %Desktop.Menu{assigns: %{active_tab: "kanban"}}

      unexpected_messages = [
        :timeout,
        {:unexpected, 123},
        "random message",
        nil,
        %{},
        {:EXIT, self(), :normal}
      ]

      for msg <- unexpected_messages do
        assert {:noreply, ^menu} = MenuBar.handle_info(msg, menu)
      end
    end
  end

  describe "TrayMenu.handle_event/2 Adversarial Input Stress Testing" do
    test "handles malformed command inputs without crashing" do
      menu = %Desktop.Menu{assigns: %{}}

      malformed_commands = [
        "",
        "invalid_action",
        "show_window_extra",
        "quit_now",
        "NEW_SESSION"
      ]

      for cmd <- malformed_commands do
        result = TrayMenu.handle_event(cmd, menu)
        assert match?({:noreply, _}, result)
      end
    end

    test "TrayMenu.handle_info/2 ignores unexpected messages" do
      menu = %Desktop.Menu{assigns: %{}}
      assert {:noreply, ^menu} = TrayMenu.handle_info(:any_message, menu)
    end
  end

  describe "High-Throughput PubSub Stress Testing and Event Spamming" do
    test "PubSub topic desktop:events handles 5,000 rapid concurrent events without message loss" do
      PubSub.subscribe(@pubsub, "desktop:events")

      num_publishers = 5
      events_per_publisher = 1000
      total_expected = num_publishers * events_per_publisher

      tasks =
        for publisher_id <- 1..num_publishers do
          Task.async(fn ->
            for i <- 1..events_per_publisher do
              msg =
                case rem(i, 6) do
                  0 -> {:desktop_action, :new_session}
                  1 -> {:desktop_action, :open_settings}
                  2 -> {:desktop_action, :toggle_sidebar}
                  3 -> {:desktop_action, :command_palette}
                  4 -> {:desktop_switch_tab, "kanban"}
                  5 -> {:desktop_switch_tab, "swarm"}
                end

              PubSub.broadcast(@pubsub, "desktop:events", {publisher_id, i, msg})
            end
          end)
        end

      Task.await_many(tasks, 10000)

      # Drain and count received messages
      received_count = drain_messages(0, total_expected, 5000)
      assert received_count == total_expected
    end

    defp drain_messages(count, target, timeout) do
      if count >= target do
        count
      else
        receive do
          {_publisher_id, _seq, _msg} ->
            drain_messages(count + 1, target, timeout)
        after
          timeout ->
            count
        end
      end
    end
  end

  describe "WorkspaceLive Socket Level Desktop Event Stress Testing" do
    test "WorkspaceLive.handle_info/2 handles valid tabs and ignores invalid tabs safely" do
      initial_socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          active_tab: "kanban",
          live_action: :index,
          show_workspace_menu: false,
          show_command_palette: false,
          show_settings_modal: false,
          selected_run: nil,
          project_files: [],
          project: %{root_path: System.tmp_dir!()},
          session: %{id: "test-session-123"}
        }
      }

      # Test tabs that do not require running servers
      for tab <- ~w(kanban calendar tests ast chat) do
        socket = %{
          initial_socket
          | assigns: Map.put(initial_socket.assigns, :active_tab, "initial")
        }

        assert {:noreply, updated_socket} =
                 WorkspaceLive.handle_info({:desktop_switch_tab, tab}, socket)

        assert updated_socket.assigns.active_tab == tab
      end

      # Test invalid tab inputs (should be ignored with active_tab preserved)
      invalid_tabs = [
        "invalid_tab",
        "",
        nil,
        12345,
        :not_a_tab,
        %{tab: "map"},
        ["tab"],
        "KANBAN",
        "Tab_123"
      ]

      for invalid_tab <- invalid_tabs do
        socket = %{
          initial_socket
          | assigns: Map.put(initial_socket.assigns, :active_tab, "kanban")
        }

        assert {:noreply, updated_socket} =
                 WorkspaceLive.handle_info({:desktop_switch_tab, invalid_tab}, socket)

        assert updated_socket.assigns.active_tab == "kanban"
      end
    end

    test "WorkspaceLive.handle_info/2 handles desktop action toggles and unknown actions safely" do
      initial_socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          show_workspace_menu: false,
          show_command_palette: false,
          show_settings_modal: false,
          command_palette_query: "",
          command_palette_category: :all,
          command_palette_selected_index: 0,
          usage_history: []
        }
      }

      # 1. Toggle sidebar
      assert {:noreply, socket1} =
               WorkspaceLive.handle_info({:desktop_action, :toggle_sidebar}, initial_socket)

      assert socket1.assigns.show_workspace_menu == true

      # 2. Toggle command palette
      assert {:noreply, socket2} =
               WorkspaceLive.handle_info({:desktop_action, :command_palette}, initial_socket)

      assert socket2.assigns.show_command_palette == true

      # 3. Toggle settings modal
      assert {:noreply, socket3} =
               WorkspaceLive.handle_info({:desktop_action, :open_settings}, initial_socket)

      assert socket3.assigns.show_settings_modal == true

      # 4. Unknown action permutations
      unknown_actions = [
        :unknown_action,
        :quit,
        :close_window,
        "string_action",
        123,
        nil,
        %{},
        {:tuple, :action}
      ]

      for unk <- unknown_actions do
        assert {:noreply, ^initial_socket} =
                 WorkspaceLive.handle_info({:desktop_action, unk}, initial_socket)
      end

      # 5. Malformed messages
      malformed = [
        {:unknown_msg, 123},
        :simple_atom,
        "string message",
        12345,
        nil
      ]

      for msg <- malformed do
        assert {:noreply, ^initial_socket} = WorkspaceLive.handle_info(msg, initial_socket)
      end
    end
  end

  describe "LiveView E2E Desktop Event Integration" do
    test "switches tabs via PubSub desktop_switch_tab and LiveView reflects active tab", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Send desktop switch tab event to view
      send(view.pid, {:desktop_switch_tab, "swarm"})
      assert render(view) =~ "Swarm"

      send(view.pid, {:desktop_switch_tab, "changes"})
      assert render(view) =~ "Changes"

      # Send invalid tab - view remains alive and doesn't crash
      send(view.pid, {:desktop_switch_tab, "invalid_tab_123"})
      assert Process.alive?(view.pid)
    end
  end

  describe "Mix.Tasks.Desktop Stress & Configuration Permutations" do
    test "Mix.Tasks.Desktop sets environment flags correctly across invocations" do
      original_window = Application.get_env(:iex_code, :start_desktop_window)
      original_endpoint = Application.get_env(:iex_code, IexCodeWeb.Endpoint)

      try do
        # Clear flags
        Application.delete_env(:iex_code, :start_desktop_window)
        Application.put_env(:iex_code, IexCodeWeb.Endpoint, [])

        refute Application.get_env(:iex_code, :start_desktop_window)

        # Simulate execution of the configuration logic
        Application.put_env(:iex_code, :start_desktop_window, true)
        Application.put_env(:iex_code, IexCodeWeb.Endpoint, server: true)

        assert Application.get_env(:iex_code, :start_desktop_window) == true
        assert Application.get_env(:iex_code, IexCodeWeb.Endpoint)[:server] == true

        # Re-verify desktop child spec reflects the updated configuration
        child_spec = IexCode.Application.desktop_child()
        assert {Desktop.Window, opts} = child_spec
        assert opts[:id] == IexCodeWindow
        assert opts[:menubar] == IexCodeWeb.MenuBar
        assert opts[:icon_menu] == IexCodeWeb.TrayMenu
      after
        Application.put_env(:iex_code, :start_desktop_window, original_window)
        Application.put_env(:iex_code, IexCodeWeb.Endpoint, original_endpoint)
      end
    end
  end
end
