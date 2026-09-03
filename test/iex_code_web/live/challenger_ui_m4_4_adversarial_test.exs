defmodule IexCodeWeb.Live.ChallengerUiM44AdversarialTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true

  describe "1. Prefix Switching & Malformed/Boundary Syntax Fuzzing" do
    setup %{workspace_path: path} do
      workspace_write_file(path, "lib/sample_core.ex", "defmodule SampleCore, do: :ok")
      workspace_write_file(path, "test/sample_core_test.exs", "defmodule SampleCoreTest, do: :ok")
      :ok
    end

    test "rapidly switches prefixes with empty, spaced, and boundary queries in LiveView", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "toggle_command_palette")
      assert has_element?(view, "#command-palette-modal")

      # Sequence of adversarial prefix transitions
      prefix_transitions = [
        # Bare prefixes
        ">",
        "@",
        "#",
        "$",
        "/",
        "!",
        # Prefixes with single space
        "> ",
        "@ ",
        "# ",
        "$ ",
        "/ ",
        "! ",
        # Prefixes with query
        "> run",
        "@ agent",
        "# sample",
        "$ claude",
        "/ feature",
        "! mix test",
        # Duplicate or multi-char prefixes
        ">>",
        "@@",
        "##",
        "$$",
        "//",
        "!!",
        ">>>",
        # Path-like queries starting with slash that should NOT be branches if they contain dots or segments
        "/Users/test/file.ex",
        "/a/b/c/d",
        # Malformed / dangerous terminal commands
        "! rm -rf /tmp/fake_dir",
        "! :(){ :|:& };:",
        # Unrecognized symbols
        "~",
        "%",
        "&",
        "?",
        "|"
      ]

      for query <- prefix_transitions do
        render_change(view, "command_palette_search", %{"query" => query})
        assert Process.alive?(view.pid), "LiveView crashed on query: #{inspect(query)}"
        assert has_element?(view, "#command-palette-modal")
      end
    end
  end

  describe "2. Rapid Selection Changes & Empty Results Boundary Handling" do
    test "handles rapid arrow navigation, negative/string indices, and empty executions", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "toggle_command_palette")

      # 1. Force completely empty result set
      render_change(view, "command_palette_search", %{
        "query" => "xyz_non_existent_unmatched_query_9999"
      })

      assert has_element?(view, "#command-palette-results")
      refute has_element?(view, "#palette-item-0")

      # 2. Rapid arrow navigation on empty result set
      for _ <- 1..30 do
        render_click(view, "command_palette_navigate", %{"direction" => "down"})
        render_click(view, "command_palette_navigate", %{"direction" => "up"})
      end

      assert Process.alive?(view.pid)

      # 3. Enter on empty results closes modal cleanly without raising
      render_click(view, "command_palette_execute_selected")
      refute has_element?(view, "#command-palette-modal")
      assert Process.alive?(view.pid)

      # 4. Reopen and test out-of-range selection
      render_click(view, "toggle_command_palette")
      assert has_element?(view, "#command-palette-modal")

      # Extreme indices
      render_click(view, "command_palette_select_item", %{"index" => "999999"})
      refute has_element?(view, "#command-palette-modal")
      assert Process.alive?(view.pid)
    end

    test "survives 100 rapid category cycling clicks in alternating directions", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "toggle_command_palette")

      for _ <- 1..50 do
        render_click(view, "command_palette_cycle_category", %{"direction" => "next"})
        render_click(view, "command_palette_cycle_category", %{"direction" => "prev"})
      end

      assert Process.alive?(view.pid)
      assert has_element?(view, "#command-palette-modal")
    end
  end

  describe "3. Full Action Execution & Window Detachment Dispatching" do
    setup %{workspace_path: path} do
      workspace_write_file(path, "lib/exec_test.ex", "defmodule ExecTest, do: :ok")
      :ok
    end

    test "dispatches window detachment actions (terminal, diff, dag) safely", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Note: Detaching windows in headless tests will invoke desktop windowing
      # or gracefully log if headless/unsupported without crashing the LiveView.
      detach_actions = [
        {"Detach Terminal Window", "detach_terminal"},
        {"Detach Diff Inspector", "detach_diff"},
        {"Detach Swarm Visualizer", "detach_dag"}
      ]

      for {title, _action_id} <- detach_actions do
        render_click(view, "toggle_command_palette")
        render_click(view, "command_palette_set_category", %{"category" => "actions"})
        render_change(view, "command_palette_search", %{"query" => title})

        # Execute
        render_click(view, "command_palette_execute_selected")
        refute has_element?(view, "#command-palette-modal")
        assert Process.alive?(view.pid)
      end
    end

    test "dispatches git branch switching, model selection, and terminal commands", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # 1. Model selection via palette
      render_click(view, "toggle_command_palette")
      render_click(view, "command_palette_set_category", %{"category" => "models"})
      render_change(view, "command_palette_search", %{"query" => "GPT-4o"})
      render_click(view, "command_palette_execute_selected")

      refute has_element?(view, "#command-palette-modal")
      assert Process.alive?(view.pid)

      # 2. Terminal command execution via palette
      render_click(view, "toggle_command_palette")
      render_click(view, "command_palette_set_category", %{"category" => "terminal"})
      render_change(view, "command_palette_search", %{"query" => "git status"})
      render_click(view, "command_palette_execute_selected")

      refute has_element?(view, "#command-palette-modal")
      assert Process.alive?(view.pid)
      assert render(view) =~ "terminal" or render(view) =~ "Terminal"
    end
  end
end
