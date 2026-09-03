defmodule IexCodeWeb.WorkspaceLiveM1AdversarialTest do
  @moduledoc """
  Empirical Adversarial Stress Test Suite for Milestone 1:
  Studio-Grade Glassmorphism & Layout Ergonomics.

  Adversarial Challenge Dimensions:
  1. Rapid sequential sidebar toggling (100 toggles)
  2. Rapid sequential bottom terminal dock toggling (100 toggles)
  3. Simultaneous sidebar collapse + bottom terminal open + compact density mode
  4. Tab switching across all 10 workspace tabs with bottom terminal dock active
  5. Zero duplicate DOM IDs across all layouts and tabs
  6. Unhandled LiveView events, boundary params, and concurrent desktop action signals
  """
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true

  @all_10_tabs ~w(kanban swarm research calendar changes tests ast chat files terminal)

  setup %{workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    %{project: project, session: session}
  end

  defp assert_no_duplicate_dom_ids(html_or_view, context_label) do
    html =
      case html_or_view do
        %Phoenix.LiveViewTest.View{} = view -> Phoenix.LiveViewTest.render(view)
        binary when is_binary(binary) -> binary
      end

    {:ok, document} = Floki.parse_fragment(html)

    all_ids =
      document
      |> Floki.find("[id]")
      |> Enum.map(fn node ->
        node |> Floki.attribute("id") |> List.first()
      end)
      |> Enum.reject(&is_nil/1)

    id_counts = Enum.frequencies(all_ids)
    duplicates = Enum.filter(id_counts, fn {_id, count} -> count > 1 end)

    assert duplicates == [],
           "Expected 0 duplicate DOM IDs in #{context_label}, but found duplicates: #{inspect(duplicates)}"
  end

  describe "Adversarial Stress Test: Rapid Sequential Toggling" do
    test "Rapid sequential sidebar toggling (100 toggles) preserves state consistency without crashing",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Initial state: expanded
      assert has_element?(view, "#workspace-sidebar[data-collapsed='false']")

      # 100 rapid sequential toggle clicks
      Enum.each(1..100, fn iteration ->
        render_click(view, "toggle_sidebar", %{})

        expected_collapsed = rem(iteration, 2) == 1

        if rem(iteration, 20) == 0 do
          assert Process.alive?(view.pid)

          if expected_collapsed do
            assert has_element?(view, "#workspace-sidebar[data-collapsed='true']")
          else
            assert has_element?(view, "#workspace-sidebar[data-collapsed='false']")
          end
        end
      end)

      # After 100 toggles (even number), sidebar should be expanded back to default
      assert has_element?(view, "#workspace-sidebar[data-collapsed='false']")
      assert Process.alive?(view.pid)

      # 101st toggle -> collapsed
      render_click(view, "toggle_sidebar", %{})
      assert has_element?(view, "#workspace-sidebar[data-collapsed='true']")
    end

    test "Rapid sequential bottom terminal panel toggling (100 toggles) maintains DOM integrity and process stability",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Initial state: closed
      refute has_element?(view, "#bottom-terminal-dock")

      # 100 rapid sequential toggle clicks
      Enum.each(1..100, fn iteration ->
        render_click(view, "toggle_bottom_terminal", %{})

        if rem(iteration, 20) == 0 do
          assert Process.alive?(view.pid)
          expected_open = rem(iteration, 2) == 1

          if expected_open do
            assert has_element?(view, "#bottom-terminal-dock")
          else
            refute has_element?(view, "#bottom-terminal-dock")
          end
        end
      end)

      # After 100 toggles (even number), dock should be closed
      refute has_element?(view, "#bottom-terminal-dock")
      assert Process.alive?(view.pid)

      # 101st toggle -> open
      render_click(view, "toggle_bottom_terminal", %{})
      assert has_element?(view, "#bottom-terminal-dock")
      assert has_element?(view, "#bottom-terminal-dock #terminal-session-container")
    end

    test "High-frequency chaotic interleaving of sidebar, dock, and density toggles",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Chaotic sequence of layout events
      events = [
        "toggle_sidebar",
        "toggle_bottom_terminal",
        "toggle_layout_density",
        "toggle_sidebar",
        "toggle_layout_density",
        "toggle_bottom_terminal"
      ]

      for _cycle <- 1..15, event <- events do
        render_click(view, event, %{})
      end

      assert Process.alive?(view.pid)
      assert has_element?(view, "#workspace-shell")
      assert has_element?(view, "#workspace-sidebar")
      assert_no_duplicate_dom_ids(view, "chaotic toggles final state")
    end
  end

  describe "Adversarial Test: Simultaneous Layout Modes & Glassmorphic Ergonomics" do
    test "Simultaneous sidebar collapse + bottom terminal open + compact density mode operates cleanly",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # 1. Switch to compact density
      render_click(view, "toggle_layout_density", %{})
      assert has_element?(view, "#workspace-shell[data-density='compact']")
      assert element(view, "#header-density-toggle") |> render() =~ "compact"

      # 2. Collapse sidebar
      render_click(view, "toggle_sidebar", %{})
      assert has_element?(view, "#workspace-sidebar[data-collapsed='true']")
      sidebar_html = element(view, "#workspace-sidebar") |> render()
      assert sidebar_html =~ "w-0"
      assert sidebar_html =~ "opacity-0"
      assert sidebar_html =~ "pointer-events-none"

      # 3. Open bottom terminal dock
      render_click(view, "toggle_bottom_terminal", %{})
      assert has_element?(view, "#bottom-terminal-dock")
      assert has_element?(view, "#bottom-terminal-dock.glass-surface-elevated")

      # All 3 active simultaneously
      assert has_element?(view, "#workspace-shell[data-density='compact']")
      assert has_element?(view, "#workspace-sidebar[data-collapsed='true']")
      assert has_element?(view, "#bottom-terminal-dock")

      # Verify glassmorphic headers and footers exist
      assert has_element?(view, "#workspace-header.glass-header")
      assert has_element?(view, "#workspace-status-footer.glass-footer")

      # Verify quick actions in dock execute properly under compact mode
      dock_test_btn = element(view, "#bottom-dock-quick-test")
      assert dock_test_btn |> render() =~ "mix test"
      render_click(dock_test_btn)

      dock_precommit_btn = element(view, "#bottom-dock-quick-precommit")
      assert dock_precommit_btn |> render() =~ "mix precommit"
      render_click(dock_precommit_btn)

      # Verify zero duplicate DOM IDs in this extreme combination
      assert_no_duplicate_dom_ids(view, "compact + collapsed sidebar + bottom terminal open")

      # Close dock via dock close button
      view |> element("#bottom-dock-close-btn") |> render_click()
      refute has_element?(view, "#bottom-terminal-dock")

      # Expand sidebar via header button
      view |> element("#sidebar-desktop-toggle-btn") |> render_click()
      assert has_element?(view, "#workspace-sidebar[data-collapsed='false']")

      # Toggle density back via header button
      view |> element("#header-density-toggle") |> render_click()
      assert has_element?(view, "#workspace-shell[data-density='comfortable']")
    end
  end

  describe "Adversarial Test: Tab Switching Across All 10 Tabs With Bottom Terminal Dock Active" do
    test "Bottom terminal dock remains functional across all 10 workspace tabs with zero duplicate DOM IDs",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Open bottom terminal dock
      render_click(view, "toggle_bottom_terminal", %{})
      assert has_element?(view, "#bottom-terminal-dock")

      # Iterate across all 10 tabs sequentially
      for tab <- @all_10_tabs do
        render_click(view, "switch_tab", %{"tab" => tab})

        # Process should stay alive
        assert Process.alive?(view.pid)

        # Dock must persist across every tab
        assert has_element?(view, "#bottom-terminal-dock"),
               "Bottom terminal dock disappeared on tab: #{tab}"

        assert has_element?(view, "#bottom-terminal-dock #terminal-session-container"),
               "Terminal session missing inside dock on tab: #{tab}"

        # Ensure exactly ONE terminal session container exists in the entire DOM
        html = render(view)
        {:ok, doc} = Floki.parse_fragment(html)
        terminal_containers = Floki.find(doc, "#terminal-session-container")

        assert length(terminal_containers) == 1,
               "Expected exactly 1 #terminal-session-container on tab #{tab}, found: #{length(terminal_containers)}"

        # Strict duplicate DOM ID assertion for this tab
        assert_no_duplicate_dom_ids(html, "Tab: #{tab} with bottom terminal dock active")
      end

      # Specific focus on Tab 10: "terminal" tab
      # Currently on "terminal" tab with bottom dock open
      assert has_element?(view, "#bottom-terminal-dock")

      # Now close bottom terminal dock while sitting on the "terminal" tab
      render_click(view, "toggle_bottom_terminal", %{})
      refute has_element?(view, "#bottom-terminal-dock")

      # The main Tab 7/10 container should now mount `<.terminal_session>`!
      assert has_element?(view, "#terminal-session-container")
      html_dock_closed = render(view)
      {:ok, doc_dock_closed} = Floki.parse_fragment(html_dock_closed)
      assert length(Floki.find(doc_dock_closed, "#terminal-session-container")) == 1
      assert_no_duplicate_dom_ids(html_dock_closed, "Terminal tab with bottom dock closed")

      # Re-open bottom terminal dock while still on the "terminal" tab
      render_click(view, "toggle_bottom_terminal", %{})
      assert has_element?(view, "#bottom-terminal-dock")
      html_dock_reopened = render(view)
      {:ok, doc_dock_reopened} = Floki.parse_fragment(html_dock_reopened)
      assert length(Floki.find(doc_dock_reopened, "#terminal-session-container")) == 1
      assert_no_duplicate_dom_ids(html_dock_reopened, "Terminal tab with bottom dock re-opened")
    end
  end

  describe "Adversarial Test: Comprehensive DOM ID Uniqueness & Boundary Event Handling" do
    test "No duplicate DOM IDs in default comfortable state across all 10 tabs with dock closed",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      for tab <- @all_10_tabs do
        render_click(view, "switch_tab", %{"tab" => tab})
        assert Process.alive?(view.pid)
        assert_no_duplicate_dom_ids(view, "Default layout - tab: #{tab}")
      end
    end

    test "Handles edge cases, malformed params, and unknown events safely without unhandled error crashes",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Unknown tab in switch_tab
      render_click(view, "switch_tab", %{"tab" => "non_existent_tab_12345"})
      assert Process.alive?(view.pid)

      render_click(view, "switch_tab", %{"tab" => ""})
      assert Process.alive?(view.pid)

      render_click(view, "switch_tab", %{"tab" => nil})
      assert Process.alive?(view.pid)

      # Malformed switch_tab params
      render_click(view, "switch_tab", %{"unexpected_key" => "value"})
      assert Process.alive?(view.pid)

      # Malformed toggle events with junk params
      render_click(view, "toggle_sidebar", %{"malicious" => "<script>alert(1)</script>"})
      assert Process.alive?(view.pid)

      render_click(view, "toggle_bottom_terminal", %{"overflow" => String.duplicate("A", 1000)})
      assert Process.alive?(view.pid)

      render_click(view, "toggle_layout_density", %{"random" => 12345})
      assert Process.alive?(view.pid)

      # Rapid PubSub desktop_action hammering
      Enum.each(1..20, fn _ ->
        send(view.pid, {:desktop_action, :toggle_sidebar})
        send(view.pid, {:desktop_action, :toggle_terminal})
      end)

      assert Process.alive?(view.pid)
      assert has_element?(view, "#workspace-shell")
    end
  end
end
