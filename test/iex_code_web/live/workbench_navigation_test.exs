defmodule IexCodeWeb.WorkbenchNavigationTest do
  use IexCode.E2E.Case, async: false

  alias IexCode.Kanban

  test "creating a task reveals its stage and card", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    view |> element("#kanban-empty-create-task") |> render_click()
    assert has_element?(view, "#new-task-modal")

    render_submit(view, "create_task", %{"title" => "Plan the next change", "status" => "todo"})
    [task] = Kanban.list_tasks(project.id)

    refute has_element?(view, "#new-task-modal")
    assert has_element?(view, "#kanban-col-todo[aria-expanded='true']")
    assert has_element?(view, "#kanban-cards-todo #task-card-#{task.id}")
    refute has_element?(view, "#task-detail-drawer")
  end

  test "stage selection, task moves, and the detail drawer stay in sync", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, task} =
      Kanban.create_task(%{
        project_id: project.id,
        session_id: session.id,
        title: "Review the workspace",
        status: "todo"
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    view |> element("#kanban-col-todo") |> render_click()
    assert has_element?(view, "#kanban-col-todo[aria-expanded='true']")
    assert has_element?(view, "#kanban-cards-todo #task-card-#{task.id}")

    view |> element("#task-card-#{task.id}") |> render_click()
    assert has_element?(view, "#task-detail-drawer")

    render_click(view, "move_task", %{"id" => task.id, "status" => "ready"})

    assert Kanban.get_task!(task.id).status == "ready"
    assert has_element?(view, "#kanban-col-ready[aria-expanded='true']")
    assert has_element?(view, "#kanban-cards-ready #task-card-#{task.id}")
    refute has_element?(view, "#kanban-cards-todo")
    assert has_element?(view, "#task-detail-drawer")
  end

  test "workspace preferences links open the requested visible section", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    assert has_element?(
             view,
             "#workspace-settings-general[href='/sessions/#{session.id}/settings/safety#execution']"
           )

    assert has_element?(
             view,
             "#workspace-settings-models[href='/sessions/#{session.id}/settings/providers#models']"
           )

    {:ok, settings, _html} = live(conn, ~p"/sessions/#{session.id}/settings/safety")
    assert has_element?(settings, "#tab-panel-safety:not(.hidden) #execution")
    assert has_element?(settings, "#tab-link-safety[aria-current='page']")
  end
end
