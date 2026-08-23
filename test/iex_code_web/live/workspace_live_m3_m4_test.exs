defmodule IexCodeWeb.WorkspaceLiveM3M4Test do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true
  alias IexCode.{Sessions, Kanban}

  setup %{conn: conn, workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    # Create a test file in the workspace
    test_file_path = Path.join(path, "lib/demo_worker.ex")
    File.mkdir_p!(Path.dirname(test_file_path))
    File.write!(test_file_path, "defmodule DemoWorker do\n  def work, do: :ok\nend\n")

    # Commit a git baseline BEFORE mounting so the Changes tab can render real
    # `git diff` hunks, then modify the file to produce uncommitted changes
    System.cmd("git", ["init"], cd: path)
    System.cmd("git", ["config", "user.name", "IexCode Test"], cd: path)
    System.cmd("git", ["config", "user.email", "test@iexcode.local"], cd: path)
    System.cmd("git", ["add", "."], cd: path)
    System.cmd("git", ["commit", "-m", "Initial commit"], cd: path)
    File.write!(test_file_path, "defmodule DemoWorker do\n  def work, do: :modified\nend\n")

    {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}")

    {:ok,
     conn: conn, project: project, session: session, view: view, html: html, workspace_path: path}
  end

  # ============================================================================
  # Milestone 3: Interactive Inline Code Editor Tests
  # ============================================================================

  describe "Interactive Inline Code Editor" do
    test "opens file in editor, manages multiple open buffers and dirty state", %{
      view: view,
      workspace_path: path
    } do
      # 1. Switch to Files view
      view |> element("#tab-btn-files") |> render_click()

      # 2. Select file
      view
      |> element("button[phx-click='select_file'][phx-value-path='lib/demo_worker.ex']")
      |> render_click()

      html = render(view)
      assert html =~ "lib/demo_worker.ex"
      assert html =~ "defmodule DemoWorker"
      assert has_element?(view, "#code-editor-viewport")

      # 3. Simulate content modification (dirty state)
      new_code = "defmodule DemoWorker do\n  def work, do: :modified_result\nend\n"
      html = render_hook(view, "file_content_changed", %{"content" => new_code})

      assert html =~ "Unsaved Changes"
      assert has_element?(view, "button[phx-click='save_file']")
      assert has_element?(view, "button[phx-click='revert_file_buffer']")

      # 4. Save file to disk
      render_hook(view, "save_file", %{"content" => new_code})

      saved_disk_content = File.read!(Path.join(path, "lib/demo_worker.ex"))
      assert saved_disk_content == new_code
      refute render(view) =~ "● Unsaved Changes"

      # 5. Revert unsaved edits test
      render_hook(view, "file_content_changed", %{"content" => "temporary broken code"})
      assert render(view) =~ "Unsaved Changes"

      view |> element("button[phx-click='revert_file_buffer']") |> render_click()
      refute render(view) =~ "temporary broken code"
      assert render(view) =~ "def work, do: :modified_result"

      # 6. Close buffer
      view
      |> element("button[phx-click='close_file_buffer'][phx-value-path='lib/demo_worker.ex']")
      |> render_click()

      assert render(view) =~ "Select a workspace file on the left to preview contents"
    end
  end

  # ============================================================================
  # Milestone 3: Interactive Diff Viewer & Hunk Actions Tests
  # ============================================================================

  describe "Interactive Diff Viewer & Granular Hunk Ops" do
    test "renders diff hunks with per-hunk action buttons and toggles display modes", %{
      view: view
    } do
      # 1. Switch to Changes view
      view |> element("#tab-btn-changes") |> render_click()

      html = render(view)
      assert html =~ "lib/demo_worker.ex"
      assert html =~ "Hunk hunk-1"
      assert has_element?(view, "button[phx-click='accept_hunk']")
      assert has_element?(view, "button[phx-click='reject_hunk']")
      assert has_element?(view, "button[phx-click='revert_hunk']")
      assert has_element?(view, "button[phx-click='accept_all_hunks']")
      assert has_element?(view, "button[phx-click='revert_file']")

      # 2. Toggle Side-by-Side (Split) mode
      view
      |> element("button[phx-click='set_diff_mode'][phx-value-mode='split']")
      |> render_click()

      assert render(view) =~ "Original"
      assert render(view) =~ "Modified"

      # 3. Toggle Inline mode
      view
      |> element("button[phx-click='set_diff_mode'][phx-value-mode='inline']")
      |> render_click()

      refute render(view) =~ "Original\n"

      # 4. Trigger accept hunk
      render_click(view, "accept_hunk", %{
        "file" => "lib/demo_worker.ex",
        "hunk_id" => "hunk-1"
      })

      # Verify LiveView process survives and updates flash / status
      assert Process.alive?(view.pid)

      # 5. Trigger reject hunk
      render_click(view, "reject_hunk", %{
        "file" => "lib/demo_worker.ex",
        "hunk_id" => "hunk-1"
      })

      assert Process.alive?(view.pid)

      # 6. Trigger revert file
      render_click(view, "revert_file", %{"file" => "lib/demo_worker.ex"})
      assert Process.alive?(view.pid)
    end
  end

  # ============================================================================
  # Milestone 4: Goal Lifecycle, Pause/Resume & Steering UI Tests
  # ============================================================================

  describe "Goal Lifecycle & Steering Controls" do
    test "creates autonomous goal via modal form", %{view: view} do
      # 1. Switch to Swarm tab & open goal modal
      view |> element("#tab-btn-swarm") |> render_click()
      render_click(view, "open_goal_modal")
      assert render(view) =~ "Create Autonomous Goal"

      # 2. Submit goal form
      html =
        render_submit(view, "create_goal", %{
          "goal" => %{
            "title" => "Build end-to-end telemetry pipeline",
            "description" => "Ensure latency and token counting are verified",
            "auto_start" => "true"
          }
        })

      refute render(view) =~ "Create Autonomous Goal"
      assert html =~ "Goal created"
    end

    test "pauses, resumes, and cancels active session execution", %{view: view} do
      # 1. Switch to Swarm tab
      view |> element("#tab-btn-swarm") |> render_click()

      # 2. Pause session
      render_click(view, "pause_session")
      assert render(view) =~ "PAUSED"

      # 3. Resume session — with no active run it never phantom-resumes into
      # running; the session settles back to IDLE
      render_click(view, "resume_session")
      assert render(view) =~ "IDLE"

      # 4. Open cancel modal
      render_click(view, "open_cancel_modal")

      assert render(view) =~ "Stop &amp; Cancel Session" or
               render(view) =~ "Stop & Cancel Session"

      assert render(view) =~ "Rollback Snapshots"
      assert render(view) =~ "Commit Changes"

      # 5. Cancel with rollback
      render_click(view, "cancel_session", %{"mode" => "rollback"})
      refute render(view) =~ "Stop & Cancel Session"
      assert render(view) =~ "Session stopped"
    end

    test "delivers real-time steering directive to active swarm", %{view: view} do
      render_click(view, "send_steering", %{"text" => "Focus on AST parser error recovery"})
      assert render(view) =~ "Steering guidance delivered"
    end
  end

  # ============================================================================
  # Milestone 4: Dead Button Elimination & UI Controls Audit Tests
  # ============================================================================

  describe "UI Control Actions & Dead Button Elimination" do
    test "switches calendar months and dates", %{view: view} do
      view |> element("#tab-btn-calendar") |> render_click()

      # Next month
      render_click(view, "calendar_next_month")
      assert render(view) =~ "September, 2026"

      # Prev month back to August
      render_click(view, "calendar_prev_month")
      assert render(view) =~ "August, 2026"
    end

    test "modifies task priority and assignee from Task Drawer", %{
      view: view,
      project: project,
      session: session
    } do
      {:ok, task} =
        Kanban.create_task(%{
          project_id: project.id,
          session_id: session.id,
          title: "Drawer Test Task",
          status: "ready",
          priority: "low",
          assignee: "default"
        })

      # Open drawer
      render_click(view, "open_task_drawer", %{"id" => task.id})
      assert render(view) =~ "Drawer Test Task"

      # Update priority to critical
      render_click(view, "update_task_priority", %{"id" => task.id, "priority" => "critical"})
      updated = Kanban.get_task!(task.id)
      assert updated.priority == "critical"

      # Update assignee to verifier
      render_click(view, "update_task_assignee", %{"id" => task.id, "assignee" => "verifier"})
      updated = Kanban.get_task!(task.id)
      assert updated.assignee == "verifier"

      # Delete task
      render_click(view, "delete_task", %{"id" => task.id})
      assert Kanban.get_task(task.id) == nil
    end

    test "toggles prompt bar tool pills and usage history modal", %{view: view} do
      # Toggle tool pills
      render_click(view, "toggle_tool", %{"tool" => "ast_search"})
      render_click(view, "toggle_tool", %{"tool" => "swarm"})

      # Toggle usage history
      render_click(view, "toggle_all_usage_modal")
      assert render(view) =~ "Usage History" or render(view) =~ "CREDITS USED"
    end

    test "executes terminal commands, handles replay and stop", %{view: view} do
      view |> element("#tab-btn-terminal") |> render_click()

      # Execute terminal command
      view
      |> form("#terminal-form", %{"command" => "echo 'hello terminal runner'"})
      |> render_submit()

      assert Process.alive?(view.pid)

      # Replay command
      render_click(view, "replay_terminal_command")
      assert Process.alive?(view.pid)

      # Stop terminal command
      render_click(view, "stop_terminal_command")
      assert Process.alive?(view.pid)
    end

    test "renders thinking traces with collapsible disclosure and markdown", %{
      view: view,
      session: session
    } do
      # Switch to chat tab
      view |> element("#tab-btn-chat") |> render_click()

      # Simulate message with reasoning
      {:ok, msg} =
        Sessions.create_message(%{
          session_id: session.id,
          role: "assistant",
          agent_name: "PlannerAgent",
          content:
            "<think>Decomposing milestone into 4 parallel tasks.</think>\n\n### Execution Strategy\nProceeding with task execution.",
          metadata: %{
            "reasoning" => "Decomposing milestone into 4 parallel tasks.",
            "duration_ms" => 125
          }
        })

      # Send PubSub broadcast
      Phoenix.PubSub.broadcast(IexCode.PubSub, "session:#{session.id}", {:message_created, msg})

      # Trigger render
      html = render(view)
      assert html =~ "Thought Process (Reasoning Trace)"
      assert html =~ "Decomposing milestone into 4 parallel tasks."
      assert html =~ "Execution Strategy"

      # Expand message modal
      render_click(view, "expand_message", %{"id" => msg.id})
      assert render(view) =~ "Execution Strategy"
      assert has_element?(view, "#copy-expanded-msg-btn")

      # Close expanded modal
      render_click(view, "close_expand_message")
      refute render(view) =~ "copy-expanded-msg-btn"
    end
  end
end
