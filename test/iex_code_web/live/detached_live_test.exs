defmodule IexCodeWeb.DetachedLiveTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true

  describe "Detached TerminalLive" do
    test "mounts and renders terminal multiplexer standalone", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/detached/terminal")

      assert has_element?(view, "#detached-terminal-toolbar-title", "Terminal multiplexer")
      assert has_element?(view, "#terminal-session-container")

      # Tab switching
      render_click(view, "switch_tab", %{"tab" => "iex"})
      assert has_element?(view, "button", "iex -S mix")

      # Clear terminal event
      render_click(view, "clear_terminal")
    end
  end

  describe "Detached DiffLive" do
    test "mounts and renders 3-tier staging hub standalone", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/detached/diff")

      assert has_element?(view, "#detached-diff-toolbar-title", "Git staging & diff inspector")
      assert has_element?(view, "button", "Stage All")
      assert has_element?(view, "button", "Unstage All")

      # Toggle diff modes
      render_click(view, "set_diff_mode", %{"mode" => "unified"})
      render_click(view, "set_diff_mode", %{"mode" => "split"})

      # PubSub git sync
      Phoenix.PubSub.broadcast(
        IexCode.PubSub,
        "project:#{project.id}:git",
        {:git_state_changed, project.id}
      )
    end
  end

  describe "Detached DagLive" do
    test "mounts and renders DAG visualizer standalone", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}/detached/dag")

      assert has_element?(view, "#detached-dag-toolbar-title", "DAG topological map")
      assert html =~ "STEP INSPECTOR"
    end
  end

  describe "WorkspaceLive Detach buttons and event" do
    test "workspace live handles detach_window event", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Trigger detachment event from UI
      render_click(view, "detach_window", %{"tool" => "terminal"})
      render_click(view, "detach_window", %{"tool" => "diff"})
      render_click(view, "detach_window", %{"tool" => "dag"})
    end
  end
end
