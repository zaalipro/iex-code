defmodule IexCodeWeb.WorkspaceConsensusNavigationTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true

  test "sidebar and header both open the consensus panel", %{conn: conn, workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    view |> element("#sidebar-tab-consensus") |> render_click()
    assert has_element?(view, "#workspace-consensus-container")
    assert has_element?(view, "#sidebar-tab-consensus[aria-current='page']")

    view |> element("#sidebar-tab-kanban") |> render_click()
    refute has_element?(view, "#workspace-consensus-container")

    view |> element("#tab-btn-consensus") |> render_click()
    assert has_element?(view, "#workspace-consensus-container")
    assert has_element?(view, "#tab-btn-consensus[aria-pressed='true']")
  end
end
