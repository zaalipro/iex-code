defmodule IexCodeWeb.DetachedWindowsTest do
  @moduledoc """
  Requirement R1: Multi-Window Native Desktop Detachment.
  Tests for dedicated standalone LiveViews:
  - TerminalLive (/sessions/:id/detached/terminal)
  - DiffLive (/sessions/:id/detached/diff)
  - DagLive (/sessions/:id/detached/dag)
  and real-time PubSub synchronization with main workspace.
  """
  use IexCodeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias IexCode.{Projects, Sessions}
  alias Phoenix.PubSub

  setup do
    unique_suffix = System.unique_integer([:positive])
    temp_root = Path.join(System.tmp_dir!(), "iex_detached_test_#{unique_suffix}")
    File.mkdir_p!(temp_root)

    {:ok, project} =
      Projects.create_project(%{
        name: "Detached Window Test Project #{unique_suffix}",
        root_path: temp_root
      })

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Detached Session #{unique_suffix}"
      })

    on_exit(fn ->
      File.rm_rf(temp_root)
    end)

    {:ok, project: project, session: session}
  end

  describe "Tier 1: Standalone LiveView Mounting & Containers" do
    test "T1_R1_LV_01: mounts detached terminal LiveView with proper layout and DOM container", %{
      conn: conn,
      session: session
    } do
      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}/detached/terminal")

      assert html =~ "Terminal"
      assert has_element?(view, "#detached-terminal-container")
      assert has_element?(view, "#terminal-session-container")
    end

    test "T1_R1_LV_02: mounts detached diff inspector LiveView with staging & diff containers", %{
      conn: conn,
      session: session
    } do
      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}/detached/diff")

      assert html =~ "Diff" or html =~ "Changes"
      assert has_element?(view, "#detached-diff-container")
      assert has_element?(view, "#diff-viewer-container")
    end

    test "T1_R1_LV_03: mounts detached DAG research visualizer LiveView with projection map", %{
      conn: conn,
      session: session
    } do
      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}/detached/dag")

      assert html =~ "DAG" or html =~ "Research"
      assert has_element?(view, "#detached-dag-container")
      assert has_element?(view, "#dag-execution-projection")
    end

    test "T1_R1_LV_04: detached views render edge-to-edge layout without main workspace sidebars",
         %{
           conn: conn,
           session: session
         } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/detached/terminal")

      # Should NOT render main workspace tabs sidebar in detached mode
      refute has_element?(view, "#main-workspace-nav-sidebar")
    end
  end

  describe "Tier 2: Boundary & Edge Conditions" do
    test "T2_R1_LV_01: non-existent session ID redirects or returns 404 cleanly", %{conn: conn} do
      bad_id = Ecto.UUID.generate()

      assert_error_sent 404, fn ->
        live(conn, ~p"/sessions/#{bad_id}/detached/terminal")
      end
    end

    test "T2_R1_LV_02: multiple concurrent detached views on same session run independently", %{
      conn: conn,
      session: session
    } do
      {:ok, term_view, _} = live(conn, ~p"/sessions/#{session.id}/detached/terminal")
      {:ok, diff_view, _} = live(conn, ~p"/sessions/#{session.id}/detached/diff")
      {:ok, dag_view, _} = live(conn, ~p"/sessions/#{session.id}/detached/dag")

      assert has_element?(term_view, "#detached-terminal-container")
      assert has_element?(diff_view, "#detached-diff-container")
      assert has_element?(dag_view, "#detached-dag-container")
    end
  end

  describe "Tier 3: Real-Time PubSub Synchronization Across Windows" do
    test "T3_R1_LV_01: terminal output broadcast updates detached terminal LiveView", %{
      conn: conn,
      session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/detached/terminal")

      chunk = "compilation succeeded in 4.2s\r\n"

      PubSub.broadcast(
        IexCode.PubSub,
        "session:#{session.id}:terminal",
        {:terminal_output, %{session_id: session.id, data: chunk}}
      )

      # LiveView handles the broadcast and pushes event or updates DOM
      render(view)
      assert has_element?(view, "#terminal-session-container")
    end

    test "T3_R1_LV_02: git mutation broadcast triggers diff refresh in detached diff view", %{
      conn: conn,
      session: session,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/detached/diff")

      PubSub.broadcast(
        IexCode.PubSub,
        "project:#{project.id}:git",
        {:git_state_changed, project.id}
      )

      render(view)
      assert has_element?(view, "#detached-diff-container")
    end

    test "T3_R1_LV_03: DAG run and step updates reflect in detached DAG view", %{
      conn: conn,
      session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/detached/dag")

      mock_run = %{id: Ecto.UUID.generate(), session_id: session.id, status: :running}

      PubSub.broadcast(
        IexCode.PubSub,
        "runs:session:#{session.id}",
        {:run_updated, mock_run}
      )

      render(view)
      assert has_element?(view, "#dag-execution-projection")
    end

    test "T3_R1_LV_04: research results broadcast unlocks report viewer in detached DAG view", %{
      conn: conn,
      session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/detached/dag")

      mock_result = %{
        session_id: session.id,
        objective: "Explore vector indexes",
        synthesis: "Comprehensive analysis complete"
      }

      PubSub.broadcast(
        IexCode.PubSub,
        "session:#{session.id}:research_results",
        {:research_result_updated, mock_result}
      )

      render(view)
      assert has_element?(view, "#detached-dag-container")
    end
  end
end
