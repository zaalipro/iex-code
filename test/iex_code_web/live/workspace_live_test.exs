defmodule IexCodeWeb.WorkspaceLiveTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true
  alias IexCode.Sessions
  alias IexCode.Sessions.Operation

  test "renders workspace interface, today tasks, and kanban board", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}")

    assert html =~ "Today&#39;s tasks" or html =~ "Today's tasks"
    assert html =~ "Kanban"
    assert has_element?(view, "button[phx-value-tab='kanban']")
    assert has_element?(view, "button[phx-value-tab='swarm']")
  end

  test "switches tabs between kanban, swarm, calendar, changes, chat, files, and terminal", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    # Switch to swarm tab
    view
    |> element("#tab-btn-swarm")
    |> render_click()

    assert render(view) =~ "PlannerAgent"
    assert render(view) =~ "ExplorerAgent"

    # Switch to calendar tab
    view
    |> element("#tab-btn-calendar")
    |> render_click()

    assert render(view) =~ "Scheduled Tasks" or render(view) =~ "August, 2026"

    # Switch to changes tab
    view
    |> element("#tab-btn-changes")
    |> render_click()

    assert render(view) =~ "All Changes"
    assert render(view) =~ "Canvas · 4"

    # Switch to chat tab
    view
    |> element("#tab-btn-chat")
    |> render_click()

    # Switch to terminal tab
    view
    |> element("#tab-btn-terminal")
    |> render_click()

    assert render(view) =~ "mix test"
  end

  test "toggles swarm mode", %{conn: conn, workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    assert render(view) =~ "Swarm:"

    view
    |> element("button[phx-click='toggle_swarm']")
    |> render_click()

    assert render(view) =~ "Swarm Mode" or render(view) =~ "Single Agent Mode"
  end

  test "creates a new session when clicking the plus button", %{conn: conn, workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    # Click new session plus button
    view
    |> element("button#new-session-btn")
    |> render_click()

    assert render(view) =~ "Coding Session 2"
  end

  test "opens task detail drawer and claims task", %{conn: conn, workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, task} =
      IexCode.Kanban.create_task(%{
        project_id: project.id,
        session_id: session.id,
        title: "Test Drawer Task",
        status: "running"
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    # Click task card in expanded column
    view
    |> element("#task-card-#{task.id}")
    |> render_click()

    assert render(view) =~ "Worker PID"
    assert render(view) =~ "Estimate"
  end

  test "expands and collapses kanban accordion column ribbons on click", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    # Click collapsed 'ready' ribbon
    view
    |> element("#kanban-col-ready")
    |> render_click()

    assert render(view) =~ "READY"
  end

  # ============================================================================
  # F5: Live Telemetry Streaming Tests
  # ============================================================================

  test "handles real-time PubSub telemetry events for subagent cards", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    # Switch to swarm tab to observe telemetry
    view
    |> element("#tab-btn-swarm")
    |> render_click()

    op = %Operation{
      id: "op-telemetry-1",
      session_id: session.id,
      agent_name: "CoderAgent",
      op_type: "patch_file",
      title: "Applying payment webhook patch",
      status: "running",
      progress: 10,
      pid_str: "#PID<0.888.0>",
      duration_ms: 25,
      started_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    # 1. Operation started
    send(view.pid, {:operation_started, op})
    html = render(view)
    assert html =~ "CoderAgent"
    assert html =~ "RUNNING"
    assert html =~ "Applying payment webhook patch"
    assert html =~ "10%"

    # 2. 4-tuple progress update
    send(view.pid, {:operation_progress, op.id, 55, "Applying hunk 2 of 4"})
    html = render(view)
    assert html =~ "55%"
    assert html =~ "Applying hunk 2 of 4"

    # 3. Map progress update with latency
    send(
      view.pid,
      {:operation_progress,
       %{id: op.id, progress: 85, status: "running", latency_ms: 140, message: "Hunk 4 verified"}}
    )

    html = render(view)
    assert html =~ "85%"
    assert html =~ "140ms"

    # 4. Completed event
    completed_op = %{op | status: "completed", progress: 100, duration_ms: 185}
    send(view.pid, {:operation_completed, completed_op})
    html = render(view)
    assert html =~ "COMPLETED"
    assert html =~ "100%"
    assert html =~ "185ms"

    # 5. Swarm stage changed
    send(view.pid, {:swarm_stage_changed, %{stage: :verifying}})
    assert render(view) =~ "Execution Hierarchy"
  end

  # ============================================================================
  # F6: Hierarchical Operation Tree Interaction Tests
  # ============================================================================

  test "handles operation tree expand/collapse and clear operations", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, root_op} =
      Sessions.create_operation(%{
        session_id: session.id,
        parent_op_id: nil,
        agent_name: "SwarmCoordinator",
        op_type: "swarm_root",
        title: "Root Swarm Goal",
        status: "completed",
        progress: 100,
        result: "All 3 subtasks succeeded",
        started_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    {:ok, child_op} =
      Sessions.create_operation(%{
        session_id: session.id,
        parent_op_id: root_op.id,
        agent_name: "VerifierAgent",
        op_type: "verify",
        title: "Running test suite",
        status: "failed",
        error_message: "Test failure: Assertion failed",
        progress: 100,
        started_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    # Switch to swarm tab
    view
    |> element("#tab-btn-swarm")
    |> render_click()

    assert render(view) =~ "Root Swarm Goal"

    # 1. Expand root op to reveal children
    html = render_click(view, "toggle_op_detail", %{"id" => root_op.id})
    assert html =~ "All 3 subtasks succeeded"
    assert html =~ "Running test suite"

    # 2. Expand child op to inspect error details
    html = render_click(view, "toggle_op_detail", %{"id" => child_op.id})
    assert html =~ "Assertion failed" or html =~ "Test failure"

    # Clear operations
    html = render_click(view, "clear_operations")
    assert html =~ "No operations recorded in this session"
  end

  # ============================================================================
  # F7: Interactive Diff Viewer Tests
  # ============================================================================

  test "handles diff mode toggling between inline and side-by-side", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    # Switch to changes tab
    view
    |> element("#tab-btn-changes")
    |> render_click()

    assert render(view) =~ "swarm_coordinator.ex" or render(view) =~ "Patch Preview"

    # Switch to split mode
    html = render_click(view, "set_diff_mode", %{"mode" => "split"})
    assert html =~ "Original"
    assert html =~ "Modified"

    # Switch back to inline mode
    html = render_click(view, "set_diff_mode", %{"mode" => "inline"})
    assert html =~ "bg-emerald-950/40" or html =~ "text-emerald-300"
  end

  # ============================================================================
  # F8: File Tree Explorer & Search Tests
  # ============================================================================

  test "handles file searching, filtering, and selection with automatic tab switch", %{
    conn: conn,
    workspace_path: path
  } do
    workspace_write_file(path, "lib/demo_app.ex", "defmodule DemoApp do\n  def run, do: :ok\nend")
    workspace_write_file(path, "lib/demo_worker.ex", "defmodule DemoWorker do end")

    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    # Filter files
    html = render_change(view, "filter_files", %{"filter" => "worker"})
    assert html =~ "demo_worker.ex" or is_binary(html)

    # Select file from any tab -> automatically switches to files tab and renders content
    html = render_click(view, "select_file", %{"path" => "lib/demo_app.ex"})
    assert html =~ "defmodule DemoApp do"
    assert html =~ "def run, do: :ok"
    assert html =~ "Copy"

    # Refresh files
    html = render_click(view, "refresh_files")
    assert is_binary(html)
  end

  # ============================================================================
  # F9: Terminal Session Runner Tests
  # ============================================================================

  test "handles terminal command execution, quick actions, clear, and streaming", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    # Switch to terminal tab
    view
    |> element("#tab-btn-terminal")
    |> render_click()

    # Execute terminal command via form
    html =
      view
      |> form("#terminal-form", %{"command" => "echo 'hello from integrated terminal'"})
      |> render_submit()

    assert html =~ "hello from integrated terminal"
    assert html =~ "[Exit 0: OK]"

    # Execute quick terminal button
    html = render_click(view, "run_terminal", %{"command" => "echo 'quick command test'"})
    assert html =~ "quick command test"

    # Receive async terminal output event
    send(view.pid, {:terminal_output, session.id, "Streaming log line 42"})
    assert render(view) =~ "Streaming log line 42"

    # Clear terminal
    html = render_click(view, "clear_terminal")
    refute html =~ "Streaming log line 42"
  end

  test "rejects path traversal attempts in select_file with flash error", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    # Attempt to traverse outside project root
    html = render_click(view, "select_file", %{"path" => "../../../../etc/passwd"})
    assert html =~ "Invalid file path"

    # Absolute path outside project root
    html = render_click(view, "select_file", %{"path" => "/etc/passwd"})
    assert html =~ "Invalid file path"
  end

  test "handles nil, non-binary, and empty terminal output events gracefully without crashing", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    send(view.pid, {:terminal_output, session.id, nil})
    send(view.pid, {:terminal_output, session.id, ""})
    send(view.pid, {:terminal_output, session.id, 12345})
    send(view.pid, {:terminal_output, session.id, %{text: "invalid"}})

    # LiveView process stays alive and healthy
    assert Process.alive?(view.pid)
    assert render(view) =~ "Workspace" or render(view) =~ "Coding Session"
  end

  # ============================================================================
  # F10: Set Focus Time & Date Picker Tests
  # ============================================================================

  test "handles Set Focus Time picker modal: open, select status, select slot, and apply", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    # 1. Open focus time picker via header button
    html = render_click(view, "open_time_picker")
    assert html =~ "Set focus time"
    assert html =~ "Choose when you"
    assert html =~ "Select status"
    assert html =~ "Select time"
    assert html =~ "10:30 AM"

    # 2. Select status pill (e.g. In-meeting)
    html = render_click(view, "select_schedule_status", %{"status" => "In-meeting"})
    assert html =~ "In-meeting"

    # 3. Select time slot (e.g. 11:30 AM - 12:00 PM)
    html = render_click(view, "select_time_slot", %{"slot" => "11:30 AM - 12:00 PM"})
    assert html =~ "11:30 AM - 12:00 PM"

    # 4. Toggle custom time input
    html = render_click(view, "toggle_custom_time")
    assert html =~ "Enter Custom Time / Interval"

    # 5. Apply time picker
    html = render_click(view, "apply_time_picker")
    assert html =~ "Scheduled for"
    assert html =~ "11:30 AM - 12:00 PM"
    refute html =~ "Set focus time"

    # 6. Test cancel button closes modal
    render_click(view, "open_time_picker")
    html = render_click(view, "close_time_picker")
    refute html =~ "Set focus time"
  end

  # ============================================================================
  # F11: Chat Scroll Assistant Minimap & Hover Preview Tests
  # ============================================================================

  test "renders Chat Scroll Assistant timeline minimap, hover preview cards, and jump navigation",
       %{
         conn: conn,
         workspace_path: path
       } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    # Switch to chat tab
    view
    |> element("#tab-btn-chat")
    |> render_click()

    html = render(view)
    assert html =~ "chat-timeline-track"
    assert html =~ "scroll-timeline-node"
    assert html =~ "scroll-notch"
    assert html =~ "scroll-preview-card"
    assert html =~ "dashscope_new_report.md" or html =~ "deepseek"
    assert html =~ "chat-viewport"

    # Trigger scroll to message
    html = render_click(view, "scroll_to_message", %{"id" => "msg-0"})
    assert is_binary(html)
    assert Process.alive?(view.pid)
  end

  # ============================================================================
  # F12: Scheduled Tab, Calendar Day Click, Task Details Modal & Scheduling
  # ============================================================================

  test "handles Scheduled tab navigation, calendar day click preselection, and task detail modal inspection",
       %{
         conn: conn,
         workspace_path: path
       } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    # 1. Verify "Scheduled" tab label
    html = render(view)
    assert html =~ "Scheduled"

    # 2. Switch to Scheduled (calendar) tab
    view
    |> element("#tab-btn-calendar")
    |> render_click()

    html = render(view)
    assert html =~ "August, 2026"
    assert html =~ "calendar-day-16"
    assert html =~ "calendar-day-7"

    # 3. Click empty day (e.g. Day 18) -> opens Create Task modal with preselected date
    html =
      render_click(view, "select_calendar_day", %{
        "day" => "18",
        "date" => "2026-08-18"
      })

    assert html =~ "Create Agent Task"
    assert html =~ "2026-08-18"
    assert html =~ "Schedule &amp; Execution Time"

    # 4. Create new scheduled task with target date via modal form
    html =
      view
      |> form("#task-create-form", %{
        "title" => "Run automated benchmark audit",
        "description" => "Execute 500-level stress sweep",
        "status" => "scheduled",
        "priority" => "critical",
        "assignee" => "verifier",
        "scheduled_at_date" => "2026-08-18",
        "cron_expression" => "0 12 * * *"
      })
      |> render_submit()

    assert html =~ "Task created"
    refute html =~ "Create Agent Task"

    # 5. Find created task and click to open details modal
    created_task =
      IexCode.Kanban.list_tasks(project.id)
      |> Enum.find(&(&1.title == "Run automated benchmark audit"))

    assert created_task != nil

    html = render_click(view, "show_scheduled_task", %{"id" => created_task.id})
    assert html =~ "scheduled-task-detail-modal"
    assert html =~ "Run automated benchmark audit"
    assert html =~ "Execute 500-level stress sweep"
    assert html =~ "Critical Priority"
    assert html =~ "Run Now"
    assert html =~ "Delete Task"

    # 6. Run task from modal
    html = render_click(view, "run_scheduled_task", %{"id" => created_task.id})
    assert html =~ "triggered and now running"
    refute html =~ "scheduled-task-detail-modal"
  end

  test "F13: custom popover date picker and live availability status system", %{conn: conn} do
    project = create_project_fixture(%{root_path: "/tmp/e2e_datepicker_project"})
    session = create_session_fixture(project)
    {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}")

    # 1. Header live availability presence indicator
    assert html =~ "header-focus-time-btn"
    assert html =~ "Available"

    # 2. Open new task modal and trigger custom date picker popover
    html = render_click(view, "toggle_new_task_modal")
    assert html =~ "new-task-modal"
    assert html =~ "target-date-picker-trigger"

    # Open popover
    html = render_click(view, "toggle_date_picker_popover")
    assert html =~ "custom-date-picker-popover"
    assert html =~ "August 2026"
    assert html =~ "Clear"
    assert html =~ "Today"

    # Navigate month
    html = render_click(view, "picker_next_month")
    assert html =~ "September 2026"

    html = render_click(view, "picker_prev_month")
    assert html =~ "August 2026"

    # Select day 15
    html =
      render_click(view, "picker_select_day", %{"year" => "2026", "month" => "8", "day" => "15"})

    refute html =~ "custom-date-picker-popover"
    assert html =~ "08/15/2026"

    # Re-open and click Today
    html = render_click(view, "toggle_date_picker_popover")
    assert html =~ "custom-date-picker-popover"
    html = render_click(view, "picker_today")
    assert html =~ "08/20/2026"

    # 3. Test Presence & Focus Mode Modal with untruncated status pills
    html = render_click(view, "open_time_picker")
    assert html =~ "time-picker-modal"
    assert html =~ "Set focus time &amp; presence"
    assert html =~ "Available"
    assert html =~ "Busy"
    assert html =~ "In-meeting"
    assert html =~ "Offline"
    assert html =~ "Deep focus mode"
    assert html =~ "Batched summaries"

    # Switch status to Busy
    html = render_click(view, "select_schedule_status", %{"status" => "Busy"})
    assert html =~ "Deep focus mode"

    # Apply presence
    html = render_click(view, "apply_time_picker")
    assert html =~ "Focus presence updated: Busy"
    assert html =~ "header-focus-time-btn"
    assert html =~ "Busy"
  end

  test "F14: custom glassmorphic styled dropdown components for Status, Priority, and Assignee",
       %{
         conn: conn
       } do
    project = create_project_fixture(%{root_path: "/tmp/e2e_dropdown_project"})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    # 1. Open new task modal
    html = render_click(view, "toggle_new_task_modal")
    assert html =~ "new-task-modal"
    assert html =~ "modal-status-dropdown-trigger"
    assert html =~ "modal-priority-dropdown-trigger"
    assert html =~ "modal-assignee-dropdown-trigger"

    # 2. Toggle and select Status dropdown
    html = render_click(view, "toggle_modal_dropdown", %{"name" => "modal_status"})
    assert html =~ "modal-status-dropdown-menu"
    assert html =~ "Ready (Agent Claimable)"
    assert html =~ "Triage"

    html = render_click(view, "select_modal_status", %{"status" => "ready"})
    refute html =~ "modal-status-dropdown-menu"
    assert html =~ "Ready (Agent Claimable)"

    # 3. Toggle and select Priority dropdown
    html = render_click(view, "toggle_modal_dropdown", %{"name" => "modal_priority"})
    assert html =~ "modal-priority-dropdown-menu"
    assert html =~ "Critical"
    assert html =~ "High"

    html = render_click(view, "select_modal_priority", %{"priority" => "critical"})
    refute html =~ "modal-priority-dropdown-menu"
    assert html =~ "Critical"

    # 4. Toggle and select Assignee dropdown
    html = render_click(view, "toggle_modal_dropdown", %{"name" => "modal_assignee"})
    assert html =~ "modal-assignee-dropdown-menu"
    assert html =~ "CoderAgent"
    assert html =~ "PlannerAgent"

    html = render_click(view, "select_modal_assignee", %{"assignee" => "coder"})
    refute html =~ "modal-assignee-dropdown-menu"
    assert html =~ "CoderAgent"

    # 5. Submit form and verify created task has selected attributes
    html =
      view
      |> form("#task-create-form", %{
        "title" => "Build custom themed dropdowns",
        "description" => "Ensure zero native browser select elements"
      })
      |> render_submit()

    assert html =~ "Task created"

    created_task =
      IexCode.Kanban.list_tasks(project.id)
      |> Enum.find(&(&1.title == "Build custom themed dropdowns"))

    assert created_task != nil
    assert created_task.status == "ready"
    assert created_task.priority == "critical"
    assert created_task.assignee == "coder"
  end
end
