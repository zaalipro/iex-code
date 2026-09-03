defmodule IexCodeWeb.Components.SwarmCanvasAdversarialTest do
  @moduledoc """
  Adversarial Stress Test Suite for SwarmCanvas component (Milestone 2 - Requirement R2).

  Empirically tests and probes:
  1. Empty graphs (0 nodes, nil/empty layers, empty agents)
  2. Single node without edges (boundary layout and rendering)
  3. Large dense graphs (50+ nodes with 300+ dense cross-dependencies)
  4. Cyclic dependencies, self-dependencies, dangling/invalid dependency IDs, cyclic agent hierarchies
  5. Unknown and unexpected task states (safe fallback to :idle across atoms, strings, numbers, structures)
  6. Extreme zoom values (negative, 0.0, 100.0, non-numeric) bounds enforcement in component and LiveViews
  7. Extreme pan values, malformed coordinate structures, and boundary telemetry metrics
  """
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true

  import Phoenix.LiveViewTest
  alias IexCodeWeb.Components.SwarmCanvas
  alias IexCode.{Projects, Sessions}

  # ============================================================================
  # 1. EMPTY GRAPH (0 NODES)
  # ============================================================================
  describe "1. Empty Graph Stress Testing" do
    test "build_graph_from_projection gracefully handles nil, empty map, empty layers, and malformed layers" do
      assert SwarmCanvas.build_graph_from_projection(nil) == %{nodes: [], edges: []}
      assert SwarmCanvas.build_graph_from_projection(%{}) == %{nodes: [], edges: []}
      assert SwarmCanvas.build_graph_from_projection(%{layers: []}) == %{nodes: [], edges: []}
      assert SwarmCanvas.build_graph_from_projection(%{layers: nil}) == %{nodes: [], edges: []}

      assert SwarmCanvas.build_graph_from_projection(%{layers: "not_a_list"}) == %{
               nodes: [],
               edges: []
             }

      assert SwarmCanvas.build_graph_from_projection(:not_even_a_map) == %{nodes: [], edges: []}
    end

    test "build_graph_from_agents(nil) returns empty graph via fallback clause" do
      assert SwarmCanvas.build_graph_from_agents([]) == %{nodes: [], edges: []}
      assert SwarmCanvas.build_graph_from_agents(nil) == %{nodes: [], edges: []}
      assert SwarmCanvas.build_graph_from_agents(:invalid) == %{nodes: [], edges: []}
    end

    test "renders empty canvas with backdrop placeholder, 0 nodes indicator, and no crash" do
      html =
        render_component(&SwarmCanvas.swarm_canvas/1,
          id: "empty-adversarial-canvas",
          nodes: [],
          edges: [],
          zoom_level: 1.0,
          pan_offset: %{x: 0, y: 0}
        )

      document = LazyHTML.from_fragment(html)

      assert LazyHTML.query(document, "#empty-adversarial-canvas")
      assert LazyHTML.query(document, "#empty-adversarial-canvas-empty")
      assert html =~ "No Active Swarm Topology"
      assert html =~ "0 nodes"
      assert html =~ "0 edges"

      assert LazyHTML.query(document, "#swarm-canvas-viewport")
      assert LazyHTML.query(document, "#swarm-canvas-edges")
      assert LazyHTML.query(document, "#swarm-canvas-nodes")
      refute html =~ "<foreignObject"
      refute html =~ "id=\"swarm-edge-"
    end
  end

  # ============================================================================
  # 2. SINGLE NODE WITHOUT EDGES
  # ============================================================================
  describe "2. Single Node Without Edges" do
    test "build_graph_from_projection positions isolated node with default coordinates and empty edges" do
      projection = %{
        layers: [
          [
            %{
              id: "single-node",
              key: "solitary",
              title: "Solitary Step",
              status: "idle",
              depends_on: []
            }
          ]
        ]
      }

      graph = SwarmCanvas.build_graph_from_projection(projection)
      assert length(graph.nodes) == 1
      assert graph.edges == []

      [node] = graph.nodes
      assert node.id == "single-node"
      assert node.key == "solitary"
      assert node.x == 60
      assert node.y == 60
      assert node.canonical_state == :idle
      assert node.dependencies == []
    end

    test "build_graph_from_projection handles node with nil depends_on" do
      projection = %{
        layers: [
          [
            %{
              id: "nil-dep-node",
              key: "nil_dep",
              title: "Nil Dep",
              status: "ready",
              depends_on: nil
            }
          ]
        ]
      }

      graph = SwarmCanvas.build_graph_from_projection(projection)
      assert length(graph.nodes) == 1
      assert graph.edges == []
      [node] = graph.nodes
      assert node.dependencies == []
      assert node.canonical_state == :planning
    end

    test "build_graph_from_agents handles single root agent without parent" do
      agents = [
        %{
          id: "solo-agent",
          key: "solo",
          role: "coder",
          display_name: "Solo Agent",
          status: "running",
          parent_agent_id: nil
        }
      ]

      graph = SwarmCanvas.build_graph_from_agents(agents)
      assert length(graph.nodes) == 1
      assert graph.edges == []

      [node] = graph.nodes
      assert node.id == "solo-agent"
      assert node.x == 60
      assert node.y == 60
      assert node.canonical_state == :running
    end

    test "renders single isolated node correctly without showing empty state banner" do
      node = %{
        id: "iso-1",
        key: "iso_1",
        title: "Isolated Node",
        raw_status: "verified",
        canonical_state: :verified,
        x: 60,
        y: 60,
        width: 250,
        height: 115
      }

      html =
        render_component(&SwarmCanvas.swarm_canvas/1,
          id: "single-node-canvas",
          nodes: [node],
          edges: [],
          zoom_level: 1.0,
          pan_offset: %{x: 0, y: 0}
        )

      document = LazyHTML.from_fragment(html)

      # Empty state banner must NOT be in HTML
      refute html =~ "single-node-canvas-empty"
      assert LazyHTML.query(document, "#swarm-node-iso-1")
      assert html =~ "1 nodes"
      assert html =~ "0 edges"
      assert html =~ "VERIFIED"
    end
  end

  # ============================================================================
  # 3. LARGE GRAPHS (50+ NODES WITH DENSE CROSS-DEPENDENCIES)
  # ============================================================================
  describe "3. Large Graph Stress Testing (50+ Nodes)" do
    test "build_graph_from_projection handles 60 nodes and 324 dense cross-dependencies efficiently" do
      # 10 layers, 6 nodes per layer = 60 nodes.
      # Each node in layer L depends on all 6 nodes in layer L - 1.
      # Total edges = 9 layers * 6 * 6 = 324 edges.
      layers =
        for layer_idx <- 0..9 do
          for row_idx <- 0..5 do
            node_key = "node_L#{layer_idx}_R#{row_idx}"

            depends_on =
              if layer_idx == 0 do
                []
              else
                for prev_row <- 0..5, do: "node_L#{layer_idx - 1}_R#{prev_row}"
              end

            status =
              case rem(layer_idx + row_idx, 5) do
                0 -> "idle"
                1 -> "planning"
                2 -> "running"
                3 -> "verified"
                4 -> "failed"
              end

            %{
              id: node_key,
              key: node_key,
              title: "Task L#{layer_idx} R#{row_idx}",
              status: status,
              depends_on: depends_on,
              tokens_in: 500 * (layer_idx + 1),
              tokens_out: 250 * (row_idx + 1),
              memory_mb: 10.0 + layer_idx * 1.5
            }
          end
        end

      projection = %{engine: "dag_v1", layers: layers}

      {build_microsec, graph} =
        :timer.tc(fn ->
          SwarmCanvas.build_graph_from_projection(projection)
        end)

      # Graph building is fast (< 50ms)
      assert build_microsec < 50_000,
             "Graph building took #{build_microsec / 1000}ms, expected < 50ms"

      assert length(graph.nodes) == 60
      assert length(graph.edges) == 324

      # Verify topological placement
      for node <- graph.nodes do
        assert node.x >= 60
        assert node.y >= 60
        assert node.width == 250
        assert node.height == 115
        assert is_binary(node.telemetry.tokens_label)
        assert is_binary(node.telemetry.memory_label)
      end

      # Verify that no coordinates format in scientific notation (e.g. "2.9e3")
      sci_notation_edges = Enum.filter(graph.edges, &(&1.d =~ ~r/\d+\.\d+e\d+/))

      assert Enum.empty?(sci_notation_edges),
             "Expected no scientific notation in SVG coordinates"

      for edge <- graph.edges do
        assert edge.d =~ ~r/^M \d+ \d+ C/
        assert edge.canonical_state in [:idle, :planning, :running, :verified, :failed]
      end

      # Render the complete large graph into the component and verify execution completes without timeout
      {render_microsec, html} =
        :timer.tc(fn ->
          render_component(&SwarmCanvas.swarm_canvas/1,
            id: "massive-swarm-canvas",
            nodes: graph.nodes,
            edges: graph.edges,
            zoom_level: 0.85,
            pan_offset: %{x: -120.0, y: -40.0}
          )
        end)

      assert render_microsec < 1_500_000, "Component render took #{render_microsec / 1000}ms"
      assert html =~ "60 nodes"
      assert html =~ "324 edges"
      assert html =~ "85%"
      assert html =~ "data-pan-x=\"-120.0\""
    end

    test "build_graph_from_agents handles a deep 56-agent hierarchical fleet" do
      lead = %{
        id: "fleet-lead",
        key: "lead",
        role: "orchestrator",
        display_name: "Fleet Orchestrator",
        status: "running",
        parent_agent_id: nil
      }

      team_leads =
        for i <- 1..5 do
          %{
            id: "team-lead-#{i}",
            key: "lead_#{i}",
            role: "lead",
            display_name: "Team Lead #{i}",
            status: "running",
            parent_agent_id: "fleet-lead"
          }
        end

      workers =
        for tl <- 1..5, w <- 1..10 do
          %{
            id: "worker-#{tl}-#{w}",
            key: "worker_#{tl}_#{w}",
            role: "worker",
            display_name: "Worker #{tl}-#{w}",
            status: if(rem(w, 2) == 0, do: "verified", else: "running"),
            parent_agent_id: "team-lead-#{tl}"
          }
        end

      agents = [lead | team_leads] ++ workers
      assert length(agents) == 56

      {time_micro, graph} =
        :timer.tc(fn ->
          SwarmCanvas.build_graph_from_agents(agents)
        end)

      assert time_micro < 30_000,
             "Agent graph building took #{time_micro / 1000}ms, expected < 30ms"

      assert length(graph.nodes) == 56
      assert length(graph.edges) == 55

      html =
        render_component(&SwarmCanvas.swarm_canvas/1,
          id: "fleet-canvas",
          nodes: graph.nodes,
          edges: graph.edges
        )

      assert html =~ "56 nodes"
      assert html =~ "55 edges"
    end
  end

  # ============================================================================
  # 4. CYCLES AND INVALID DEPENDENCY IDS
  # ============================================================================
  describe "4. Cyclic and Invalid Dependency Robustness" do
    test "projection with cyclic mutual dependencies terminates cleanly without infinite loop" do
      projection = %{
        layers: [
          [
            %{
              id: "step-a",
              key: "step_a",
              title: "Step A",
              status: "running",
              depends_on: ["step_b"]
            },
            %{
              id: "step-b",
              key: "step_b",
              title: "Step B",
              status: "planning",
              depends_on: ["step_a"]
            }
          ]
        ]
      }

      graph = SwarmCanvas.build_graph_from_projection(projection)
      assert length(graph.nodes) == 2
      assert length(graph.edges) == 2

      edge_ids = Enum.map(graph.edges, & &1.id)
      assert "step-b->step-a" in edge_ids
      assert "step-a->step-b" in edge_ids
    end

    test "projection with self-referential dependency builds valid Bézier loop without division by zero" do
      projection = %{
        layers: [
          [
            %{
              id: "self-loop",
              key: "loop",
              title: "Loop Step",
              status: "running",
              depends_on: ["loop"]
            }
          ]
        ]
      }

      graph = SwarmCanvas.build_graph_from_projection(projection)
      assert length(graph.nodes) == 1
      assert length(graph.edges) == 1

      [edge] = graph.edges
      assert edge.from == "self-loop"
      assert edge.to == "self-loop"
      assert edge.d =~ "M"
      assert edge.d =~ "C"
      refute edge.d =~ "NaN"
    end

    test "projection with dangling and invalid dependency IDs silently drops phantom edges" do
      projection = %{
        layers: [
          [
            %{
              id: "node-1",
              key: "valid_1",
              title: "Valid 1",
              status: "running",
              depends_on: ["phantom_1", "ghost_node", "non_existent_key", nil, 99999]
            }
          ]
        ]
      }

      graph = SwarmCanvas.build_graph_from_projection(projection)
      assert length(graph.nodes) == 1
      assert graph.edges == []
    end

    test "agent fleet with mutual parent cycle terminates recursion at depth guard" do
      agents = [
        %{
          id: "agent-a",
          key: "a",
          role: "lead",
          display_name: "Agent A",
          status: "running",
          parent_agent_id: "agent-b"
        },
        %{
          id: "agent-b",
          key: "b",
          role: "lead",
          display_name: "Agent B",
          status: "running",
          parent_agent_id: "agent-a"
        }
      ]

      graph = SwarmCanvas.build_graph_from_agents(agents)
      assert length(graph.nodes) == 2
      assert length(graph.edges) == 2
    end

    test "agent with self-parenting does not crash depth calculation" do
      agents = [
        %{
          id: "ouroboros",
          key: "ouroboros",
          role: "lead",
          display_name: "Self Parent",
          status: "idle",
          parent_agent_id: "ouroboros"
        }
      ]

      graph = SwarmCanvas.build_graph_from_agents(agents)
      assert length(graph.nodes) == 1
      assert length(graph.edges) == 1
    end

    test "agent with dangling parent ID is rendered as an isolated root node" do
      agents = [
        %{
          id: "orphan",
          key: "orphan",
          role: "coder",
          display_name: "Orphan Agent",
          status: "idle",
          parent_agent_id: "non-existent-parent-uuid-999"
        }
      ]

      graph = SwarmCanvas.build_graph_from_agents(agents)
      assert length(graph.nodes) == 1
      assert graph.edges == []
    end

    test "edge referencing missing node ID renders safely without BadBooleanError" do
      nodes = [
        %{id: "n-valid", key: "valid", title: "Valid", raw_status: "running", x: 10, y: 10}
      ]

      edges = [
        %{id: "ghost-edge-1", from: "ghost_from", to: "ghost_to"}
      ]

      html =
        render_component(&SwarmCanvas.swarm_canvas/1,
          id: "corrupt-edge-canvas",
          nodes: nodes,
          edges: edges
        )

      assert html =~ "corrupt-edge-canvas"
    end
  end

  # ============================================================================
  # 5. UNKNOWN/UNEXPECTED TASK STATES (SAFE FALLBACK TO :IDLE)
  # ============================================================================
  describe "5. Task State Normalization & Safe Fallback" do
    test "normalize_task_state maps known engine variants correctly" do
      for s <- ~w(running leased active executing in_progress) do
        assert SwarmCanvas.normalize_task_state(s) == :running
        assert SwarmCanvas.normalize_task_state(String.to_atom(s)) == :running
        assert SwarmCanvas.normalize_task_state(String.upcase(s)) == :running
      end

      for s <-
            ~w(planning ready scheduled waiting_dependencies approval waiting_approval triage queued pending_claim) do
        assert SwarmCanvas.normalize_task_state(s) == :planning
        assert SwarmCanvas.normalize_task_state(String.to_atom(s)) == :planning
      end

      for s <- ~w(completed verified done finished success terminal) do
        assert SwarmCanvas.normalize_task_state(s) == :verified
        assert SwarmCanvas.normalize_task_state(String.to_atom(s)) == :verified
      end

      for s <-
            ~w(failed dependency_failed error cancelled interrupted lease_expired rejected timeout) do
        assert SwarmCanvas.normalize_task_state(s) == :failed
        assert SwarmCanvas.normalize_task_state(String.to_atom(s)) == :failed
      end

      for s <- ~w(idle pending paused stopped waiting retry_backoff blocked) do
        assert SwarmCanvas.normalize_task_state(s) == :idle
        assert SwarmCanvas.normalize_task_state(String.to_atom(s)) == :idle
      end
    end

    test "normalize_task_state safely falls back to :idle for arbitrary, unknown, or corrupt inputs" do
      # Arbitrary atoms
      assert SwarmCanvas.normalize_task_state(:some_weird_unknown_state) == :idle
      assert SwarmCanvas.normalize_task_state(:super_custom_status) == :idle
      assert SwarmCanvas.normalize_task_state(:undefined) == :idle

      # Arbitrary strings without keyword substrings
      assert SwarmCanvas.normalize_task_state("arbitrary_custom_state") == :idle
      assert SwarmCanvas.normalize_task_state("gibberish12345") == :idle
      assert SwarmCanvas.normalize_task_state("") == :idle
      assert SwarmCanvas.normalize_task_state("   ") == :idle
      assert SwarmCanvas.normalize_task_state("???!!!###") == :idle

      # Verify words like "completely_unstarted" fall back to :idle, avoiding false positive :verified
      assert SwarmCanvas.normalize_task_state("completely_unstarted") == :idle
      assert SwarmCanvas.normalize_task_state("incompletely_planned") == :idle

      # Substring heuristic checks
      assert SwarmCanvas.normalize_task_state("system_error_encountered") == :failed
      assert SwarmCanvas.normalize_task_state("test_run_in_progress") == :running
      assert SwarmCanvas.normalize_task_state("preliminary_plan") == :planning

      # Non-string, non-atom types safely return :idle without raising
      assert SwarmCanvas.normalize_task_state(nil) == :idle
      assert SwarmCanvas.normalize_task_state(12345) == :idle
      assert SwarmCanvas.normalize_task_state(3.14159) == :idle
      assert SwarmCanvas.normalize_task_state(%{status: :running}) == :idle
      assert SwarmCanvas.normalize_task_state(["running"]) == :idle
      assert SwarmCanvas.normalize_task_state({:ok, :running}) == :idle
    end

    test "canonical_state_meta returns complete styling dictionary even for unrecognized state atom" do
      meta = SwarmCanvas.canonical_state_meta(:unrecognized_atom)
      assert meta.state == :idle
      assert meta.label == "IDLE"
      assert meta.border =~ "zinc"
      assert meta.icon == "hero-clock"
      assert meta.pulse? == false
    end

    test "nodes with unexpected task statuses render cleanly with IDLE badge and zinc border" do
      nodes = [
        %{id: "n-weird-1", key: "w1", title: "Weird 1", raw_status: "bizarre_engine_code_99"},
        %{id: "n-weird-2", key: "w2", title: "Weird 2", raw_status: nil},
        %{id: "n-weird-3", key: "w3", title: "Weird 3", raw_status: ""}
      ]

      html =
        render_component(&SwarmCanvas.swarm_canvas/1,
          id: "weird-states-canvas",
          nodes: nodes,
          edges: []
        )

      document = LazyHTML.from_fragment(html)

      assert LazyHTML.query(document, "#swarm-node-n-weird-1[data-canonical-state='idle']")
      assert LazyHTML.query(document, "#swarm-node-n-weird-2[data-canonical-state='idle']")
      assert LazyHTML.query(document, "#swarm-node-n-weird-3[data-canonical-state='idle']")
      assert html =~ "IDLE"
    end
  end

  # ============================================================================
  # 6. EXTREME ZOOM VALUES (NEGATIVE, 0.0, 100.0) — BOUNDS ENFORCEMENT
  # ============================================================================
  describe "6. Extreme Zoom Values & Bounds Enforcement" do
    test "component enforces zoom bounds [0.2, 3.0] across extreme float, integer, string, and invalid inputs" do
      # 1. Negative numbers -> clamped to 0.2
      html_neg =
        render_component(&SwarmCanvas.swarm_canvas/1,
          id: "zoom-neg",
          nodes: [],
          edges: [],
          zoom_level: -5.0
        )

      assert html_neg =~ "data-zoom=\"0.2\""
      assert html_neg =~ "scale(0.2)"
      assert html_neg =~ "20%"

      # 2. Zero -> clamped to 0.2
      html_zero =
        render_component(&SwarmCanvas.swarm_canvas/1,
          id: "zoom-zero",
          nodes: [],
          edges: [],
          zoom_level: 0.0
        )

      assert html_zero =~ "data-zoom=\"0.2\""
      assert html_zero =~ "scale(0.2)"
      assert html_zero =~ "20%"

      # Integer 0
      html_zero_int =
        render_component(&SwarmCanvas.swarm_canvas/1,
          id: "zoom-zero-int",
          nodes: [],
          edges: [],
          zoom_level: 0
        )

      assert html_zero_int =~ "data-zoom=\"0.2\""

      # 3. Huge positive numbers -> clamped to 3.0
      html_huge =
        render_component(&SwarmCanvas.swarm_canvas/1,
          id: "zoom-huge",
          nodes: [],
          edges: [],
          zoom_level: 100.0
        )

      assert html_huge =~ "data-zoom=\"3.0\""
      assert html_huge =~ "scale(3.0)"
      assert html_huge =~ "300%"

      # 4. String format with extreme values
      html_str_neg =
        render_component(&SwarmCanvas.swarm_canvas/1,
          id: "zoom-str-neg",
          nodes: [],
          edges: [],
          zoom_level: "-99.5"
        )

      assert html_str_neg =~ "data-zoom=\"0.2\""

      html_str_huge =
        render_component(&SwarmCanvas.swarm_canvas/1,
          id: "zoom-str-huge",
          nodes: [],
          edges: [],
          zoom_level: "999.9"
        )

      assert html_str_huge =~ "data-zoom=\"3.0\""

      # 5. Malformed string or non-numeric zoom -> fallback to default 1.0
      html_corrupt =
        render_component(&SwarmCanvas.swarm_canvas/1,
          id: "zoom-corrupt",
          nodes: [],
          edges: [],
          zoom_level: "not_a_float"
        )

      assert html_corrupt =~ "data-zoom=\"1.0\""
      assert html_corrupt =~ "100%"

      html_nil =
        render_component(&SwarmCanvas.swarm_canvas/1,
          id: "zoom-nil",
          nodes: [],
          edges: [],
          zoom_level: nil
        )

      assert html_nil =~ "data-zoom=\"1.0\""
    end

    test "WorkspaceLive canvas_zoom clamps extreme inputs and prevents underflow/overflow",
         %{conn: conn} do
      test_dir = "/tmp/wl_zoom_#{System.unique_integer([:positive])}"
      File.mkdir_p!(test_dir)

      {:ok, project} =
        Projects.create_project(%{
          name: "WL Zoom Test Project #{System.unique_integer()}",
          root_path: test_dir
        })

      {:ok, session} =
        Sessions.create_session(%{
          project_id: project.id,
          title: "WL Zoom Test Session",
          model_provider: "openai",
          model_name: "gemini-2.5-pro"
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      render_click(view, "switch_tab", %{"tab" => "swarm"})

      # Direct extreme negative zoom level event
      render_click(view, "canvas_zoom", %{"level" => "-10.0"})
      assert has_element?(view, "#workspace-swarm-canvas[data-zoom='0.2']")

      # Direct extreme zero zoom level event
      render_click(view, "canvas_zoom", %{"level" => "0.0"})
      assert has_element?(view, "#workspace-swarm-canvas[data-zoom='0.2']")

      # Direct extreme huge zoom level event
      render_click(view, "canvas_zoom", %{"level" => "100.0"})
      assert has_element?(view, "#workspace-swarm-canvas[data-zoom='3.0']")

      # Malformed non-numeric zoom level event (falls back to 0.0 -> clamped to 0.2)
      render_click(view, "canvas_zoom", %{"level" => "garbage_string"})
      assert has_element?(view, "#workspace-swarm-canvas[data-zoom='0.2']")

      # Test sequential zoom out underflow clamping
      for _ <- 1..30 do
        render_click(view, "canvas_zoom", %{"direction" => "out"})
      end

      assert has_element?(view, "#workspace-swarm-canvas[data-zoom='0.2']")

      # Test sequential zoom in overflow clamping
      for _ <- 1..30 do
        render_click(view, "canvas_zoom", %{"direction" => "in"})
      end

      assert has_element?(view, "#workspace-swarm-canvas[data-zoom='3.0']")
    end

    test "Detached DagLive canvas_zoom clamps extreme inputs and prevents underflow/overflow",
         %{conn: conn} do
      test_dir = "/tmp/det_zoom_#{System.unique_integer([:positive])}"
      File.mkdir_p!(test_dir)

      {:ok, project} =
        Projects.create_project(%{
          name: "Detached Zoom Test Project #{System.unique_integer()}",
          root_path: test_dir
        })

      {:ok, session} =
        Sessions.create_session(%{
          project_id: project.id,
          title: "Detached Zoom Test Session",
          model_provider: "openai",
          model_name: "gemini-2.5-pro"
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/detached/dag")

      # Direct extreme negative zoom level event
      render_click(view, "canvas_zoom", %{"level" => "-500.0"})
      assert has_element?(view, "#detached-dag-canvas[data-zoom='0.2']")

      # Direct 0.0 zoom level event
      render_click(view, "canvas_zoom", %{"level" => "0.0"})
      assert has_element?(view, "#detached-dag-canvas[data-zoom='0.2']")

      # Direct extreme huge zoom level event
      render_click(view, "canvas_zoom", %{"level" => "50.0"})
      assert has_element?(view, "#detached-dag-canvas[data-zoom='3.0']")

      # Sequential zoom out underflow clamping
      for _ <- 1..30 do
        render_click(view, "canvas_zoom", %{"direction" => "out"})
      end

      assert has_element?(view, "#detached-dag-canvas[data-zoom='0.2']")

      # Sequential zoom in overflow clamping
      for _ <- 1..30 do
        render_click(view, "canvas_zoom", %{"direction" => "in"})
      end

      assert has_element?(view, "#detached-dag-canvas[data-zoom='3.0']")
    end
  end

  # ============================================================================
  # 7. EXTREME PAN VALUES & TELEMETRY BOUNDARY CONDITIONS
  # ============================================================================
  describe "7. Pan Offsets and Telemetry Boundary Cases" do
    test "component safely normalizes extreme and heterogeneous pan offset formats" do
      # Negative and large map with atom keys
      html1 =
        render_component(&SwarmCanvas.swarm_canvas/1,
          id: "pan-canvas-1",
          nodes: [],
          edges: [],
          pan_offset: %{x: -4500.5, y: 8200.2}
        )

      assert html1 =~ "data-pan-x=\"-4500.5\""
      assert html1 =~ "data-pan-y=\"8200.2\""

      # String map keys
      html2 =
        render_component(&SwarmCanvas.swarm_canvas/1,
          id: "pan-canvas-2",
          nodes: [],
          edges: [],
          pan_offset: %{"x" => 120, "y" => -90}
        )

      assert html2 =~ "data-pan-x=\"120.0\""
      assert html2 =~ "data-pan-y=\"-90.0\""

      # Tuple format
      html3 =
        render_component(&SwarmCanvas.swarm_canvas/1,
          id: "pan-canvas-3",
          nodes: [],
          edges: [],
          pan_offset: {-33, 44}
        )

      assert html3 =~ "data-pan-x=\"-33.0\""
      assert html3 =~ "data-pan-y=\"44.0\""

      # Nil or corrupt pan offset -> fallback to 0.0, 0.0
      html4 =
        render_component(&SwarmCanvas.swarm_canvas/1,
          id: "pan-canvas-4",
          nodes: [],
          edges: [],
          pan_offset: "corrupt_pan"
        )

      assert html4 =~ "data-pan-x=\"0.0\""
      assert html4 =~ "data-pan-y=\"0.0\""
    end

    test "format_tokens and format_memory boundary values and scientific notation probe" do
      # Format tokens
      assert SwarmCanvas.format_tokens(nil) == "0 tok"
      assert SwarmCanvas.format_tokens(-100) == "0 tok"
      assert SwarmCanvas.format_tokens(0) == "0 tok"
      assert SwarmCanvas.format_tokens(999) == "999 tok"
      assert SwarmCanvas.format_tokens(1_000) == "1.0k tok"
      assert SwarmCanvas.format_tokens(1_249) == "1.2k tok"

      # Verify 999_999 formats as "1000.0k tok" without scientific notation
      tokens_999k = SwarmCanvas.format_tokens(999_999)
      assert tokens_999k == "1000.0k tok"
      refute tokens_999k =~ "e"

      assert SwarmCanvas.format_tokens(1_000_000) == "1.0M tok"
      assert SwarmCanvas.format_tokens(2_540_000) == "2.5M tok"
      assert SwarmCanvas.format_tokens(12.75) == "13 tok"
      assert SwarmCanvas.format_tokens(:invalid) == "0 tok"

      # Format memory
      assert SwarmCanvas.format_memory(nil) == "12.0 MB"
      assert SwarmCanvas.format_memory(-5.0) == "12.0 MB"
      assert SwarmCanvas.format_memory(0.0) == "0.0 MB"
      assert SwarmCanvas.format_memory(14.24) == "14.2 MB"
      assert SwarmCanvas.format_memory(14) == "14.0 MB"
      assert SwarmCanvas.format_memory(33_554_432) == "32.0 MB"
      assert SwarmCanvas.format_memory(:invalid) == "12.0 MB"
    end
  end
end
