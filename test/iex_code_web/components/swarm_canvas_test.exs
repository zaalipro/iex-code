defmodule IexCodeWeb.Components.SwarmCanvasTest do
  @moduledoc """
  Authoritative Unit and LiveView Integration Tests for Milestone 2:
  Interactive Swarm & Workflow Visualizer Canvas (Requirement R2).
  """
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true

  import Phoenix.LiveViewTest
  alias IexCodeWeb.Components.SwarmCanvas
  alias IexCode.{Projects, Sessions}

  setup %{workspace_path: path} do
    {:ok, project} =
      Projects.create_project(%{
        name: "Swarm Canvas Test Project",
        root_path: path
      })

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Swarm Canvas Test Session",
        model_provider: "openai",
        model_name: "gemini-2.5-pro"
      })

    {:ok, project: project, session: session}
  end

  # ============================================================================
  # TIER 1: UNIT & COMPONENT TESTS
  # ============================================================================
  describe "SwarmCanvas Component Rendering" do
    test "renders SVG canvas with viewport transform, grid pattern, and controls toolbar" do
      nodes = [
        %{
          id: "node-1",
          key: "init",
          title: "Init Node",
          raw_status: "ready",
          canonical_state: :planning,
          tokens_label: "1.2k tok",
          memory_label: "14.2 MB",
          x: 60,
          y: 60,
          width: 250,
          height: 115
        }
      ]

      edges = []

      html =
        render_component(&SwarmCanvas.swarm_canvas/1,
          id: "test-swarm-canvas",
          nodes: nodes,
          edges: edges,
          zoom_level: 1.25,
          pan_offset: %{x: 45.0, y: 30.0}
        )

      document = LazyHTML.from_fragment(html)

      assert LazyHTML.query(document, "#test-swarm-canvas")
      assert LazyHTML.query(document, "#test-swarm-canvas-svg")

      assert LazyHTML.query(
               document,
               "#swarm-canvas-viewport[transform='translate(45.0, 30.0) scale(1.25)']"
             )

      # Controls toolbar
      assert LazyHTML.query(document, "#test-swarm-canvas-zoom-in")
      assert LazyHTML.query(document, "#test-swarm-canvas-zoom-out")
      assert LazyHTML.query(document, "#test-swarm-canvas-reset")
      assert LazyHTML.query(document, "#test-swarm-canvas-fit")
      assert html =~ "125%"
      assert html =~ "1 nodes"
    end

    test "generates dynamic cubic Bézier connector edges between nodes" do
      from_node = %{
        id: "step-a",
        key: "step_a",
        title: "Step A",
        x: 60,
        y: 80,
        width: 240,
        height: 100,
        canonical_state: :verified
      }

      to_node = %{
        id: "step-b",
        key: "step_b",
        title: "Step B",
        x: 420,
        y: 160,
        width: 240,
        height: 100,
        canonical_state: :running
      }

      edge =
        SwarmCanvas.bezier_edge(from_node, to_node)
        |> Map.merge(%{
          id: "step-a->step-b",
          from: "step-a",
          to: "step-b",
          active?: true,
          canonical_state: :running
        })

      # Assert curve mathematical structure
      assert edge.x1 == 300
      assert edge.y1 == 130
      assert edge.x2 == 420
      assert edge.y2 == 210
      assert edge.d =~ "M 300 130 C"
      assert edge.d =~ "420 210"

      html =
        render_component(&SwarmCanvas.swarm_canvas/1,
          id: "bezier-canvas",
          nodes: [from_node, to_node],
          edges: [edge],
          zoom_level: 1.0,
          pan_offset: %{x: 0, y: 0}
        )

      assert html =~ "swarm-edge-step-a-&gt;step-b" or html =~ "swarm-edge-step-a->step-b"
      assert html =~ "M 300 130 C"
    end

    test "animates traveling pulses along active/running edges via stroke-dasharray and SVG animate" do
      from_node = %{id: "n1", key: "n1", x: 60, y: 60, width: 200, height: 100}
      to_node = %{id: "n2", key: "n2", x: 360, y: 60, width: 200, height: 100}

      edge = %{
        id: "n1->n2",
        from: "n1",
        to: "n2",
        active?: true,
        canonical_state: :running
      }

      html =
        render_component(&SwarmCanvas.swarm_canvas/1,
          id: "pulse-canvas",
          nodes: [from_node, to_node],
          edges: [edge],
          zoom_level: 1.0,
          pan_offset: %{x: 0, y: 0}
        )

      assert html =~ "flow-pulse"
      assert html =~ "stroke-dasharray=\"8,6\""
      assert html =~ "attributeName=\"stroke-dashoffset\""
      assert html =~ "<animateMotion"
      assert html =~ "stroke-cyan-400"
    end

    test "5 canonical task states map correctly and display status badges and active halo" do
      # 1. Test normalizer function
      assert SwarmCanvas.normalize_task_state("pending") == :idle
      assert SwarmCanvas.normalize_task_state("starting") == :idle
      assert SwarmCanvas.normalize_task_state("paused") == :idle
      assert SwarmCanvas.normalize_task_state("ready") == :planning
      assert SwarmCanvas.normalize_task_state("planning") == :planning
      assert SwarmCanvas.normalize_task_state("waiting_dependencies") == :planning
      assert SwarmCanvas.normalize_task_state("running") == :running
      assert SwarmCanvas.normalize_task_state("leased") == :running
      assert SwarmCanvas.normalize_task_state("completed") == :verified
      assert SwarmCanvas.normalize_task_state("verified") == :verified
      assert SwarmCanvas.normalize_task_state("failed") == :failed
      assert SwarmCanvas.normalize_task_state("dependency_failed") == :failed
      assert SwarmCanvas.normalize_task_state("cancelled") == :failed

      # Atom versions
      assert SwarmCanvas.normalize_task_state(:running) == :running
      assert SwarmCanvas.normalize_task_state(:completed) == :verified
      assert SwarmCanvas.normalize_task_state(:failed) == :failed
      assert SwarmCanvas.normalize_task_state(:ready) == :planning
      assert SwarmCanvas.normalize_task_state(:idle) == :idle

      # 2. Render all 5 states in component
      states = [
        %{id: "n-idle", key: "idle_task", title: "Idle Task", raw_status: "idle"},
        %{id: "n-plan", key: "plan_task", title: "Plan Task", raw_status: "ready"},
        %{id: "n-run", key: "run_task", title: "Run Task", raw_status: "running"},
        %{id: "n-ver", key: "ver_task", title: "Verified Task", raw_status: "completed"},
        %{id: "n-fail", key: "fail_task", title: "Failed Task", raw_status: "failed"}
      ]

      html =
        render_component(&SwarmCanvas.swarm_canvas/1,
          id: "states-canvas",
          nodes: states,
          edges: [],
          zoom_level: 1.0,
          pan_offset: %{x: 0, y: 0}
        )

      document = LazyHTML.from_fragment(html)

      assert LazyHTML.query(document, "#swarm-node-n-idle[data-canonical-state='idle']")
      assert LazyHTML.query(document, "#swarm-node-n-plan[data-canonical-state='planning']")
      assert LazyHTML.query(document, "#swarm-node-n-run[data-canonical-state='running']")
      assert LazyHTML.query(document, "#swarm-node-n-ver[data-canonical-state='verified']")
      assert LazyHTML.query(document, "#swarm-node-n-fail[data-canonical-state='failed']")

      # Check badge text and halos
      assert html =~ "IDLE"
      assert html =~ "PLANNING"
      assert html =~ "RUNNING"
      assert html =~ "VERIFIED"
      assert html =~ "FAILED"

      # Running node has active pulse halo and cyan border
      assert html =~ "shadow-[0_0_22px_rgba(34,211,238,0.45)]"
      assert html =~ "border-cyan-400"
    end

    test "per-node telemetry pills format token counts and memory usage accurately" do
      # 1. Test formatters directly
      assert SwarmCanvas.format_tokens(0) == "0 tok"
      assert SwarmCanvas.format_tokens(450) == "450 tok"
      assert SwarmCanvas.format_tokens(1_250) == "1.3k tok"
      assert SwarmCanvas.format_tokens(24_800) == "24.8k tok"
      assert SwarmCanvas.format_tokens(1_500_000) == "1.5M tok"

      assert SwarmCanvas.format_memory(14.2) == "14.2 MB"
      assert SwarmCanvas.format_memory(8) == "8.0 MB"
      assert SwarmCanvas.format_memory(16_777_216) == "16.0 MB"

      # 2. Test in component output
      nodes = [
        %{
          id: "tele-node",
          key: "indexer",
          title: "Codebase Indexer",
          raw_status: "running",
          telemetry: %{
            tokens: 3_200,
            tokens_label: "3.2k tok",
            memory_mb: 18.5,
            memory_label: "18.5 MB"
          }
        }
      ]

      html =
        render_component(&SwarmCanvas.swarm_canvas/1,
          id: "tele-canvas",
          nodes: nodes,
          edges: [],
          zoom_level: 1.0,
          pan_offset: %{x: 0, y: 0}
        )

      assert html =~ "3.2k tok"
      assert html =~ "18.5 MB"
      assert html =~ "telemetry-pill-tele-node"
    end

    test "build_graph_from_projection converts layered DAG into nodes and Bézier edges" do
      projection = %{
        engine: "dag_v1",
        available?: true,
        summary: %{},
        layers: [
          [
            %{id: "p1", key: "parse", title: "Parse AST", status: "completed", depends_on: []}
          ],
          [
            %{
              id: "p2",
              key: "typecheck",
              title: "Type Check",
              status: "running",
              depends_on: ["parse"]
            }
          ]
        ]
      }

      graph = SwarmCanvas.build_graph_from_projection(projection)
      assert length(graph.nodes) == 2
      assert length(graph.edges) == 1

      edge = List.first(graph.edges)
      assert edge.from == "p1"
      assert edge.to == "p2"
      assert edge.active? == true
      assert edge.canonical_state == :running
      assert edge.d =~ "M"
      assert edge.d =~ "C"
    end

    test "build_graph_from_agents builds hierarchical tree from parent_agent_id relations" do
      agents = [
        %{
          id: "lead-agent",
          key: "lead",
          role: "lead",
          display_name: "Swarm Orchestrator",
          status: "running",
          parent_agent_id: nil,
          input_tokens: 1_200,
          output_tokens: 800,
          memory_mb: 24.5
        },
        %{
          id: "worker-agent",
          key: "coder",
          role: "coder",
          display_name: "Coder Subagent",
          status: "running",
          parent_agent_id: "lead-agent",
          input_tokens: 500,
          output_tokens: 1_100,
          memory_mb: 16.0
        }
      ]

      graph = SwarmCanvas.build_graph_from_agents(agents)
      assert length(graph.nodes) == 2
      assert length(graph.edges) == 1

      edge = List.first(graph.edges)
      assert edge.from == "lead-agent"
      assert edge.to == "worker-agent"
      assert edge.active? == true
      assert edge.canonical_state == :running
    end

    test "handles empty and corrupt inputs gracefully" do
      assert SwarmCanvas.build_graph_from_projection(nil) == %{nodes: [], edges: []}
      assert SwarmCanvas.build_graph_from_agents([]) == %{nodes: [], edges: []}

      html =
        render_component(&SwarmCanvas.swarm_canvas/1,
          id: "empty-canvas",
          nodes: [],
          edges: [],
          zoom_level: 1.0,
          pan_offset: %{x: 0, y: 0}
        )

      assert html =~ "empty-canvas"
      assert html =~ "No Active Swarm Topology"
    end
  end

  # ============================================================================
  # TIER 2: LIVEVIEW INTEGRATION TESTS
  # ============================================================================
  describe "Detached DagLive Integration" do
    test "detached DagLive mounts interactive canvas and handles pan, zoom, reset, and view toggling",
         %{conn: conn, session: session} do
      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}/detached/dag")

      assert has_element?(view, "#detached-dag-toolbar-title", "DAG topological map")
      assert html =~ "STEP INSPECTOR"
      assert has_element?(view, "#dag-view-toggle-canvas")
      assert has_element?(view, "#dag-view-toggle-stages")

      # 1. Test Zoom In event
      render_click(view, "canvas_zoom", %{"direction" => "in"})
      assert has_element?(view, "#detached-dag-canvas[data-zoom='1.15']")

      # 2. Test Zoom Out event
      render_click(view, "canvas_zoom", %{"direction" => "out"})
      assert has_element?(view, "#detached-dag-canvas[data-zoom='1.0']")

      # 3. Test Direct Zoom Level event
      render_click(view, "canvas_zoom", %{"level" => "1.5"})
      assert has_element?(view, "#detached-dag-canvas[data-zoom='1.5']")

      # 4. Test Pan event
      render_click(view, "canvas_pan", %{"x" => 150.0, "y" => 80.0})
      assert has_element?(view, "#detached-dag-canvas[data-pan-x='150.0'][data-pan-y='80.0']")

      # 5. Test Reset event
      render_click(view, "canvas_reset")

      assert has_element?(
               view,
               "#detached-dag-canvas[data-zoom='1.0'][data-pan-x='0.0'][data-pan-y='0.0']"
             )

      # 6. Test Toggle View Mode between Canvas and Stages
      render_click(view, "toggle_dag_view", %{"mode" => "stages"})
      assert has_element?(view, "#dag-execution-projection")

      render_click(view, "toggle_dag_view", %{"mode" => "canvas"})
      assert has_element?(view, "#detached-dag-canvas")
    end
  end

  describe "WorkspaceLive Swarm Tab Integration" do
    test "WorkspaceLive Swarm tab mounts canvas and handles pan and zoom events",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Switch to Swarm tab
      render_click(view, "switch_tab", %{"tab" => "swarm"})

      assert has_element?(view, "#workspace-swarm-canvas-section")
      assert has_element?(view, "#workspace-swarm-canvas")

      # 1. Trigger Canvas Zoom In
      render_click(view, "canvas_zoom", %{"direction" => "in"})
      assert has_element?(view, "#workspace-swarm-canvas[data-zoom='1.15']")

      # 2. Trigger Canvas Pan
      render_click(view, "canvas_pan", %{"x" => 60.0, "y" => 40.0})
      assert has_element?(view, "#workspace-swarm-canvas[data-pan-x='60.0'][data-pan-y='40.0']")

      # 3. Trigger Canvas Reset
      render_click(view, "canvas_reset")

      assert has_element?(
               view,
               "#workspace-swarm-canvas[data-zoom='1.0'][data-pan-x='0.0'][data-pan-y='0.0']"
             )
    end
  end
end
