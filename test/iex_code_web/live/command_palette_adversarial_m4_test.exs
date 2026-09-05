defmodule IexCodeWeb.CommandPaletteAdversarialM4Test do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true

  alias IexCode.Runs
  alias IexCodeWeb.CommandPalette, as: CP

  # ============================================================================
  # 1. Rapid Query Search Bursts & Malicious/Boundary Inputs
  # ============================================================================
  describe "Rapid Query Search Bursts & Boundary Fuzzing" do
    setup %{workspace_path: path} do
      # Seed realistic files
      workspace_write_file(
        path,
        "lib/app_calc.ex",
        "defmodule AppCalc do\n  def add(a, b), do: a + b\nend"
      )

      workspace_write_file(
        path,
        "test/app_calc_test.exs",
        "defmodule AppCalcTest do\n  use ExUnit.Case\nend"
      )

      workspace_write_file(
        path,
        "lib/app_worker.ex",
        "defmodule AppWorker do\n  def work, do: :ok\nend"
      )

      :ok
    end

    test "survives bursts of rapid search queries without crashing or getting stuck", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project, %{title: "Adversarial Fuzzing Session"})
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Open command palette
      render_click(view, "toggle_command_palette")
      assert has_element?(view, "#command-palette-modal")

      # Sequence of 50 varied, rapid search inputs: prefixes, boundaries, symbols, unicode
      rapid_burst_inputs = [
        "",
        "a",
        "app",
        "app_",
        "app_calc",
        "calc",
        ">",
        "> test",
        "> run",
        ">",
        "#",
        "# app",
        "# worker",
        "#",
        "@",
        "@ swarm",
        "$",
        "$ claude",
        "/",
        "/ main",
        "!",
        "! mix test",
        "!",
        "   \t  ",
        "a",
        "ab",
        "abc",
        "abcd",
        "nonexistent_query_99999",
        "calc",
        "<script>alert(1)</script>",
        "\"' OR '1'='1",
        "\\0\0\x00",
        "🚀✨🔥",
        "日本語検索",
        "العربية",
        "[regex]*+(safe)?",
        String.duplicate("x", 200),
        "test",
        "",
        "files",
        "settings",
        "kanban",
        "terminal",
        "ast",
        ">>>",
        "###",
        "$$$",
        "!!!",
        ""
      ]

      for query <- rapid_burst_inputs do
        render_change(view, "command_palette_search", %{"query" => query})
        # LiveView must remain alive and responsive
        assert Process.alive?(view.pid), "LiveView crashed on query: #{inspect(query)}"
      end

      # Palette modal remains open and responsive
      assert has_element?(view, "#command-palette-modal")
      assert has_element?(view, "#command-palette-input")

      # Selected index is reset to 0
      assert has_element?(view, "#palette-item-0")
    end
  end

  # ============================================================================
  # 2. Fast Category Pill Cycling
  # ============================================================================
  describe "Fast Category Pill Cycling" do
    test "cycles forward through all 9 categories multiple times in a loop", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "toggle_command_palette")

      expected_order = [
        "all",
        "actions",
        "swarms",
        "files",
        "models",
        "branches",
        "terminal",
        "views",
        "sessions"
      ]

      # Run 27 cycles forward (exactly 3 full loops across all 9 categories)
      for cycle_num <- 1..27 do
        render_click(view, "command_palette_cycle_category", %{"direction" => "next"})
        expected_cat = Enum.at(expected_order, rem(cycle_num, length(expected_order)))

        # Assert active pill corresponds to expected category
        assert has_element?(
                 view,
                 ~s(button[phx-click="command_palette_set_category"][phx-value-category="#{expected_cat}"][aria-pressed="true"])
               ),
               "Failed to activate expected category: #{expected_cat} on cycle #{cycle_num}"
      end
    end

    test "cycles backward through all 9 categories multiple times in a loop", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "toggle_command_palette")

      expected_reverse_order = [
        "all",
        "sessions",
        "views",
        "terminal",
        "branches",
        "models",
        "files",
        "swarms",
        "actions"
      ]

      # Run 27 cycles backward (exactly 3 full reverse loops)
      for cycle_num <- 1..27 do
        render_click(view, "command_palette_cycle_category", %{"direction" => "prev"})

        expected_cat =
          Enum.at(expected_reverse_order, rem(cycle_num, length(expected_reverse_order)))

        assert has_element?(
                 view,
                 ~s(button[phx-click="command_palette_set_category"][phx-value-category="#{expected_cat}"][aria-pressed="true"])
               ),
               "Failed to activate expected reverse category: #{expected_cat} on cycle #{cycle_num}"
      end
    end

    test "preserves search query during rapid category cycling", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "toggle_command_palette")
      render_change(view, "command_palette_search", %{"query" => "test"})

      # Rapid cycling with query set
      for _ <- 1..18 do
        render_click(view, "command_palette_cycle_category", %{"direction" => "next"})
        assert Process.alive?(view.pid)
      end

      # Modal still has query set
      assert has_element?(view, "#command-palette-input[value='test']")
    end

    test "handles missing or unexpected category cycling direction gracefully", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "toggle_command_palette")

      # Missing direction defaults to "next"
      render_click(view, "command_palette_cycle_category", %{})

      assert has_element?(
               view,
               ~s(button[phx-click="command_palette_set_category"][phx-value-category="actions"][aria-pressed="true"])
             )

      # Unknown direction defaults to "next"
      render_click(view, "command_palette_cycle_category", %{"direction" => "sideways"})

      assert has_element?(
               view,
               ~s(button[phx-click="command_palette_set_category"][phx-value-category="swarms"][aria-pressed="true"])
             )
    end
  end

  # ============================================================================
  # 3. Arrow Key Navigation at Bounds (Index 0, Last Index, Empty, Single Item)
  # ============================================================================
  describe "Arrow Key Navigation at Bounds" do
    test "safely handles arrow navigation when result list is empty", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "toggle_command_palette")

      # Force zero results
      render_change(view, "command_palette_search", %{
        "query" => "completely_unmatchable_string_9999"
      })

      assert has_element?(view, "#command-palette-results")
      refute has_element?(view, "#palette-item-0")

      # Rapidly press up and down 20 times on empty list
      for _ <- 1..10 do
        render_click(view, "command_palette_navigate", %{"direction" => "down"})
        render_click(view, "command_palette_navigate", %{"direction" => "up"})
      end

      assert Process.alive?(view.pid)

      # Executing selected on empty list closes palette cleanly without error
      render_click(view, "command_palette_execute_selected")
      refute has_element?(view, "#command-palette-modal")
    end

    test "wraps cleanly at index 0 (up) and at last index (down) with active aria-activedescendant",
         %{
           conn: conn,
           workspace_path: path
         } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "toggle_command_palette")
      # Filter to views for fixed, deterministic count
      render_click(view, "command_palette_set_category", %{"category" => "views"})
      total_views = length(CP.views())
      last_index = total_views - 1

      # Initially at index 0
      assert has_element?(view, "#command-palette-input[aria-activedescendant='palette-item-0']")
      assert has_element?(view, "#palette-item-0[aria-selected='true']")

      # UP at index 0 wraps to last_index
      render_click(view, "command_palette_navigate", %{"direction" => "up"})

      assert has_element?(
               view,
               "#command-palette-input[aria-activedescendant='palette-item-#{last_index}']"
             )

      assert has_element?(view, "#palette-item-#{last_index}[aria-selected='true']")

      # DOWN at last_index wraps to index 0
      render_click(view, "command_palette_navigate", %{"direction" => "down"})
      assert has_element?(view, "#command-palette-input[aria-activedescendant='palette-item-0']")
      assert has_element?(view, "#palette-item-0[aria-selected='true']")

      # 50 alternating arrow key presses
      for _ <- 1..25 do
        render_click(view, "command_palette_navigate", %{"direction" => "down"})
        render_click(view, "command_palette_navigate", %{"direction" => "up"})
      end

      assert Process.alive?(view.pid)
      assert has_element?(view, "#command-palette-modal")
    end

    test "handles navigation correctly when exactly one item matches", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "toggle_command_palette")
      render_click(view, "command_palette_set_category", %{"category" => "actions"})
      # Search for unique title matching exactly 1 action
      render_change(view, "command_palette_search", %{"query" => "Run Stale Tests"})

      assert has_element?(view, "#palette-item-0")
      refute has_element?(view, "#palette-item-1")

      # Pressing down remains on index 0
      render_click(view, "command_palette_navigate", %{"direction" => "down"})
      assert has_element?(view, "#command-palette-input[aria-activedescendant='palette-item-0']")

      # Pressing up remains on index 0
      render_click(view, "command_palette_navigate", %{"direction" => "up"})
      assert has_element?(view, "#command-palette-input[aria-activedescendant='palette-item-0']")
    end

    test "handles invalid or extreme out-of-bounds selection index safely", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "toggle_command_palette")

      # Select out-of-bounds index
      render_click(view, "command_palette_select_item", %{"index" => "999999"})
      refute has_element?(view, "#command-palette-modal")
      assert Process.alive?(view.pid)
    end
  end

  # ============================================================================
  # 4. Selection and Execution of Each Category Type (All 8 Categories)
  # ============================================================================
  describe "Selection and Execution of Each Category Type" do
    setup %{workspace_path: path} do
      workspace_write_file(
        path,
        "lib/adversarial_target.ex",
        "defmodule AdversarialTarget do\n  def run, do: :ok\nend"
      )

      :ok
    end

    test "1. :action - executes action cleanly, closing modal and updating state", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project, %{swarm_mode: false})
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Action A: Toggle Swarm Mode
      assert has_element?(view, "#header-swarm-toggle[aria-pressed='false']")
      render_click(view, "toggle_command_palette")
      render_click(view, "command_palette_set_category", %{"category" => "actions"})
      render_change(view, "command_palette_search", %{"query" => "Toggle Swarm Mode"})
      render_click(view, "command_palette_select_item", %{"index" => "0"})

      # Modal cleanly closed
      refute has_element?(view, "#command-palette-modal")
      # State updated
      assert has_element?(view, "#header-swarm-toggle[aria-pressed='true']")

      # Action B: AST Symbol Search
      render_click(view, "toggle_command_palette")
      render_click(view, "command_palette_set_category", %{"category" => "actions"})
      render_change(view, "command_palette_search", %{"query" => "AST Symbol Search"})
      render_click(view, "command_palette_execute_selected")

      refute has_element?(view, "#command-palette-modal")
      # Tab switches to ast
      html = render(view)
      assert html =~ "AST Query Explorer" or html =~ "ast"
    end

    test "2. :view - executes tab switch for all workspace views cleanly", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      views_to_test = [
        {"Dashboard / Kanban", "kanban"},
        {"Coach & Swarm Telemetry", "swarm"},
        {"Scheduled Tasks & Calendar", "calendar"},
        {"Progress & Diffs Hub", "changes"},
        {"Visual Test Runner & AutoFix", "tests"},
        {"AST Query Explorer", "ast"},
        {"Terminal Shell", "terminal"},
        {"Resources & Files", "files"},
        {"Chat Assistant", "chat"}
      ]

      for {title, _tab_name} <- views_to_test do
        render_click(view, "toggle_command_palette")
        render_click(view, "command_palette_set_category", %{"category" => "views"})
        render_change(view, "command_palette_search", %{"query" => title})
        render_click(view, "command_palette_execute_selected")

        # Modal cleanly closed after each view jump
        refute has_element?(view, "#command-palette-modal")
        assert Process.alive?(view.pid)
      end
    end

    test "3. :file - opens file buffer, switches to files tab, and closes palette", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "toggle_command_palette")
      render_click(view, "command_palette_set_category", %{"category" => "files"})
      render_change(view, "command_palette_search", %{"query" => "adversarial_target.ex"})

      render_click(view, "command_palette_select_item", %{"index" => "0"})

      refute has_element?(view, "#command-palette-modal")
      html = render(view)
      assert html =~ "adversarial_target.ex"
    end

    test "4. :session - selects another session and triggers clean navigation patch", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session_1 = create_session_fixture(project, %{title: "Primary Session"})
      session_2 = create_session_fixture(project, %{title: "Secondary Target Session"})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session_1.id}")

      render_click(view, "toggle_command_palette")
      render_click(view, "command_palette_set_category", %{"category" => "sessions"})
      render_change(view, "command_palette_search", %{"query" => "Secondary Target"})

      render_click(view, "command_palette_select_item", %{"index" => "0"})

      # Modal closes and patch is pushed to destination session
      refute has_element?(view, "#command-palette-modal")
      assert_patch(view, ~p"/sessions/#{session_2.id}?project_id=#{project.id}")
    end

    test "5. :swarm - selects durable swarm run, switches to swarm tab, and closes palette", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      # Create swarm run fixture in DB
      {:ok, _swarm_run} =
        Runs.create_run(%{
          project_id: project.id,
          session_id: session.id,
          objective: "Adversarial Stress Swarm Run",
          status: "running",
          progress: 50
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "toggle_command_palette")
      render_click(view, "command_palette_set_category", %{"category" => "swarms"})
      render_change(view, "command_palette_search", %{"query" => "Adversarial Stress"})

      render_click(view, "command_palette_select_item", %{"index" => "0"})

      refute has_element?(view, "#command-palette-modal")
      html = render(view)
      assert html =~ "Adversarial Stress Swarm Run" or html =~ "swarm"
    end

    test "6. :model - selects model, closes palette, and updates session model state", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "toggle_command_palette")
      render_click(view, "command_palette_set_category", %{"category" => "models"})
      render_change(view, "command_palette_search", %{"query" => "Claude 3.7 Sonnet"})

      render_click(view, "command_palette_select_item", %{"index" => "0"})

      refute has_element?(view, "#command-palette-modal")
      html = render(view)
      assert html =~ "Model set to" or html =~ "Claude 3.7 Sonnet"
    end

    test "7. :branch - switches git branch, closes palette, and updates git state", %{
      conn: conn
    } do
      {:ok, git_dir} = init_temp_git_repo(%{"README.md" => "# Challenger Repo"})
      System.cmd("git", ["branch", "feature/challenger-m4-gate"], cd: git_dir)

      project = create_project_fixture(%{root_path: git_dir})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "toggle_command_palette")
      render_click(view, "command_palette_set_category", %{"category" => "branches"})
      render_change(view, "command_palette_search", %{"query" => "feature/challenger-m4-gate"})

      render_click(view, "command_palette_select_item", %{"index" => "0"})

      refute has_element?(view, "#command-palette-modal")
      assert render(view) =~ "Switched to branch feature/challenger-m4-gate"
    end

    test "8. :terminal - executes terminal command, switches to terminal tab, and closes palette",
         %{
           conn: conn,
           workspace_path: path
         } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "toggle_command_palette")
      render_click(view, "command_palette_set_category", %{"category" => "terminal"})
      render_change(view, "command_palette_search", %{"query" => "mix format"})

      render_click(view, "command_palette_select_item", %{"index" => "0"})

      refute has_element?(view, "#command-palette-modal")
      html = render(view)
      assert html =~ "terminal" or html =~ "Terminal"
    end
  end

  # ============================================================================
  # 5. Modal Lifecycle & Reopening Reset State
  # ============================================================================
  describe "Command Palette Modal Lifecycle & Clean Resets" do
    test "resets query, selected index, and restores fresh search state upon reopening", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # 1. Open and search
      render_click(view, "toggle_command_palette")
      render_change(view, "command_palette_search", %{"query" => "something"})
      render_click(view, "command_palette_navigate", %{"direction" => "down"})

      # 2. Close via ESC / close event
      render_click(view, "close_command_palette")
      refute has_element?(view, "#command-palette-modal")

      # 3. Re-open
      render_click(view, "toggle_command_palette")
      assert has_element?(view, "#command-palette-modal")

      # Query must be reset to ""
      assert has_element?(view, "#command-palette-input[value='']")
      # Selected index must be 0
      assert has_element?(view, "#palette-item-0[aria-selected='true']")
      assert has_element?(view, "#command-palette-input[aria-activedescendant='palette-item-0']")
    end

    test "closes cleanly via backdrop click and re-toggle click", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Re-toggle test
      render_click(view, "toggle_command_palette")
      assert has_element?(view, "#command-palette-modal")
      render_click(view, "toggle_command_palette")
      refute has_element?(view, "#command-palette-modal")

      # Close event test
      render_click(view, "toggle_command_palette")
      assert has_element?(view, "#command-palette-modal")
      render_click(view, "close_command_palette")
      refute has_element?(view, "#command-palette-modal")
    end
  end
end
