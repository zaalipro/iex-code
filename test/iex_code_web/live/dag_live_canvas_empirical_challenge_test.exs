defmodule IexCodeWeb.Live.DagLiveCanvasEmpiricalChallengeTest do
  @moduledoc """
  Adversarial Empirical Challenge Test for SwarmCanvas LiveView integration (Milestone 2).

  Empirically tests:
  1. Rapid sequential pan and zoom events (`canvas_pan`, `canvas_zoom`, `canvas_reset`, `canvas_fit`)
     in WorkspaceLive and Detached DagLive.
  2. Toggling view mode in `DagLive` between "canvas" and "stages" under high-frequency updates.
  3. Node selection (`select_canvas_node`) with valid and non-existent IDs in both LiveViews.
  4. PubSub step updates (`:run_step_updated` and `:run_updated`) refreshing canvas smoothly without crashes.
  5. Empirical stress test with actual Run and RunSteps in the database.
  """
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true

  import Phoenix.LiveViewTest
  alias IexCode.{Projects, Repo, Runs, Sessions}

  setup %{workspace_path: path} do
    {:ok, project} =
      Projects.create_project(%{
        name: "Empirical Challenge Project",
        root_path: path
      })

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Empirical Challenge Session",
        model_provider: "openai",
        model_name: "gemini-2.5-pro"
      })

    {:ok, project: project, session: session}
  end

  describe "1. Rapid sequential pan, zoom, reset, fit in WorkspaceLive & DagLive" do
    test "WorkspaceLive Swarm tab survives rapid pan and zoom event bursts",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      render_click(view, "switch_tab", %{"tab" => "swarm"})

      # Rapid pan event burst with negative, integer, float, and decimal strings
      for i <- 1..30 do
        x = i * 15.5 - 200.0
        y = i * -10.2 + 150.0
        render_click(view, "canvas_pan", %{"x" => to_string(x), "y" => to_string(y)})
      end

      assert Process.alive?(view.pid)

      # Rapid zoom events
      for _ <- 1..15 do
        render_click(view, "canvas_zoom", %{"direction" => "in"})
      end

      # Zoom must clamp at 3.0
      assert has_element?(view, "#workspace-swarm-canvas[data-zoom='3.0']")

      for _ <- 1..25 do
        render_click(view, "canvas_zoom", %{"direction" => "out"})
      end

      # Zoom must clamp at 0.2
      assert has_element?(view, "#workspace-swarm-canvas[data-zoom='0.2']")

      # Direct zoom level burst
      for level <- [0.5, 1.25, 2.5, 0.2, 3.0, 100.0, -50.0] do
        render_click(view, "canvas_zoom", %{"level" => to_string(level)})
      end

      # Reset and fit
      render_click(view, "canvas_reset")

      assert has_element?(
               view,
               "#workspace-swarm-canvas[data-zoom='1.0'][data-pan-x='0.0'][data-pan-y='0.0']"
             )

      render_click(view, "canvas_fit")

      assert has_element?(
               view,
               "#workspace-swarm-canvas[data-zoom='0.9'][data-pan-x='20.0'][data-pan-y='20.0']"
             )
    end

    test "Detached DagLive survives rapid pan and zoom event bursts",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/detached/dag")

      # Rapid pan event burst
      for i <- 1..30 do
        x = i * -22.5 + 300.0
        y = i * 18.0 - 100.0
        render_click(view, "canvas_pan", %{"x" => to_string(x), "y" => to_string(y)})
      end

      assert Process.alive?(view.pid)

      # Rapid zoom in and zoom out
      for _ <- 1..20 do
        render_click(view, "canvas_zoom", %{"direction" => "in"})
      end

      assert has_element?(view, "#detached-dag-canvas[data-zoom='3.0']")

      for _ <- 1..30 do
        render_click(view, "canvas_zoom", %{"direction" => "out"})
      end

      assert has_element?(view, "#detached-dag-canvas[data-zoom='0.2']")

      # Reset and fit
      render_click(view, "canvas_reset")

      assert has_element?(
               view,
               "#detached-dag-canvas[data-zoom='1.0'][data-pan-x='0.0'][data-pan-y='0.0']"
             )

      render_click(view, "canvas_fit")

      assert has_element?(
               view,
               "#detached-dag-canvas[data-zoom='0.9'][data-pan-x='20.0'][data-pan-y='20.0']"
             )
    end
  end

  describe "2. View mode toggling in DagLive under high frequency" do
    test "toggling view mode rapidly between canvas and stages",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/detached/dag")

      for _ <- 1..25 do
        render_click(view, "toggle_dag_view", %{"mode" => "stages"})
        render_click(view, "toggle_dag_view", %{"mode" => "canvas"})
      end

      assert Process.alive?(view.pid)
      assert has_element?(view, "#detached-dag-canvas")
    end
  end

  describe "3. Node selection with valid and non-existent IDs" do
    test "select_canvas_node in WorkspaceLive with valid, empty, and non-existent IDs",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      render_click(view, "switch_tab", %{"tab" => "swarm"})

      # Non-existent node ID
      render_click(view, "select_canvas_node", %{"id" => "non-existent-node-9999"})
      assert Process.alive?(view.pid)

      # Empty string ID
      render_click(view, "select_canvas_node", %{"id" => ""})
      assert Process.alive?(view.pid)

      # Arbitrary string with special characters
      render_click(view, "select_canvas_node", %{"id" => "<script>alert(1)</script>"})
      assert Process.alive?(view.pid)
    end

    test "select_canvas_node in Detached DagLive with non-existent IDs",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/detached/dag")

      # Non-existent node ID
      render_click(view, "select_canvas_node", %{"id" => "node-does-not-exist"})
      assert Process.alive?(view.pid)

      # Empty string ID
      render_click(view, "select_canvas_node", %{"id" => ""})
      assert Process.alive?(view.pid)
    end
  end

  describe "4. PubSub step updates and live step rendering" do
    test "PubSub {:run_updated, ...} and {:run_step_updated, ...} refresh canvas without crashing when no run exists",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/detached/dag")

      fake_run = %{id: "fake-run-id", status: "running"}
      fake_step = %{id: "fake-step-id", run_id: "fake-run-id", key: "step-1", status: "running"}

      send(view.pid, {:run_updated, fake_run})
      assert Process.alive?(view.pid)

      send(view.pid, {:run_step_updated, fake_step})
      assert Process.alive?(view.pid)
    end

    test "Detached DagLive mounting and rendering when an actual Run and RunStep exist in the database",
         %{conn: conn, session: session, project: project} do
      # Create an actual run in the database
      {:ok, run} =
        Runs.create_run(%{
          project_id: project.id,
          session_id: session.id,
          objective: "DAG Challenge Test Run",
          kind: "analysis",
          mode: "single",
          execution_engine: "legacy_v1"
        })

      # Create actual steps for this run
      {:ok, step1} =
        Runs.create_step(run, %{
          key: "init_analysis",
          kind: "analysis",
          title: "Initial Architecture Analysis",
          position: 0
        })

      {:ok, _step2} =
        Runs.create_step(run, %{
          key: "verify_plan",
          kind: "verify",
          title: "Verification Pass",
          position: 1
        })

      # Mount Detached DagLive with actual Run and RunSteps in DB
      # This tests whether step[:title] or other struct access raises an error!
      result = live(conn, ~p"/sessions/#{session.id}/detached/dag")

      case result do
        {:ok, view, html} ->
          assert has_element?(view, "#detached-dag-toolbar-title", "DAG topological map")
          assert html =~ "Initial Architecture Analysis"
          assert html =~ "Verification Pass"

          # Select canvas node
          render_click(view, "select_canvas_node", %{"id" => step1.key})
          assert Process.alive?(view.pid)

          # Send PubSub step update
          send(view.pid, {:run_step_updated, %{run_id: run.id, id: step1.id}})
          assert Process.alive?(view.pid)

        {:error, reason} ->
          flunk("Detached DagLive crashed on mount with active run and steps: #{inspect(reason)}")
      end
    end

    test "WorkspaceLive Swarm tab mounts and renders smoothly when an actual Run and RunStep exist in the database",
         %{conn: conn, session: session, project: project} do
      {:ok, run} =
        Runs.create_run(%{
          project_id: project.id,
          session_id: session.id,
          objective: "Workspace Swarm Run",
          kind: "analysis",
          mode: "single",
          execution_engine: "legacy_v1"
        })

      {:ok, _step} =
        Runs.create_step(run, %{
          key: "workspace_step",
          kind: "analysis",
          title: "Workspace Analysis Step",
          position: 0
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      render_click(view, "switch_tab", %{"tab" => "swarm"})

      assert has_element?(view, "#workspace-swarm-canvas-section")
      assert has_element?(view, "#workspace-swarm-canvas")
      assert Process.alive?(view.pid)
    end

    test "Detached DagLive mounting and rendering with dag_v1 run renders steps cleanly without struct access crash",
         %{conn: conn, session: session, project: project} do
      {:ok, run} =
        %Runs.Run{project_id: project.id, session_id: session.id}
        |> Runs.Run.create_changeset(%{
          objective: "DAG v1 objective",
          kind: "analysis",
          mode: "single",
          execution_engine: "dag_v1",
          manifest_hash: String.duplicate("0", 64)
        })
        |> IexCode.Repo.insert()

      {:ok, _step} =
        %Runs.RunStep{run_id: run.id}
        |> Runs.RunStep.create_changeset(%{
          key: "dag_v1_step",
          kind: "analysis",
          title: "DAG v1 Step Title",
          position: 0
        })
        |> IexCode.Repo.insert()

      # Mount Detached DagLive
      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}/detached/dag")
      assert has_element?(view, "#detached-dag-toolbar-title", "DAG topological map")
      assert html =~ "DAG v1 Step Title"
      assert Process.alive?(view.pid)
    end
  end

  describe "5. Empirical verification of %Run{} & %RunStep{} structs" do
    test "view toggling with active dag_v1 multi-stage graph",
         %{conn: conn, session: session, project: project} do
      {:ok, run} =
        %Runs.Run{project_id: project.id, session_id: session.id}
        |> Runs.Run.create_changeset(%{
          objective: "Multi-Stage DAG Run",
          kind: "analysis",
          mode: "single",
          execution_engine: "dag_v1",
          manifest_hash: String.duplicate("b", 64)
        })
        |> Repo.insert()

      {:ok, run} =
        run
        |> Ecto.Changeset.change(%{event_sequence: 88, status: "running"})
        |> Repo.update()

      {:ok, _step1} =
        %Runs.RunStep{run_id: run.id}
        |> Runs.RunStep.create_changeset(%{
          key: "prep",
          kind: "analysis",
          title: "Preparation Step",
          position: 0,
          status: "completed",
          depends_on: []
        })
        |> Repo.insert()

      {:ok, _step2} =
        %Runs.RunStep{run_id: run.id}
        |> Runs.RunStep.create_changeset(%{
          key: "process",
          kind: "verify",
          title: "Processing Step",
          position: 1,
          status: "running",
          depends_on: ["prep"]
        })
        |> Repo.insert()

      {:ok, _step3} =
        %Runs.RunStep{run_id: run.id}
        |> Runs.RunStep.create_changeset(%{
          key: "report",
          kind: "analysis",
          title: "Reporting Step",
          position: 2,
          status: "ready",
          depends_on: ["process"]
        })
        |> Repo.insert()

      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}/detached/dag")

      assert has_element?(view, "#detached-dag-toolbar-title", "DAG topological map")
      assert html =~ "Run: #{run.id} (running)"
      assert has_element?(view, "#detached-dag-canvas")

      res = render_click(view, "toggle_dag_view", %{"mode" => "stages"})
      assert res =~ "DAG execution map"
      assert Process.alive?(view.pid)

      _res2 = render_click(view, "toggle_dag_view", %{"mode" => "canvas"})
      assert has_element?(view, "#detached-dag-canvas")
      assert Process.alive?(view.pid)
    end

    test "step selection and detail inspection with %RunStep{}",
         %{conn: conn, session: session, project: project} do
      {:ok, run} =
        %Runs.Run{project_id: project.id, session_id: session.id}
        |> Runs.Run.create_changeset(%{
          objective: "Step Inspector Challenge Run",
          kind: "analysis",
          mode: "single",
          execution_engine: "dag_v1",
          manifest_hash: String.duplicate("c", 64)
        })
        |> Repo.insert()

      {:ok, s1} =
        %Runs.RunStep{run_id: run.id}
        |> Runs.RunStep.create_changeset(%{
          key: "step_output",
          kind: "analysis",
          title: "Step With Result Output",
          position: 0,
          status: "completed",
          depends_on: []
        })
        |> Repo.insert()

      {:ok, s1} =
        s1
        |> Ecto.Changeset.change(%{result: %{"exit_code" => 0, "logs" => "Success output"}})
        |> Repo.update()

      {:ok, s2} =
        %Runs.RunStep{run_id: run.id}
        |> Runs.RunStep.create_changeset(%{
          key: "step_running",
          kind: "worker_exec",
          title: "Active Worker Step",
          position: 1,
          status: "running",
          depends_on: ["step_output"]
        })
        |> Repo.insert()

      {:ok, s3} =
        %Runs.RunStep{run_id: run.id}
        |> Runs.RunStep.create_changeset(%{
          key: "step_failed",
          kind: "lint_check",
          title: "Failed Verification Step",
          position: 2,
          status: "failed",
          depends_on: ["step_output"]
        })
        |> Repo.insert()

      {:ok, s4} =
        %Runs.RunStep{run_id: run.id}
        |> Runs.RunStep.create_changeset(%{
          key: "step_blocked",
          kind: "deploy_task",
          title: "Blocked Deploy Step",
          position: 3,
          status: "blocked",
          depends_on: ["step_running", "step_failed"]
        })
        |> Repo.insert()

      {:ok, _s5} =
        %Runs.RunStep{run_id: run.id}
        |> Runs.RunStep.create_changeset(%{
          key: "step_fallback_name",
          kind: "custom_analyzer",
          title: "Custom Step Fallback",
          position: 4,
          status: "ready",
          depends_on: []
        })
        |> Repo.insert()

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/detached/dag")

      # 1. Select s1
      render_click(view, "select_step", %{"id" => s1.id})
      html1 = render(view)
      assert html1 =~ "Step With Result Output"
      assert html1 =~ s1.id
      assert html1 =~ "completed"
      assert html1 =~ "analysis"
      assert html1 =~ "Dependencies: 0"

      # 2. Select s2 via string ID
      render_click(view, "select_step", %{"id" => to_string(s2.id)})
      html2 = render(view)
      assert html2 =~ "Active Worker Step"
      assert html2 =~ "running"
      assert html2 =~ "worker_exec"
      assert html2 =~ "Dependencies: 1"

      # 3. Select s3 via select_canvas_node with key
      render_click(view, "select_canvas_node", %{"id" => s3.key})
      html3 = render(view)
      assert html3 =~ "Failed Verification Step"
      assert html3 =~ "failed"
      assert html3 =~ "lint_check"

      # 4. Select s4 via select_canvas_node with string ID
      render_click(view, "select_canvas_node", %{"id" => to_string(s4.id)})
      html4 = render(view)
      assert html4 =~ "Blocked Deploy Step"
      assert html4 =~ "blocked"
      assert html4 =~ "Dependencies: 2"

      # 5. Select non-existent step ID
      render_click(view, "select_step", %{"id" => "non-existent-uuid-12345"})
      assert Process.alive?(view.pid)

      # 6. Select non-existent canvas node key
      render_click(view, "select_canvas_node", %{"id" => "unknown_key_999"})
      assert Process.alive?(view.pid)
    end

    test "PubSub updates and revisions with struct payloads",
         %{conn: conn, session: session, project: project} do
      {:ok, run} =
        %Runs.Run{project_id: project.id, session_id: session.id}
        |> Runs.Run.create_changeset(%{
          objective: "PubSub Revision Struct Run",
          kind: "analysis",
          mode: "single",
          execution_engine: "dag_v1",
          manifest_hash: String.duplicate("d", 64)
        })
        |> Repo.insert()

      {:ok, run} =
        run
        |> Ecto.Changeset.change(%{event_sequence: 33, status: "running"})
        |> Repo.update()

      {:ok, step} =
        %Runs.RunStep{run_id: run.id}
        |> Runs.RunStep.create_changeset(%{
          key: "pubsub_node",
          kind: "analysis",
          title: "Initial Node Title",
          position: 0,
          status: "pending",
          depends_on: []
        })
        |> Repo.insert()

      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}/detached/dag")
      assert html =~ "Initial Node Title"
      assert html =~ "Run: #{run.id} (running)"

      # Update run in database and send %Runs.Run{} struct
      {:ok, updated_run} =
        run
        |> Ecto.Changeset.change(%{status: "completed", event_sequence: 142})
        |> Repo.update()

      # Send %Runs.Run{} struct through PubSub
      send(view.pid, {:run_updated, updated_run})
      updated_html = render(view)
      assert updated_html =~ "Run: #{run.id} (completed)"
      assert Process.alive?(view.pid)

      # Update step in database and send %Runs.RunStep{} struct
      {:ok, updated_step} =
        step
        |> Ecto.Changeset.change(%{status: "completed", title: "Mutated Node Title"})
        |> Repo.update()

      # Send %Runs.RunStep{} struct through PubSub
      send(view.pid, {:run_step_updated, updated_step})
      step_updated_html = render(view)
      assert step_updated_html =~ "Mutated Node Title"
      assert Process.alive?(view.pid)
    end

    test "fallback error projection preserves revision",
         %{conn: conn, session: session, project: project} do
      # Create a legacy_v1 run which DagProjection rejects with {:error, {:not_dag_run, "legacy_v1"}}
      {:ok, run} =
        %Runs.Run{project_id: project.id, session_id: session.id}
        |> Runs.Run.create_changeset(%{
          objective: "Fallback Error Projection Run",
          kind: "analysis",
          mode: "single",
          execution_engine: "legacy_v1"
        })
        |> Repo.insert()

      {:ok, run} =
        run
        |> Ecto.Changeset.change(%{event_sequence: 77, status: "queued"})
        |> Repo.update()

      {:ok, step} =
        %Runs.RunStep{run_id: run.id}
        |> Runs.RunStep.create_changeset(%{
          key: "fallback_step",
          kind: "analysis",
          title: "Fallback Analysis Step",
          position: 0,
          status: "pending",
          depends_on: []
        })
        |> Repo.insert()

      # Mount Detached.DagLive - triggers DagProjection.build which fails closed
      # line 231 executes: revision: if(run, do: Map.get(run, :event_sequence, 0), else: 0)
      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}/detached/dag")

      assert has_element?(view, "#detached-dag-toolbar-title", "DAG topological map")
      assert html =~ "Fallback Analysis Step"
      assert html =~ "Run: #{run.id} (queued)"
      assert Process.alive?(view.pid)

      # Step selection on fallback projection
      render_click(view, "select_step", %{"id" => step.id})
      html_selected = render(view)
      assert html_selected =~ "Fallback Analysis Step"
      assert html_selected =~ step.id
      assert Process.alive?(view.pid)
    end
  end
end
