defmodule IexCodeWeb.WorkspaceLive do
  use IexCodeWeb, :live_view
  require Logger
  alias IexCode.{Projects, Runs, Sessions, Settings, Kanban, WorkspaceLocks, WorkspacePath}
  alias IexCode.Engine.SessionServer
  alias IexCode.Runs.RunDispatcher
  alias IexCode.Research.Registry, as: SearchRegistry
  alias IexCode.Tools.Git
  alias IexCode.Tools.Git.{DiffParser, HunkOps}
  alias IexCode.Tools.TerminalServer
  alias IexCodeWeb.CommandPalette
  alias Phoenix.PubSub
  import IexCodeWeb.WorkspaceComponents
  import IexCodeWeb.RunComponents

  # Terminal output is capped to the last N lines (ring buffer)
  @terminal_output_max_lines 500
  @workspace_tabs ~w(kanban swarm calendar changes tests ast chat files terminal)

  @impl true
  def mount(params, _session, socket) do
    # 1. Resolve session and project consistently (never raise on bad client params)
    {session, project, mount_error} = resolve_mount_context(params)

    today = Date.utc_today()
    today_str = Date.to_iso8601(today)

    projects = Projects.list_projects()

    if connected?(socket) do
      PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")
      PubSub.subscribe(IexCode.PubSub, "session:#{session.id}:terminal")
      Runs.subscribe_session(session.id)
      Runs.subscribe_workspace_locks(project.id)
      Kanban.subscribe(project.id)
      SessionServer.ensure_started(session.id)
      _ = TerminalServer.ensure_started(session.id, workspace_path: project.root_path)
    end

    messages = Sessions.list_messages(session.id)

    messages =
      if messages == [] do
        seed_initial_messages(session.id)
      else
        messages
      end

    operations = Sessions.list_operations(session.id)
    durable_runs = Runs.list_runs(session_id: session.id, limit: 100)
    selected_run = List.first(durable_runs)
    run_events = if selected_run, do: Runs.list_latest_events(selected_run, limit: 500), else: []
    run_steps = if selected_run, do: Runs.list_steps(selected_run), else: []
    run_approvals = if selected_run, do: Runs.list_approvals(selected_run), else: []
    run_controls = if selected_run, do: Runs.list_controls(selected_run), else: []
    pending_approval_count = Runs.count_pending_approvals(session.id)
    run_artifacts = if selected_run, do: Runs.list_artifacts(selected_run), else: []
    run_agents = if selected_run, do: Runs.list_run_agents(selected_run, limit: 100), else: []
    run_agent_receipts = run_agent_control_receipts(selected_run)
    workspace_locks = Runs.list_workspace_locks(project_id: project.id, active: true)
    settings = Settings.get_settings()
    files = list_project_files(project.root_path)
    sessions = Sessions.list_sessions_for_project(project.id)
    tasks = Kanban.list_tasks(project.id)

    # Seed initial demo tasks if empty to immediately populate Kanban
    tasks =
      if tasks == [] do
        seed_initial_tasks(project.id, session.id)
      else
        tasks
      end

    selected_task = List.first(tasks)

    terminal_state =
      case TerminalServer.get_state(session.id) do
        {:ok, st} -> st
        _ -> %{}
      end

    terminal_status = Map.get(terminal_state, :status, :ready)
    terminal_shell = Map.get(terminal_state, :shell, "zsh")
    terminal_cols = Map.get(terminal_state, :cols, 80)
    terminal_rows = Map.get(terminal_state, :rows, 24)
    terminal_occupant = Map.get(terminal_state, :occupant, :user)

    socket =
      socket
      |> assign(:page_title, "#{session.title} · #{project.name}")
      |> assign(:project, project)
      |> assign(:projects, projects)
      |> assign(:session, session)
      |> assign(:sessions, sessions)
      |> assign(:messages, messages)
      |> assign(:all_messages, messages)
      |> assign(:operations, operations)
      |> assign(:selected_run, selected_run)
      |> assign(:run_steps, run_steps)
      |> assign(:run_approvals, run_approvals)
      |> assign(:run_controls, run_controls)
      |> assign(:run_manifest, run_manifest(selected_run))
      |> assign(:run_artifacts, run_artifacts)
      |> assign(:run_agent_count, length(run_agents))
      |> assign(:run_fleet_summary, run_fleet_summary(run_agents))
      |> assign(:run_fleet_loading?, false)
      |> assign(:run_agent_guidance, %{})
      |> assign(:run_agent_receipts, run_agent_receipts)
      |> assign(:workspace_locks, workspace_locks)
      |> assign(:run_rows, durable_runs)
      |> assign(:run_event_rows, run_events)
      |> assign(:run_count, length(durable_runs))
      |> assign(:run_counts, run_counts(durable_runs, pending_approval_count))
      |> assign(:run_dispatcher_stats, safe_dispatcher_stats())
      |> assign(:dispatch_mode, "background")
      |> assign(:run_setup_open?, false)
      |> assign(:run_setup_mode, "code")
      |> assign(:run_setup_priority, "normal")
      |> assign(:run_setup_max_attempts, 3)
      |> assign(:run_setup_token_budget, nil)
      |> assign(:run_setup_cost_budget_cents, nil)
      |> assign(:run_setup_time_budget_minutes, nil)
      |> assign(:run_setup_research_depth, settings.research_depth || "standard")
      |> assign(:run_setup_research_sources, settings.research_max_sources || 12)
      |> assign(:run_setup_providers, enabled_search_providers(settings))
      |> assign(:expanded_ops, MapSet.new())
      |> assign(:active_agent, nil)
      |> assign(:active_stage, :init)
      |> assign(:settings, settings)
      |> assign(:search_provider_descriptors, SearchRegistry.descriptors())
      # "swarm", "kanban", "calendar", "changes", "chat", "files", "terminal"
      |> assign(:active_tab, "kanban")
      |> assign(:expanded_column, "running")
      |> assign(:tasks, tasks)
      |> assign(:selected_task, selected_task)
      |> assign(:show_task_drawer, false)
      |> assign(:show_new_task_modal, false)
      |> assign(:show_workspace_menu, false)
      |> assign(:workspace_search, "")
      |> assign(:kanban_filter, %{
        "status" => "",
        "priority" => "",
        "assignee" => "",
        "search" => ""
      })
      # Inline Editor assigns
      |> assign(:open_buffers, [])
      |> assign(:active_editor_path, nil)
      |> assign(:active_editor_content, nil)
      |> assign(:selected_file, nil)
      |> assign(:file_content, nil)
      |> assign(:dirty_content, nil)
      |> assign(:is_dirty?, false)
      |> assign(:file_filter, "")
      |> assign(:expanded_folders, all_directory_paths(files))
      # Interactive Diff assigns (real git state; populated by refresh_git_state below)
      |> assign(:diff_text, "")
      |> assign(:diff_mode, "inline")
      |> assign(:diff_file_path, nil)
      |> assign(:diff_hunks, [])
      |> assign(:parsed_diffs, [])
      |> assign(:selected_diff_file, nil)
      |> assign(:git_status, nil)
      |> assign(:git_error, nil)
      |> assign(:changes_subtab, "changes")
      |> assign(:project_files, files)
      |> assign(:files, files)
      # Terminal assigns
      |> assign(:terminal_output, "")
      |> assign(:terminal_running?, terminal_status in [:ready, :running])
      |> assign(:terminal_status, terminal_status)
      |> assign(:terminal_shell, terminal_shell)
      |> assign(:terminal_cols, terminal_cols)
      |> assign(:terminal_rows, terminal_rows)
      |> assign(:terminal_occupant, terminal_occupant)
      |> assign(:terminal_active_cmd, nil)
      |> assign(:terminal_port, nil)
      |> assign(:terminal_history, [
        "iex -S mix",
        "mix test",
        "mix precommit",
        "git status",
        "git diff"
      ])
      |> assign(:terminal_form, to_form(%{"command" => ""}))
      # Goal & Steering assigns
      |> assign(:show_goal_modal, false)
      |> assign(:show_cancel_modal, false)
      |> assign(:cancel_mode, "rollback")
      |> assign(:steer_text, "")
      |> assign(:submitting?, false)
      |> assign(:cancelling?, false)
      # Telemetry assigns (real values only — tokens/latency are not fabricated)
      |> assign(:session_tokens, 0)
      |> assign(:current_latency_ms, 0)
      |> assign(:active_worker_pid, nil)
      |> assign(:swarm_iteration, 1)
      |> assign(:max_retries, 3)
      |> assign(:active_tools, MapSet.new(["ast_search", "swarm"]))
      # Dropdown & Modal state
      |> assign(:open_dropdown, nil)
      |> assign(:show_settings_modal, false)
      |> assign(:show_project_modal, false)
      |> assign(:show_time_picker, false)
      |> assign(:selected_time_slot, "10:30 AM - 11:00 AM")
      |> assign(:selected_schedule_status, "Available")
      |> assign(:show_custom_time_input, false)
      |> assign(:show_scheduled_task_modal, false)
      |> assign(:show_edit_scheduled_task_modal, false)
      |> assign(:expanded_message_id, nil)
      |> assign(:selected_scheduled_task, nil)
      |> assign(:selected_calendar_date, today_str)
      |> assign(:calendar_year, today.year)
      |> assign(:calendar_month, today.month)
      |> assign(:new_task_date, today_str)
      |> assign(:show_date_picker_popover, false)
      |> assign(:picker_year, today.year)
      |> assign(:picker_month, today.month)
      |> assign(:user_availability, "Available")
      |> assign(:user_availability_subtext, "Instant notifications & swarm active")
      |> assign(:new_task_status, "scheduled")
      |> assign(:task_schedule_type, "scheduled")
      |> assign(:usage_history, Sessions.list_usage_history(10))
      |> assign(:new_task_priority, "medium")
      |> assign(:new_task_assignee, "default")
      |> assign(:open_modal_dropdown, nil)
      # Forms
      |> assign(:prompt_form, to_form(%{"prompt" => ""}))
      |> assign(:run_setup_form, to_form(run_setup_defaults(settings), as: :run_setup))
      |> assign(
        :goal_form,
        to_form(%{"title" => "", "description" => "", "auto_start" => "true"})
      )
      |> assign(
        :task_form,
        to_form(%{
          "title" => "",
          "description" => "",
          "priority" => "medium",
          "assignee" => "default",
          "steps_total" => "4",
          "status" => "ready"
        })
      )
      |> assign(:settings_form, Settings.change_settings(settings) |> to_form())
      |> assign(:project_form, to_form(%{"path" => "", "name" => ""}))
      |> assign(:terminal_form, to_form(%{"command" => "mix test"}))
      # Command Palette assigns
      |> assign(:show_command_palette, false)
      |> assign(:command_palette_query, "")
      |> assign(:command_palette_category, "all")
      |> assign(:command_palette_results, CommandPalette.search("", files, sessions, "all"))
      |> assign(:command_palette_selected_index, 0)
      # Visual Test Studio & AutoFix assigns
      |> assign(:test_runner_status, :idle)
      |> assign(:test_runner_progress_pct, 0)
      |> assign(:test_runner_progress_msg, "")
      |> assign(:test_runner_result, nil)
      |> assign(:test_runner_async_task, nil)
      |> assign(:test_runner_task_token, nil)
      |> assign(:show_autofix_modal, false)
      |> assign(:autofix_status, :idle)
      |> assign(:autofix_target_failure, nil)
      |> assign(:autofix_proposals, [])
      |> assign(:autofix_planned_patches, [])
      |> assign(:autofix_diff, nil)
      |> assign(:autofix_tx_id, nil)
      # AST Query Explorer assigns
      |> assign(:ast_query, "")
      |> assign(:ast_type_filter, "all")
      |> assign(:ast_visibility, "all")
      |> assign(:ast_scope_path, "")
      |> assign(:ast_results, [])
      |> assign(:ast_searching?, false)
      |> assign(:ast_total_count, 0)
      # Git Branch & Staging Hub assigns
      |> assign(:git_branches, [])
      |> assign(:current_branch, "main")
      |> assign(:show_branch_menu, false)
      |> assign(:commit_message, "")
      |> assign(:commit_generating?, false)
      |> assign(:git_syncing?, false)
      |> assign(:staged_diffs, [])
      |> assign(:unstaged_diffs, [])
      |> assign(:active_diff_scope, :unstaged)
      |> stream(:run_agents, run_agents, dom_id: &"run-agent-#{&1.id}")

    # Initialize live git state if git is available
    socket = refresh_git_state(socket)

    socket =
      if mount_error do
        put_flash(socket, :error, mount_error)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    if params["id"] && params["id"] != socket.assigns.session.id do
      old_id = socket.assigns.session.id
      old_project_id = socket.assigns.project.id

      case fetch_session(params["id"]) do
        nil ->
          {:noreply, put_flash(socket, :error, "Session not found")}

        new_session ->
          case fetch_project(new_session.project_id) do
            nil ->
              {:noreply, put_flash(socket, :error, "Project for this session was not found")}

            project ->
              if connected?(socket) do
                PubSub.unsubscribe(IexCode.PubSub, "session:#{old_id}")
                PubSub.unsubscribe(IexCode.PubSub, "session:#{old_id}:terminal")
                PubSub.unsubscribe(IexCode.PubSub, "runs:session:#{old_id}")
                PubSub.subscribe(IexCode.PubSub, "session:#{new_session.id}")
                PubSub.subscribe(IexCode.PubSub, "session:#{new_session.id}:terminal")
                Runs.subscribe_session(new_session.id)

                if new_session.project_id != old_project_id do
                  PubSub.unsubscribe(IexCode.PubSub, "kanban:#{old_project_id}")

                  PubSub.unsubscribe(
                    IexCode.PubSub,
                    "workspace_locks:project:#{old_project_id}"
                  )

                  Kanban.subscribe(new_session.project_id)
                  Runs.subscribe_workspace_locks(new_session.project_id)
                end

                SessionServer.ensure_started(new_session.id)

                _ =
                  TerminalServer.ensure_started(new_session.id, workspace_path: project.root_path)
              end

              messages = Sessions.list_messages(new_session.id)
              operations = Sessions.list_operations(new_session.id)
              sessions = Sessions.list_sessions_for_project(project.id)
              files = list_project_files(project.root_path)
              tasks = Kanban.list_tasks(project.id)

              terminal_state =
                case TerminalServer.get_state(new_session.id) do
                  {:ok, st} -> st
                  _ -> %{}
                end

              terminal_status = Map.get(terminal_state, :status, :ready)
              terminal_shell = Map.get(terminal_state, :shell, "zsh")
              terminal_cols = Map.get(terminal_state, :cols, 80)
              terminal_rows = Map.get(terminal_state, :rows, 24)
              terminal_occupant = Map.get(terminal_state, :occupant, :user)

              socket =
                socket
                |> assign(:session, new_session)
                |> assign(:project, project)
                |> assign(:sessions, sessions)
                |> assign(:project_files, files)
                |> assign(:tasks, tasks)
                |> assign(:page_title, "#{new_session.title} · #{project.name}")
                |> assign(:messages, messages)
                |> assign(:all_messages, messages)
                |> assign(:workspace_search, "")
                |> assign(:operations, operations)
                |> assign(:terminal_running?, terminal_status in [:ready, :running])
                |> assign(:terminal_status, terminal_status)
                |> assign(:terminal_shell, terminal_shell)
                |> assign(:terminal_cols, terminal_cols)
                |> assign(:terminal_rows, terminal_rows)
                |> assign(:terminal_occupant, terminal_occupant)
                |> assign(:terminal_active_cmd, nil)
                |> assign(:terminal_output, "")
                |> assign(
                  :workspace_locks,
                  Runs.list_workspace_locks(project_id: project.id, active: true)
                )
                |> assign_run_projection(new_session.id)
                |> refresh_git_state()

              {:noreply, socket}
          end
      end
    else
      {:noreply, socket}
    end
  end

  # ============================================================================
  # Event Handlers: Navigation & Tabs
  # ============================================================================

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) when tab in @workspace_tabs do
    socket =
      socket
      |> assign(:active_tab, tab)
      |> maybe_set_tab_dispatch_mode(tab)

    socket = if tab == "changes", do: refresh_git_state(socket), else: socket

    socket =
      if tab == "files",
        do: assign(socket, :project_files, list_project_files(socket.assigns.project.root_path)),
        else: socket

    socket = if tab == "swarm", do: refresh_run_fleet(socket), else: socket

    {:noreply, socket}
  end

  def handle_event("switch_tab", %{"tab" => _invalid}, socket), do: {:noreply, socket}

  def handle_event("switch_tab", %{"sidebar_tab" => tab}, socket)
      when tab in @workspace_tabs do
    socket =
      socket
      |> assign(:active_tab, tab)
      |> maybe_set_tab_dispatch_mode(tab)

    socket = if tab == "changes", do: refresh_git_state(socket), else: socket

    socket =
      if tab == "files",
        do: assign(socket, :project_files, list_project_files(socket.assigns.project.root_path)),
        else: socket

    socket = if tab == "swarm", do: refresh_run_fleet(socket), else: socket

    {:noreply, socket}
  end

  def handle_event("switch_tab", %{"sidebar_tab" => _invalid}, socket), do: {:noreply, socket}

  @impl true
  def handle_event("switch_changes_subtab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :changes_subtab, tab)}
  end

  @impl true
  def handle_event("toggle_dropdown", %{"name" => name}, socket) do
    new_state = if socket.assigns.open_dropdown == name, do: nil, else: name
    {:noreply, assign(socket, :open_dropdown, new_state)}
  end

  @impl true
  def handle_event("close_dropdowns", _params, socket) do
    {:noreply, assign(socket, :open_dropdown, nil)}
  end

  @impl true
  def handle_event("toggle_coach_menu", _params, socket) do
    new_state = if socket.assigns.open_dropdown == "coach_menu", do: nil, else: "coach_menu"
    {:noreply, assign(socket, :open_dropdown, new_state)}
  end

  @impl true
  def handle_event("toggle_tool", %{"tool" => tool_id}, socket) do
    tools = socket.assigns.active_tools

    new_tools =
      if MapSet.member?(tools, tool_id) do
        MapSet.delete(tools, tool_id)
      else
        MapSet.put(tools, tool_id)
      end

    {:noreply, assign(socket, :active_tools, new_tools)}
  end

  @impl true
  def handle_event("toggle_all_usage_modal", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("expand_message", %{"id" => id}, socket) do
    {:noreply, assign(socket, :expanded_message_id, id)}
  end

  @impl true
  def handle_event("close_expand_message", _params, socket) do
    {:noreply, assign(socket, :expanded_message_id, nil)}
  end

  @impl true
  def handle_event("select_kanban_filter", %{"key" => key, "value" => val}, socket) do
    current = socket.assigns.kanban_filter
    new_val = if current[key] == val, do: "", else: val
    new_filter = Map.put(current, key, new_val)
    tasks = Kanban.list_tasks(socket.assigns.project.id, new_filter)

    {:noreply,
     socket
     |> assign(:kanban_filter, new_filter)
     |> assign(:tasks, tasks)
     |> assign(:open_dropdown, nil)}
  end

  @impl true
  def handle_event("change_model", %{"provider" => provider, "model" => model}, socket) do
    case Sessions.update_session(socket.assigns.session, %{
           model_provider: provider,
           model_name: model
         }) do
      {:ok, updated_session} ->
        {:noreply,
         socket
         |> assign(:session, updated_session)
         |> assign(:open_dropdown, nil)
         |> put_flash(:info, "Model set to #{model} (#{provider})")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to set model: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("change_model", %{"model" => model_name}, socket) do
    case Sessions.update_session(socket.assigns.session, %{model_name: model_name}) do
      {:ok, session} ->
        {:noreply,
         socket
         |> assign(:session, session)
         |> assign(:open_dropdown, nil)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to set model: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("toggle_workspace_menu", _params, socket) do
    {:noreply, assign(socket, :show_workspace_menu, !socket.assigns.show_workspace_menu)}
  end

  @impl true
  def handle_event("search_workspace", %{"query" => q}, socket) do
    messages = filter_history_messages(socket.assigns.all_messages, q)

    {:noreply,
     socket
     |> assign(:workspace_search, q)
     |> assign(:messages, messages)}
  end

  @impl true
  def handle_event("open_time_picker", _params, socket) do
    {:noreply, assign(socket, :show_time_picker, true)}
  end

  @impl true
  def handle_event("close_time_picker", _params, socket) do
    {:noreply, assign(socket, :show_time_picker, false)}
  end

  @impl true
  def handle_event("select_time_slot", %{"slot" => slot}, socket) do
    {:noreply, assign(socket, :selected_time_slot, slot)}
  end

  @impl true
  def handle_event("select_schedule_status", %{"status" => status}, socket) do
    subtext =
      case status do
        "Available" -> "Instant notifications & swarm active"
        "Busy" -> "Deep focus · autonomous background mode"
        "In-meeting" -> "Collaboration window · batched summaries"
        "Offline" -> "Away · automated scheduled cron only"
        _ -> "Active"
      end

    {:noreply,
     socket
     |> assign(:selected_schedule_status, status)
     |> assign(:user_availability, status)
     |> assign(:user_availability_subtext, subtext)}
  end

  @impl true
  def handle_event("toggle_date_picker_popover", _params, socket) do
    {:noreply,
     assign(socket, :show_date_picker_popover, !socket.assigns.show_date_picker_popover)}
  end

  @impl true
  def handle_event("close_date_picker_popover", _params, socket) do
    {:noreply, assign(socket, :show_date_picker_popover, false)}
  end

  @impl true
  def handle_event("picker_prev_month", _params, socket) do
    month = socket.assigns.picker_month
    year = socket.assigns.picker_year

    {new_year, new_month} =
      if month == 1, do: {year - 1, 12}, else: {year, month - 1}

    {:noreply, socket |> assign(:picker_year, new_year) |> assign(:picker_month, new_month)}
  end

  @impl true
  def handle_event("picker_next_month", _params, socket) do
    month = socket.assigns.picker_month
    year = socket.assigns.picker_year

    {new_year, new_month} =
      if month == 12, do: {year + 1, 1}, else: {year, month + 1}

    {:noreply, socket |> assign(:picker_year, new_year) |> assign(:picker_month, new_month)}
  end

  @impl true
  def handle_event("calendar_prev_month", _params, socket) do
    month = socket.assigns.calendar_month
    year = socket.assigns.calendar_year

    {new_year, new_month} =
      if month == 1, do: {year - 1, 12}, else: {year, month - 1}

    {:noreply, socket |> assign(:calendar_year, new_year) |> assign(:calendar_month, new_month)}
  end

  @impl true
  def handle_event("calendar_next_month", _params, socket) do
    month = socket.assigns.calendar_month
    year = socket.assigns.calendar_year

    {new_year, new_month} =
      if month == 12, do: {year + 1, 1}, else: {year, month + 1}

    {:noreply, socket |> assign(:calendar_year, new_year) |> assign(:calendar_month, new_month)}
  end

  @impl true
  def handle_event("picker_select_day", %{"year" => y, "month" => m, "day" => d}, socket) do
    y_int = if is_binary(y), do: String.to_integer(y), else: y
    m_int = if is_binary(m), do: String.to_integer(m), else: m
    d_int = if is_binary(d), do: String.to_integer(d), else: d

    date = Date.new!(y_int, m_int, d_int)
    date_str = Date.to_iso8601(date)

    {:noreply,
     socket
     |> assign(:new_task_date, date_str)
     |> assign(:selected_calendar_date, date_str)
     |> assign(:picker_year, y_int)
     |> assign(:picker_month, m_int)
     |> assign(:show_date_picker_popover, false)}
  end

  @impl true
  def handle_event("picker_today", _params, socket) do
    today = Date.utc_today()
    today_str = Date.to_iso8601(today)

    {:noreply,
     socket
     |> assign(:new_task_date, today_str)
     |> assign(:selected_calendar_date, today_str)
     |> assign(:picker_year, today.year)
     |> assign(:picker_month, today.month)
     |> assign(:show_date_picker_popover, false)}
  end

  @impl true
  def handle_event("picker_clear", _params, socket) do
    {:noreply,
     socket
     |> assign(:new_task_date, "")
     |> assign(:show_date_picker_popover, false)}
  end

  @impl true
  def handle_event("toggle_custom_time", _params, socket) do
    {:noreply, assign(socket, :show_custom_time_input, !socket.assigns.show_custom_time_input)}
  end

  @impl true
  def handle_event("apply_time_picker", _params, socket) do
    slot = socket.assigns.selected_time_slot
    status = socket.assigns.selected_schedule_status
    date = socket.assigns.new_task_date

    {:noreply,
     socket
     |> assign(:show_time_picker, false)
     |> assign(:user_availability, status)
     |> put_flash(
       :info,
       "Scheduled for #{date} · #{slot} (#{status}) · Focus presence updated: #{status}"
     )}
  end

  @impl true
  def handle_event("select_calendar_day", params, socket) do
    date = params["date"] || socket.assigns.selected_calendar_date

    {:noreply,
     socket
     |> assign(:selected_calendar_date, date)
     |> assign(:new_task_date, date)
     |> assign(:show_new_task_modal, true)}
  end

  @impl true
  def handle_event("show_scheduled_task", %{"id" => task_id}, socket) do
    task = Kanban.get_task(task_id) || Enum.find(socket.assigns.tasks, &(&1.id == task_id))

    {:noreply,
     socket
     |> assign(:selected_scheduled_task, task)
     |> assign(:show_scheduled_task_modal, true)}
  end

  @impl true
  def handle_event("close_scheduled_task_modal", _params, socket) do
    {:noreply, assign(socket, :show_scheduled_task_modal, false)}
  end

  @impl true
  def handle_event("open_edit_scheduled_task", %{"id" => task_id}, socket) do
    task = Kanban.get_task(task_id) || Enum.find(socket.assigns.tasks, &(&1.id == task_id))

    {:noreply,
     socket
     |> assign(:selected_scheduled_task, task)
     |> assign(:show_edit_scheduled_task_modal, true)}
  end

  @impl true
  def handle_event("close_edit_scheduled_task", _params, socket) do
    {:noreply, assign(socket, :show_edit_scheduled_task_modal, false)}
  end

  @impl true
  def handle_event("update_scheduled_task", params, socket) do
    task_params = params["task"] || params

    id =
      task_params["id"] ||
        (socket.assigns.selected_scheduled_task && socket.assigns.selected_scheduled_task.id)

    if id do
      case Kanban.get_task(id) do
        nil ->
          {:noreply, put_flash(socket, :error, "Scheduled task not found")}

        task ->
          sched_date = task_params["scheduled_at_date"]

          sched_at =
            if sched_date && sched_date != "" do
              case Date.from_iso8601(to_string(sched_date)) do
                {:ok, date} -> DateTime.new!(date, ~T[10:30:00], "Etc/UTC")
                _ -> task.scheduled_at
              end
            else
              task.scheduled_at
            end

          attrs = %{
            title: task_params["title"] || task.title,
            description: task_params["description"] || task.description,
            priority: task_params["priority"] || task.priority,
            assignee: task_params["assignee"] || task.assignee,
            cron_expression: task_params["cron_expression"] || task.cron_expression,
            scheduled_at: sched_at
          }

          case Kanban.update_task(task, attrs) do
            {:ok, updated} ->
              tasks = Kanban.list_tasks(socket.assigns.project.id, socket.assigns.kanban_filter)

              {:noreply,
               socket
               |> assign(:tasks, tasks)
               |> assign(:selected_scheduled_task, updated)
               |> assign(:show_edit_scheduled_task_modal, false)
               |> put_flash(:info, "Scheduled task updated")}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, "Failed to update task: #{inspect(reason)}")}
          end
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("run_scheduled_task", %{"id" => task_id}, socket) do
    case Kanban.get_task(task_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Scheduled task not found")}

      task ->
        prompt = """
        [scheduled-task] #{task.title}
        #{task.description || "No description provided."}
        """

        run_attrs = %{
          project_id: socket.assigns.project.id,
          session_id: socket.assigns.session.id,
          objective: String.trim(prompt),
          kind: "coding_swarm",
          mode: "swarm",
          priority: task_priority_to_run_priority(task.priority),
          metadata: %{"source" => "scheduled_task", "kanban_task_id" => task.id}
        }

        case RunDispatcher.enqueue(run_attrs) do
          {:ok, run} ->
            {:ok, updated} =
              Kanban.update_task(task, %{status: "running", worker_pid: "run:#{run.id}"})

            tasks = Kanban.list_tasks(socket.assigns.project.id, socket.assigns.kanban_filter)

            {:noreply,
             socket
             |> assign(:tasks, tasks)
             |> assign(:selected_task, updated)
             |> assign(:show_scheduled_task_modal, false)
             |> select_run_projection(run)
             |> assign(:active_tab, "swarm")
             |> put_flash(
               :info,
               "Task '#{task.title}' dispatched to the session via the durable run queue"
             )}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Failed to queue task: #{format_run_error(reason)}")}
        end
    end
  end

  def handle_event("run_scheduled_task_now", %{"id" => task_id}, socket) do
    handle_event("run_scheduled_task", %{"id" => task_id}, socket)
  end

  @impl true
  def handle_event("delete_scheduled_task", %{"id" => task_id}, socket) do
    case Kanban.get_task(task_id) do
      nil ->
        {:noreply, socket}

      task ->
        case Kanban.delete_task(task) do
          {:ok, _deleted} ->
            tasks = Kanban.list_tasks(socket.assigns.project.id, socket.assigns.kanban_filter)

            {:noreply,
             socket
             |> assign(:tasks, tasks)
             |> assign(:show_scheduled_task_modal, false)
             |> put_flash(:info, "Scheduled task removed")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to remove task: #{inspect(reason)}")}
        end
    end
  end

  @impl true
  def handle_event("set_task_schedule_type", %{"type" => type}, socket) do
    {:noreply,
     socket
     |> assign(:task_schedule_type, type)
     |> assign(:new_task_status, type)}
  end

  def handle_event("set_task_schedule_type", params, socket) do
    type = params["type"] || params["schedule_type"] || "scheduled"

    {:noreply,
     socket
     |> assign(:task_schedule_type, type)
     |> assign(:new_task_status, type)}
  end

  @impl true
  def handle_event("toggle_folder", %{"path" => path}, socket) do
    expanded = socket.assigns.expanded_folders || MapSet.new()

    new_expanded =
      if MapSet.member?(expanded, path) do
        MapSet.delete(expanded, path)
      else
        MapSet.put(expanded, path)
      end

    {:noreply, assign(socket, :expanded_folders, new_expanded)}
  end

  @impl true
  def handle_event("insert_code_to_editor", %{"code" => code}, socket) do
    file_path = socket.assigns.selected_file

    if file_path do
      current = socket.assigns.dirty_content || socket.assigns.file_content || ""

      new_text =
        cond do
          current == "" -> code
          String.ends_with?(current, "\n") -> current <> code <> "\n"
          true -> current <> "\n\n" <> code <> "\n"
        end

      buffers =
        Enum.map(socket.assigns.open_buffers, fn b ->
          if b.path == file_path do
            %{b | dirty_content: new_text, dirty?: true}
          else
            b
          end
        end)

      {:noreply,
       socket
       |> assign(:dirty_content, new_text)
       |> assign(:is_dirty?, true)
       |> assign(:open_buffers, buffers)
       |> put_flash(:info, "Inserted snippet into #{file_path}")}
    else
      {:noreply,
       put_flash(socket, :error, "No active file buffer. Open a file in the editor first.")}
    end
  end

  @impl true
  def handle_event("scroll_to_msg", %{"id" => id}, socket) do
    {:noreply, push_event(socket, "scroll_to_msg", %{id: id})}
  end

  # ============================================================================
  # Event Handlers: Inline Code Editor (Files View)
  # ============================================================================

  @impl true
  def handle_event("filter_files", %{"filter" => filter}, socket) do
    {:noreply, assign(socket, :file_filter, filter)}
  end

  @impl true
  def handle_event("search_files", %{"query" => query}, socket) do
    {:noreply, assign(socket, :file_filter, query)}
  end

  @impl true
  def handle_event("select_file", %{"path" => rel_path}, socket) do
    socket =
      socket
      |> open_file_buffer(rel_path)
      |> assign(:active_tab, "files")

    {:noreply, socket}
  end

  @impl true
  def handle_event("file_content_changed", %{"content" => new_text}, socket) do
    current_orig = socket.assigns.file_content || ""
    is_dirty = new_text != current_orig
    file_path = socket.assigns.selected_file

    buffers =
      Enum.map(socket.assigns.open_buffers, fn b ->
        if b.path == file_path do
          %{b | dirty_content: new_text, dirty?: is_dirty}
        else
          b
        end
      end)

    {:noreply,
     socket
     |> assign(:dirty_content, new_text)
     |> assign(:is_dirty?, is_dirty)
     |> assign(:open_buffers, buffers)}
  end

  @impl true
  def handle_event("save_file", params, socket) do
    file_path = socket.assigns.selected_file

    content =
      case params["content"] do
        text when is_binary(text) -> text
        _ -> socket.assigns.dirty_content || socket.assigns.file_content || ""
      end

    if file_path do
      # The hotkey can deliver content before the preceding input event reaches
      # the server. Keep that exact buffer even when authorization is denied.
      socket = put_active_buffer_content(socket, content)

      case save_editor_file(socket, file_path, content) do
        :ok ->
          buffers =
            Enum.map(socket.assigns.open_buffers, fn b ->
              if b.path == file_path do
                %{b | content: content, dirty_content: content, dirty?: false}
              else
                b
              end
            end)

          files = list_project_files(socket.assigns.project.root_path)

          {:noreply,
           socket
           |> assign(:file_content, content)
           |> assign(:dirty_content, content)
           |> assign(:is_dirty?, false)
           |> assign(:open_buffers, buffers)
           |> assign(:project_files, files)
           |> refresh_git_state()
           |> put_flash(:info, "Saved #{file_path}")}

        {:error, {:workspace_lock_waiting, _locks}} ->
          {:noreply,
           socket
           |> refresh_workspace_locks()
           |> put_flash(
             :error,
             "Save blocked: another session owns the workspace lock. Your changes are still in the editor."
           )}

        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Failed to save file: #{editor_save_error(reason)}. Your changes are still in the editor."
           )}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("retry_file_lock", _params, socket) do
    socket = refresh_workspace_locks(socket)

    case editor_lock(socket.assigns) do
      nil ->
        {:noreply,
         put_flash(socket, :info, "The file is available. You can save your changes now.")}

      _lock ->
        {:noreply, put_flash(socket, :error, "The file is still locked by another session.")}
    end
  end

  @impl true
  def handle_event("revert_file_buffer", _params, socket) do
    orig = socket.assigns.file_content || ""
    file_path = socket.assigns.selected_file

    buffers =
      Enum.map(socket.assigns.open_buffers, fn b ->
        if b.path == file_path do
          %{b | dirty_content: orig, dirty?: false}
        else
          b
        end
      end)

    {:noreply,
     socket
     |> assign(:dirty_content, orig)
     |> assign(:is_dirty?, false)
     |> assign(:open_buffers, buffers)
     |> put_flash(:info, "Reverted unsaved edits in #{file_path}")}
  end

  @impl true
  def handle_event("close_file_buffer", %{"path" => path}, socket) do
    buffers = Enum.reject(socket.assigns.open_buffers, &(&1.path == path))

    {selected, content, dirty_content, is_dirty} =
      if socket.assigns.selected_file == path do
        case buffers do
          [first | _] ->
            {first.path, first.content, first.dirty_content, first.dirty?}

          [] ->
            {nil, nil, nil, false}
        end
      else
        {socket.assigns.selected_file, socket.assigns.file_content, socket.assigns.dirty_content,
         socket.assigns.is_dirty?}
      end

    {:noreply,
     socket
     |> assign(:open_buffers, buffers)
     |> assign(:selected_file, selected)
     |> assign(:file_content, content)
     |> assign(:dirty_content, dirty_content)
     |> assign(:is_dirty?, is_dirty)}
  end

  @impl true
  def handle_event("refresh_files", _params, socket) do
    files = list_project_files(socket.assigns.project.root_path)

    new_expanded =
      MapSet.union(
        socket.assigns.expanded_folders || MapSet.new(),
        all_directory_paths(files)
      )

    {:noreply,
     socket
     |> assign(:project_files, files)
     |> assign(:expanded_folders, new_expanded)}
  end

  # ============================================================================
  # Event Handlers: Interactive Diff Hunk Viewer & Git Changes
  # ============================================================================

  @impl true
  def handle_event("set_diff_mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, :diff_mode, mode)}
  end

  @impl true
  def handle_event("select_diff_file", params, socket) do
    file_path = params["file"] || params["path"]
    root = socket.assigns.project.root_path

    if file_path do
      # Find in parsed_diffs
      matching_diff =
        Enum.find(
          socket.assigns.parsed_diffs,
          &(&1.path == file_path or &1.new_path == file_path or &1.old_path == file_path)
        )

      {hunks, diff_text} =
        if matching_diff do
          formatted =
            Enum.map_join(
              matching_diff.hunks,
              "\n",
              &DiffParser.format_hunk_patch(matching_diff, &1)
            )

          {matching_diff.hunks, formatted}
        else
          case Git.diff(root, paths: [file_path], unified: 3) do
            {:ok, raw} when is_binary(raw) and raw != "" ->
              case DiffParser.parse(raw) do
                {:ok, [fd | _]} -> {fd.hunks, raw}
                _ -> {[], raw}
              end

            _ ->
              {[], ""}
          end
        end

      {:noreply,
       socket
       |> assign(:selected_diff_file, file_path)
       |> assign(:diff_file_path, file_path)
       |> assign(:diff_hunks, hunks)
       |> assign(:diff_text, diff_text)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("accept_hunk", %{"file" => file, "hunk_id" => hunk_id}, socket) do
    root = socket.assigns.project.root_path

    case with_ui_mutation_lock(socket, fn ->
           HunkOps.accept_hunk(root, file, hunk_id, diff: socket.assigns.diff_text)
         end) do
      {:ok, _} ->
        {:noreply,
         socket
         |> refresh_git_state()
         |> put_flash(:info, "Accepted hunk #{hunk_id} for #{file}")}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Failed to accept hunk: #{ui_mutation_error(reason)}")}
    end
  end

  @impl true
  def handle_event("reject_hunk", %{"file" => file, "hunk_id" => hunk_id}, socket) do
    root = socket.assigns.project.root_path

    case with_ui_mutation_lock(socket, fn ->
           HunkOps.reject_hunk(root, file, hunk_id, diff: socket.assigns.diff_text)
         end) do
      {:ok, _} ->
        {:noreply,
         socket
         |> refresh_git_state()
         |> put_flash(:info, "Reverted hunk #{hunk_id} in #{file}")}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Failed to revert hunk: #{ui_mutation_error(reason)}")}
    end
  end

  @impl true
  def handle_event("revert_hunk", params, socket), do: handle_event("reject_hunk", params, socket)

  @impl true
  def handle_event("accept_all_hunks", %{"file" => file}, socket) do
    root = socket.assigns.project.root_path

    case with_ui_mutation_lock(socket, fn -> HunkOps.accept_all_hunks(root, file) end) do
      {:ok, _} ->
        {:noreply,
         socket
         |> refresh_git_state()
         |> put_flash(:info, "Staged all changes for #{file}")}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Failed to stage changes: #{ui_mutation_error(reason)}")}
    end
  end

  @impl true
  def handle_event("revert_file", %{"file" => file}, socket) do
    root = socket.assigns.project.root_path

    case with_ui_mutation_lock(socket, fn -> HunkOps.revert_file(root, file) end) do
      {:ok, _} ->
        # If the file is open in editor, reload content
        socket =
          if socket.assigns.selected_file == file do
            full_path = Path.join(root, file)
            content = if File.exists?(full_path), do: File.read!(full_path), else: ""

            socket
            |> assign(:file_content, content)
            |> assign(:dirty_content, content)
            |> assign(:is_dirty?, false)
          else
            socket
          end

        {:noreply,
         socket
         |> refresh_git_state()
         |> put_flash(:info, "Reverted #{file} to clean git working state")}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Failed to revert file: #{ui_mutation_error(reason)}")}
    end
  end

  # ============================================================================
  # Event Handlers: Global Command Palette (Cmd+K)
  # ============================================================================

  @impl true
  def handle_event("toggle_command_palette", _params, socket) do
    new_show = !socket.assigns.show_command_palette
    query = if new_show, do: "", else: socket.assigns.command_palette_query
    files = socket.assigns[:project_files] || []
    sessions = socket.assigns[:sessions] || []

    results =
      if new_show,
        do: CommandPalette.search("", files, sessions, socket.assigns.command_palette_category),
        else: []

    socket =
      socket
      |> assign(:show_command_palette, new_show)
      |> assign(:command_palette_query, query)
      |> assign(:command_palette_results, results)
      |> assign(:command_palette_selected_index, 0)

    socket = if new_show, do: push_event(socket, "focus_palette_input", %{}), else: socket
    {:noreply, socket}
  end

  @impl true
  def handle_event("close_command_palette", _params, socket) do
    {:noreply, assign(socket, :show_command_palette, false)}
  end

  @impl true
  def handle_event("command_palette_search", %{"query" => query}, socket) do
    files = socket.assigns[:project_files] || []
    sessions = socket.assigns[:sessions] || []

    results =
      CommandPalette.search(query, files, sessions, socket.assigns.command_palette_category)

    {:noreply,
     socket
     |> assign(:command_palette_query, query)
     |> assign(:command_palette_results, results)
     |> assign(:command_palette_selected_index, 0)}
  end

  @impl true
  def handle_event("command_palette_set_category", %{"category" => category}, socket) do
    files = socket.assigns[:project_files] || []
    sessions = socket.assigns[:sessions] || []

    results =
      CommandPalette.search(socket.assigns.command_palette_query, files, sessions, category)

    {:noreply,
     socket
     |> assign(:command_palette_category, category)
     |> assign(:command_palette_results, results)
     |> assign(:command_palette_selected_index, 0)}
  end

  @impl true
  def handle_event("command_palette_navigate", %{"direction" => dir}, socket) do
    results = socket.assigns.command_palette_results
    count = length(results)

    if count == 0 do
      {:noreply, socket}
    else
      curr = socket.assigns.command_palette_selected_index

      new_index =
        case dir do
          "down" -> rem(curr + 1, count)
          "up" -> if curr <= 0, do: count - 1, else: curr - 1
          _ -> curr
        end

      {:noreply,
       socket
       |> assign(:command_palette_selected_index, new_index)
       |> push_event("scroll_to_palette_item", %{index: new_index})}
    end
  end

  @impl true
  def handle_event("command_palette_execute_selected", _params, socket) do
    results = socket.assigns.command_palette_results
    index = socket.assigns.command_palette_selected_index
    item = Enum.at(results, index)

    if item do
      execute_command_palette_item(socket, item)
    else
      {:noreply, assign(socket, :show_command_palette, false)}
    end
  end

  @impl true
  def handle_event("command_palette_select_item", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    item = Enum.at(socket.assigns.command_palette_results, index)

    if item do
      execute_command_palette_item(socket, item)
    else
      {:noreply, assign(socket, :show_command_palette, false)}
    end
  end

  # ============================================================================
  # Event Handlers: Visual Test Runner & 1-Click AutoFix Studio
  # ============================================================================

  @impl true
  def handle_event("run_tests", params, socket) do
    if socket.assigns.test_runner_async_task do
      {:noreply,
       put_flash(
         socket,
         :error,
         "A test run is already in progress. Wait for it to finish before retrying."
       )}
    else
      start_test_runner(params, socket)
    end
  end

  @impl true
  def handle_event("autofix_failure", %{"index" => idx_str}, socket) do
    idx = String.to_integer(idx_str)
    result = socket.assigns.test_runner_result

    failure =
      if result do
        Enum.find(result.failures, fn f -> f.index == idx end) ||
          Enum.find(result.compilation_errors, fn ce -> to_string(ce.line) == idx_str end)
      end

    if is_nil(failure) do
      {:noreply, put_flash(socket, :error, "Failure ##{idx} not found in current test results")}
    else
      project_root = socket.assigns.project.root_path

      case IexCode.Tools.AutoFix.generate_patch_proposals(project_root, failure) do
        {:ok, []} ->
          {:noreply,
           socket
           |> put_flash(:error, "No heuristic AutoFix patch could be formulated for this error.")}

        {:ok, proposals} ->
          case IexCode.Tools.MultiPatch.preview_patches(project_root, proposals) do
            {:ok, %{diff: diff_str, patches: planned}} ->
              {:noreply,
               socket
               |> assign(:show_autofix_modal, true)
               |> assign(:autofix_status, :proposal_ready)
               |> assign(:autofix_target_failure, failure)
               |> assign(:autofix_proposals, proposals)
               |> assign(:autofix_planned_patches, planned)
               |> assign(:autofix_diff, diff_str)
               |> assign(:autofix_tx_id, nil)}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, "Preview error: #{inspect(reason)}")}
          end

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "AutoFix error: #{inspect(reason)}")}
      end
    end
  end

  @impl true
  def handle_event("apply_autofix_patch", _params, socket) do
    project_root = socket.assigns.project.root_path
    planned = socket.assigns.autofix_planned_patches
    proposals = socket.assigns.autofix_proposals
    target_failure = socket.assigns.autofix_target_failure

    if planned == [] do
      {:noreply, socket |> assign(:show_autofix_modal, false)}
    else
      lock_opts = [
        project_id: socket.assigns.project.id,
        session_id: socket.assigns.session.id
      ]

      case IexCode.Tools.multi_patch(proposals, project_root, lock_opts) do
        {:ok, %{applied: _count, transaction_id: tx_id}} ->
          socket =
            socket
            |> assign(:show_autofix_modal, false)
            |> assign(:autofix_status, :applied)
            |> assign(:autofix_tx_id, tx_id)
            |> refresh_git_state()

          socket =
            if target_failure && Map.get(target_failure, :file) do
              file = Map.get(target_failure, :file)
              line = Map.get(target_failure, :line)

              {:noreply, s} =
                handle_event(
                  "run_tests",
                  %{"mode" => "file", "file" => file, "line" => to_string(line)},
                  socket
                )

              s
            else
              socket
            end

          {:noreply, socket |> put_flash(:info, "AutoFix patch applied successfully!")}

        {:error, {:workspace_lock_waiting, _locks} = reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Failed to apply patch: #{ui_mutation_error(reason)}"
           )}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:autofix_status, :failed)
           |> put_flash(:error, "Failed to apply patch: #{ui_mutation_error(reason)}")}
      end
    end
  end

  @impl true
  def handle_event("rollback_autofix", _params, socket) do
    tx_id = socket.assigns.autofix_tx_id

    if tx_id do
      lock_opts = [
        project_id: socket.assigns.project.id,
        session_id: socket.assigns.session.id
      ]

      case IexCode.Tools.rollback_multi_patch(tx_id, socket.assigns.project.root_path, lock_opts) do
        {:ok, _} ->
          socket =
            socket
            |> assign(:show_autofix_modal, false)
            |> assign(:autofix_status, :rolled_back)
            |> assign(:autofix_tx_id, nil)
            |> refresh_git_state()

          {:noreply, socket |> put_flash(:info, "AutoFix patch rolled back successfully.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Rollback failed: #{ui_mutation_error(reason)}")}
      end
    else
      {:noreply, assign(socket, :show_autofix_modal, false)}
    end
  end

  @impl true
  def handle_event("close_autofix_modal", _params, socket) do
    {:noreply, assign(socket, :show_autofix_modal, false)}
  end

  # ============================================================================
  # Event Handlers: AST Query Explorer & Symbol Navigator
  # ============================================================================

  @impl true
  def handle_event("search_ast_symbols", %{"query" => query} = params, socket) do
    root = socket.assigns.project.root_path
    type_filter = params["type"] || socket.assigns.ast_type_filter
    vis_filter = params["visibility"] || socket.assigns.ast_visibility

    query_spec =
      %{
        query: query,
        type: if(type_filter != "all", do: type_filter, else: nil),
        visibility: if(vis_filter != "all", do: vis_filter, else: nil)
      }
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Map.new()

    results =
      case IexCode.Tools.ASTSearch.search(root, query_spec, limit: 100) do
        {:ok, res} -> res
        _ -> []
      end

    {:noreply,
     socket
     |> assign(:ast_query, query)
     |> assign(:ast_results, results)
     |> assign(:ast_total_count, length(results))}
  end

  @impl true
  def handle_event("set_ast_type_filter", %{"type" => type_filter}, socket) do
    root = socket.assigns.project.root_path
    query = socket.assigns.ast_query
    vis_filter = socket.assigns.ast_visibility

    query_spec =
      %{
        query: query,
        type: if(type_filter != "all", do: type_filter, else: nil),
        visibility: if(vis_filter != "all", do: vis_filter, else: nil)
      }
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Map.new()

    results =
      case IexCode.Tools.ASTSearch.search(root, query_spec, limit: 100) do
        {:ok, []} when is_binary(query) and query != "" ->
          case IexCode.Tools.ASTSearch.search(root, Map.delete(query_spec, :query), limit: 100) do
            {:ok, res} -> res
            _ -> []
          end

        {:ok, res} ->
          res

        _ ->
          []
      end

    {:noreply,
     socket
     |> assign(:ast_type_filter, type_filter)
     |> assign(:ast_results, results)
     |> assign(:ast_total_count, length(results))}
  end

  @impl true
  def handle_event("set_ast_visibility", %{"visibility" => vis}, socket) do
    root = socket.assigns.project.root_path
    query = socket.assigns.ast_query
    type_filter = socket.assigns.ast_type_filter

    query_spec =
      %{
        query: query,
        type: if(type_filter != "all", do: type_filter, else: nil),
        visibility: if(vis != "all", do: vis, else: nil)
      }
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Map.new()

    results =
      case IexCode.Tools.ASTSearch.search(root, query_spec, limit: 100) do
        {:ok, res} -> res
        _ -> []
      end

    {:noreply,
     socket
     |> assign(:ast_visibility, vis)
     |> assign(:ast_results, results)
     |> assign(:ast_total_count, length(results))}
  end

  @impl true
  def handle_event("jump_to_symbol", %{"path" => rel_path, "line" => line_str}, socket) do
    line = String.to_integer(line_str)

    socket =
      socket
      |> open_file_buffer(rel_path)
      |> assign(:active_tab, "files")
      |> push_event("jump_to_editor_line", %{line: line, file: rel_path})

    {:noreply, socket}
  end

  # ============================================================================
  # Event Handlers: Git Branch & Multi-File Staging Hub
  # ============================================================================

  @impl true
  def handle_event("toggle_branch_menu", _params, socket) do
    {:noreply, assign(socket, :show_branch_menu, !socket.assigns.show_branch_menu)}
  end

  @impl true
  def handle_event("switch_git_branch", %{"branch" => branch}, socket) do
    root = socket.assigns.project.root_path

    case with_ui_mutation_lock(socket, fn -> Git.switch_branch(root, branch) end) do
      {:ok, _} ->
        socket =
          socket
          |> assign(:show_branch_menu, false)
          |> refresh_git_state()
          |> put_flash(:info, "Switched to branch #{branch}")

        {:noreply, socket}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Failed to switch branch: #{ui_mutation_error(reason)}")}
    end
  end

  @impl true
  def handle_event("create_git_branch", params, socket) do
    name = params["name"] || params["branch_name"] || ""
    name = String.trim(name)

    if name == "" do
      {:noreply, put_flash(socket, :error, "Branch name cannot be empty")}
    else
      root = socket.assigns.project.root_path

      case with_ui_mutation_lock(socket, fn -> Git.create_branch(root, name) end) do
        {:ok, _} ->
          socket =
            socket
            |> assign(:show_branch_menu, false)
            |> refresh_git_state()
            |> put_flash(:info, "Created and checked out branch #{name}")

          {:noreply, socket}

        {:error, reason} ->
          {:noreply,
           put_flash(socket, :error, "Failed to create branch: #{ui_mutation_error(reason)}")}
      end
    end
  end

  @impl true
  def handle_event("git_fetch", _params, socket) do
    root = socket.assigns.project.root_path

    case with_ui_mutation_lock(socket, fn -> Git.fetch(root) end) do
      {:ok, _} ->
        {:noreply,
         socket |> refresh_git_state() |> put_flash(:info, "Fetched latest remote updates")}

      {:error, reason} ->
        {:noreply,
         socket
         |> refresh_git_state()
         |> put_flash(:error, "Fetch failed: #{ui_mutation_error(reason)}")}
    end
  end

  @impl true
  def handle_event("git_pull", _params, socket) do
    root = socket.assigns.project.root_path

    case with_ui_mutation_lock(socket, fn -> Git.pull(root) end) do
      {:ok, _} ->
        {:noreply,
         socket |> refresh_git_state() |> put_flash(:info, "Pulled latest changes from remote")}

      {:error, reason} ->
        {:noreply,
         socket
         |> refresh_git_state()
         |> put_flash(:error, "Pull failed: #{ui_mutation_error(reason)}")}
    end
  end

  @impl true
  def handle_event("stage_file", %{"file" => file}, socket) do
    root = socket.assigns.project.root_path

    case with_ui_mutation_lock(socket, fn -> Git.stage(file, root) end) do
      :ok ->
        {:noreply, refresh_git_state(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Staging failed: #{ui_mutation_error(reason)}")}
    end
  end

  @impl true
  def handle_event("unstage_file", %{"file" => file}, socket) do
    root = socket.assigns.project.root_path

    case with_ui_mutation_lock(socket, fn -> Git.unstage(file, root) end) do
      :ok ->
        {:noreply, refresh_git_state(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Unstaging failed: #{ui_mutation_error(reason)}")}
    end
  end

  @impl true
  def handle_event("stage_all", _params, socket) do
    root = socket.assigns.project.root_path

    case with_ui_mutation_lock(socket, fn -> Git.stage(:all, root) end) do
      :ok ->
        {:noreply, refresh_git_state(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Stage all failed: #{ui_mutation_error(reason)}")}
    end
  end

  @impl true
  def handle_event("unstage_all", _params, socket) do
    root = socket.assigns.project.root_path

    case with_ui_mutation_lock(socket, fn -> Git.unstage(:all, root) end) do
      :ok ->
        {:noreply, refresh_git_state(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Unstage all failed: #{ui_mutation_error(reason)}")}
    end
  end

  @impl true
  def handle_event("unstage_hunk", %{"file" => file, "hunk_id" => hunk_id}, socket) do
    root = socket.assigns.project.root_path

    case with_ui_mutation_lock(socket, fn -> HunkOps.unstage_hunk(root, file, hunk_id) end) do
      {:ok, _diff} ->
        {:noreply, refresh_git_state(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Unstage hunk failed: #{ui_mutation_error(reason)}")}
    end
  end

  @impl true
  def handle_event("update_commit_message", params, socket) do
    msg = params["message"] || params["commit_message"] || ""
    {:noreply, assign(socket, :commit_message, msg)}
  end

  @impl true
  def handle_event("generate_commit_msg", _params, socket) do
    root = socket.assigns.project.root_path

    case Git.generate_commit_message(root) do
      {:ok, msg} ->
        {:noreply, assign(socket, :commit_message, msg)}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Failed to generate commit message: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("git_commit", _params, socket) do
    root = socket.assigns.project.root_path
    msg = String.trim(socket.assigns.commit_message || "")

    if msg == "" do
      {:noreply, put_flash(socket, :error, "Please enter a commit message")}
    else
      case with_ui_mutation_lock(socket, fn -> Git.commit(root, msg) end) do
        {:ok, _result} ->
          socket =
            socket
            |> assign(:commit_message, "")
            |> refresh_git_state()
            |> put_flash(:info, "Changes committed successfully!")

          {:noreply, socket}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Commit failed: #{ui_mutation_error(reason)}")}
      end
    end
  end

  # ============================================================================
  # Event Handlers: Goal Lifecycle & Steering Controls
  # ============================================================================

  @impl true
  def handle_event("open_goal_modal", _params, socket) do
    {:noreply, assign(socket, :show_goal_modal, true)}
  end

  @impl true
  def handle_event("close_goal_modal", _params, socket) do
    {:noreply, assign(socket, :show_goal_modal, false)}
  end

  @impl true
  def handle_event("create_goal", params, socket) do
    if socket.assigns.submitting? do
      {:noreply, socket}
    else
      goal_params = params["goal"] || params
      title = goal_params["title"] || ""
      desc = goal_params["description"] || ""
      auto_start = goal_params["auto_start"] != "false"

      if String.trim(to_string(title)) != "" do
        socket = assign(socket, :submitting?, true)

        socket =
          try do
            {:ok, _goal} =
              SessionServer.create_goal(
                socket.assigns.session.id,
                %{title: String.trim(title), description: desc},
                auto_start: auto_start
              )

            socket
            |> assign(:show_goal_modal, false)
            |> assign(:active_tab, "swarm")
            |> put_flash(
              :info,
              "Goal created#{if auto_start, do: " and autonomous swarm launched", else: ""}"
            )
          rescue
            e ->
              Logger.error("create_goal failed: #{Exception.message(e)}")
              put_flash(socket, :error, "Failed to create goal: #{Exception.message(e)}")
          catch
            :exit, {:timeout, _} ->
              put_flash(socket, :error, "Creating the goal timed out — try again shortly")

            :exit, reason ->
              put_flash(socket, :error, "Failed to create goal: #{inspect(reason)}")
          end

        {:noreply, assign(socket, :submitting?, false)}
      else
        {:noreply, put_flash(socket, :error, "Goal title is required")}
      end
    end
  end

  @impl true
  def handle_event("pause_session", _params, socket) do
    SessionServer.pause_session(socket.assigns.session.id)
    updated_session = %{socket.assigns.session | status: "paused"}

    {:noreply,
     socket
     |> assign(:session, updated_session)
     |> put_flash(:info, "Swarm execution paused")}
  end

  @impl true
  def handle_event("resume_session", _params, socket) do
    SessionServer.resume_session(socket.assigns.session.id)
    updated_session = %{socket.assigns.session | status: "running"}

    {:noreply,
     socket
     |> assign(:session, updated_session)
     |> put_flash(:info, "Swarm execution resumed")}
  end

  @impl true
  def handle_event("toggle_session_pause", _params, socket) do
    if socket.assigns.session.status in ["running", :running] do
      handle_event("pause_session", %{}, socket)
    else
      handle_event("resume_session", %{}, socket)
    end
  end

  def handle_event("toggle_goal_pause", params, socket),
    do: handle_event("toggle_session_pause", params, socket)

  @impl true
  def handle_event("open_cancel_modal", _params, socket) do
    {:noreply, assign(socket, :show_cancel_modal, true)}
  end

  @impl true
  def handle_event("close_cancel_modal", _params, socket) do
    {:noreply, assign(socket, :show_cancel_modal, false)}
  end

  @impl true
  def handle_event("cancel_session", params, socket) do
    if socket.assigns.cancelling? do
      {:noreply, socket}
    else
      mode = params["mode"] || socket.assigns.cancel_mode || "rollback"

      opts =
        if mode == "commit" do
          [
            action: :commit,
            commit_message: params["commit_message"] || "Cancelled session commit"
          ]
        else
          [action: :rollback]
        end

      socket = assign(socket, :cancelling?, true)

      socket =
        try do
          SessionServer.cancel_session(socket.assigns.session.id, opts)

          socket
          |> assign(:session, %{socket.assigns.session | status: "stopped"})
          |> assign(:show_cancel_modal, false)
          |> put_flash(:info, "Session stopped (#{mode} executed)")
        rescue
          e ->
            Logger.error("cancel_session failed: #{Exception.message(e)}")
            put_flash(socket, :error, "Failed to stop session: #{Exception.message(e)}")
        catch
          :exit, {:timeout, _} ->
            put_flash(
              socket,
              :error,
              "Stopping the session timed out — it may still be running, try again"
            )

          :exit, reason ->
            put_flash(socket, :error, "Failed to stop session: #{inspect(reason)}")
        end

      {:noreply, assign(socket, :cancelling?, false)}
    end
  end

  @impl true
  def handle_event("send_steering", params, socket) do
    text = String.trim(params["steering"] || params["text"] || "")

    if text != "" do
      SessionServer.send_steering(socket.assigns.session.id, text)

      {:noreply,
       socket
       |> assign(:steer_text, "")
       |> put_flash(:info, "Steering guidance delivered to active swarm")}
    else
      {:noreply, socket}
    end
  end

  # ============================================================================
  # Event Handlers: Kanban & Tasks
  # ============================================================================

  @impl true
  def handle_event("open_task_drawer", %{"id" => task_id}, socket) do
    task = Kanban.get_task(task_id)
    {:noreply, socket |> assign(:selected_task, task) |> assign(:show_task_drawer, true)}
  end

  @impl true
  def handle_event("close_task_drawer", _params, socket) do
    {:noreply, assign(socket, :show_task_drawer, false)}
  end

  @impl true
  def handle_event("toggle_new_task_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_new_task_modal, !socket.assigns.show_new_task_modal)
     |> assign(:open_modal_dropdown, nil)}
  end

  @impl true
  def handle_event("toggle_modal_dropdown", %{"name" => name}, socket) do
    new_state = if socket.assigns.open_modal_dropdown == name, do: nil, else: name
    {:noreply, assign(socket, :open_modal_dropdown, new_state)}
  end

  @impl true
  def handle_event("select_modal_status", %{"status" => status}, socket) do
    {:noreply, socket |> assign(:new_task_status, status) |> assign(:open_modal_dropdown, nil)}
  end

  @impl true
  def handle_event("select_modal_priority", %{"priority" => priority}, socket) do
    {:noreply,
     socket |> assign(:new_task_priority, priority) |> assign(:open_modal_dropdown, nil)}
  end

  @impl true
  def handle_event("select_modal_assignee", %{"assignee" => assignee}, socket) do
    {:noreply,
     socket |> assign(:new_task_assignee, assignee) |> assign(:open_modal_dropdown, nil)}
  end

  @impl true
  def handle_event("create_task", params, socket) do
    params = params["task"] || params[:task] || params
    title = params["title"] || params[:title] || ""
    sched_date = params["scheduled_at_date"] || params[:scheduled_at_date]
    status = params["status"] || params[:status] || socket.assigns.new_task_status || "ready"

    priority =
      params["priority"] || params[:priority] || socket.assigns.new_task_priority || "medium"

    assignee =
      params["assignee"] || params[:assignee] || socket.assigns.new_task_assignee || "default"

    cron_expr = params["cron_expression"] || params[:cron_expression]
    steps_total = params["steps_total"] || params[:steps_total] || "4"
    tag = params["tag"] || params[:tag]

    if String.trim(to_string(title)) != "" do
      scheduled_at =
        if sched_date && to_string(sched_date) != "" do
          case Date.from_iso8601(to_string(sched_date)) do
            {:ok, date} -> DateTime.new!(date, ~T[10:30:00], "Etc/UTC")
            _ -> nil
          end
        else
          if status == "scheduled" do
            DateTime.utc_now() |> DateTime.add(3600 * 24, :second)
          else
            nil
          end
        end

      steps_count =
        case Integer.parse(to_string(steps_total)) do
          {n, _} when n > 0 -> n
          _ -> 4
        end

      attrs = %{
        project_id: socket.assigns.project.id,
        session_id: socket.assigns.session.id,
        title: String.trim(to_string(title)),
        description: params["description"] || params[:description],
        priority: priority,
        assignee: assignee,
        status: status,
        scheduled_at: scheduled_at,
        cron_expression: cron_expr,
        steps_total: steps_count,
        steps_completed: 0,
        tags: if(tag && to_string(tag) != "", do: [to_string(tag)], else: ["Task"])
      }

      case Kanban.create_task(attrs) do
        {:ok, task} ->
          tasks = Kanban.list_tasks(socket.assigns.project.id, socket.assigns.kanban_filter)

          {:noreply,
           socket
           |> assign(:tasks, tasks)
           |> assign(:selected_task, task)
           |> assign(:show_new_task_modal, false)
           |> put_flash(:info, "Task created")}

        {:error, changeset} ->
          {:noreply,
           socket
           |> assign(:show_new_task_modal, false)
           |> put_flash(
             :error,
             "Failed to create task: #{inspect(translated_errors(changeset))}"
           )}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_column", %{"status" => status}, socket) do
    new_status = if socket.assigns.expanded_column == status, do: nil, else: status
    {:noreply, assign(socket, :expanded_column, new_status)}
  end

  @impl true
  def handle_event("set_expanded_column", %{"status" => status}, socket) do
    if socket.assigns.expanded_column != status do
      {:noreply, assign(socket, :expanded_column, status)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("move_task", %{"id" => id, "status" => status}, socket) do
    case Kanban.get_task(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Task not found")}

      task ->
        case Kanban.move_task_status(task, status) do
          {:ok, updated} ->
            tasks = Kanban.list_tasks(socket.assigns.project.id, socket.assigns.kanban_filter)

            selected =
              if socket.assigns.selected_task && socket.assigns.selected_task.id == id,
                do: updated,
                else: socket.assigns.selected_task

            {:noreply,
             socket
             |> assign(:tasks, tasks)
             |> assign(:selected_task, selected)
             |> assign(:expanded_column, status)}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Invalid task status")}
        end
    end
  end

  def handle_event("move_task", _params, socket) do
    {:noreply, put_flash(socket, :error, "Invalid task move request")}
  end

  @impl true
  def handle_event("update_task_priority", %{"id" => id, "priority" => priority}, socket) do
    case Kanban.get_task(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Task not found")}

      task ->
        case Kanban.update_task(task, %{priority: priority}) do
          {:ok, updated} ->
            tasks = Kanban.list_tasks(socket.assigns.project.id, socket.assigns.kanban_filter)

            {:noreply,
             socket
             |> assign(:tasks, tasks)
             |> assign(:selected_task, updated)
             |> put_flash(:info, "Task priority updated to #{priority}")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Invalid task priority")}
        end
    end
  end

  def handle_event("update_task_priority", _params, socket) do
    {:noreply, put_flash(socket, :error, "Invalid task priority request")}
  end

  @impl true
  def handle_event("update_task_assignee", %{"id" => id, "assignee" => assignee}, socket) do
    case Kanban.get_task(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Task not found")}

      task ->
        case Kanban.update_task(task, %{assignee: assignee}) do
          {:ok, updated} ->
            tasks = Kanban.list_tasks(socket.assigns.project.id, socket.assigns.kanban_filter)

            {:noreply,
             socket
             |> assign(:tasks, tasks)
             |> assign(:selected_task, updated)
             |> put_flash(:info, "Task assignee updated to #{assignee}")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Invalid task assignee")}
        end
    end
  end

  def handle_event("update_task_assignee", _params, socket) do
    {:noreply, put_flash(socket, :error, "Invalid task assignee request")}
  end

  @impl true
  def handle_event("add_subtask", params, socket) do
    task_id =
      params["task_id"] || (socket.assigns.selected_task && socket.assigns.selected_task.id)

    title = params["title"] || params["subtask_title"] || ""

    if task_id && String.trim(title) != "" do
      case Kanban.add_subtask(task_id, %{"title" => title}) do
        {:ok, updated} ->
          tasks = Kanban.list_tasks(socket.assigns.project.id, socket.assigns.kanban_filter)

          {:noreply,
           socket
           |> assign(:tasks, tasks)
           |> assign(:selected_task, updated)
           |> put_flash(:info, "Subtask added")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to add subtask: #{inspect(reason)}")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_subtask", %{"id" => subtask_id} = params, socket) do
    task_id =
      params["task_id"] || (socket.assigns.selected_task && socket.assigns.selected_task.id)

    if task_id do
      case Kanban.toggle_subtask(task_id, subtask_id) do
        {:ok, updated} ->
          tasks = Kanban.list_tasks(socket.assigns.project.id, socket.assigns.kanban_filter)

          {:noreply,
           socket
           |> assign(:tasks, tasks)
           |> assign(:selected_task, updated)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to toggle subtask: #{inspect(reason)}")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("delete_subtask", %{"id" => subtask_id} = params, socket) do
    task_id =
      params["task_id"] || (socket.assigns.selected_task && socket.assigns.selected_task.id)

    if task_id do
      case Kanban.delete_subtask(task_id, subtask_id) do
        {:ok, updated} ->
          tasks = Kanban.list_tasks(socket.assigns.project.id, socket.assigns.kanban_filter)

          {:noreply,
           socket
           |> assign(:tasks, tasks)
           |> assign(:selected_task, updated)
           |> put_flash(:info, "Subtask deleted")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to delete subtask: #{inspect(reason)}")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("update_task", params, socket) do
    id = params["id"] || (socket.assigns.selected_task && socket.assigns.selected_task.id)
    task_params = params["task"] || params

    if id do
      case Kanban.get_task(id) do
        nil ->
          {:noreply, put_flash(socket, :error, "Task not found")}

        task ->
          tags =
            cond do
              is_list(task_params["tags"]) ->
                task_params["tags"]

              is_binary(task_params["tags"]) ->
                task_params["tags"]
                |> String.split(",")
                |> Enum.map(&String.trim/1)
                |> Enum.reject(&(&1 == ""))

              true ->
                task.tags
            end

          attrs = %{
            title: task_params["title"] || task.title,
            description: task_params["description"] || task.description,
            priority: task_params["priority"] || task.priority,
            assignee: task_params["assignee"] || task.assignee,
            status: task_params["status"] || task.status,
            tags: tags
          }

          case Kanban.update_task(task, attrs) do
            {:ok, updated} ->
              tasks = Kanban.list_tasks(socket.assigns.project.id, socket.assigns.kanban_filter)

              {:noreply,
               socket
               |> assign(:tasks, tasks)
               |> assign(:selected_task, updated)
               |> put_flash(:info, "Task updated")}

            {:error, _reason} ->
              {:noreply, put_flash(socket, :error, "Failed to update task")}
          end
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("delete_task", %{"id" => id}, socket) do
    case Kanban.get_task(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Task not found")}

      task ->
        case Kanban.delete_task(task) do
          {:ok, _deleted} ->
            tasks = Kanban.list_tasks(socket.assigns.project.id, socket.assigns.kanban_filter)

            {:noreply,
             socket
             |> assign(:tasks, tasks)
             |> assign(:selected_task, nil)
             |> assign(:show_task_drawer, false)
             |> put_flash(:info, "Task deleted")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to delete task: #{inspect(reason)}")}
        end
    end
  end

  @impl true
  def handle_event("claim_task", %{"id" => id}, socket) do
    case Kanban.get_task(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Task not found")}

      task ->
        case Kanban.claim_task(task, "coder") do
          {:ok, claimed} ->
            tasks = Kanban.list_tasks(socket.assigns.project.id, socket.assigns.kanban_filter)

            {:noreply,
             socket
             |> assign(:tasks, tasks)
             |> assign(:selected_task, claimed)
             |> put_flash(:info, "Worker #{claimed.worker_pid} claimed task")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to claim task: #{inspect(reason)}")}
        end
    end
  end

  @impl true
  def handle_event("estimate_task", %{"id" => id}, socket) do
    case Kanban.get_task(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Task not found")}

      task ->
        case Kanban.estimate_effort(task) do
          {:ok, estimated} ->
            tasks = Kanban.list_tasks(socket.assigns.project.id, socket.assigns.kanban_filter)

            {:noreply,
             socket
             |> assign(:tasks, tasks)
             |> assign(:selected_task, estimated)
             |> put_flash(:info, "Effort estimated: #{estimated.estimate}")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to estimate effort: #{inspect(reason)}")}
        end
    end
  end

  @impl true
  def handle_event("filter_kanban", %{"search" => search} = params, socket) do
    filters = %{
      "search" => search,
      "priority" => params["priority"] || "",
      "assignee" => params["assignee"] || "",
      "status" => params["status"] || ""
    }

    tasks = Kanban.list_tasks(socket.assigns.project.id, filters)
    {:noreply, socket |> assign(:kanban_filter, filters) |> assign(:tasks, tasks)}
  end

  # ============================================================================
  # Event Handlers: Prompts, Swarm & Sessions
  # ============================================================================

  @impl true
  def handle_event("select_async_run", %{"id" => run_id}, socket) do
    case Runs.get_run(run_id) do
      %Runs.Run{session_id: session_id} = run when session_id == socket.assigns.session.id ->
        {:noreply, select_run_projection(socket, run)}

      _ ->
        {:noreply, put_flash(socket, :error, "Run not found in this session")}
    end
  end

  @impl true
  def handle_event("pause_async_run", %{"id" => run_id}, socket) do
    control_async_run(socket, run_id, :pause)
  end

  @impl true
  def handle_event("resume_async_run", %{"id" => run_id}, socket) do
    control_async_run(socket, run_id, :resume)
  end

  @impl true
  def handle_event("cancel_async_run", %{"id" => run_id}, socket) do
    control_async_run(socket, run_id, :cancel)
  end

  @impl true
  def handle_event("retry_async_run", %{"id" => run_id}, socket) do
    control_async_run(socket, run_id, :retry)
  end

  @impl true
  def handle_event("steer_async_run", params, socket) do
    run_id = params["run_id"]
    guidance = String.trim(params["steering"] || "")

    case Runs.get_run(run_id) do
      %Runs.Run{session_id: session_id} = run
      when session_id == socket.assigns.session.id and guidance != "" ->
        case RunDispatcher.steer(run, guidance) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> select_run_projection(updated)
             |> put_flash(:info, "Run-scoped guidance dispatched and journaled")}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Run steering failed: #{format_run_error(reason)}")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Select an active run and enter guidance")}
    end
  catch
    :exit, _ -> {:noreply, put_flash(socket, :error, "The run dispatcher is not available")}
  end

  @impl true
  def handle_event(
        "update_run_agent_guidance",
        %{"agent_id" => agent_id, "agent_control" => %{"guidance" => guidance}},
        socket
      ) do
    if selected_run_agent?(socket, agent_id) do
      {:noreply,
       update(
         socket,
         :run_agent_guidance,
         &Map.put(&1, agent_id, String.slice(guidance, 0, 4_000))
       )}
    else
      {:noreply, put_flash(socket, :error, "Agent not found in the selected run")}
    end
  end

  def handle_event("update_run_agent_guidance", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event(
        "steer_run_agent",
        %{"agent_id" => agent_id, "agent_control" => %{"guidance" => guidance}},
        socket
      ) do
    guidance = guidance |> to_string() |> String.trim() |> String.slice(0, 4_000)

    cond do
      guidance == "" ->
        {:noreply, put_flash(socket, :error, "Enter guidance for this agent")}

      !selected_run_agent?(socket, agent_id) ->
        {:noreply, put_flash(socket, :error, "Agent not found in the selected run")}

      true ->
        case control_selected_run_agent(socket, agent_id, :steer, %{"guidance" => guidance}) do
          {:ok, _result} ->
            {:noreply,
             socket
             |> update(:run_agent_guidance, &Map.delete(&1, agent_id))
             |> refresh_run_fleet()
             |> push_event("reset_run_agent_guidance", %{agent_id: agent_id})
             |> put_flash(:info, "Agent guidance queued for this worker")}

          {:error, reason} ->
            {:noreply,
             socket
             |> update(:run_agent_guidance, &Map.put(&1, agent_id, guidance))
             |> put_flash(:error, "Agent steering failed: #{format_run_error(reason)}")}
        end
    end
  end

  def handle_event("steer_run_agent", _params, socket),
    do: {:noreply, put_flash(socket, :error, "Invalid agent steering request")}

  @impl true
  def handle_event(
        "control_run_agent",
        %{"id" => agent_id, "action" => action},
        socket
      )
      when action in ["pause", "resume", "cancel", "restart"] do
    kind =
      case action do
        "pause" -> :pause
        "resume" -> :resume
        "cancel" -> :cancel
        "restart" -> :restart
      end

    if selected_run_agent?(socket, agent_id) do
      case control_selected_run_agent(socket, agent_id, kind, %{}) do
        {:ok, _result} ->
          {:noreply,
           socket
           |> refresh_run_fleet()
           |> put_flash(:info, "Agent #{action} request persisted")}

        {:error, reason} ->
          {:noreply,
           put_flash(socket, :error, "Agent control failed: #{format_run_error(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "Agent not found in the selected run")}
    end
  end

  def handle_event("control_run_agent", _params, socket),
    do: {:noreply, put_flash(socket, :error, "Invalid agent control request")}

  @impl true
  def handle_event("toggle_run_setup", _params, socket) do
    {:noreply, assign(socket, :run_setup_open?, !socket.assigns.run_setup_open?)}
  end

  @impl true
  def handle_event("update_run_setup", %{"run_setup" => params}, socket) do
    providers =
      params
      |> Map.get("providers", %{})
      |> Enum.filter(fn {_provider, enabled} -> enabled in ["true", "on", "1"] end)
      |> Enum.map(&elem(&1, 0))

    {:noreply,
     socket
     |> assign(:run_setup_mode, normalize_run_mode(params["mode"]))
     |> assign(:run_setup_priority, normalize_run_priority(params["priority"]))
     |> assign(:run_setup_max_attempts, bounded_integer(params["max_attempts"], 3, 1, 10))
     |> assign(:run_setup_token_budget, optional_integer(params["token_budget"], 1, 10_000_000))
     |> assign(
       :run_setup_cost_budget_cents,
       optional_integer(params["cost_budget_cents"], 1, 10_000_000)
     )
     |> assign(
       :run_setup_time_budget_minutes,
       optional_integer(params["time_budget_minutes"], 1, 10_080)
     )
     |> assign(:run_setup_research_depth, normalize_research_depth(params["research_depth"]))
     |> assign(
       :run_setup_research_sources,
       bounded_integer(params["research_max_sources"], 12, 1, 100)
     )
     |> assign(
       :run_setup_providers,
       providers
     )
     |> assign(:run_setup_form, to_form(params, as: :run_setup))}
  end

  @impl true
  def handle_event(
        "decide_run_approval",
        %{"id" => approval_id, "decision" => decision},
        socket
      )
      when decision in ["approved", "denied"] do
    approval = Runs.get_approval(approval_id)

    if approval && socket.assigns.selected_run &&
         approval.run_id == socket.assigns.selected_run.id do
      case Runs.decide_approval(approval, decision, %{
             decided_by: "local-user",
             decision_note: "Decision recorded in workspace run console"
           }) do
        {:ok, _updated} ->
          {:noreply,
           socket
           |> refresh_selected_run()
           |> put_flash(:info, "Approval decision persisted")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Decision failed: #{format_run_error(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "Approval not found in the selected run")}
    end
  end

  def handle_event("decide_run_approval", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("submit_prompt", %{"prompt" => prompt_text}, socket) do
    text = String.trim(prompt_text)

    if text != "" do
      tab =
        cond do
          String.starts_with?(text, "/swarm") -> "swarm"
          String.starts_with?(text, "/kanban") -> "kanban"
          true -> socket.assigns.active_tab
        end

      if socket.assigns.dispatch_mode == "background" do
        objective =
          text
          |> String.replace_prefix("/swarm", "")
          |> String.trim()
          |> then(
            &if(&1 == "", do: "Analyze the workspace and propose the next safe change", else: &1)
          )

        research_command? = String.starts_with?(text, "/research")
        selected_mode = if research_command?, do: "research", else: socket.assigns.run_setup_mode
        deep_research? = selected_mode == "research"

        objective =
          if research_command? do
            text
            |> String.replace_prefix("/research", "")
            |> String.trim()
            |> then(
              &if(&1 == "", do: "Research the requested topic with cited evidence", else: &1)
            )
          else
            objective
          end

        research_manifest = %{
          "mode" => selected_mode,
          "providers" => socket.assigns.run_setup_providers,
          "depth" => socket.assigns.run_setup_research_depth,
          "max_sources" => socket.assigns.run_setup_research_sources
        }

        metadata = %{
          "source" => "workspace_composer",
          "original_prompt" => text,
          "allowed_tools" => enabled_tools(socket.assigns.active_tools)
        }

        metadata =
          if deep_research?, do: Map.put(metadata, "research", research_manifest), else: metadata

        attrs = %{
          project_id: socket.assigns.project.id,
          session_id: socket.assigns.session.id,
          objective: objective,
          kind: if(deep_research?, do: "deep_research", else: "coding_swarm"),
          mode: if(deep_research?, do: "research", else: "swarm"),
          priority: socket.assigns.run_setup_priority,
          max_attempts: socket.assigns.run_setup_max_attempts,
          token_budget: socket.assigns.run_setup_token_budget,
          cost_budget_cents: socket.assigns.run_setup_cost_budget_cents,
          time_budget_ms: minutes_to_ms(socket.assigns.run_setup_time_budget_minutes),
          metadata: metadata
        }

        if deep_research? and socket.assigns.run_setup_providers == [] do
          {:noreply, put_flash(socket, :error, "Select at least one research provider")}
        else
          case RunDispatcher.enqueue(attrs) do
            {:ok, run} ->
              {:noreply,
               socket
               |> assign(:active_tab, "swarm")
               |> assign(:run_setup_open?, false)
               |> assign(:prompt_form, to_form(%{"prompt" => ""}))
               |> select_run_projection(run)
               |> put_flash(:info, "Background run queued. It will continue if you disconnect.")}

            {:error, reason} ->
              {:noreply,
               put_flash(socket, :error, "Could not queue run: #{format_run_error(reason)}")}
          end
        end
      else
        SessionServer.send_prompt(socket.assigns.session.id, text,
          allowed_tools: enabled_tools(socket.assigns.active_tools)
        )

        {:noreply,
         socket
         |> assign(:active_tab, tab)
         |> assign(:prompt_form, to_form(%{"prompt" => ""}))}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("set_dispatch_mode", %{"mode" => mode}, socket)
      when mode in ["background", "interactive"] do
    {:noreply, assign(socket, :dispatch_mode, mode)}
  end

  def handle_event("set_dispatch_mode", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_swarm", _params, socket) do
    session_id = socket.assigns.session.id

    case SessionServer.toggle_swarm(session_id) do
      {:ok, new_mode} ->
        updated_session = %{socket.assigns.session | swarm_mode: new_mode}

        {:noreply,
         socket
         |> assign(:session, updated_session)
         |> put_flash(
           :info,
           if(new_mode,
             do: "🐝 Swarm Mode Enabled (Multi-Agent OTP Architecture)",
             else: "Single Agent Mode Active"
           )
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to toggle swarm mode: #{inspect(reason)}")}

      :error ->
        {:noreply, put_flash(socket, :error, "Failed to toggle swarm mode")}
    end
  end

  @impl true
  def handle_event("toggle_op_detail", %{"id" => op_id}, socket) do
    expanded = socket.assigns.expanded_ops

    new_expanded =
      if MapSet.member?(expanded, op_id) do
        MapSet.delete(expanded, op_id)
      else
        MapSet.put(expanded, op_id)
      end

    {:noreply, assign(socket, :expanded_ops, new_expanded)}
  end

  @impl true
  def handle_event("clear_operations", _params, socket) do
    SessionServer.clear_operations(socket.assigns.session.id)
    {:noreply, assign(socket, :operations, [])}
  end

  @impl true
  def handle_event("new_session", _params, socket) do
    project = socket.assigns.project
    count = length(socket.assigns.sessions) + 1

    case Sessions.create_session(%{
           project_id: project.id,
           title: "Coding Session #{count}",
           swarm_mode: socket.assigns.session.swarm_mode,
           model_provider: socket.assigns.session.model_provider,
           model_name: socket.assigns.session.model_name
         }) do
      {:ok, session} ->
        {:noreply,
         socket
         |> assign(:sessions, Sessions.list_sessions_for_project(project.id))
         |> push_patch(to: ~p"/sessions/#{session.id}?project_id=#{project.id}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to create session: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("delete_session", %{"id" => session_id}, socket) do
    case fetch_session(session_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Session not found")}

      session ->
        # Stop the SessionServer first so it doesn't keep running against a deleted row
        stop_session_server(session.id)

        case Sessions.delete_session(session) do
          {:ok, _} ->
            remaining = Sessions.list_sessions_for_project(socket.assigns.project.id)

            if remaining == [] do
              case Sessions.create_session(%{
                     project_id: socket.assigns.project.id,
                     title: "Coding Session 1"
                   }) do
                {:ok, new_s} ->
                  {:noreply, push_patch(socket, to: ~p"/sessions/#{new_s.id}")}

                {:error, reason} ->
                  {:noreply,
                   put_flash(
                     socket,
                     :error,
                     "Failed to create replacement session: #{inspect(reason)}"
                   )}
              end
            else
              [next | _] = remaining
              {:noreply, push_patch(socket, to: ~p"/sessions/#{next.id}")}
            end

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to delete session: #{inspect(reason)}")}
        end
    end
  end

  # ============================================================================
  # Event Handlers: Terminal Integration & PTY Control
  # ============================================================================

  @impl true
  def handle_event("terminal_input", %{"data" => data}, socket) do
    session_id = socket.assigns.session.id

    case TerminalServer.send_input(session_id, data) do
      :ok ->
        {:noreply, socket}

      {:error, :agent_occupied} ->
        {:noreply, put_flash(socket, :warning, "Terminal is locked by active agent.")}

      {:error, reason} ->
        Logger.warning("[WorkspaceLive] Terminal input error: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("terminal_resize", params, socket) do
    session_id = socket.assigns.session.id
    cols = parse_terminal_dimension(params["cols"] || params[:cols], socket.assigns.terminal_cols)
    rows = parse_terminal_dimension(params["rows"] || params[:rows], socket.assigns.terminal_rows)

    if cols > 0 and rows > 0 do
      _ = TerminalServer.resize(session_id, cols, rows)
      {:noreply, socket |> assign(:terminal_cols, cols) |> assign(:terminal_rows, rows)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("run_terminal_quick_action", params, socket) do
    cmd = params["cmd"] || params["command"] || ""
    session_id = socket.assigns.session.id

    if String.trim(cmd) != "" do
      command_result = TerminalServer.run_command_with_id(session_id, cmd)

      updated_history =
        [cmd | Enum.reject(socket.assigns.terminal_history, &(&1 == cmd))]
        |> Enum.take(25)

      case command_result do
        {:ok, _command_id} ->
          {:noreply,
           socket
           |> assign(:terminal_history, updated_history)
           |> assign(:terminal_active_cmd, cmd)
           |> assign(:terminal_form, to_form(%{"command" => cmd}))}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Terminal command failed: #{inspect(reason)}")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("run_terminal", params, socket) do
    cmd = params["command"] || params["cmd"] || ""
    handle_event("run_terminal_quick_action", %{"cmd" => cmd}, socket)
  end

  @impl true
  def handle_event("run_terminal_command", params, socket) do
    cmd = params["command"] || params["cmd"] || ""
    handle_event("run_terminal_quick_action", %{"cmd" => cmd}, socket)
  end

  @impl true
  def handle_event("quick_terminal", params, socket) do
    cmd = params["command"] || params["cmd"] || ""
    handle_event("run_terminal_quick_action", %{"cmd" => cmd}, socket)
  end

  @impl true
  def handle_event("clear_terminal", _params, socket) do
    session_id = socket.assigns.session.id
    _ = TerminalServer.clear(session_id)
    {:noreply, socket |> assign(:terminal_output, "") |> push_event("terminal_clear", %{})}
  end

  @impl true
  def handle_event("restart_terminal_session", _params, socket) do
    session_id = socket.assigns.session.id
    root = socket.assigns.project.root_path
    cols = socket.assigns.terminal_cols
    rows = socket.assigns.terminal_rows

    case TerminalServer.restart(session_id, workspace_path: root, cols: cols, rows: rows) do
      {:ok, _pid} ->
        {:noreply,
         socket
         |> assign(:terminal_running?, true)
         |> assign(:terminal_status, :running)
         |> assign(:terminal_occupant, :user)
         |> assign(:terminal_active_cmd, nil)
         |> assign(:terminal_output, "")
         |> push_event("terminal_reset", %{})
         |> put_flash(:info, "Terminal session restarted")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to restart terminal: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("kill_terminal_session", _params, socket) do
    session_id = socket.assigns.session.id
    _ = TerminalServer.send_signal(session_id, :sigint)

    {:noreply,
     socket |> assign(:terminal_active_cmd, nil) |> put_flash(:info, "Terminal command stopped")}
  end

  @impl true
  def handle_event("stop_terminal_command", params, socket) do
    handle_event("kill_terminal_session", params, socket)
  end

  @impl true
  def handle_event("replay_terminal_command", _params, socket) do
    case socket.assigns.terminal_history do
      [last_cmd | _] -> handle_event("run_terminal_quick_action", %{"cmd" => last_cmd}, socket)
      [] -> {:noreply, put_flash(socket, :info, "No commands in history")}
    end
  end

  @impl true
  def handle_event("request_terminal_history", _params, socket) do
    session_id = socket.assigns.session.id
    history = TerminalServer.get_history(session_id)
    {:noreply, push_event(socket, "terminal_history", %{history: history})}
  end

  # ============================================================================
  # Event Handlers: Settings & Workspaces
  # ============================================================================

  @impl true
  def handle_event("toggle_settings_modal", _params, socket) do
    show? = !socket.assigns.show_settings_modal
    usage = if show?, do: Sessions.list_usage_history(10), else: socket.assigns.usage_history
    {:noreply, socket |> assign(:show_settings_modal, show?) |> assign(:usage_history, usage)}
  end

  @impl true
  def handle_event("save_settings", %{"settings" => params}, socket) do
    # Only overwrite the stored API key when the submitted value is non-empty
    clean_params =
      params
      |> then(fn p ->
        case p["openai_api_key"] do
          key when is_binary(key) ->
            if String.trim(key) == "",
              do: Map.delete(p, "openai_api_key"),
              else: Map.put(p, "openai_api_key", String.trim(key))

          _ ->
            Map.delete(p, "openai_api_key")
        end
      end)
      |> then(fn p ->
        case p["anthropic_api_key"] do
          key when is_binary(key) ->
            if String.trim(key) == "",
              do: Map.delete(p, "anthropic_api_key"),
              else: Map.put(p, "anthropic_api_key", String.trim(key))

          _ ->
            Map.delete(p, "anthropic_api_key")
        end
      end)
      |> merge_search_provider_settings(socket.assigns.settings)
      |> sanitize_settings_params()

    case Settings.update_settings(clean_params) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:settings, updated)
         |> assign(:usage_history, Sessions.list_usage_history(10))
         |> assign(:settings_form, Settings.change_settings(updated) |> to_form())
         |> refresh_run_setup_settings(updated)
         |> assign(:show_settings_modal, false)
         |> put_flash(:info, "Settings saved successfully")}

      {:error, changeset} ->
        {:noreply, assign(socket, :settings_form, to_form(changeset))}
    end
  end

  @impl true
  def handle_event("toggle_project_modal", _params, socket) do
    {:noreply, assign(socket, :show_project_modal, !socket.assigns.show_project_modal)}
  end

  @impl true
  def handle_event("open_project", %{"project" => %{"path" => path, "name" => name}}, socket) do
    trimmed_path = String.trim(path)

    proj_name =
      if String.trim(name) == "", do: Path.basename(trimmed_path), else: String.trim(name)

    case Projects.get_or_create_project(trimmed_path, proj_name) do
      {:ok, project} ->
        case Sessions.create_session(%{
               project_id: project.id,
               title: "Coding Session 1",
               swarm_mode: true
             }) do
          {:ok, session} ->
            {:noreply,
             socket
             |> assign(:show_project_modal, false)
             |> assign(:show_workspace_menu, false)
             |> push_patch(to: ~p"/sessions/#{session.id}?project_id=#{project.id}")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to create session: #{inspect(reason)}")}
        end

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to open project: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("switch_project", %{"id" => project_id}, socket) do
    case fetch_project(project_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Project not found")}

      project ->
        sessions = Sessions.list_sessions_for_project(project.id)

        session =
          case sessions do
            [first | _] ->
              first

            [] ->
              case Sessions.create_session(%{project_id: project.id, title: "Coding Session 1"}) do
                {:ok, s} -> s
                {:error, reason} -> {:error, reason}
              end
          end

        case session do
          %Sessions.Session{} ->
            {:noreply,
             socket
             |> assign(:show_workspace_menu, false)
             |> push_patch(to: ~p"/sessions/#{session.id}?project_id=#{project.id}")}

          _ ->
            {:noreply, put_flash(socket, :error, "Failed to open project session")}
        end
    end
  end

  @impl true
  def handle_event("open_project_modal", _params, socket) do
    {:noreply, assign(socket, :show_project_modal, true)}
  end

  @impl true
  def handle_event("close_project_modal", _params, socket) do
    {:noreply, assign(socket, :show_project_modal, false)}
  end

  @impl true
  def handle_event(_event, _params, socket) do
    {:noreply, socket}
  end

  # ============================================================================
  # PubSub Info Callbacks
  # ============================================================================

  @impl true
  def handle_info({:message_created, message}, socket) do
    all_messages = socket.assigns.all_messages ++ [message]

    {:noreply,
     socket
     |> assign(:all_messages, all_messages)
     |> assign(:messages, filter_history_messages(all_messages, socket.assigns.workspace_search))}
  end

  @impl true
  def handle_info({:operation_started, op}, socket) do
    operations = [op | Enum.reject(socket.assigns.operations, &(&1.id == op.id))]

    {:noreply,
     socket
     |> assign(:operations, operations)
     |> assign(:active_agent, op.agent_name)
     |> assign(:active_worker_pid, op.pid_str || socket.assigns.active_worker_pid)}
  end

  @impl true
  def handle_info({:operation_created, op}, socket) do
    operations = [op | Enum.reject(socket.assigns.operations, &(&1.id == op.id))]
    {:noreply, assign(socket, :operations, operations)}
  end

  @impl true
  def handle_info({:operation_updated, updated_op}, socket) do
    operations =
      Enum.map(socket.assigns.operations, fn op ->
        if op.id == updated_op.id, do: updated_op, else: op
      end)

    {:noreply, assign(socket, :operations, operations)}
  end

  @impl true
  def handle_info({:operation_progress, op_id, pct, msg}, socket) when is_binary(op_id) do
    operations =
      Enum.map(socket.assigns.operations, fn op ->
        if op.id == op_id do
          %{op | progress: pct, result: msg || op.result, status: "running"}
        else
          op
        end
      end)

    {:noreply, assign(socket, :operations, operations)}
  end

  @impl true
  def handle_info(
        {:operation_progress, %{id: op_id, progress: pct} = data},
        socket
      ) do
    latency = Map.get(data, :latency_ms)
    status = Map.get(data, :status, "running")
    msg = Map.get(data, :message)

    operations =
      Enum.map(socket.assigns.operations, fn op ->
        if op.id == op_id do
          op
          |> Map.put(:progress, pct)
          |> Map.put(:status, status)
          |> then(fn o -> if latency, do: Map.put(o, :duration_ms, latency), else: o end)
          |> then(fn o -> if msg, do: Map.put(o, :result, msg), else: o end)
        else
          op
        end
      end)

    socket =
      if latency do
        assign(socket, :current_latency_ms, latency)
      else
        socket
      end

    {:noreply, assign(socket, :operations, operations)}
  end

  @impl true
  def handle_info({:operation_completed, op}, socket) do
    handle_info({:operation_updated, op}, socket)
  end

  @impl true
  def handle_info({:operation_failed, op}, socket) do
    handle_info({:operation_updated, op}, socket)
  end

  @impl true
  def handle_info({:swarm_stage_changed, metadata}, socket) do
    stage =
      case metadata do
        %{stage: s} -> s
        s when is_atom(s) -> s
        _ -> :init
      end

    iter =
      case metadata do
        %{iteration: i} when is_integer(i) -> i
        _ -> socket.assigns.swarm_iteration
      end

    latency =
      case metadata do
        %{latency_ms: l} when is_integer(l) -> l
        _ -> socket.assigns.current_latency_ms
      end

    agent_pid =
      case metadata do
        %{agent_pid: p} when is_binary(p) -> p
        _ -> socket.assigns.active_worker_pid
      end

    {:noreply,
     socket
     |> assign(:active_stage, stage)
     |> assign(:swarm_iteration, iter)
     |> assign(:current_latency_ms, latency)
     |> assign(:active_worker_pid, agent_pid)}
  end

  @impl true
  def handle_info({:swarm_steered, %{steering: text}}, socket) do
    {:noreply,
     socket
     |> put_flash(
       :info,
       "🧭 Steering guidance delivered: #{String.slice(to_string(text), 0, 80)}"
     )}
  end

  @impl true
  def handle_info({:swarm_steered, _}, socket) do
    {:noreply, put_flash(socket, :info, "🧭 Steering guidance delivered")}
  end

  @impl true
  def handle_info({:session_cancelled, %{action: action}}, socket) do
    updated_session = %{socket.assigns.session | status: "stopped"}

    {:noreply,
     socket
     |> assign(:session, updated_session)
     |> assign(:show_cancel_modal, false)
     |> assign(:cancelling?, false)
     |> put_flash(:info, "Session stopped (#{action} completed)")}
  end

  @impl true
  def handle_info({:session_cancelled, _}, socket) do
    updated_session = %{socket.assigns.session | status: "stopped"}

    {:noreply,
     socket
     |> assign(:session, updated_session)
     |> assign(:show_cancel_modal, false)
     |> assign(:cancelling?, false)}
  end

  # ============================================================================
  # Info Handlers: Terminal Output & Lifecycle PubSub
  # ============================================================================

  @impl true
  def handle_info({:terminal_output, %{session_id: sid, data: data}}, socket) do
    if sid == socket.assigns.session.id do
      {:noreply,
       socket
       |> append_terminal_output(data)
       |> push_event("terminal_output", %{data: data})}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:terminal_output, sid, data}, socket)
      when is_binary(sid) and is_binary(data) do
    if sid == socket.assigns.session.id do
      {:noreply,
       socket
       |> append_terminal_output(data)
       |> push_event("terminal_output", %{data: data})}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:terminal_output, _session_id, _}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(
        {:terminal_status, %{session_id: sid, status: status, shell: shell, occupant: occupant}},
        socket
      ) do
    if sid == socket.assigns.session.id do
      {:noreply,
       socket
       |> assign(:terminal_status, status)
       |> assign(:terminal_shell, shell)
       |> assign(:terminal_occupant, occupant)
       |> assign(:terminal_running?, status in [:ready, :running])}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:terminal_occupant, %{session_id: sid, occupant: occupant}}, socket) do
    if sid == socket.assigns.session.id do
      {:noreply, assign(socket, :terminal_occupant, occupant)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(
        {:terminal_command_completed,
         %{session_id: sid, exit_code: code, command_id: _command_id}},
        socket
      ) do
    if sid == socket.assigns.session.id do
      exit_msg = "\n[Exit #{code}#{if code == 0, do: ": OK", else: ": Error"}]\n"

      {:noreply,
       socket
       |> append_terminal_output(exit_msg)
       |> assign(:terminal_active_cmd, nil)
       |> push_event("terminal_output", %{data: exit_msg})}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:terminal_command_started, %{session_id: sid, command: command}}, socket) do
    if sid == socket.assigns.session.id do
      {:noreply, assign(socket, :terminal_active_cmd, command)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:terminal_exit, %{session_id: sid, exit_code: code}}, socket) do
    if sid == socket.assigns.session.id do
      exit_msg = "\r\n[Process completed with exit code #{code}]\r\n"

      {:noreply,
       socket
       |> assign(:terminal_running?, false)
       |> assign(:terminal_status, :stopped)
       |> assign(:terminal_active_cmd, nil)
       |> append_terminal_output(exit_msg)
       |> push_event("terminal_output", %{data: exit_msg})}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:terminal_cleared, %{session_id: sid}}, socket) do
    if sid == socket.assigns.session.id do
      {:noreply,
       socket
       |> assign(:terminal_output, "")
       |> push_event("terminal_clear", %{})}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:terminal_resized, %{session_id: sid, cols: cols, rows: rows}}, socket) do
    if sid == socket.assigns.session.id do
      {:noreply,
       socket
       |> assign(:terminal_cols, cols)
       |> assign(:terminal_rows, rows)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({port, {:data, text}}, %{assigns: %{terminal_port: port}} = socket)
      when is_port(port) and is_binary(text) do
    {:noreply, append_terminal_output(socket, text)}
  end

  @impl true
  def handle_info({port, {:exit_status, code}}, %{assigns: %{terminal_port: port}} = socket)
      when is_port(port) do
    {:noreply,
     socket
     |> append_terminal_output("\n[Exit #{code}#{if code == 0, do: ": OK", else: ": Error"}]\n")
     |> assign(:terminal_running?, false)
     |> assign(:terminal_port, nil)}
  end

  # Stale messages from a port we already stopped
  @impl true
  def handle_info({port, _msg}, socket) when is_port(port) do
    case :erlang.port_info(port, :os_pid) do
      :undefined ->
        try do
          Port.close(port)
        catch
          _kind, _reason -> :ok
        end

      _os_pid ->
        :ok
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info(:operations_cleared, socket) do
    {:noreply, assign(socket, :operations, [])}
  end

  @impl true
  def handle_info({:session_status_changed, status}, socket) do
    updated_session = %{socket.assigns.session | status: to_string(status)}
    {:noreply, assign(socket, :session, updated_session)}
  end

  @impl true
  def handle_info({:goal_created, _goal}, socket) do
    {:noreply, socket |> put_flash(:info, "Autonomous Goal active in session")}
  end

  @impl true
  def handle_info({:task_created, task}, socket) do
    if task.project_id == socket.assigns.project.id do
      if Enum.any?(socket.assigns.tasks, &(&1.id == task.id)) do
        {:noreply, socket}
      else
        {:noreply, assign(socket, :tasks, [task | socket.assigns.tasks])}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:task_updated, updated_task}, socket) do
    if updated_task.project_id == socket.assigns.project.id do
      tasks =
        Enum.map(socket.assigns.tasks, fn t ->
          if t.id == updated_task.id, do: updated_task, else: t
        end)

      selected =
        if socket.assigns.selected_task && socket.assigns.selected_task.id == updated_task.id,
          do: updated_task,
          else: socket.assigns.selected_task

      {:noreply, socket |> assign(:tasks, tasks) |> assign(:selected_task, selected)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:task_deleted, deleted_task}, socket) do
    if deleted_task.project_id == socket.assigns.project.id do
      tasks = Enum.reject(socket.assigns.tasks, &(&1.id == deleted_task.id))
      {:noreply, assign(socket, :tasks, tasks)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(
        {:test_runner_progress, token, pct, msg},
        %{assigns: %{test_runner_task_token: token}} = socket
      ) do
    {:noreply, apply_test_runner_progress(socket, pct, msg)}
  end

  @impl true
  def handle_info({:test_runner_progress, _stale_token, _pct, _msg}, socket) do
    {:noreply, socket}
  end

  # Keep the legacy shape for tests and older local producers, while applying
  # the same monotonic rule so a delayed "starting" callback cannot overwrite
  # newer progress already visible to the user.
  @impl true
  def handle_info({:test_runner_progress, pct, msg}, socket) do
    {:noreply, apply_test_runner_progress(socket, pct, msg)}
  end

  @impl true
  def handle_info({:test_runner_result, result}, socket) do
    {:noreply,
     socket
     |> assign(:test_runner_status, result.status)
     |> assign(:test_runner_result, result)
     |> assign(:test_runner_progress_pct, 100)
     |> assign(
       :test_runner_progress_msg,
       "Tests completed (#{result.passed}/#{result.total} passed)"
     )
     |> assign(:test_runner_async_task, nil)
     |> assign(:test_runner_task_token, nil)}
  end

  @impl true
  def handle_info(
        {ref, {:ok, %IexCode.Tools.TestRunner.Result{} = result}},
        %{assigns: %{test_runner_async_task: %Task{ref: ref}}} = socket
      ) do
    Process.demonitor(ref, [:flush])

    {:noreply,
     socket
     |> assign(:test_runner_status, result.status)
     |> assign(:test_runner_result, result)
     |> assign(:test_runner_progress_pct, 100)
     |> assign(
       :test_runner_progress_msg,
       "Tests completed (#{result.passed}/#{result.total} passed)"
     )
     |> assign(:test_runner_async_task, nil)
     |> assign(:test_runner_task_token, nil)}
  end

  @impl true
  def handle_info(
        {ref, {:error, reason}},
        %{assigns: %{test_runner_async_task: %Task{ref: ref}}} = socket
      ) do
    Process.demonitor(ref, [:flush])

    error_msg =
      case reason do
        :timeout -> "Test execution timed out after 60s"
        {:workspace_lock_waiting, _locks} -> "Test runner failed: #{ui_mutation_error(reason)}"
        _ -> "Test runner failed: #{inspect(reason)}"
      end

    {:noreply,
     socket
     |> assign(:test_runner_status, :error)
     |> assign(:test_runner_progress_pct, 100)
     |> assign(:test_runner_progress_msg, error_msg)
     |> assign(:test_runner_async_task, nil)
     |> assign(:test_runner_task_token, nil)
     |> put_flash(:error, error_msg)}
  end

  @impl true
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{assigns: %{test_runner_async_task: %Task{ref: ref}}} = socket
      ) do
    if reason in [:normal, :noproc] do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:test_runner_status, :error)
       |> assign(:test_runner_progress_pct, 100)
       |> assign(:test_runner_progress_msg, "Test task exited abnormally: #{inspect(reason)}")
       |> assign(:test_runner_async_task, nil)
       |> assign(:test_runner_task_token, nil)}
    end
  end

  # Durable run updates are broadcast only after their transaction commits.
  # Refreshing from the database here makes PubSub a low-latency hint while the
  # journal remains the source of truth after reconnects or missed messages.
  @impl true
  def handle_info({:run_created, run}, socket) do
    if run.session_id == socket.assigns.session.id do
      {:noreply, select_run_projection(socket, run)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:run_updated, run}, socket) do
    if run.session_id == socket.assigns.session.id do
      socket = sync_run_linked_task(socket, run)

      if socket.assigns.selected_run && socket.assigns.selected_run.id == run.id do
        {:noreply, select_run_projection(socket, run)}
      else
        {:noreply, assign_run_projection(socket, socket.assigns.session.id)}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:run_event, event}, socket) do
    if socket.assigns.selected_run && event.run_id == socket.assigns.selected_run.id do
      updated_run = Runs.get_run(event.run_id) || socket.assigns.selected_run

      events = Runs.list_latest_events(updated_run, limit: 500)
      {:noreply, socket |> assign(:selected_run, updated_run) |> assign(:run_event_rows, events)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({event_name, entity}, socket)
      when event_name in [
             :run_step_created,
             :run_step_updated,
             :run_command_enqueued,
             :run_command_updated,
             :run_approval_requested,
             :run_approval_decided,
             :run_artifact_created,
             :run_control_enqueued,
             :run_control_updated
           ] do
    cond do
      socket.assigns.selected_run && entity.run_id == socket.assigns.selected_run.id ->
        {:noreply, refresh_selected_run(socket)}

      event_name in [:run_approval_requested, :run_approval_decided] ->
        {:noreply, refresh_run_counts(socket)}

      true ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({event_name, agent}, socket)
      when event_name in [:run_agent_created, :run_agent_updated] do
    if socket.assigns.selected_run && agent.run_id == socket.assigns.selected_run.id do
      {:noreply, refresh_run_fleet(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({event_name, control}, socket)
      when event_name in [:run_agent_control_enqueued, :run_agent_control_updated] do
    if socket.assigns.selected_run && control.run_id == socket.assigns.selected_run.id do
      {:noreply, refresh_run_fleet(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:async_run_started, run, _pid}, socket) do
    {:noreply, select_run_projection(socket, Runs.get_run(run.id) || run)}
  end

  @impl true
  def handle_info({:async_run_updated, run}, socket) do
    {:noreply, select_run_projection(socket, Runs.get_run(run.id) || run)}
  end

  @impl true
  def handle_info({:workspace_locks_updated, _locks}, socket) do
    {:noreply, refresh_workspace_locks(socket)}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # ============================================================================
  # Helpers & Seeders
  # ============================================================================

  # -- Safe fetches (client params must never raise) ---------------------------

  defp fetch_session(id) when is_binary(id) do
    Sessions.get_session(id)
  rescue
    _ in [Ecto.Query.CastError] -> nil
  end

  defp fetch_session(_), do: nil

  defp fetch_project(id) when is_binary(id) do
    Projects.get_project!(id)
  rescue
    _ in [Ecto.NoResultsError, Ecto.Query.CastError] -> nil
  end

  defp fetch_project(_), do: nil

  defp resolve_mount_context(params) do
    case params["id"] && fetch_session(params["id"]) do
      %Sessions.Session{} = session ->
        case fetch_project(session.project_id) do
          nil ->
            {session, project} = default_context(nil)
            {session, project, "Project for this session was not found — opened a new session"}

          project ->
            {session, project, nil}
        end

      _ ->
        {session, project} = default_context(params["project_id"])

        error =
          if params["id"] in [nil, ""] do
            nil
          else
            "Session not found — opened a new session instead"
          end

        {session, project, error}
    end
  end

  defp default_context(project_id) do
    project =
      case project_id && fetch_project(project_id) do
        nil ->
          cwd = File.cwd!()
          {:ok, p} = Projects.get_or_create_project(cwd, Path.basename(cwd))
          p

        project ->
          project
      end

    session =
      case Sessions.list_sessions_for_project(project.id) do
        [first | _] ->
          first

        [] ->
          {:ok, s} =
            Sessions.create_session(%{
              project_id: project.id,
              title: "Coding Session 1",
              swarm_mode: true,
              model_provider: "openai",
              model_name: "gemini-3.7-flash-high"
            })

          s
      end

    {session, project}
  end

  defp stop_session_server(session_id) do
    case SessionServer.ensure_started(session_id) do
      {:ok, pid} when is_pid(pid) ->
        try do
          GenServer.stop(pid, :normal, 5_000)
        catch
          :exit, _reason -> :ok
        end

      _ ->
        :ok
    end
  end

  # -- File buffer and command palette helpers ---------------------------------

  defp open_file_buffer(socket, rel_path) do
    root = socket.assigns.project.root_path

    case WorkspacePath.resolve(root, rel_path) do
      {:ok, full_path} ->
        content =
          case File.read(full_path) do
            {:ok, text} -> text
            {:error, reason} -> "Could not read file: #{inspect(reason)}"
          end

        # Add or select open buffer
        buffers = socket.assigns.open_buffers

        updated_buffers =
          if Enum.any?(buffers, &(&1.path == rel_path)) do
            buffers
          else
            buffers ++
              [%{path: rel_path, content: content, dirty_content: content, dirty?: false}]
          end

        active_buffer = Enum.find(updated_buffers, &(&1.path == rel_path))
        is_dirty = active_buffer && active_buffer.dirty?
        dirty_text = (active_buffer && active_buffer.dirty_content) || content

        socket
        |> assign(:open_buffers, updated_buffers)
        |> assign(:selected_file, rel_path)
        |> assign(:file_content, content)
        |> assign(:dirty_content, dirty_text)
        |> assign(:is_dirty?, is_dirty)

      {:error, _reason} ->
        put_flash(socket, :error, "Invalid file path")
    end
  end

  defp start_test_runner(params, socket) do
    mode = Map.get(params, "mode", "all")
    file_path = Map.get(params, "file")
    line = Map.get(params, "line")

    opts =
      case mode do
        "failed" ->
          [failed: true]

        "stale" ->
          [stale: true]

        "file" when is_binary(file_path) and file_path != "" ->
          l = if line && line != "", do: String.to_integer(line), else: nil
          [paths: [file_path], line: l]

        _ ->
          []
      end

    project_root = socket.assigns.project.root_path
    lv_pid = self()
    task_token = make_ref()

    on_progress = fn pct, msg ->
      send(lv_pid, {:test_runner_progress, task_token, pct, msg})
    end

    opts =
      opts
      |> Keyword.put(:project_root, project_root)
      |> Keyword.put(:project_id, socket.assigns.project.id)
      |> Keyword.put(:session_id, socket.assigns.session.id)
      |> Keyword.put(:on_progress, on_progress)
      |> Keyword.put(:timeout_ms, 60_000)

    task =
      Task.Supervisor.async_nolink(IexCode.TaskSupervisor, fn ->
        IexCode.Tools.run_tests(opts)
      end)

    {:noreply,
     socket
     |> assign(:test_runner_status, :running)
     |> assign(:test_runner_progress_pct, 10)
     |> assign(:test_runner_progress_msg, "Starting ExUnit test suite...")
     |> assign(:test_runner_async_task, task)
     |> assign(:test_runner_task_token, task_token)
     |> assign(:active_tab, "tests")}
  end

  defp apply_test_runner_progress(socket, pct, msg)
       when is_number(pct) and is_binary(msg) do
    current = socket.assigns.test_runner_progress_pct || 0

    if pct >= current do
      socket
      |> assign(:test_runner_progress_pct, pct)
      |> assign(:test_runner_progress_msg, msg)
    else
      socket
    end
  end

  defp apply_test_runner_progress(socket, _pct, _msg), do: socket

  # Editor writes intentionally use the low-level gateway form so the lock can
  # be asserted at the last possible moment before the atomic filesystem effect
  # and still be released from `after` on every success or failure path.
  defp save_editor_file(socket, rel_path, content) do
    project = socket.assigns.project
    session = socket.assigns.session

    with {:ok, full_path} <- WorkspacePath.resolve(project.root_path, rel_path),
         {:ok, handle} <-
           WorkspaceLocks.acquire(project, [{{:file, full_path}, :write}],
             owner_id: editor_lock_owner(session.id),
             session_id: session.id,
             lease_seconds: 5,
             heartbeat_interval_ms: 1_000
           ) do
      try do
        with :ok <- WorkspaceLocks.assert(handle),
             :ok <- atomic_editor_write(full_path, content) do
          :ok
        end
      after
        _ = WorkspaceLocks.release(handle)
      end
    end
  end

  # LiveView event parameters are never trusted as lock identity. Every direct
  # UI workspace mutation is scoped to the mounted project/session and takes a
  # conservative exclusive project lock. The opaque handle remains on this
  # stack only, is asserted immediately before the callback effect, and is
  # released from `after` even when the effect raises or returns an error.
  defp with_ui_mutation_lock(socket, fun) when is_function(fun, 0) do
    project = socket.assigns.project
    session_id = socket.assigns.session.id

    with {:ok, handle} <-
           WorkspaceLocks.acquire(project, [:project],
             owner_id: editor_lock_owner(session_id),
             session_id: session_id,
             lease_seconds: 15,
             heartbeat_interval_ms: 3_000
           ) do
      try do
        case WorkspaceLocks.assert(handle) do
          :ok -> fun.()
          {:error, _reason} = error -> error
        end
      after
        _ = WorkspaceLocks.release(handle)
      end
    end
  end

  defp ui_mutation_error({:workspace_lock_waiting, _locks}) do
    "Workspace change blocked by another IexCode task. Retry after it releases the reservation; no UI state was discarded."
  end

  defp ui_mutation_error(reason), do: inspect(reason)

  defp atomic_editor_write(full_path, content) do
    tmp_path =
      Path.join(
        Path.dirname(full_path),
        ".#{Path.basename(full_path)}.iex-code-#{System.unique_integer([:positive, :monotonic])}.tmp"
      )

    result =
      with :ok <- File.write(tmp_path, content, [:binary, :exclusive]),
           :ok <- preserve_editor_file_mode(full_path, tmp_path),
           :ok <- File.rename(tmp_path, full_path) do
        :ok
      end

    if result != :ok, do: File.rm(tmp_path)
    result
  end

  defp preserve_editor_file_mode(full_path, tmp_path) do
    case File.stat(full_path) do
      {:ok, stat} -> File.chmod(tmp_path, stat.mode)
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp put_active_buffer_content(socket, content) do
    file_path = socket.assigns.selected_file
    original = socket.assigns.file_content || ""
    dirty? = content != original

    buffers =
      Enum.map(socket.assigns.open_buffers, fn buffer ->
        if buffer.path == file_path,
          do: %{buffer | dirty_content: content, dirty?: dirty?},
          else: buffer
      end)

    socket
    |> assign(:dirty_content, content)
    |> assign(:is_dirty?, dirty?)
    |> assign(:open_buffers, buffers)
  end

  defp refresh_workspace_locks(socket) do
    assign(
      socket,
      :workspace_locks,
      Runs.list_workspace_locks(project_id: socket.assigns.project.id, active: true)
    )
  end

  defp editor_lock_owner(session_id), do: "session:#{session_id}"

  defp editor_lock(assigns) do
    with path when is_binary(path) <- assigns.selected_file,
         {:ok, full_path} <- WorkspacePath.resolve(assigns.project.root_path, path) do
      owner_id = editor_lock_owner(assigns.session.id)

      Enum.find(assigns.workspace_locks, fn lock ->
        lock.status == "held" and lock.owner_id != owner_id and
          (lock.resource_type == "project" or
             (lock.resource_type == "file" and
                Path.expand(lock.resource_key) == full_path))
      end)
    else
      _ -> nil
    end
  end

  defp editor_save_error(:outside_workspace), do: "invalid file path"
  defp editor_save_error(:invalid_path), do: "invalid file path"
  defp editor_save_error(reason), do: inspect(reason)

  defp execute_command_palette_item(socket, item) do
    socket = assign(socket, :show_command_palette, false)

    case item.category do
      :view ->
        {:noreply, assign(socket, :active_tab, item.tab)}

      :file ->
        path = item.path

        socket =
          socket
          |> open_file_buffer(path)
          |> assign(:active_tab, "files")

        {:noreply, socket}

      :session ->
        {:noreply,
         push_patch(socket,
           to: ~p"/sessions/#{item.session_id}?project_id=#{socket.assigns.project.id}"
         )}

      :action ->
        case item.id do
          "run_all_tests" ->
            handle_event("run_tests", %{"mode" => "all"}, socket)

          "run_failed_tests" ->
            handle_event("run_tests", %{"mode" => "failed"}, socket)

          "run_stale_tests" ->
            handle_event("run_tests", %{"mode" => "stale"}, socket)

          "start_goal" ->
            handle_event("open_goal_modal", %{}, socket)

          "trigger_autofix" ->
            {:noreply,
             socket |> assign(:active_tab, "tests") |> assign(:show_autofix_modal, true)}

          "ast_search" ->
            {:noreply, assign(socket, :active_tab, "ast")}

          "new_task" ->
            handle_event("toggle_new_task_modal", %{}, socket)

          "new_session" ->
            handle_event("new_session", %{}, socket)

          "toggle_swarm" ->
            handle_event("toggle_swarm_mode", %{}, socket)

          "open_settings" ->
            handle_event("toggle_settings_modal", %{}, socket)

          "git_fetch" ->
            handle_event("git_fetch", %{}, socket)

          _ ->
            {:noreply, socket}
        end
    end
  end

  # -- Terminal helpers --------------------------------------------------------

  defp append_terminal_output(socket, text) do
    assign(socket, :terminal_output, cap_terminal_output(terminal_base(socket) <> text))
  end

  defp terminal_base(socket) do
    case socket.assigns.terminal_output do
      nil -> ""
      output -> output
    end
  end

  defp cap_terminal_output(output) do
    lines = String.split(output, "\n")

    if length(lines) > @terminal_output_max_lines do
      lines
      |> Enum.drop(length(lines) - @terminal_output_max_lines)
      |> Enum.join("\n")
    else
      output
    end
  end

  defp parse_terminal_dimension(val, _default) when is_integer(val) and val > 0, do: val

  defp parse_terminal_dimension(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} when int > 0 -> int
      _ -> default
    end
  end

  defp parse_terminal_dimension(_val, default), do: default

  # -- History search ----------------------------------------------------------

  defp filter_history_messages(messages, query) do
    q = query |> to_string() |> String.trim() |> String.downcase()

    if q == "" do
      messages
    else
      Enum.filter(messages, fn msg ->
        String.contains?(String.downcase(to_string(msg.content)), q) or
          String.contains?(String.downcase(to_string(msg.agent_name)), q)
      end)
    end
  end

  defp translated_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp refresh_git_state(socket) do
    root = socket.assigns.project.root_path

    with {:ok, status} <- Git.status(root) do
      branches =
        case Git.branches(root) do
          {:ok, b} -> b
          _ -> []
        end

      current_branch =
        case Git.current_branch(root) do
          {:ok, cb} -> cb
          _ -> "main"
        end

      unstaged_diff_raw =
        case Git.diff(root, unified: 3) do
          {:ok, d} -> d || ""
          _ -> ""
        end

      staged_diff_raw =
        case Git.diff(root, staged: true, unified: 3) do
          {:ok, d} -> d || ""
          _ -> ""
        end

      unstaged_diffs = DiffParser.parse!(unstaged_diff_raw)
      staged_diffs = DiffParser.parse!(staged_diff_raw)
      parsed_diffs = unstaged_diffs ++ staged_diffs

      scope = socket.assigns[:active_diff_scope] || :unstaged

      active_list =
        case scope do
          :staged -> staged_diffs
          _ -> unstaged_diffs
        end

      selected_diff_file =
        socket.assigns[:selected_diff_file] ||
          (List.first(active_list) &&
             (List.first(active_list).path || List.first(active_list).new_path)) ||
          (List.first(parsed_diffs) &&
             (List.first(parsed_diffs).path || List.first(parsed_diffs).new_path)) ||
          socket.assigns[:diff_file_path]

      selected_file_diff =
        Enum.find(
          if(active_list != [], do: active_list, else: parsed_diffs),
          &(&1.path == selected_diff_file or &1.new_path == selected_diff_file or
              &1.old_path == selected_diff_file)
        )

      diff_hunks = if selected_file_diff, do: selected_file_diff.hunks, else: []

      diff_text =
        cond do
          selected_file_diff && selected_file_diff.hunks != [] ->
            Enum.map_join(
              selected_file_diff.hunks,
              "\n",
              &DiffParser.format_hunk_patch(selected_file_diff, &1)
            )

          scope == :staged and staged_diff_raw != "" ->
            staged_diff_raw

          true ->
            unstaged_diff_raw
        end

      files = list_project_files(root)

      socket
      |> assign(:git_status, status)
      |> assign(:git_branches, branches)
      |> assign(:current_branch, current_branch)
      |> assign(:staged_diffs, staged_diffs)
      |> assign(:unstaged_diffs, unstaged_diffs)
      |> assign(:parsed_diffs, parsed_diffs)
      |> assign(:selected_diff_file, selected_diff_file)
      |> assign(:diff_file_path, selected_diff_file || socket.assigns[:diff_file_path])
      |> assign(:diff_hunks, diff_hunks)
      |> assign(:diff_text, diff_text)
      |> assign(:project_files, files)
      |> assign(:git_error, nil)
    else
      {:error, reason} ->
        assign(socket, :git_error, "Git error: #{inspect(reason)}")

      _ ->
        assign(socket, :git_error, "Git is not available for this project")
    end
  end

  defp seed_initial_tasks(project_id, session_id) do
    sample_tasks = [
      %{
        project_id: project_id,
        session_id: session_id,
        title: "say hi to me <3",
        description: "Verify worker connection and greeting ping.",
        status: "running",
        priority: "low",
        assignee: "default",
        worker_pid: "78042",
        estimate: "3m (Low effort)",
        latest_summary: "Said hi to Brooklyn with love <3",
        steps_total: 4,
        steps_completed: 2,
        tags: ["Test", "Heartbeat"]
      },
      %{
        project_id: project_id,
        session_id: session_id,
        title: "Fix incorrect transaction status for pending card payments",
        description: "Reconcile payment webhook states under high concurrency.",
        status: "ready",
        priority: "high",
        assignee: "coder",
        worker_pid: nil,
        estimate: "15-20m (Medium effort)",
        latest_summary: "Reproduction test case formulated.",
        steps_total: 4,
        steps_completed: 2,
        tags: ["FinPay", "Bug"]
      },
      %{
        project_id: project_id,
        session_id: session_id,
        title: "AST search engine & multi-file fuzzy patch matcher",
        description: "Implement Elixir AST query formatters and parser tests.",
        status: "done",
        priority: "critical",
        assignee: "verifier",
        worker_pid: "91024",
        estimate: "30m (High effort)",
        latest_summary: "AST query and multi-patch verified with 100% test coverage.",
        steps_total: 4,
        steps_completed: 4,
        tags: ["Core", "AST"]
      },
      %{
        project_id: project_id,
        session_id: session_id,
        title: "Nightly regression test runner & telemetry sync",
        description: "Scheduled cron task executing at 00:00 UTC daily.",
        status: "scheduled",
        priority: "medium",
        assignee: "verifier",
        worker_pid: nil,
        estimate: "10m",
        latest_summary: "Scheduled for next trigger at 00:00 UTC.",
        steps_total: 3,
        steps_completed: 0,
        scheduled_at: DateTime.new!(~D[2026-08-10], ~T[00:00:00], "Etc/UTC"),
        cron_expression: "0 0 * * *",
        tags: ["Cron", "Regression"]
      },
      %{
        project_id: project_id,
        session_id: session_id,
        title: "AST indexer & schema cache sync",
        description: "Rebuild AST semantic indices across all repository modules.",
        status: "scheduled",
        priority: "high",
        assignee: "planner",
        worker_pid: nil,
        estimate: "15m",
        latest_summary: "Ready to index 240 module ASTs.",
        steps_total: 4,
        steps_completed: 1,
        scheduled_at: DateTime.new!(~D[2026-08-07], ~T[10:30:00], "Etc/UTC"),
        cron_expression: "0 10 * * 5",
        tags: ["AST", "Cron"]
      },
      %{
        project_id: project_id,
        session_id: session_id,
        title: "Staging deployment canary validation",
        description: "Run automated health probes and canary traffic test.",
        status: "scheduled",
        priority: "critical",
        assignee: "verifier",
        worker_pid: nil,
        estimate: "20m",
        latest_summary: "Staging canary container deployed.",
        steps_total: 5,
        steps_completed: 2,
        scheduled_at: DateTime.new!(~D[2026-08-15], ~T[14:00:00], "Etc/UTC"),
        cron_expression: nil,
        tags: ["Staging", "Canary"]
      },
      %{
        project_id: project_id,
        session_id: session_id,
        title: "Auto-heal swarm diagnostic cycle",
        description: "Analyze error logs and suggest self-healing auto-fix patches.",
        status: "scheduled",
        priority: "high",
        assignee: "coder",
        worker_pid: nil,
        estimate: "12m",
        latest_summary: "Diagnostic triggers active.",
        steps_total: 3,
        steps_completed: 0,
        scheduled_at: DateTime.new!(~D[2026-08-20], ~T[16:30:00], "Etc/UTC"),
        cron_expression: "30 16 * * *",
        tags: ["Heal", "Swarm"]
      },
      %{
        project_id: project_id,
        session_id: session_id,
        title: "PubSub telemetry & channel optimizer",
        description: "Optimize high-throughput PubSub buffer distribution.",
        status: "scheduled",
        priority: "medium",
        assignee: "default",
        worker_pid: nil,
        estimate: "8m",
        latest_summary: "Monitoring 60 concurrent channel streams.",
        steps_total: 2,
        steps_completed: 1,
        scheduled_at: DateTime.new!(~D[2026-08-25], ~T[09:00:00], "Etc/UTC"),
        cron_expression: nil,
        tags: ["PubSub", "Perf"]
      }
    ]

    for attrs <- sample_tasks do
      {:ok, task} = Kanban.create_task(attrs)
      task
    end
  end

  defp tasks_for_day(tasks, %Date{} = date) do
    Enum.filter(tasks, &scheduled_on?(&1, date))
  end

  # Calendar grid cells carry the full year/month/day — prefer passing those
  defp tasks_for_day(tasks, %{year: year, month: month, day: day}) do
    case Date.new(year, month, day) do
      {:ok, date} -> tasks_for_day(tasks, date)
      _ -> []
    end
  end

  defp tasks_for_day(tasks, day) when is_binary(day) do
    case Date.from_iso8601(day) do
      {:ok, date} -> tasks_for_day(tasks, date)
      _ -> []
    end
  end

  # Legacy integer day-of-month fallback
  defp tasks_for_day(tasks, day) when is_integer(day) do
    Enum.filter(tasks, fn task ->
      (task.scheduled_at && task.scheduled_at.day == day) ||
        (task.metadata && task.metadata["day"] == day)
    end)
  end

  defp scheduled_on?(task, %Date{} = date) do
    cond do
      match?(%DateTime{}, task.scheduled_at) ->
        DateTime.to_date(task.scheduled_at) == date

      match?(%NaiveDateTime{}, task.scheduled_at) ->
        NaiveDateTime.to_date(task.scheduled_at) == date

      match?(%Date{}, task.scheduled_at) ->
        task.scheduled_at == date

      true ->
        (task.metadata && task.metadata["date"]) == Date.to_iso8601(date)
    end
  end

  defp list_project_files(root_path) do
    if File.dir?(root_path) do
      root_path
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.reject(&String.contains?(&1, ["_build", "deps", ".git", ".elixir_ls", ".agents"]))
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.relative_to(&1, root_path))
      |> Enum.sort()
    else
      []
    end
  end

  defp seed_initial_messages(session_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    sample_msgs = [
      %{
        session_id: session_id,
        role: "user",
        content: "generate dashscope_new_report.md and inspect probe statuses",
        inserted_at: DateTime.add(now, -300, :second)
      },
      %{
        session_id: session_id,
        role: "assistant",
        agent_name: "PlannerAgent",
        content: """
        ### dashscope_new_report.md

        Total probed: 3504 keys (3386 + 158 unique)
        Buckets: 40 working + 1075 insufficient + 2389 invalid

        Per-endpoint HTTP status:
        - 200 (working)
        - 400 (arrears)
        - 401 (invalid)
        - 403 (quota)
        - 0 (network)

        Changes since last probe (Aug 19 -> Aug 20):
        • CN working: 29 -> 30 (+1 new working key)
        • Intl working: 11 -> 10 (-1, sk-0fc24c22... is new)
        • Insufficient: 1083 -> 1075 (-8, some moved to active)
        • 6 CN keys had network timeouts (classified under transient)
        • Still zero keys work on both endpoints
        """,
        inserted_at: DateTime.add(now, -240, :second)
      },
      %{
        session_id: session_id,
        role: "user",
        content: "also update deepseek_.md file",
        inserted_at: DateTime.add(now, -180, :second)
      },
      %{
        session_id: session_id,
        role: "assistant",
        agent_name: "CoderAgent",
        content: """
        deepseek_working.md updated from 3 -> 6 working keys. All 6 re-probed fresh with live balances:

        • sk-dsk-8849... (150.00 CNY remaining)
        • sk-dsk-3291... (85.40 CNY remaining)
        • sk-dsk-7712... (210.00 CNY remaining)
        • sk-dsk-1049... (50.00 CNY remaining)
        • sk-dsk-4921... (120.00 CNY remaining)
        • sk-dsk-9923... (300.00 CNY remaining)
        """,
        inserted_at: DateTime.add(now, -120, :second)
      },
      %{
        session_id: session_id,
        role: "user",
        content: "also add balances like other deepseek keys",
        inserted_at: DateTime.add(now, -60, :second)
      },
      %{
        session_id: session_id,
        role: "assistant",
        agent_name: "VerifierAgent",
        content: """
        All balances synchronized with live provider telemetry. Full access quota verified across all 6 keys.
        """,
        inserted_at: now
      }
    ]

    for attrs <- sample_msgs do
      case Sessions.create_message(attrs) do
        {:ok, msg} -> msg
        _ -> nil
      end
    end
    |> Enum.filter(& &1)
  end

  # Durable asynchronous run projection. Runs and their journal are loaded from
  # SQLite, never inferred from ephemeral worker PIDs, so reconnects are exact.
  defp assign_run_projection(socket, session_id) do
    runs = Runs.list_runs(session_id: session_id, limit: 100)
    selected = List.first(runs)
    approvals = if selected, do: Runs.list_approvals(selected), else: []
    pending_approval_count = Runs.count_pending_approvals(session_id)
    agents = if selected, do: Runs.list_run_agents(selected, limit: 100), else: []

    socket
    |> assign(:selected_run, selected)
    |> assign(:run_steps, if(selected, do: Runs.list_steps(selected), else: []))
    |> assign(:run_approvals, approvals)
    |> assign(:run_controls, if(selected, do: Runs.list_controls(selected), else: []))
    |> assign(:run_manifest, run_manifest(selected))
    |> assign(:run_artifacts, if(selected, do: Runs.list_artifacts(selected), else: []))
    |> assign(:run_agent_count, length(agents))
    |> assign(:run_fleet_summary, run_fleet_summary(agents))
    |> assign(:run_fleet_loading?, false)
    |> assign(:run_agent_guidance, %{})
    |> assign(:run_agent_receipts, run_agent_control_receipts(selected))
    |> stream(:run_agents, agents, reset: true, dom_id: &"run-agent-#{&1.id}")
    |> assign(:run_rows, runs)
    |> assign(
      :run_event_rows,
      if(selected, do: Runs.list_latest_events(selected, limit: 500), else: [])
    )
    |> assign(:run_count, length(runs))
    |> assign(:run_counts, run_counts(runs, pending_approval_count))
    |> assign(:run_dispatcher_stats, safe_dispatcher_stats())
  end

  defp select_run_projection(socket, run) do
    approvals = Runs.list_approvals(run)
    session_runs = Runs.list_runs(session_id: socket.assigns.session.id, limit: 100)
    pending_approval_count = Runs.count_pending_approvals(socket.assigns.session.id)
    agents = Runs.list_run_agents(run, limit: 100)

    agent_guidance =
      case socket.assigns.selected_run do
        %{id: selected_id} when selected_id == run.id -> socket.assigns.run_agent_guidance
        _other -> %{}
      end

    socket
    |> assign(:selected_run, run)
    |> assign(:run_steps, Runs.list_steps(run))
    |> assign(:run_approvals, approvals)
    |> assign(:run_controls, Runs.list_controls(run))
    |> assign(:run_manifest, run_manifest(run))
    |> assign(:run_artifacts, Runs.list_artifacts(run))
    |> assign(:run_agent_count, length(agents))
    |> assign(:run_fleet_summary, run_fleet_summary(agents))
    |> assign(:run_fleet_loading?, false)
    |> assign(:run_agent_guidance, agent_guidance)
    |> assign(:run_agent_receipts, run_agent_control_receipts(run))
    |> stream(:run_agents, agents, reset: true, dom_id: &"run-agent-#{&1.id}")
    |> assign(:run_rows, session_runs)
    |> assign(:run_event_rows, Runs.list_latest_events(run, limit: 500))
    |> assign(:run_count, length(session_runs))
    |> assign(:run_counts, run_counts(session_runs, pending_approval_count))
    |> assign(:run_dispatcher_stats, safe_dispatcher_stats())
  end

  defp refresh_selected_run(socket) do
    case socket.assigns.selected_run do
      nil -> assign_run_projection(socket, socket.assigns.session.id)
      selected -> select_run_projection(socket, Runs.get_run(selected.id) || selected)
    end
  end

  defp refresh_run_fleet(socket) do
    agents =
      case socket.assigns.selected_run do
        nil -> []
        run -> Runs.list_run_agents(run, limit: 100)
      end

    socket
    |> assign(:run_agent_count, length(agents))
    |> assign(:run_fleet_summary, run_fleet_summary(agents))
    |> assign(:run_fleet_loading?, false)
    |> assign(:run_agent_receipts, run_agent_control_receipts(socket.assigns.selected_run))
    |> stream(:run_agents, agents, reset: true, dom_id: &"run-agent-#{&1.id}")
  end

  defp run_agent_control_receipts(nil), do: %{}

  defp run_agent_control_receipts(run) do
    run
    |> Runs.list_run_agent_controls_for_run(limit: 1)
    |> Enum.group_by(& &1.run_agent_id)
  end

  defp run_fleet_summary(agents) do
    %{
      active: Enum.count(agents, &(&1.status in ["starting", "idle", "running", "stopping"])),
      paused: Enum.count(agents, &(&1.status == "paused")),
      attention: Enum.count(agents, &(&1.status in ["failed", "interrupted"])),
      recovering: Enum.count(agents, &(&1.status == "starting" and &1.attempt > 1)),
      tokens: Enum.reduce(agents, 0, &((&1.input_tokens || 0) + (&1.output_tokens || 0) + &2))
    }
  end

  defp refresh_run_counts(socket) do
    runs = Runs.list_runs(session_id: socket.assigns.session.id, limit: 100)
    pending_approval_count = Runs.count_pending_approvals(socket.assigns.session.id)

    socket
    |> assign(:run_rows, runs)
    |> assign(:run_count, length(runs))
    |> assign(:run_counts, run_counts(runs, pending_approval_count))
  end

  defp run_counts(runs, pending_approval_count) do
    %{
      active: Enum.count(runs, &(&1.status in ["running", "paused"])),
      queued: Enum.count(runs, &(&1.status == "queued")),
      attention: Enum.count(runs, &(&1.status in ["failed", "interrupted"])),
      approvals: pending_approval_count
    }
  end

  defp safe_dispatcher_stats do
    if Process.whereis(RunDispatcher) do
      RunDispatcher.get_stats() |> Map.put(:online, true)
    else
      offline_dispatcher_stats()
    end
  catch
    :exit, _ -> offline_dispatcher_stats()
  end

  defp offline_dispatcher_stats do
    %{online: false, queued: 0, active: 0, capacity: 0, max_concurrency: 0, projects: []}
  end

  defp control_async_run(socket, run_id, action) do
    run = Runs.get_run(run_id)

    if run && run.session_id == socket.assigns.session.id do
      result =
        case action do
          :pause -> RunDispatcher.pause(run)
          :resume -> RunDispatcher.resume(run)
          :cancel -> RunDispatcher.cancel(run)
          :retry -> RunDispatcher.retry(run)
        end

      case result do
        {:ok, updated} ->
          label = action |> Atom.to_string() |> String.capitalize()

          {:noreply,
           socket
           |> select_run_projection(updated)
           |> put_flash(:info, "#{label} request persisted")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Run control failed: #{format_run_error(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "Run not found in this session")}
    end
  catch
    :exit, _ ->
      {:noreply, put_flash(socket, :error, "The run dispatcher is not available")}
  end

  defp selected_run_agent?(socket, agent_id) when is_binary(agent_id) do
    case socket.assigns.selected_run do
      nil -> false
      run -> not is_nil(Runs.get_run_agent(run, agent_id))
    end
  end

  defp selected_run_agent?(_socket, _agent_id), do: false

  defp control_selected_run_agent(socket, agent_id, kind, payload)
       when kind in [:pause, :resume, :cancel, :steer, :restart] and is_map(payload) do
    run = socket.assigns.selected_run
    module = IexCode.Engine.RunFleetSupervisor

    if run && Code.ensure_loaded?(module) && function_exported?(module, :control_agent, 4) do
      apply(module, :control_agent, [run, agent_id, kind, payload])
    else
      {:error, :fleet_control_unavailable}
    end
  catch
    :exit, reason -> {:error, {:fleet_control_unavailable, reason}}
  end

  defp format_run_error(%Ecto.Changeset{} = changeset) do
    changeset.errors
    |> Enum.map_join(", ", fn {field, {message, _}} -> "#{field} #{message}" end)
  end

  defp format_run_error(reason), do: inspect(reason)

  defp task_priority_to_run_priority("critical"), do: "critical"
  defp task_priority_to_run_priority("high"), do: "high"
  defp task_priority_to_run_priority("low"), do: "low"
  defp task_priority_to_run_priority(_), do: "normal"

  # Chat is intentionally live and conversational. All operational views keep
  # the safer durable background default.
  defp maybe_set_tab_dispatch_mode(socket, "chat"),
    do: assign(socket, :dispatch_mode, "interactive")

  defp maybe_set_tab_dispatch_mode(socket, _tab), do: socket

  defp sync_run_linked_task(socket, run) do
    task_id = Map.get(run.metadata || %{}, "kanban_task_id")

    if is_binary(task_id) do
      case Kanban.get_task(task_id) do
        nil ->
          socket

        task ->
          recurring? = task.cron_expression not in [nil, ""]

          attrs =
            cond do
              recurring? ->
                # This row already represents the next occurrence. The
                # dispatcher projects terminal state only through the guarded
                # `run:<id>` claim, so the previous occurrence cannot touch it.
                nil

              run.status in ["completed", "failed", "interrupted", "cancelled"] ->
                :terminal

              true ->
                status =
                  case run.status do
                    "queued" -> "ready"
                    "running" -> "running"
                    "paused" -> "blocked"
                    _ -> task.status
                  end

                %{
                  status: status,
                  worker_pid: "run:#{run.id}",
                  latest_summary: "Durable run #{run.status}"
                }
            end

          update_result =
            case attrs do
              nil -> :noop
              :terminal -> Kanban.project_run_terminal(run.id, run.status, run.error_message)
              attrs -> Kanban.update_task(task, attrs)
            end

          case update_result do
            {:ok, updated} ->
              tasks =
                Enum.map(socket.assigns.tasks, fn existing ->
                  if existing.id == updated.id, do: updated, else: existing
                end)

              assign(socket, :tasks, tasks)

            _ ->
              socket
          end
      end
    else
      socket
    end
  end

  defp month_name(1), do: "January"
  defp month_name(2), do: "February"
  defp month_name(3), do: "March"
  defp month_name(4), do: "April"
  defp month_name(5), do: "May"
  defp month_name(6), do: "June"
  defp month_name(7), do: "July"
  defp month_name(8), do: "August"
  defp month_name(9), do: "September"
  defp month_name(10), do: "October"
  defp month_name(11), do: "November"
  defp month_name(12), do: "December"
  defp month_name(_), do: "August"

  defp format_date_display(nil), do: format_date_display(Date.to_iso8601(Date.utc_today()))
  defp format_date_display(""), do: format_date_display(Date.to_iso8601(Date.utc_today()))

  defp format_date_display(date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, date} ->
        m = String.pad_leading("#{date.month}", 2, "0")
        d = String.pad_leading("#{date.day}", 2, "0")
        "#{m}/#{d}/#{date.year}"

      _ ->
        date_str
    end
  end

  defp calendar_grid_cells(year, month, selected_date_str) do
    first_date = Date.new!(year, month, 1)
    day_of_week = Date.day_of_week(first_date)
    sunday_offset = if day_of_week == 7, do: 0, else: day_of_week
    days_in_current = Date.days_in_month(first_date)

    {prev_year, prev_month} =
      if month == 1, do: {year - 1, 12}, else: {year, month - 1}

    days_in_prev = Date.days_in_month(Date.new!(prev_year, prev_month, 1))

    selected_date =
      case Date.from_iso8601(selected_date_str || "") do
        {:ok, d} -> d
        _ -> nil
      end

    today = Date.utc_today()

    prev_cells =
      if sunday_offset > 0 do
        start_day = days_in_prev - sunday_offset + 1

        for d <- start_day..days_in_prev do
          cell_date = Date.new!(prev_year, prev_month, d)

          %{
            year: prev_year,
            month: prev_month,
            day: d,
            is_current_month: false,
            is_today: cell_date == today,
            is_selected: cell_date == selected_date
          }
        end
      else
        []
      end

    current_cells =
      for d <- 1..days_in_current do
        cell_date = Date.new!(year, month, d)

        %{
          year: year,
          month: month,
          day: d,
          is_current_month: true,
          is_today: cell_date == today,
          is_selected: cell_date == selected_date
        }
      end

    total_so_far = length(prev_cells) + length(current_cells)
    remaining = 42 - total_so_far

    {next_year, next_month} =
      if month == 12, do: {year + 1, 1}, else: {year, month + 1}

    next_cells =
      for d <- 1..remaining do
        cell_date = Date.new!(next_year, next_month, d)

        %{
          year: next_year,
          month: next_month,
          day: d,
          is_current_month: false,
          is_today: cell_date == today,
          is_selected: cell_date == selected_date
        }
      end

    prev_cells ++ current_cells ++ next_cells
  end

  defp sanitize_settings_params(params) when is_map(params) do
    params
    |> maybe_parse_int("swarm_agent_count")
    |> maybe_parse_int("max_tokens")
    |> maybe_parse_int("research_max_sources")
    |> maybe_parse_int("research_parallelism")
    |> maybe_parse_float("temperature")
    |> maybe_parse_bool("auto_save")
  end

  defp merge_search_provider_settings(params, settings) do
    case Map.get(params, "search_providers") do
      submitted when is_map(submitted) ->
        existing = settings.search_providers || %{}

        merged =
          Map.new(submitted, fn {provider, raw_config} ->
            previous = Map.get(existing, provider, %{})
            raw_config = if is_map(raw_config), do: raw_config, else: %{}

            config =
              previous
              |> Map.merge(
                raw_config
                |> Enum.reject(fn {_key, value} ->
                  is_binary(value) and String.trim(value) == ""
                end)
                |> Map.new()
              )
              |> Map.put("enabled", Map.get(raw_config, "enabled") in ["true", "1", "on", true])

            {provider, config}
          end)

        Map.put(params, "search_providers", Map.merge(existing, merged))

      _ ->
        params
    end
  end

  defp run_setup_defaults(settings) do
    %{
      "mode" => "code",
      "priority" => "normal",
      "max_attempts" => "3",
      "token_budget" => "",
      "cost_budget_cents" => "",
      "time_budget_minutes" => "",
      "research_depth" => settings.research_depth || "standard",
      "research_max_sources" => to_string(settings.research_max_sources || 12),
      "providers" =>
        settings
        |> enabled_search_providers()
        |> Map.new(&{&1, "true"})
    }
  end

  defp enabled_search_providers(settings) do
    providers = settings.search_providers || %{}
    order = settings.search_provider_order || Map.keys(providers)

    enabled =
      Enum.filter(order, fn provider ->
        config = Map.get(providers, provider, %{})

        Map.get(config, "enabled", Map.get(config, :enabled, false)) == true and
          IexCode.Research.Registry.automatically_selectable?(provider)
      end)

    enabled
  end

  defp refresh_run_setup_settings(socket, settings) do
    providers = enabled_search_providers(settings)
    depth = settings.research_depth || "standard"
    sources = settings.research_max_sources || 12

    params = %{
      "mode" => socket.assigns.run_setup_mode,
      "priority" => socket.assigns.run_setup_priority,
      "max_attempts" => socket.assigns.run_setup_max_attempts,
      "token_budget" => socket.assigns.run_setup_token_budget,
      "cost_budget_cents" => socket.assigns.run_setup_cost_budget_cents,
      "time_budget_minutes" => socket.assigns.run_setup_time_budget_minutes,
      "research_depth" => depth,
      "research_max_sources" => sources,
      "providers" => Map.new(providers, &{&1, "true"})
    }

    socket
    |> assign(:run_setup_research_depth, depth)
    |> assign(:run_setup_research_sources, sources)
    |> assign(:run_setup_providers, providers)
    |> assign(:run_setup_form, to_form(params, as: :run_setup))
  end

  defp search_provider_config(settings, provider) do
    settings.search_providers
    |> Kernel.||(%{})
    |> Map.get(provider, %{})
  end

  defp search_lifecycle_tone(:active),
    do: "border-emerald-500/20 bg-emerald-500/[0.05] text-emerald-300"

  defp search_lifecycle_tone(:sunsetting),
    do: "border-amber-500/25 bg-amber-500/[0.06] text-amber-300"

  defp search_lifecycle_tone(:retired),
    do: "border-rose-500/25 bg-rose-500/[0.06] text-rose-300"

  defp search_lifecycle_tone(:unofficial),
    do: "border-blue-500/20 bg-blue-500/[0.05] text-blue-300"

  defp search_lifecycle_tone(_lifecycle),
    do: "border-[#303844] bg-[#151b22] text-gray-400"

  defp search_lifecycle_note(%{lifecycle: :active, capabilities: capabilities}) do
    capabilities
    |> Enum.take(3)
    |> Enum.map_join(" · ", &(&1 |> Atom.to_string() |> String.replace("_", " ")))
  end

  defp search_lifecycle_note(%{lifecycle: :sunsetting, retires_at: retires_at}) do
    "No new customers · sunsets #{Date.to_iso8601(retires_at)}"
  end

  defp search_lifecycle_note(%{lifecycle: :retired}),
    do: "Retired compatibility adapter · explicit API requests only"

  defp search_lifecycle_note(%{lifecycle: :unofficial}),
    do: "Unofficial credential-free HTML adapter"

  defp search_lifecycle_note(_descriptor), do: "Provider lifecycle not reported"

  defp masked_secret(secret) when is_binary(secret) and byte_size(secret) >= 4,
    do: "Configured ·•••• #{String.slice(secret, -4, 4)}"

  defp masked_secret(_secret), do: "Not configured"

  defp run_manifest(nil), do: %{}

  defp run_manifest(%{kind: "deep_research"} = run) do
    metadata = run.metadata || %{}
    research = Map.get(metadata, "research") || Map.get(metadata, :research) || %{}

    research
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.put_new("mode", if(run.kind == "deep_research", do: "research", else: run.mode))
  end

  defp run_manifest(_run), do: %{}

  defp enabled_tools(active_tools) do
    core =
      ~w(read_file write_file patch_file multi_patch list_dir grep_search run_tests run_command git_status git_diff git_stage git_commit git_generate_commit)

    optional =
      active_tools
      |> MapSet.to_list()
      |> Enum.flat_map(fn
        "ast_search" -> ["ast_search"]
        "web_search" -> ["web_search", "fetch_url"]
        _ -> []
      end)

    Enum.uniq(core ++ optional)
  end

  defp normalize_run_mode(mode) when mode in ["code", "research"], do: mode
  defp normalize_run_mode(_mode), do: "code"

  defp normalize_run_priority(priority) when priority in ~w(low normal high critical),
    do: priority

  defp normalize_run_priority(_priority), do: "normal"

  defp normalize_research_depth(depth) when depth in ~w(quick standard deep), do: depth
  defp normalize_research_depth(_depth), do: "standard"

  defp optional_integer(value, minimum, maximum) do
    case value do
      integer when is_integer(integer) ->
        integer |> max(minimum) |> min(maximum)

      binary when is_binary(binary) ->
        case Integer.parse(String.trim(binary)) do
          {integer, ""} -> integer |> max(minimum) |> min(maximum)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp bounded_integer(value, default, minimum, maximum),
    do: optional_integer(value, minimum, maximum) || default

  defp minutes_to_ms(nil), do: nil
  defp minutes_to_ms(minutes) when is_integer(minutes), do: minutes * 60_000

  defp maybe_parse_int(map, key) do
    case Map.get(map, key) do
      val when is_binary(val) and val != "" ->
        case Integer.parse(val) do
          {int, _} -> Map.put(map, key, int)
          :error -> map
        end

      _ ->
        map
    end
  end

  defp maybe_parse_float(map, key) do
    case Map.get(map, key) do
      val when is_binary(val) and val != "" ->
        case Float.parse(val) do
          {flt, _} -> Map.put(map, key, flt)
          :error -> map
        end

      _ ->
        map
    end
  end

  defp maybe_parse_bool(map, key) do
    case Map.get(map, key) do
      "true" -> Map.put(map, key, true)
      "false" -> Map.put(map, key, false)
      "1" -> Map.put(map, key, true)
      "0" -> Map.put(map, key, false)
      _ -> map
    end
  end

  defp all_directory_paths(files) when is_list(files) do
    files
    |> Enum.flat_map(fn file ->
      parts = Path.split(to_string(file))

      if length(parts) > 1 do
        Enum.map(1..(length(parts) - 1), fn len ->
          parts |> Enum.take(len) |> Path.join()
        end)
      else
        []
      end
    end)
    |> MapSet.new()
  end

  defp all_directory_paths(_), do: MapSet.new()
end
