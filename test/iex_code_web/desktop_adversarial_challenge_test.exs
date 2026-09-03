defmodule IexCodeWeb.DesktopAdversarialChallengeTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true

  alias IexCodeWeb.MenuBar
  alias IexCodeWeb.TrayMenu
  alias Phoenix.PubSub

  @all_10_workspace_tabs ~w(kanban swarm research calendar changes tests ast chat files terminal)

  describe "Section 1: All 10 Workspace Tabs Stress & Invariants" do
    test "switches to every single one of the 10 workspace tabs via PubSub desktop_switch_tab without crashing",
         %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      for tab <- @all_10_workspace_tabs do
        send(view.pid, {:desktop_switch_tab, tab})
        html = render(view)
        assert is_binary(html)
        assert Process.alive?(view.pid), "LiveView crashed when switching to tab #{tab}"
      end
    end

    test "rapidly cycles through all 10 tabs multiple times in random and sequential orders",
         %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Forward cycle
      for tab <- @all_10_workspace_tabs do
        send(view.pid, {:desktop_switch_tab, tab})
      end

      # Reverse cycle
      for tab <- Enum.reverse(@all_10_workspace_tabs) do
        send(view.pid, {:desktop_switch_tab, tab})
      end

      # 30 random switch events
      for _ <- 1..30 do
        tab = Enum.random(@all_10_workspace_tabs)
        send(view.pid, {:desktop_switch_tab, tab})
      end

      # Verify LiveView is still alive and responsive
      html = render(view)
      assert is_binary(html)
      assert Process.alive?(view.pid)
    end
  end

  describe "Section 2: Tab Switching Edge Cases & Adversarial Inputs" do
    test "safely ignores invalid tab string names without crashing LiveView",
         %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Start on kanban
      send(view.pid, {:desktop_switch_tab, "kanban"})
      _ = render(view)

      invalid_tab_strings = [
        "",
        "unknown_tab",
        "KANBAN",
        "kanban ",
        " kanban",
        "tab_kanban",
        "../etc/passwd",
        "<script>alert('xss')</script>",
        "null\0byte",
        String.duplicate("long_tab_name_", 500)
      ]

      for invalid_tab <- invalid_tab_strings do
        send(view.pid, {:desktop_switch_tab, invalid_tab})

        assert Process.alive?(view.pid),
               "LiveView crashed on invalid tab: #{inspect(invalid_tab)}"
      end

      # LiveView should still be functional and render properly
      html = render(view)
      assert is_binary(html)
      assert Process.alive?(view.pid)
    end

    test "safely handles non-string and malformed tab payloads without crashing",
         %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      malformed_payloads = [
        :kanban,
        :terminal,
        :unknown_atom,
        nil,
        12345,
        -1,
        3.1415,
        %{tab: "kanban"},
        ["kanban"],
        {:tuple, "kanban"},
        fn -> "kanban" end
      ]

      for payload <- malformed_payloads do
        send(view.pid, {:desktop_switch_tab, payload})
        assert Process.alive?(view.pid), "LiveView crashed on malformed tab: #{inspect(payload)}"
      end

      html = render(view)
      assert is_binary(html)
      assert Process.alive?(view.pid)
    end
  end

  describe "Section 3: Modal & Desktop Action Dispatches" do
    test "handles :new_session action and creates a new project session",
         %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      initial_count = length(IexCode.Sessions.list_sessions_for_project(project.id))

      send(view.pid, {:desktop_action, :new_session})
      _ = render(view)

      new_count = length(IexCode.Sessions.list_sessions_for_project(project.id))
      assert new_count == initial_count + 1
      assert Process.alive?(view.pid)
    end

    test "handles :open_settings action and toggles modal visibility",
         %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      refute has_element?(view, "#settings-modal")

      # Open
      send(view.pid, {:desktop_action, :open_settings})
      assert has_element?(view, "#settings-modal")

      # Toggle / Close
      send(view.pid, {:desktop_action, :open_settings})
      refute has_element?(view, "#settings-modal")
      assert Process.alive?(view.pid)
    end

    test "handles :command_palette action and toggles palette visibility",
         %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      refute has_element?(view, "#command-palette-modal")

      # Open
      send(view.pid, {:desktop_action, :command_palette})
      assert has_element?(view, "#command-palette-modal")

      # Toggle / Close
      send(view.pid, {:desktop_action, :command_palette})
      refute has_element?(view, "#command-palette-modal")
      assert Process.alive?(view.pid)
    end

    test "handles :toggle_sidebar action without crashing",
         %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      send(view.pid, {:desktop_action, :toggle_sidebar})
      html = render(view)
      assert is_binary(html)
      assert Process.alive?(view.pid)

      send(view.pid, {:desktop_action, :toggle_sidebar})
      html2 = render(view)
      assert is_binary(html2)
      assert Process.alive?(view.pid)
    end

    test "handles unknown actions and malformed action payloads gracefully",
         %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      adversarial_actions = [
        {:desktop_action, :unknown_action},
        {:desktop_action, :crash_app},
        {:desktop_action, :destroy_all},
        {:desktop_action, "new_session"},
        {:desktop_action, "open_settings"},
        {:desktop_action, nil},
        {:desktop_action, 123},
        {:desktop_action, %{action: :new_session}},
        {:desktop_action, [:new_session]},
        {:desktop_action, {:tuple, :new_session}},
        # Completely unknown messages
        :random_atom_message,
        {:unknown_tuple, 1, 2, 3},
        "raw_string_message"
      ]

      for action_msg <- adversarial_actions do
        send(view.pid, action_msg)

        assert Process.alive?(view.pid),
               "LiveView crashed on action message: #{inspect(action_msg)}"
      end

      html = render(view)
      assert is_binary(html)
      assert Process.alive?(view.pid)
    end

    test "rapid burst of alternating actions and tab switches does not deadlock or crash LiveView",
         %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      for i <- 1..40 do
        case rem(i, 6) do
          0 -> send(view.pid, {:desktop_action, :open_settings})
          1 -> send(view.pid, {:desktop_action, :command_palette})
          2 -> send(view.pid, {:desktop_action, :toggle_sidebar})
          3 -> send(view.pid, {:desktop_switch_tab, Enum.at(@all_10_workspace_tabs, rem(i, 10))})
          4 -> send(view.pid, {:desktop_action, :unknown_action})
          5 -> send(view.pid, {:desktop_switch_tab, "invalid_tab_#{i}"})
        end
      end

      html = render(view)
      assert is_binary(html)
      assert Process.alive?(view.pid)
    end
  end

  describe "Section 4: MenuBar and TrayMenu Handler Stress & Edge Cases" do
    test "MenuBar.handle_event/2 handles all standard and edge-case commands safely" do
      PubSub.subscribe(IexCode.PubSub, "desktop:events")
      menu = %Desktop.Menu{assigns: %{active_tab: "kanban"}}

      # Tab switching commands
      all_tab_commands = [
        {"tab_kanban", "kanban"},
        {"tab_swarm", "swarm"},
        {"tab_research", "research"},
        {"tab_calendar", "calendar"},
        {"tab_changes", "changes"},
        {"tab_tests", "tests"},
        {"tab_ast", "ast"},
        {"tab_chat", "chat"},
        {"tab_files", "files"},
        {"tab_terminal", "terminal"},
        {"tab_custom_xyz", "custom_xyz"}
      ]

      for {cmd, expected_tab} <- all_tab_commands do
        assert {:noreply, ^menu} = MenuBar.handle_event(cmd, menu)
        assert_receive {:desktop_switch_tab, ^expected_tab}
      end

      # Window commands when window process is absent (nil)
      refute Process.whereis(IexCodeWindow)
      assert {:noreply, ^menu} = MenuBar.handle_event("close_window", menu)
      assert {:noreply, ^menu} = MenuBar.handle_event("reload_window", menu)
      assert {:noreply, ^menu} = MenuBar.handle_event("help_about", menu)

      # Action commands
      assert {:noreply, ^menu} = MenuBar.handle_event("new_session", menu)
      assert_receive {:desktop_action, :new_session}

      assert {:noreply, ^menu} = MenuBar.handle_event("open_settings", menu)
      assert_receive {:desktop_action, :open_settings}

      assert {:noreply, ^menu} = MenuBar.handle_event("toggle_sidebar", menu)
      assert_receive {:desktop_action, :toggle_sidebar}

      assert {:noreply, ^menu} = MenuBar.handle_event("focus_command_palette", menu)
      assert_receive {:desktop_action, :command_palette}

      assert {:noreply, ^menu} = MenuBar.handle_event("help_shortcuts", menu)
      assert_receive {:desktop_action, :command_palette}

      # Unknown / Malformed commands
      assert {:noreply, ^menu} = MenuBar.handle_event("unrecognized_command", menu)
      assert {:noreply, ^menu} = MenuBar.handle_event("", menu)
      assert {:noreply, ^menu} = MenuBar.handle_event(nil, menu)
      assert {:noreply, ^menu} = MenuBar.handle_event(:atom_command, menu)
      assert {:noreply, ^menu} = MenuBar.handle_event(12345, menu)
      assert {:noreply, ^menu} = MenuBar.handle_event(%{key: "val"}, menu)

      # handle_info catch-all
      assert {:noreply, ^menu} = MenuBar.handle_info(:any_message, menu)
    end

    test "MenuBar.mount/1 handles unexpected inputs gracefully" do
      assert {:ok, menu1} = MenuBar.mount(%Desktop.Menu{assigns: %{active_tab: "swarm"}})
      assert menu1.assigns.active_tab == "kanban"

      assert {:ok, menu2} = MenuBar.mount(nil)
      assert menu2.assigns.active_tab == "kanban"

      assert {:ok, menu3} = MenuBar.mount(%{})
      assert menu3.assigns.active_tab == "kanban"
    end

    test "TrayMenu.handle_event/2 handles standard and edge-case commands safely" do
      PubSub.subscribe(IexCode.PubSub, "desktop:events")
      menu = %Desktop.Menu{assigns: %{}}

      # Window command when window process is absent
      refute Process.whereis(IexCodeWindow)
      assert {:noreply, ^menu} = TrayMenu.handle_event("show_window", menu)

      # Action command
      assert {:noreply, ^menu} = TrayMenu.handle_event("new_session", menu)
      assert_receive {:desktop_action, :new_session}

      # Unknown / Malformed commands
      assert {:noreply, ^menu} = TrayMenu.handle_event("unknown", menu)
      assert {:noreply, ^menu} = TrayMenu.handle_event("", menu)
      assert {:noreply, ^menu} = TrayMenu.handle_event(nil, menu)
      assert {:noreply, ^menu} = TrayMenu.handle_event(:atom_command, menu)
      assert {:noreply, ^menu} = TrayMenu.handle_event(999, menu)

      # handle_info catch-all
      assert {:noreply, ^menu} = TrayMenu.handle_info(:any_message, menu)
    end

    test "TrayMenu.mount/1 and render/1 work with valid and empty assigns" do
      assert {:ok, menu} = TrayMenu.mount(%Desktop.Menu{assigns: %{}})
      rendered = TrayMenu.render(menu.assigns)
      assert Desktop.Menu.Parser.parse(rendered)
    end
  end

  describe "Section 5: Desktop.Window Configuration Invariants & URL Handler" do
    test "desktop_child/0 specs satisfy all Desktop.Window structural contracts" do
      original_env = Application.get_env(:iex_code, :start_desktop_window)

      try do
        Application.put_env(:iex_code, :start_desktop_window, true)

        child_spec = IexCode.Application.desktop_child()
        assert {Desktop.Window, opts} = child_spec

        assert opts[:app] == :iex_code
        assert opts[:id] == IexCodeWindow
        assert is_binary(opts[:title]) and opts[:title] != ""

        # Sizing geometry invariants
        {width, height} = opts[:size]
        {min_width, min_height} = opts[:min_size]
        assert width >= min_width
        assert height >= min_height
        assert min_width >= 800
        assert min_height >= 600

        # Menus
        assert opts[:menubar] == IexCodeWeb.MenuBar
        assert opts[:icon_menu] == IexCodeWeb.TrayMenu
        assert opts[:on_close] == :quit

        # URL function contract
        assert is_function(opts[:url], 0)
        url_result = opts[:url].()
        assert is_binary(url_result)
        assert URI.parse(url_result).scheme in ["http", "https"]
      after
        Application.put_env(:iex_code, :start_desktop_window, original_env)
      end
    end

    test "desktop_child/0 evaluates to nil when disabled" do
      original_env = Application.get_env(:iex_code, :start_desktop_window)

      try do
        Application.put_env(:iex_code, :start_desktop_window, false)
        assert IexCode.Application.desktop_child() == nil
      after
        Application.put_env(:iex_code, :start_desktop_window, original_env)
      end
    end
  end
end
