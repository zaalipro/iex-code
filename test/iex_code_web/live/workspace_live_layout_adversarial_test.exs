defmodule IexCodeWeb.WorkspaceLiveLayoutAdversarialTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true

  setup %{workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    %{project: project, session: session}
  end

  describe "Adversarial terminal quick actions and close button" do
    test "repeated sequential clicks of quick action mix test and mix precommit in bottom terminal dock",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Open bottom terminal dock
      render_click(view, "toggle_bottom_terminal", %{})
      assert has_element?(view, "#bottom-terminal-dock")
      assert has_element?(view, "#bottom-dock-quick-test")
      assert has_element?(view, "#bottom-dock-quick-precommit")

      # Stress: Rapidly click mix test 15 times
      for _i <- 1..15 do
        view
        |> element("#bottom-dock-quick-test")
        |> render_click()

        assert Process.alive?(view.pid)
      end

      # Stress: Rapidly click mix precommit 15 times
      for _i <- 1..15 do
        view
        |> element("#bottom-dock-quick-precommit")
        |> render_click()

        assert Process.alive?(view.pid)
      end

      # LiveView process must remain alive and responsive
      assert Process.alive?(view.pid)
      assert has_element?(view, "#bottom-terminal-dock")
    end

    test "alternating rapid clicks between mix test and mix precommit in bottom dock",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "toggle_bottom_terminal", %{})
      assert has_element?(view, "#bottom-terminal-dock")

      # Alternate 20 times (40 clicks)
      for _i <- 1..20 do
        view |> element("#bottom-dock-quick-test") |> render_click()
        view |> element("#bottom-dock-quick-precommit") |> render_click()
        assert Process.alive?(view.pid)
      end

      assert Process.alive?(view.pid)
      assert has_element?(view, "#bottom-terminal-dock")
    end

    test "rapidly toggling bottom terminal dock open and closed via close button and toggle event",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      refute has_element?(view, "#bottom-terminal-dock")

      for _i <- 1..15 do
        # Open via event
        render_click(view, "toggle_bottom_terminal", %{})
        assert has_element?(view, "#bottom-terminal-dock")
        assert has_element?(view, "#bottom-dock-close-btn")

        # Close via close button in dock header
        view
        |> element("#bottom-dock-close-btn")
        |> render_click()

        refute has_element?(view, "#bottom-terminal-dock")
        assert Process.alive?(view.pid)
      end

      assert Process.alive?(view.pid)
    end

    test "terminal quick actions and dock toggle while on tab terminal",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Switch to Tab 7 (terminal)
      view
      |> element("#tab-btn-terminal")
      |> render_click()

      # Terminal container exists in Tab 7 while dock is closed
      assert has_element?(view, "#terminal-session-container")
      refute has_element?(view, "#bottom-terminal-dock")

      # Open bottom terminal dock
      render_click(view, "toggle_bottom_terminal", %{})
      assert has_element?(view, "#bottom-terminal-dock")

      # Exactly one terminal-session-container in the DOM (in the dock)
      assert has_element?(view, "#bottom-terminal-dock #terminal-session-container")

      # Trigger quick actions inside the dock
      view |> element("#bottom-dock-quick-test") |> render_click()
      assert Process.alive?(view.pid)

      # Close dock via close button
      view |> element("#bottom-dock-close-btn") |> render_click()
      refute has_element?(view, "#bottom-terminal-dock")

      # Terminal container cleanly returned to Tab 7
      assert has_element?(view, "#terminal-session-container")
      assert has_element?(view, "#btn-quick-precommit")

      # Trigger quick action from Tab 7
      view |> element("#btn-quick-precommit") |> render_click()
      assert Process.alive?(view.pid)
    end

    test "handles terminal failure or stopped session without crashing LiveView",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "toggle_bottom_terminal", %{})
      assert has_element?(view, "#bottom-terminal-dock")

      # Cleanly stop terminal session
      IexCode.Tools.TerminalSession.stop(session.id)

      # Attempt quick action with terminated backend
      render_click(view, "run_terminal_quick_action", %{"cmd" => "mix test"})
      assert Process.alive?(view.pid)

      # Re-attempt with precommit
      render_click(view, "run_terminal_quick_action", %{"cmd" => "mix precommit"})
      assert Process.alive?(view.pid)
    end

    test "edge case parameters to run_terminal_quick_action do not crash LiveView",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Empty string cmd
      render_click(view, "run_terminal_quick_action", %{"cmd" => ""})
      assert Process.alive?(view.pid)

      # Whitespace-only cmd
      render_click(view, "run_terminal_quick_action", %{"cmd" => "     \t\n  "})
      assert Process.alive?(view.pid)

      # Using alternate parameter key "command"
      render_click(view, "run_terminal_quick_action", %{"command" => "mix test"})
      assert Process.alive?(view.pid)

      # Overly large command
      render_click(
        view,
        "run_terminal_quick_action",
        %{"cmd" => String.duplicate("echo hello; ", 500)}
      )

      assert Process.alive?(view.pid)
    end
  end

  describe "Adversarial desktop action message handling" do
    test "concurrent background tasks sending toggle_sidebar and toggle_terminal directly to view.pid",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view_pid = view.pid

      # Spawn 20 tasks sending toggle_sidebar and 20 sending toggle_terminal concurrently
      tasks =
        for i <- 1..40 do
          Task.async(fn ->
            action = if rem(i, 2) == 0, do: :toggle_sidebar, else: :toggle_terminal
            send(view_pid, {:desktop_action, action})
          end)
        end

      Enum.each(tasks, &Task.await(&1, 5000))

      _ = :sys.get_state(view_pid)
      assert Process.alive?(view_pid)

      # Verify LiveView is still functional
      assert has_element?(view, "#workspace-shell")
    end

    test "desktop action messages broadcast via Phoenix.PubSub on 'desktop:events'",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Initial state
      assert has_element?(view, "#workspace-sidebar[data-collapsed='false']")
      refute has_element?(view, "#bottom-terminal-dock")

      # Broadcast toggle_sidebar
      Phoenix.PubSub.broadcast(
        IexCode.PubSub,
        "desktop:events",
        {:desktop_action, :toggle_sidebar}
      )

      _ = :sys.get_state(view.pid)
      assert has_element?(view, "#workspace-sidebar[data-collapsed='true']")

      # Broadcast toggle_sidebar again
      Phoenix.PubSub.broadcast(
        IexCode.PubSub,
        "desktop:events",
        {:desktop_action, :toggle_sidebar}
      )

      _ = :sys.get_state(view.pid)
      assert has_element?(view, "#workspace-sidebar[data-collapsed='false']")

      # Broadcast toggle_terminal
      Phoenix.PubSub.broadcast(
        IexCode.PubSub,
        "desktop:events",
        {:desktop_action, :toggle_terminal}
      )

      _ = :sys.get_state(view.pid)
      assert has_element?(view, "#bottom-terminal-dock")

      # Broadcast toggle_terminal again
      Phoenix.PubSub.broadcast(
        IexCode.PubSub,
        "desktop:events",
        {:desktop_action, :toggle_terminal}
      )

      _ = :sys.get_state(view.pid)
      refute has_element?(view, "#bottom-terminal-dock")

      assert Process.alive?(view.pid)
    end

    test "desktop action messages received during unexpected modal/drawer states",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # 1. While settings modal is open
      render_click(view, "toggle_settings_modal", %{})
      assert has_element?(view, "#settings-modal")

      send(view.pid, {:desktop_action, :toggle_sidebar})
      send(view.pid, {:desktop_action, :toggle_terminal})
      _ = :sys.get_state(view.pid)

      assert Process.alive?(view.pid)
      assert has_element?(view, "#settings-modal")
      assert has_element?(view, "#bottom-terminal-dock")

      # Close settings modal
      render_click(view, "toggle_settings_modal", %{})
      refute has_element?(view, "#settings-modal")

      # 2. While time picker is open
      render_click(view, "open_time_picker", %{})
      assert has_element?(view, "#time-picker-modal")

      send(view.pid, {:desktop_action, :toggle_sidebar})
      send(view.pid, {:desktop_action, :toggle_terminal})
      _ = :sys.get_state(view.pid)

      assert Process.alive?(view.pid)
      assert has_element?(view, "#time-picker-modal")

      # Close time picker modal
      render_click(view, "close_time_picker", %{})
      refute has_element?(view, "#time-picker-modal")

      assert Process.alive?(view.pid)
    end

    test "unexpected, unknown, and malformed desktop action messages do not crash LiveView",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Unknown atom action
      send(view.pid, {:desktop_action, :nonexistent_action})
      _ = :sys.get_state(view.pid)
      assert Process.alive?(view.pid)

      # Nil action
      send(view.pid, {:desktop_action, nil})
      _ = :sys.get_state(view.pid)
      assert Process.alive?(view.pid)

      # Integer action
      send(view.pid, {:desktop_action, 12345})
      _ = :sys.get_state(view.pid)
      assert Process.alive?(view.pid)

      # String action
      send(view.pid, {:desktop_action, "toggle_sidebar"})
      _ = :sys.get_state(view.pid)
      assert Process.alive?(view.pid)

      # Detach window with atom
      send(view.pid, {:desktop_action, {:detach_window, :terminal}})
      _ = :sys.get_state(view.pid)
      assert Process.alive?(view.pid)

      # Detach window with unknown tool
      send(view.pid, {:desktop_action, {:detach_window, :unknown_tool}})
      _ = :sys.get_state(view.pid)
      assert Process.alive?(view.pid)

      # Arbitrary unhandled info tuple
      send(view.pid, {:completely_unhandled_info_tuple, 1, 2, 3})
      _ = :sys.get_state(view.pid)
      assert Process.alive?(view.pid)
    end

    test "combined stress: concurrent PubSub broadcasts while rapidly clicking quick actions",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Open bottom terminal dock
      render_click(view, "toggle_bottom_terminal", %{})
      assert has_element?(view, "#bottom-terminal-dock")

      # Background broadcaster
      parent = self()

      _broadcaster =
        spawn(fn ->
          for _i <- 1..30 do
            Phoenix.PubSub.broadcast(
              IexCode.PubSub,
              "desktop:events",
              {:desktop_action, :toggle_sidebar}
            )

            Process.sleep(5)
          end

          send(parent, :broadcaster_done)
        end)

      # Foreground rapid quick action clicks
      for _i <- 1..15 do
        render_click(view, "run_terminal_quick_action", %{"cmd" => "mix test"})
        render_click(view, "run_terminal_quick_action", %{"cmd" => "mix precommit"})
      end

      assert_receive :broadcaster_done, 5000
      _ = :sys.get_state(view.pid)

      assert Process.alive?(view.pid)
    end
  end
end
