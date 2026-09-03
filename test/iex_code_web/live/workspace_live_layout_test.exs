defmodule IexCodeWeb.WorkspaceLiveLayoutTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true

  setup %{workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    %{project: project, session: session}
  end

  test "renders default layout with comfortable density and expanded sidebar", %{
    conn: conn,
    session: session
  } do
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    # Layout density attribute on workspace shell
    assert has_element?(view, "#workspace-shell[data-density='comfortable']")

    # Header density toggle button is rendered
    assert has_element?(view, "#header-density-toggle")
    assert element(view, "#header-density-toggle") |> render() =~ "comfortable"

    # Sidebar is expanded by default
    assert has_element?(view, "#workspace-sidebar[data-collapsed='false']")
    assert has_element?(view, "#sidebar-desktop-toggle-btn")

    # Bottom terminal dock is closed by default
    refute has_element?(view, "#bottom-terminal-dock")
  end

  test "toggles sidebar collapse state via desktop button and event", %{
    conn: conn,
    session: session
  } do
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    # Initial state: expanded
    assert has_element?(view, "#workspace-sidebar[data-collapsed='false']")

    # Click desktop toggle button -> collapses
    view
    |> element("#sidebar-desktop-toggle-btn")
    |> render_click()

    assert has_element?(view, "#workspace-sidebar[data-collapsed='true']")
    sidebar_html = element(view, "#workspace-sidebar") |> render()
    assert sidebar_html =~ "w-0"
    assert sidebar_html =~ "opacity-0"

    # Click again -> expands
    view
    |> element("#sidebar-desktop-toggle-btn")
    |> render_click()

    assert has_element?(view, "#workspace-sidebar[data-collapsed='false']")
    refute element(view, "#workspace-sidebar") |> render() =~ "w-0 min-w-0"

    # Direct event trigger
    render_click(view, "toggle_sidebar", %{})
    assert has_element?(view, "#workspace-sidebar[data-collapsed='true']")
  end

  test "toggles bottom terminal panel via event and close button", %{
    conn: conn,
    session: session
  } do
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    # Initially closed
    refute has_element?(view, "#bottom-terminal-dock")

    # Toggle open
    render_click(view, "toggle_bottom_terminal", %{})
    assert has_element?(view, "#bottom-terminal-dock")

    # Verify dock header and contents
    assert has_element?(view, "#bottom-dock-quick-test")
    assert has_element?(view, "#bottom-dock-quick-precommit")
    assert has_element?(view, "#bottom-dock-close-btn")
    assert has_element?(view, "#bottom-terminal-dock #terminal-session-container")

    # Test quick action click inside bottom terminal dock
    view
    |> element("#bottom-dock-quick-test")
    |> render_click()

    # Click close button inside dock -> closes dock
    view
    |> element("#bottom-dock-close-btn")
    |> render_click()

    refute has_element?(view, "#bottom-terminal-dock")
  end

  test "toggles layout density between comfortable and compact", %{
    conn: conn,
    session: session
  } do
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    # Initial density: comfortable
    assert has_element?(view, "#workspace-shell[data-density='comfortable']")
    assert element(view, "#header-density-toggle") |> render() =~ "comfortable"

    # Click density toggle -> compact
    view
    |> element("#header-density-toggle")
    |> render_click()

    assert has_element?(view, "#workspace-shell[data-density='compact']")
    assert element(view, "#header-density-toggle") |> render() =~ "compact"

    # Click again -> comfortable
    view
    |> element("#header-density-toggle")
    |> render_click()

    assert has_element?(view, "#workspace-shell[data-density='comfortable']")
    assert element(view, "#header-density-toggle") |> render() =~ "comfortable"
  end

  test "handles desktop menu bar action messages for sidebar and terminal", %{
    conn: conn,
    session: session
  } do
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    # Send {:desktop_action, :toggle_sidebar}
    assert has_element?(view, "#workspace-sidebar[data-collapsed='false']")
    send(view.pid, {:desktop_action, :toggle_sidebar})
    assert has_element?(view, "#workspace-sidebar[data-collapsed='true']")

    send(view.pid, {:desktop_action, :toggle_sidebar})
    assert has_element?(view, "#workspace-sidebar[data-collapsed='false']")

    # Send {:desktop_action, :toggle_terminal}
    refute has_element?(view, "#bottom-terminal-dock")
    send(view.pid, {:desktop_action, :toggle_terminal})
    assert has_element?(view, "#bottom-terminal-dock")

    send(view.pid, {:desktop_action, :toggle_terminal})
    refute has_element?(view, "#bottom-terminal-dock")
  end

  test "bottom terminal dock persists across tab switching and executes mix precommit", %{
    conn: conn,
    session: session
  } do
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    # Open bottom terminal dock
    render_click(view, "toggle_bottom_terminal", %{})
    assert has_element?(view, "#bottom-terminal-dock")

    # Switch to swarm tab
    view
    |> element("#tab-btn-swarm")
    |> render_click()

    # Terminal dock is still visible while viewing swarm
    assert has_element?(view, "#bottom-terminal-dock")
    assert render(view) =~ "PlannerAgent"

    # Switch to changes tab
    view
    |> element("#tab-btn-changes")
    |> render_click()

    # Terminal dock is still visible while viewing changes
    assert has_element?(view, "#bottom-terminal-dock")
    assert render(view) =~ "All Changes"

    # Click mix precommit quick action in dock header
    view
    |> element("#bottom-dock-quick-precommit")
    |> render_click()

    # Close bottom terminal dock
    render_click(view, "toggle_bottom_terminal", %{})
    refute has_element?(view, "#bottom-terminal-dock")
  end
end
