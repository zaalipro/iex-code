defmodule IexCodeWeb.Live.TeamworkModalTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true

  describe "Teamwork Modal & Orchestration Controls" do
    test "opens and closes teamwork modal via events and buttons", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      refute has_element?(view, "#teamwork-modal")

      # Open modal via toolbar button or event
      render_click(view, "open_teamwork")
      assert has_element?(view, "#teamwork-modal")
      assert has_element?(view, "#teamwork-blueprint-objective")
      assert has_element?(view, "#teamwork-patterns-grid")
      assert has_element?(view, "#teamwork-squad-grid")
      assert has_element?(view, "#teamwork-milestones-list")
      assert has_element?(view, "#teamwork-modal-launch-btn")

      # Close modal via close button
      render_click(view, "close_teamwork")
      refute has_element?(view, "#teamwork-modal")
    end

    test "switching blueprint pattern updates active pattern styling and squad", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "open_teamwork")
      assert has_element?(view, "#teamwork-modal")

      # Switch pattern to root_cause_and_fix
      render_click(view, "change_blueprint_pattern", %{"pattern" => "root_cause_and_fix"})
      assert has_element?(view, "#pattern-select-root_cause_and_fix.border-cyan-500")

      # Switch pattern to self_verification
      render_click(view, "change_blueprint_pattern", %{"pattern" => "self_verification"})
      assert has_element?(view, "#pattern-select-self_verification.border-cyan-500")
    end

    test "toggling boost mode dynamically updates blueprint boost state and pill", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "open_teamwork")
      assert has_element?(view, "#teamwork-modal")

      # Toggle boost on
      render_click(view, "toggle_boost_mode")
      assert has_element?(view, "#teamwork-boost-active-pill")

      # Toggle boost off
      render_click(view, "toggle_boost_mode")
      refute has_element?(view, "#teamwork-boost-active-pill")
    end

    test "launching teamwork swarm queues run and closes modal", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "open_teamwork")
      assert has_element?(view, "#teamwork-modal")

      # Launch swarm
      render_click(view, "launch_teamwork_swarm")
      refute has_element?(view, "#teamwork-modal")
    end

    test "renders structured deliverables and acceptance criteria in milestone breakdown", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "open_teamwork", %{
        "objective" => "Investigate and resolve deadlock in connection pool",
        "pattern" => "root_cause_and_fix"
      })

      assert has_element?(view, "#teamwork-modal")
      html = render(view)
      assert html =~ "Deliverables:"
      assert html =~ "Acceptance Criteria:"
      assert html =~ "hero-document-check"
      assert html =~ "hero-check-circle"
      assert html =~ "Failure Isolation &amp; Minimal Repro"
      assert html =~ "Implement Targeted Fix"
    end

    test "composer parses and routes compound /teamwork /boost /goal command", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      refute has_element?(view, "#teamwork-modal")

      render_submit(view, "submit_prompt", %{
        "prompt" => "/teamwork /boost /goal Synthesize high-throughput streaming pipeline"
      })

      assert has_element?(view, "#teamwork-modal")
      assert has_element?(view, "#teamwork-boost-active-pill")
      html = render(view)
      assert html =~ "Synthesize high-throughput streaming pipeline"

      # Dismiss modal
      render_click(view, "close_teamwork")
      refute has_element?(view, "#teamwork-modal")
    end

    test "RunComponents renders teamwork blueprint and boost telemetry cards on run overview" do
      blueprint =
        IexCode.Execution.Teamwork.generate_blueprint(
          "Architect distributed ingestion engine",
          boost?: true
        )

      run = %IexCode.Runs.Run{
        id: "run-boost-team-01",
        objective: "Architect distributed ingestion engine",
        status: "running",
        kind: "coding_swarm",
        mode: "swarm",
        priority: "high",
        execution_engine: "legacy_v1",
        progress: 42,
        metadata: %{
          "boost" => true,
          "teamwork_blueprint" => IexCode.Execution.Teamwork.to_map(blueprint)
        }
      }

      html =
        Phoenix.LiveViewTest.render_component(&IexCodeWeb.RunComponents.run_control_plane/1,
          runs: [run],
          run_count: 1,
          run_counts: %{active: 1, queued: 0, attention: 0, approvals: 0},
          selected_run: run,
          events: [],
          steps: [],
          approvals: [],
          artifacts: [],
          controls: []
        )

      assert html =~ ~s(id="selected-run-boost-badge")
      assert html =~ "BOOST ACTIVE"
      assert html =~ ~s(id="selected-run-teamwork-badge")
      assert html =~ "TEAMWORK"
      assert html =~ ~s(id="async-run-teamwork-blueprint")
      assert html =~ "Teamwork Blueprint"
      assert html =~ blueprint.pattern_name
      assert html =~ ~s(id="async-run-boost-telemetry")
      assert html =~ "3-Tier Boost Reasoning Hierarchy"
      assert html =~ "Tier 1: Sentinel"
      assert html =~ "Tier 2: DeepCoder"
      assert html =~ "Tier 3: Verifier"
    end

    test "RunComponents renders teamwork blueprint directly from Blueprint struct and atom maps" do
      blueprint =
        IexCode.Execution.Teamwork.generate_blueprint(
          "Refactor concurrent job queue",
          pattern: "root_cause_and_fix",
          boost?: true
        )

      # Run metadata with atom keys and Blueprint struct directly
      run = %IexCode.Runs.Run{
        id: "run-struct-test-01",
        objective: "Refactor concurrent job queue",
        status: "running",
        kind: "coding_swarm",
        mode: "swarm",
        priority: "high",
        execution_engine: "legacy_v1",
        progress: 60,
        metadata: %{
          boost: true,
          teamwork_blueprint: blueprint
        }
      }

      html =
        Phoenix.LiveViewTest.render_component(&IexCodeWeb.RunComponents.run_control_plane/1,
          runs: [run],
          run_count: 1,
          run_counts: %{active: 1, queued: 0, attention: 0, approvals: 0},
          selected_run: run,
          events: [],
          steps: [],
          approvals: [],
          artifacts: [],
          controls: []
        )

      assert html =~ ~s(id="async-run-teamwork-blueprint")
      assert html =~ "Root Cause &amp; Fix"
      assert html =~ "Failure Isolation &amp; Minimal Repro"
      assert html =~ "Milestone Progress:"
    end
  end
end
