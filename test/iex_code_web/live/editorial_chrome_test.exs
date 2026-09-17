defmodule IexCodeWeb.EditorialChromeTest do
  @moduledoc """
  Direction B stage B2: the editorial masthead (pill command palette + top nav)
  renders only under the editorial theme, keeps every route reachable, and
  leaves the sidebar code path intact as the narrow-screen fallback.
  """
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true

  alias IexCode.Settings

  setup %{workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    %{project: project, session: session}
  end

  defp use_editorial_theme do
    {:ok, settings} = Settings.update_settings(%{ui_theme: "editorial"})
    assert settings.ui_theme == "editorial"
  end

  test "workspace renders masthead with pill palette and session top nav", %{
    conn: conn,
    session: session
  } do
    use_editorial_theme()

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    assert has_element?(view, "#editorial-masthead")
    assert has_element?(view, "#editorial-palette-pill[phx-click='toggle_command_palette']")
    assert has_element?(view, "#editorial-topnav[aria-label='Primary']")

    assert view
           |> element("#editorial-nav-workspace")
           |> render() =~ ~s(href="/sessions/#{session.id}")

    assert view
           |> element("#editorial-nav-workflows")
           |> render() =~ ~s(href="/sessions/#{session.id}/workflows")

    assert view
           |> element("#editorial-nav-research")
           |> render() =~ ~s(href="/sessions/#{session.id}/research")

    assert view
           |> element("#editorial-nav-settings")
           |> render() =~ ~s(href="/sessions/#{session.id}/settings")

    assert has_element?(view, "#editorial-nav-workspace[aria-current='page']")
    assert has_element?(view, ".ed-session-chip", "session")

    # The sidebar code path stays rendered as the narrow-screen fallback.
    assert has_element?(view, "#workspace-sidebar")
    assert has_element?(view, "#workspace-sidebar-backdrop")
  end

  test "masthead pill opens the real command palette", %{conn: conn, session: session} do
    use_editorial_theme()

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    refute has_element?(view, "#command-palette-modal")

    view |> element("#editorial-palette-pill") |> render_click()

    assert has_element?(view, "#command-palette-modal")
    assert has_element?(view, "#command-palette-input")
  end

  test "settings and workflows pages render the masthead with a palette link home", %{
    conn: conn,
    session: session
  } do
    use_editorial_theme()

    {:ok, settings_view, _html} = live(conn, ~p"/sessions/#{session.id}/settings/providers")
    assert has_element?(settings_view, "#editorial-masthead")
    assert has_element?(settings_view, "#editorial-nav-settings[aria-current='page']")

    assert settings_view
           |> element("#editorial-palette-pill")
           |> render() =~ ~s(href="/sessions/#{session.id}")

    {:ok, workflows_view, _html} = live(conn, ~p"/sessions/#{session.id}/workflows")
    assert has_element?(workflows_view, "#editorial-masthead")
    assert has_element?(workflows_view, "#editorial-nav-workflows[aria-current='page']")

    # Every top-nav destination stays a working route under the theme.
    for path <- [
          "/sessions/#{session.id}",
          "/sessions/#{session.id}/workflows",
          "/sessions/#{session.id}/research",
          "/sessions/#{session.id}/settings"
        ] do
      {:ok, _routed_view, html} = live(conn, path)
      assert html =~ "editorial-masthead"
    end
  end

  test "non-editorial themes render no masthead", %{conn: conn, session: session} do
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    refute has_element?(view, "#editorial-masthead")
    assert has_element?(view, "#workspace-sidebar[data-collapsed='false']")
  end
end
