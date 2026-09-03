defmodule IexCodeWeb.WorkspaceLiveDockTitleTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true
  @moduletag timeout: 60_000

  alias IexCode.Desktop.Dock
  alias Phoenix.PubSub

  describe "WorkspaceLive Dynamic Dock Title Integration" do
    test "updates LiveView page title when dock_activity_updated is received", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Initial page title is based on session title and project name
      initial_title = page_title(view)
      assert initial_title =~ session.title

      # 1. Update activity via Dock
      Dock.set_activity(3, 1)

      # Ensure message has been handled by LiveView process
      _ = :sys.get_state(view.pid)

      assert page_title(view) == "IexCode - 3 running, 1 waiting"

      # 2. Update activity via PubSub broadcast directly
      PubSub.broadcast(
        IexCode.PubSub,
        "desktop:activity",
        {:dock_activity_updated,
         %{
           running: 0,
           waiting: 2,
           badge: "2",
           title: "IexCode - 0 running, 2 waiting"
         }}
      )

      _ = :sys.get_state(view.pid)
      assert page_title(view) == "IexCode - 0 running, 2 waiting"

      # 3. Clear dock activity
      Dock.clear()
      _ = :sys.get_state(view.pid)
      assert page_title(view) == "IexCode - Desktop AI Coding Harness"
    end
  end
end
