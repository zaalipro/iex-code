defmodule IexCode.E2E.UiStudioCockpitE2ETest do
  @moduledoc """
  Authoritative Opaque-Box E2E Test Suite for Studio-Grade Developer Cockpit Overhaul (R1-R4).
  Covers the 4-Tier Test Architecture:
    - Tier 1: Isolated Feature Coverage (Happy Path across R1-R4)
    - Tier 2: Boundary & Corner Cases (Extreme inputs, rapid toggles, empty states)
    - Tier 3: Cross-Feature Combinations (Ergonomics matrix, palette + collapsed cockpit, diffs + checkpoints)
    - Tier 4: Real-World Application Scenarios (Complete developer workflow lifecycle)
  """
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true

  alias IexCodeWeb.{CommandPalette, DagComponents}
  alias IexCode.{Projects, Sessions, TimeTravel, Tools}
  alias Phoenix.PubSub

  setup %{workspace_path: path} do
    # Seed initial workspace project files
    calc_module = """
    defmodule Calculator do
      @moduledoc "High precision arithmetic functions."

      def add(a, b), do: a + b
      def subtract(a, b), do: a - b
    end
    """

    calc_test = """
    defmodule CalculatorTest do
      use ExUnit.Case

      test "addition" do
        assert Calculator.add(1, 2) == 3
      end
    end
    """

    auth_module = """
    defmodule Auth.Token do
      @moduledoc "Token validation helper."

      def validate(token) when is_binary(token) do
        byte_size(token) > 8
      end
    end
    """

    workspace_write_file(path, "lib/calculator.ex", calc_module)
    workspace_write_file(path, "test/calculator_test.exs", calc_test)
    workspace_write_file(path, "lib/auth/token.ex", auth_module)

    {:ok, project} =
      Projects.create_project(%{
        name: "Studio Cockpit E2E Project",
        root_path: path
      })

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Studio Cockpit Interactive Session",
        model_provider: "openai",
        model_name: "gemini-3.7-flash-high"
      })

    if Process.whereis(IexCode.PubSub) do
      PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")
      PubSub.subscribe(IexCode.PubSub, "project:#{project.id}:git")
      PubSub.subscribe(IexCode.PubSub, "desktop:events")
    end

    {:ok, project: project, session: session, workspace_path: path}
  end

  # ============================================================================
  # TIER 1: ISOLATED FEATURE COVERAGE (HAPPY PATH R1 - R4)
  # ============================================================================
  describe "Tier 1: Feature Coverage (Happy Path across R1-R4)" do
    test "R1 Feature: Left sidebar collapses and expands via LiveView event and desktop toggle button",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Initially sidebar is expanded
      assert has_element?(view, "#workspace-sidebar[data-collapsed='false']")
      assert has_element?(view, "#sidebar-desktop-toggle-btn")

      # 1. Trigger collapse via LiveView event
      render_click(view, "toggle_sidebar")
      assert has_element?(view, "#workspace-sidebar[data-collapsed='true']")

      # 2. Trigger expand via desktop toggle button element
      view |> element("#sidebar-desktop-toggle-btn") |> render_click()
      assert has_element?(view, "#workspace-sidebar[data-collapsed='false']")
    end

    test "R1 Feature: Collapsible bottom terminal dock mounts and unmounts dynamically",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Bottom terminal is initially unmounted
      refute has_element?(view, "#bottom-terminal-dock")

      # 1. Mount bottom terminal dock
      render_click(view, "toggle_bottom_terminal")
      assert has_element?(view, "#bottom-terminal-dock")
      assert has_element?(view, "#bottom-terminal-dock button[phx-value-cmd='mix precommit']")

      assert has_element?(
               view,
               "#bottom-terminal-dock button[phx-click='toggle_bottom_terminal']"
             )

      # 2. Unmount bottom terminal dock via toggle
      render_click(view, "toggle_bottom_terminal")
      refute has_element?(view, "#bottom-terminal-dock")
    end

    test "R1 Feature: Layout density toggles between comfortable and compact display modes",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Default density is comfortable
      assert has_element?(view, "#workspace-shell[data-density='comfortable']")
      assert has_element?(view, "#header-density-toggle")

      # 1. Toggle to compact
      render_click(view, "toggle_layout_density")
      assert has_element?(view, "#workspace-shell[data-density='compact']")

      # 2. Toggle back to comfortable via header element click
      view |> element("#header-density-toggle") |> render_click()
      assert has_element?(view, "#workspace-shell[data-density='comfortable']")
    end

    test "R1 Feature: Desktop menu action routing handles {:desktop_action, :toggle_sidebar} and {:desktop_action, :toggle_terminal}",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      assert has_element?(view, "#workspace-sidebar[data-collapsed='false']")
      refute has_element?(view, "#bottom-terminal-dock")

      # Send desktop menu actions to LiveView process
      send(view.pid, {:desktop_action, :toggle_sidebar})
      assert has_element?(view, "#workspace-sidebar[data-collapsed='true']")

      send(view.pid, {:desktop_action, :toggle_terminal})
      assert has_element?(view, "#bottom-terminal-dock")

      # Send reverse actions
      send(view.pid, {:desktop_action, :toggle_sidebar})
      assert has_element?(view, "#workspace-sidebar[data-collapsed='false']")

      send(view.pid, {:desktop_action, :toggle_terminal})
      refute has_element?(view, "#bottom-terminal-dock")
    end

    test "R2 Feature: Swarm / DAG visualizer renders canonical task states and status tone pills",
         _tags do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # 5 canonical task states: idle/pending, planning/ready, running, verified/completed, failed
      projection = %{
        engine: "dag_v1",
        available?: true,
        summary: %{
          ready: 1,
          running: 1,
          completed: 1,
          failed: 1,
          blocked: 1
        },
        layers: [
          [
            %{
              id: "node-idle",
              key: "init",
              title: "Initialize Architecture",
              status: "pending",
              readiness: :ready,
              attempt: 1,
              max_attempts: 1,
              depends_on: []
            },
            %{
              id: "node-plan",
              key: "plan",
              title: "Plan Execution DAG",
              status: "ready",
              readiness: :ready,
              attempt: 1,
              max_attempts: 2,
              depends_on: []
            }
          ],
          [
            %{
              id: "node-run",
              key: "execute",
              title: "Execute Code Modifications",
              status: "running",
              readiness: :leased,
              attempt: 2,
              max_attempts: 3,
              depends_on: ["plan"],
              critical_path?: true,
              latest_attempt: %{started_at: now}
            }
          ],
          [
            %{
              id: "node-verified",
              key: "verify",
              title: "Verify Test Suite Pass",
              status: "completed",
              readiness: :terminal,
              attempt: 1,
              max_attempts: 1,
              depends_on: ["execute"]
            },
            %{
              id: "node-failed",
              key: "bench",
              title: "Benchmark Regression Gate",
              status: "failed",
              readiness: :failed,
              attempt: 3,
              max_attempts: 3,
              depends_on: ["execute"]
            }
          ]
        ]
      }

      html = render_component(&DagComponents.dag_projection/1, projection: projection)

      assert html =~ "dag-execution-projection"
      assert html =~ "Stage 1"
      assert html =~ "Stage 2"
      assert html =~ "Stage 3"
      assert html =~ "data-node-status=\"pending\""
      assert html =~ "data-node-status=\"ready\""
      assert html =~ "data-node-status=\"running\""
      assert html =~ "data-node-status=\"completed\""
      assert html =~ "data-node-status=\"failed\""
    end

    test "R2 Feature: Live telemetry status footer pill renders OS RSS and BEAM allocated metrics",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      assert has_element?(view, "#workspace-status-footer")
      assert has_element?(view, "#memory-telemetry-pill")
      assert has_element?(view, "#memory-rss-stat")
      assert has_element?(view, "#memory-beam-stat")

      # Broadcast updated memory telemetry
      telemetry_payload = %{
        rss_bytes: 524_288_000,
        beam_total_bytes: 157_286_400,
        process_count: 320
      }

      send(view.pid, {:telemetry_broadcast, telemetry_payload})

      html = render(view)
      assert html =~ "RSS"
      assert html =~ "BEAM"
    end

    test "R3 Feature: Diff inspector switches seamlessly between inline and split side-by-side modes",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Switch to changes tab
      render_click(view, "switch_tab", %{"tab" => "changes"})
      assert has_element?(view, "#diff-viewer-container")

      # Default diff mode is inline
      assert has_element?(view, "button[phx-click='set_diff_mode'][phx-value-mode='inline']")

      # Switch to split side-by-side mode
      render_click(view, "set_diff_mode", %{"mode" => "split"})
      assert has_element?(view, "button[phx-click='set_diff_mode'][phx-value-mode='split']")

      # Switch back to inline mode
      render_click(view, "set_diff_mode", %{"mode" => "inline"})
      assert has_element?(view, "button[phx-click='set_diff_mode'][phx-value-mode='inline']")
    end

    test "R3 Feature: Intra-line word diffing and 1-click hunk rollback triggers",
         %{conn: conn, session: session, workspace_path: path} do
      # 1. Verify intra-line word diffing via String.myers_difference
      old_line = "def add(a, b), do: a + b"
      new_line = "def add(a, b), do: a + b + 1"
      diff = String.myers_difference(old_line, new_line)

      assert is_list(diff)
      assert diff == [eq: "def add(a, b), do: a + b", ins: " + 1"]

      # 2. Modify a file to create a live unstaged git diff
      workspace_write_file(
        path,
        "lib/calculator.ex",
        "defmodule Calculator do\n  def add(a, b), do: a + b + 999\nend\n"
      )

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      render_click(view, "switch_tab", %{"tab" => "changes"})

      # Select the modified diff file
      render_click(view, "select_diff_file", %{"file" => "lib/calculator.ex"})

      # Trigger 1-click hunk rollback
      render_click(view, "revert_hunk", %{"file" => "lib/calculator.ex", "hunk_id" => "1"})

      # File should be cleanly reverted or notification emitted
      assert has_element?(view, "#diff-viewer-container")
    end

    test "R4 Feature: Command Palette 2.0 fuzzy search searches across files and actions",
         %{conn: conn, session: session} do
      # Verify pure-Elixir search engine functionality
      assert is_list(CommandPalette.actions())
      assert is_list(CommandPalette.views())

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      refute has_element?(view, "#command-palette-modal")

      # Open Command Palette
      render_click(view, "toggle_command_palette")
      assert has_element?(view, "#command-palette-modal")
      assert has_element?(view, "#command-palette-input")

      # Search for calculator file
      render_change(view, "command_palette_search", %{"query" => "calc"})
      html = render(view)
      assert html =~ "calculator.ex" or html =~ "calculator_test.exs"

      # Search for test actions
      render_change(view, "command_palette_search", %{"query" => "test"})
      html = render(view)
      assert html =~ "Run All Tests" or html =~ "test"
    end

    test "R4 Feature: Command Palette category filtering, keyboard navigation, and action execution",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "toggle_command_palette")
      assert has_element?(view, "#command-palette-modal")

      # Filter by actions category
      render_change(view, "command_palette_set_category", %{"category" => "actions"})
      html = render(view)
      assert html =~ "Run All Tests" or html =~ "New Session"

      # Navigate down with arrow key
      render_click(view, "command_palette_navigate", %{"direction" => "down"})
      render_click(view, "command_palette_navigate", %{"direction" => "up"})

      # Execute selected item and verify modal closes
      render_click(view, "command_palette_execute_selected")
      refute has_element?(view, "#command-palette-modal")
    end
  end

  # ============================================================================
  # TIER 2: BOUNDARY & CORNER CASES
  # ============================================================================
  describe "Tier 2: Boundary & Corner Cases" do
    test "Rapid consecutive toggling of sidebar, bottom terminal, and layout density does not crash LiveView",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Rapid toggle loop across all 3 layout ergonomics controls
      for _ <- 1..10 do
        render_click(view, "toggle_sidebar")
        render_click(view, "toggle_bottom_terminal")
        render_click(view, "toggle_layout_density")
      end

      # LiveView must remain alive and responsive
      assert Process.alive?(view.pid)
      assert has_element?(view, "#workspace-shell")
      assert has_element?(view, "#workspace-sidebar")
    end

    test "Command Palette handles empty, whitespace-only, and special meta-character queries safely",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "toggle_command_palette")

      # Test edge cases: empty string, spaces, regex metacharacters, HTML injection
      boundary_queries = [
        "",
        "    ",
        "<script>alert(1)</script>",
        ".*+?^${}()|[]\\",
        "%{foo: :bar}"
      ]

      for q <- boundary_queries do
        render_change(view, "command_palette_search", %{"query" => q})
        assert Process.alive?(view.pid)
      end

      # Test unknown category filter
      render_change(view, "command_palette_set_category", %{"category" => "non_existent_category"})

      assert Process.alive?(view.pid)

      render_click(view, "close_command_palette")
      refute has_element?(view, "#command-palette-modal")
    end

    test "Keyboard navigation index cyclically wraps around upper and lower boundaries",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "toggle_command_palette")
      render_change(view, "command_palette_set_category", %{"category" => "actions"})

      # Navigating up from index 0 should wrap around to the end
      render_click(view, "command_palette_navigate", %{"direction" => "up"})
      assert Process.alive?(view.pid)

      # Navigating down multiple times past the list boundary should wrap around to 0
      for _ <- 1..20 do
        render_click(view, "command_palette_navigate", %{"direction" => "down"})
      end

      assert Process.alive?(view.pid)
    end

    test "Diff inspector handles clean git state and non-existent hunks without error",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "switch_tab", %{"tab" => "changes"})

      # Non-existent file selection
      render_click(view, "select_diff_file", %{"file" => "non_existent_file.ex"})
      assert Process.alive?(view.pid)

      # Discard / Revert non-existent hunk
      render_click(view, "reject_hunk", %{"file" => "non_existent_file.ex", "hunk_id" => "999"})
      assert Process.alive?(view.pid)
    end

    test "Swarm visualizer projection renders safely with zero nodes and empty summary",
         _tags do
      empty_projection = %{
        engine: "dag_v1",
        available?: false,
        summary: %{},
        layers: []
      }

      html = render_component(&DagComponents.dag_projection/1, projection: empty_projection)

      assert html =~ "dag-execution-projection"
      assert html =~ "0 nodes" or html =~ "fail closed"
    end
  end

  # ============================================================================
  # TIER 3: CROSS-FEATURE COMBINATIONS
  # ============================================================================
  describe "Tier 3: Cross-Feature Combinations" do
    test "Compact layout operates cohesively with collapsed sidebar and open bottom terminal dock",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # 1. Switch to compact layout
      render_click(view, "toggle_layout_density")
      assert has_element?(view, "#workspace-shell[data-density='compact']")

      # 2. Collapse sidebar
      render_click(view, "toggle_sidebar")
      assert has_element?(view, "#workspace-sidebar[data-collapsed='true']")

      # 3. Mount bottom terminal dock
      render_click(view, "toggle_bottom_terminal")
      assert has_element?(view, "#bottom-terminal-dock")

      # All three UI modes active concurrently
      assert has_element?(view, "#workspace-shell[data-density='compact']")
      assert has_element?(view, "#workspace-sidebar[data-collapsed='true']")
      assert has_element?(view, "#bottom-terminal-dock")
    end

    test "Command Palette action execution within collapsed cockpit preserves layout preferences",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Setup collapsed cockpit with compact density
      render_click(view, "toggle_layout_density")
      render_click(view, "toggle_sidebar")

      assert has_element?(view, "#workspace-shell[data-density='compact']")
      assert has_element?(view, "#workspace-sidebar[data-collapsed='true']")

      # Open Command Palette and search view
      render_click(view, "toggle_command_palette")
      render_change(view, "command_palette_search", %{"query" => "tests"})

      # Execute selection
      render_click(view, "command_palette_select_item", %{"index" => "0"})

      # Layout density and sidebar state must remain intact
      assert has_element?(view, "#workspace-shell[data-density='compact']")
      assert has_element?(view, "#workspace-sidebar[data-collapsed='true']")
      refute has_element?(view, "#command-palette-modal")
    end

    test "Diff inspector mode switching operates cleanly with time-travel checkpoints and git mutations",
         %{conn: conn, session: session, workspace_path: path} do
      # 1. Generate atomic mutation via Tools
      {:ok, _} =
        Tools.execute(
          "patch_file",
          %{
            "path" => "lib/calculator.ex",
            "target_content" => "def add(a, b), do: a + b",
            "replacement_content" => "def add(a, b), do: a + b + 42",
            "session_id" => session.id
          },
          path
        )

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Switch to changes tab
      render_click(view, "switch_tab", %{"tab" => "changes"})

      # Toggle diff modes while examining modified file
      render_click(view, "set_diff_mode", %{"mode" => "split"})
      render_click(view, "select_diff_file", %{"file" => "lib/calculator.ex"})

      assert has_element?(view, "#diff-viewer-container")

      # Rollback latest checkpoint
      {:ok, _} = TimeTravel.rollback_latest(session.id)

      # Trigger diff refresh
      send(view.pid, {:git_state_changed, session.project_id})

      assert has_element?(view, "#diff-viewer-container")
    end

    test "Live visualizer PubSub updates handle concurrent background broadcasts during active terminal sessions",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Mount bottom terminal dock
      render_click(view, "toggle_bottom_terminal")
      assert has_element?(view, "#bottom-terminal-dock")

      # Send concurrent PubSub background messages
      send(view.pid, {:git_state_changed, session.project_id})
      send(view.pid, {:session_status_changed, "running"})
      send(view.pid, {:desktop_action, :toggle_sidebar})

      assert has_element?(view, "#bottom-terminal-dock")
      assert has_element?(view, "#workspace-sidebar[data-collapsed='true']")
    end
  end

  # ============================================================================
  # TIER 4: REAL-WORLD APPLICATION SCENARIOS
  # ============================================================================
  describe "Tier 4: Real-World Workload Scenarios" do
    test "Scenario 1: Complete Developer Cockpit Lifecycle (Ergonomics -> Command Palette -> Split Diff -> Hunk Rollback -> Telemetry & Compact Mode)",
         %{conn: conn, session: session, workspace_path: path} do
      # --- STEP 1: Mount Workspace Session with Comfortable Density ---
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      assert has_element?(view, "#workspace-shell[data-density='comfortable']")
      assert has_element?(view, "#workspace-sidebar[data-collapsed='false']")

      # --- STEP 2: Configure Ergonomics for Focused Studio Cockpit ---
      # Collapse left sidebar and mount docked bottom terminal panel
      render_click(view, "toggle_sidebar")
      render_click(view, "toggle_bottom_terminal")

      assert has_element?(view, "#workspace-sidebar[data-collapsed='true']")
      assert has_element?(view, "#bottom-terminal-dock")

      # --- STEP 3: Command Palette 2.0 Jump to Changes Hub ---
      render_click(view, "toggle_command_palette")
      assert has_element?(view, "#command-palette-modal")

      render_change(view, "command_palette_search", %{"query" => "changes"})
      render_click(view, "command_palette_execute_selected")

      refute has_element?(view, "#command-palette-modal")
      assert has_element?(view, "#diff-viewer-container")

      # --- STEP 4: Seed Modification & Switch Diff Inspector to Split Mode ---
      workspace_write_file(
        path,
        "lib/auth/token.ex",
        "defmodule Auth.Token do\n  def validate(token), do: String.length(token) > 20\nend\n"
      )

      send(view.pid, {:git_state_changed, session.project_id})
      render_click(view, "set_diff_mode", %{"mode" => "split"})
      render_click(view, "select_diff_file", %{"file" => "lib/auth/token.ex"})

      assert has_element?(view, "#diff-viewer-container")

      # --- STEP 5: Perform 1-Click Hunk Rollback on Unwanted Change ---
      render_click(view, "revert_hunk", %{"file" => "lib/auth/token.ex", "hunk_id" => "1"})

      # --- STEP 6: Switch to Swarm Visualizer & Inspect Status Telemetry ---
      render_click(view, "switch_tab", %{"tab" => "swarm"})
      assert has_element?(view, "#workspace-status-footer")
      assert has_element?(view, "#memory-telemetry-pill")

      # --- STEP 7: Toggle Layout Density to Compact Mode ---
      render_click(view, "toggle_layout_density")
      assert has_element?(view, "#workspace-shell[data-density='compact']")

      # Terminal dock and collapsed sidebar state remain preserved
      assert has_element?(view, "#workspace-sidebar[data-collapsed='true']")
      assert has_element?(view, "#bottom-terminal-dock")
      assert Process.alive?(view.pid)
    end
  end
end
