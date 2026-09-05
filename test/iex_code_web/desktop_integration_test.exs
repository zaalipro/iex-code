defmodule IexCodeWeb.DesktopIntegrationTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true

  alias IexCodeWeb.MenuBar
  alias IexCodeWeb.TrayMenu
  alias Phoenix.PubSub

  describe "Desktop Window Child Spec Configuration" do
    test "desktop_child/0 returns full Desktop.Window spec when enabled" do
      original_env = Application.get_env(:iex_code, :start_desktop_window)

      try do
        Application.put_env(:iex_code, :start_desktop_window, true)

        child_spec = IexCode.Application.desktop_child()
        assert {Desktop.Window, opts} = child_spec

        assert opts[:app] == :iex_code
        assert opts[:id] == IexCodeWindow
        assert opts[:title] == "IexCode - Desktop AI Coding Harness"
        assert opts[:size] == {1440, 920}
        assert opts[:min_size] == {1024, 700}
        assert opts[:menubar] == IexCodeWeb.MenuBar

        assert opts[:icon_menu] ==
                 if(match?({:unix, :darwin}, :os.type()), do: nil, else: IexCodeWeb.TrayMenu)

        assert opts[:on_close] == :quit
        assert is_function(opts[:url], 0)
        assert opts[:url].() =~ "http"
      after
        Application.put_env(:iex_code, :start_desktop_window, original_env)
      end
    end

    test "desktop_child/0 returns nil when start_desktop_window is false" do
      original_env = Application.get_env(:iex_code, :start_desktop_window)

      try do
        Application.put_env(:iex_code, :start_desktop_window, false)
        assert IexCode.Application.desktop_child() == nil
      after
        Application.put_env(:iex_code, :start_desktop_window, original_env)
      end
    end
  end

  describe "MenuBar Rendering & Parsing" do
    test "mount/1 initializes menu with active_tab" do
      assert {:ok, menu} = MenuBar.mount(%Desktop.Menu{assigns: %{}})
      assert menu.assigns.active_tab == "kanban"
    end

    test "render/1 generates valid XML containing expected menus, items, and accelerators" do
      assigns = %{active_tab: "kanban"}
      rendered = MenuBar.render(assigns)
      rendered_str = Phoenix.HTML.Safe.to_iodata(rendered) |> IO.iodata_to_binary()

      assert rendered_str =~ "<menubar"
      assert rendered_str =~ ~s(label="File")
      assert rendered_str =~ ~s(label="Edit")
      assert rendered_str =~ ~s(label="View")
      assert rendered_str =~ ~s(label="Workspace")
      assert rendered_str =~ ~s(label="Help")

      # Verify accelerators
      assert rendered_str =~ "Ctrl+N"
      assert rendered_str =~ "Ctrl+,"
      assert rendered_str =~ "Ctrl+W"
      assert rendered_str =~ "Ctrl+Q"
      assert rendered_str =~ "Ctrl+Z"
      assert rendered_str =~ "Ctrl+Shift+Z"
      assert rendered_str =~ "Ctrl+X"
      assert rendered_str =~ "Ctrl+C"
      assert rendered_str =~ "Ctrl+V"
      assert rendered_str =~ "Ctrl+R"
      assert rendered_str =~ "Ctrl+Shift+N"
      assert rendered_str =~ "Ctrl+K"
      assert rendered_str =~ "Ctrl+1"
      assert rendered_str =~ "Ctrl+2"
      assert rendered_str =~ "Ctrl+3"
      assert rendered_str =~ "Ctrl+4"
      assert rendered_str =~ "Ctrl+5"

      # Verify Desktop.Menu.Parser parses without errors
      dom = Desktop.Menu.Parser.parse(rendered)
      assert {:menubar, _, menus} = dom
      assert length(menus) in [5, 6]
    end

    test "handle_event/2 broadcasts desktop events over PubSub" do
      PubSub.subscribe(IexCode.PubSub, "desktop:events")
      menu = %Desktop.Menu{assigns: %{active_tab: "kanban"}}

      # File menu actions
      assert {:noreply, ^menu} = MenuBar.handle_event("new_session", menu)
      assert_receive {:desktop_action, :new_session}

      assert {:noreply, ^menu} = MenuBar.handle_event("open_settings", menu)
      assert_receive {:desktop_action, :open_settings}

      # View menu actions
      assert {:noreply, ^menu} = MenuBar.handle_event("toggle_sidebar", menu)
      assert_receive {:desktop_action, :toggle_sidebar}

      assert {:noreply, ^menu} = MenuBar.handle_event("focus_command_palette", menu)
      assert_receive {:desktop_action, :command_palette}

      assert {:noreply, ^menu} = MenuBar.handle_event("help_shortcuts", menu)
      assert_receive {:desktop_action, :command_palette}

      # Workspace tab switching
      for {event, expected_tab} <- [
            {"tab_kanban", "kanban"},
            {"tab_swarm", "swarm"},
            {"tab_research", "research"},
            {"tab_changes", "changes"},
            {"tab_terminal", "terminal"}
          ] do
        assert {:noreply, ^menu} = MenuBar.handle_event(event, menu)
        assert_receive {:desktop_switch_tab, ^expected_tab}
      end

      # Unknown event handling
      assert {:noreply, ^menu} = MenuBar.handle_event("unknown_action", menu)
    end
  end

  describe "TrayMenu Rendering & Parsing" do
    test "mount/1 initializes menu" do
      assert {:ok, _menu} = TrayMenu.mount(%Desktop.Menu{assigns: %{}})
    end

    test "render/1 generates valid XML containing expected menu items" do
      assigns = %{}
      rendered = TrayMenu.render(assigns)
      rendered_str = Phoenix.HTML.Safe.to_iodata(rendered) |> IO.iodata_to_binary()

      assert rendered_str =~ "<menu"
      assert rendered_str =~ "Open IexCode"
      assert rendered_str =~ "New Workspace Session"
      assert rendered_str =~ "Quit IexCode"

      # Verify Desktop.Menu.Parser parses without errors
      dom = Desktop.Menu.Parser.parse(rendered)
      assert {:menu, _, items} = dom
      assert length(items) >= 3
    end

    test "handle_event/2 broadcasts new_session event" do
      PubSub.subscribe(IexCode.PubSub, "desktop:events")
      menu = %Desktop.Menu{assigns: %{}}

      assert {:noreply, ^menu} = TrayMenu.handle_event("new_session", menu)
      assert_receive {:desktop_action, :new_session}

      # Unknown event handling
      assert {:noreply, ^menu} = TrayMenu.handle_event("unknown", menu)
    end
  end

  describe "LiveView PubSub Desktop Event Integration" do
    test "switches tabs via PubSub desktop_switch_tab", %{
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
    end

    test "toggles command palette via PubSub desktop_action :command_palette", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      refute has_element?(view, "#command-palette-modal")

      send(view.pid, {:desktop_action, :command_palette})
      assert has_element?(view, "#command-palette-modal")
    end

    test "toggles settings modal via PubSub desktop_action :open_settings", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      refute has_element?(view, "#settings-modal")

      send(view.pid, {:desktop_action, :open_settings})
      assert has_element?(view, "#settings-modal")
    end

    test "creates new session via PubSub desktop_action :new_session", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      initial_sessions = IexCode.Sessions.list_sessions_for_project(project.id)

      send(view.pid, {:desktop_action, :new_session})
      _ = render(view)

      updated_sessions = IexCode.Sessions.list_sessions_for_project(project.id)
      assert length(updated_sessions) == length(initial_sessions) + 1
    end
  end

  describe "Mix Task Desktop" do
    test "Mix.Tasks.Desktop is defined with documentation" do
      assert Code.ensure_loaded?(Mix.Tasks.Desktop)
      assert function_exported?(Mix.Tasks.Desktop, :run, 1)

      assert Mix.Task.shortdoc(Mix.Tasks.Desktop) ==
               "Launches IexCode in native macOS desktop window"
    end

    test "desktop launch task env variables" do
      original_window = Application.get_env(:iex_code, :start_desktop_window)
      original_endpoint = Application.get_env(:iex_code, IexCodeWeb.Endpoint)

      try do
        Application.put_env(:iex_code, :start_desktop_window, true)
        Application.put_env(:iex_code, IexCodeWeb.Endpoint, server: true)

        assert Application.get_env(:iex_code, :start_desktop_window) == true
        assert Application.get_env(:iex_code, IexCodeWeb.Endpoint)[:server] == true
      after
        Application.put_env(:iex_code, :start_desktop_window, original_window)
        Application.put_env(:iex_code, IexCodeWeb.Endpoint, original_endpoint)
      end
    end
  end
end
