defmodule IexCodeWeb.WorkspaceLive do
  use IexCodeWeb, :live_view
  require Logger
  alias IexCode.{Projects, Sessions, Settings, Kanban}
  alias IexCode.Engine.SessionServer
  alias Phoenix.PubSub
  import IexCodeWeb.WorkspaceComponents

  @impl true
  def mount(params, _session, socket) do
    # 1. Resolve session and project consistently
    {session, project} =
      case params["id"] do
        nil ->
          project =
            case params["project_id"] do
              nil ->
                cwd = File.cwd!()
                {:ok, p} = Projects.get_or_create_project(cwd, Path.basename(cwd))
                p

              p_id ->
                Projects.get_project!(p_id)
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

        s_id ->
          session = Sessions.get_session!(s_id)
          project = Projects.get_project!(session.project_id)
          {session, project}
      end

    projects = Projects.list_projects()

    if connected?(socket) do
      PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")
      Kanban.subscribe(project.id)
      SessionServer.ensure_started(session.id)
    end

    messages = Sessions.list_messages(session.id)

    messages =
      if messages == [] do
        seed_initial_messages(session.id)
      else
        messages
      end

    operations = Sessions.list_operations(session.id)
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

    sample_diff = """
    --- a/lib/iex_code/engine/swarm_coordinator.ex
    +++ b/lib/iex_code/engine/swarm_coordinator.ex
    @@ -45,7 +45,9 @@ defmodule IexCode.Engine.SwarmCoordinator do
       def run_swarm(session_id, prompt, opts \\ []) do
    -    # Single-pass execution
    -    {:ok, summary}
    +    # Self-healing feedback loop with cycle detection
    +    with {:ok, plan} <- PlannerAgent.plan(session_id, prompt),
    +         {:ok, patches} <- CoderAgent.formulate_patches(session_id, plan) do
    +      VerifierAgent.verify_and_heal(session_id, patches, max_retries: 3)
    +    end
       end
     end
    """

    {:ok,
     socket
     |> assign(:page_title, "#{session.title} · #{project.name}")
     |> assign(:project, project)
     |> assign(:projects, projects)
     |> assign(:session, session)
     |> assign(:sessions, sessions)
     |> assign(:messages, messages)
     |> assign(:operations, operations)
     |> assign(:expanded_ops, MapSet.new())
     |> assign(:active_agent, nil)
     |> assign(:active_stage, :init)
     |> assign(:settings, settings)
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
     |> assign(:selected_file, nil)
     |> assign(:file_content, nil)
     |> assign(:file_filter, "")
     |> assign(:diff_text, sample_diff)
     |> assign(:diff_mode, "inline")
     |> assign(:diff_file_path, "lib/iex_code/engine/swarm_coordinator.ex")
     |> assign(:changes_subtab, "changes")
     |> assign(:project_files, files)
     |> assign(:terminal_output, "Ready. Type a command or click a quick action above.")
     |> assign(:open_dropdown, nil)
     |> assign(:show_settings_modal, false)
     |> assign(:show_project_modal, false)
     |> assign(:show_time_picker, false)
     |> assign(:selected_time_slot, "10:30 AM - 11:00 AM")
     |> assign(:selected_schedule_status, "Available")
     |> assign(:show_custom_time_input, false)
     |> assign(:show_scheduled_task_modal, false)
     |> assign(:selected_scheduled_task, nil)
     |> assign(:selected_calendar_date, "2026-08-20")
     |> assign(:selected_calendar_day, 20)
     |> assign(:new_task_date, "2026-08-20")
     |> assign(:new_task_time, "10:30 AM")
     |> assign(:new_task_schedule_type, "scheduled")
     |> assign(:picker_mode, :datetime)
     |> assign(:show_date_picker_popover, false)
     |> assign(:picker_year, 2026)
     |> assign(:picker_month, 8)
     |> assign(:user_availability, "Available")
     |> assign(:user_availability_subtext, "Instant notifications & swarm active")
     |> assign(:prompt_form, to_form(%{"prompt" => ""}))
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
     |> assign(:terminal_form, to_form(%{"command" => "mix test"}))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    if params["id"] && params["id"] != socket.assigns.session.id do
      old_id = socket.assigns.session.id
      new_session = Sessions.get_session!(params["id"])
      project = Projects.get_project!(new_session.project_id)

      if connected?(socket) do
        PubSub.unsubscribe(IexCode.PubSub, "session:#{old_id}")
        PubSub.subscribe(IexCode.PubSub, "session:#{new_session.id}")
        SessionServer.ensure_started(new_session.id)
      end

      messages = Sessions.list_messages(new_session.id)
      operations = Sessions.list_operations(new_session.id)
      sessions = Sessions.list_sessions_for_project(project.id)
      files = list_project_files(project.root_path)
      tasks = Kanban.list_tasks(project.id)

      {:noreply,
       socket
       |> assign(:session, new_session)
       |> assign(:project, project)
       |> assign(:sessions, sessions)
       |> assign(:project_files, files)
       |> assign(:tasks, tasks)
       |> assign(:page_title, "#{new_session.title} · #{project.name}")
       |> assign(:messages, messages)
       |> assign(:operations, operations)}
    else
      {:noreply, socket}
    end
  end

  # ============================================================================
  # Event Handlers: Navigation & Tabs
  # ============================================================================

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  def handle_event("switch_tab", %{"sidebar_tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, tab)}
  end

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
    {:ok, updated_session} =
      Sessions.update_session(socket.assigns.session, %{
        model_provider: provider,
        model_name: model
      })

    {:noreply,
     socket
     |> assign(:session, updated_session)
     |> assign(:open_dropdown, nil)
     |> put_flash(:info, "Model set to #{model} (#{provider})")}
  end

  @impl true
  def handle_event("change_model", %{"model" => model_name}, socket) do
    {:ok, session} = Sessions.update_session(socket.assigns.session, %{model_name: model_name})

    {:noreply,
     socket
     |> assign(:session, session)
     |> assign(:open_dropdown, nil)}
  end

  @impl true
  def handle_event("toggle_workspace_menu", _params, socket) do
    {:noreply, assign(socket, :show_workspace_menu, !socket.assigns.show_workspace_menu)}
  end

  @impl true
  def handle_event("search_workspace", %{"query" => q}, socket) do
    {:noreply, assign(socket, :workspace_search, q)}
  end

  @impl true
  def handle_event("open_time_picker", params, socket) do
    mode =
      case params["mode"] do
        "date" -> :date
        "time" -> :time
        _ -> :datetime
      end

    {:noreply,
     socket
     |> assign(:picker_mode, mode)
     |> assign(:show_time_picker, true)}
  end

  @impl true
  def handle_event("close_time_picker", _params, socket) do
    {:noreply, assign(socket, :show_time_picker, false)}
  end

  @impl true
  def handle_event("select_time_slot", %{"slot" => slot}, socket) do
    {:noreply,
     socket
     |> assign(:selected_time_slot, slot)
     |> assign(:new_task_time, slot)}
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
     |> assign(:selected_calendar_day, d_int)
     |> assign(:picker_year, y_int)
     |> assign(:picker_month, m_int)
     |> assign(:show_date_picker_popover, false)}
  end

  @impl true
  def handle_event("picker_today", _params, socket) do
    today_str = "2026-08-20"

    {:noreply,
     socket
     |> assign(:new_task_date, today_str)
     |> assign(:selected_calendar_date, today_str)
     |> assign(:selected_calendar_day, 20)
     |> assign(:picker_year, 2026)
     |> assign(:picker_month, 8)
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
  def handle_event("select_calendar_day", %{"day" => day, "date" => date}, socket) do
    day_int = if is_binary(day), do: String.to_integer(day), else: day

    {:noreply,
     socket
     |> assign(:selected_calendar_date, date)
     |> assign(:selected_calendar_day, day_int)
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
  def handle_event("run_scheduled_task", %{"id" => task_id}, socket) do
    case Kanban.get_task(task_id) do
      nil ->
        {:noreply, socket}

      task ->
        {:ok, updated} =
          Kanban.update_task(task, %{status: "running", worker_pid: inspect(self())})

        tasks = Kanban.list_tasks(socket.assigns.project.id, socket.assigns.kanban_filter)

        {:noreply,
         socket
         |> assign(:tasks, tasks)
         |> assign(:selected_task, updated)
         |> assign(:show_scheduled_task_modal, false)
         |> put_flash(:info, "Task '#{task.title}' triggered and now running")}
    end
  end

  @impl true
  def handle_event("delete_scheduled_task", %{"id" => task_id}, socket) do
    case Kanban.get_task(task_id) do
      nil ->
        {:noreply, socket}

      task ->
        {:ok, _deleted} = Kanban.delete_task(task)
        tasks = Kanban.list_tasks(socket.assigns.project.id, socket.assigns.kanban_filter)

        {:noreply,
         socket
         |> assign(:tasks, tasks)
         |> assign(:show_scheduled_task_modal, false)
         |> put_flash(:info, "Scheduled task removed")}
    end
  end

  @impl true
  def handle_event("set_task_schedule_type", %{"type" => type}, socket) do
    {:noreply, assign(socket, :new_task_schedule_type, type)}
  end

  @impl true
  def handle_event("scroll_to_message", %{"id" => msg_id}, socket) do
    {:noreply, push_event(socket, "scroll_to_msg", %{id: msg_id})}
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
    {:noreply, assign(socket, :show_new_task_modal, !socket.assigns.show_new_task_modal)}
  end

  @impl true
  def handle_event("create_task", params, socket) do
    params = params["task"] || params[:task] || params
    title = params["title"] || params[:title] || ""
    sched_date = params["scheduled_at_date"] || params[:scheduled_at_date]
    status = params["status"] || params[:status] || "ready"
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

      attrs = %{
        project_id: socket.assigns.project.id,
        session_id: socket.assigns.session.id,
        title: String.trim(to_string(title)),
        description: params["description"] || params[:description],
        priority: params["priority"] || params[:priority] || "medium",
        assignee: params["assignee"] || params[:assignee] || "default",
        status: status,
        scheduled_at: scheduled_at,
        cron_expression: cron_expr,
        steps_total: String.to_integer(to_string(steps_total)),
        steps_completed: 0,
        tags: if(tag && to_string(tag) != "", do: [to_string(tag)], else: ["Task"])
      }

      {:ok, task} = Kanban.create_task(attrs)
      tasks = Kanban.list_tasks(socket.assigns.project.id, socket.assigns.kanban_filter)

      {:noreply,
       socket
       |> assign(:tasks, tasks)
       |> assign(:selected_task, task)
       |> assign(:show_new_task_modal, false)
       |> put_flash(:info, "Task created")}
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
    task = Kanban.get_task!(id)
    {:ok, updated} = Kanban.move_task_status(task, status)
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
  end

  @impl true
  def handle_event("claim_task", %{"id" => id}, socket) do
    task = Kanban.get_task!(id)
    {:ok, claimed} = Kanban.claim_task(task, "coder")
    tasks = Kanban.list_tasks(socket.assigns.project.id, socket.assigns.kanban_filter)

    {:noreply,
     socket
     |> assign(:tasks, tasks)
     |> assign(:selected_task, claimed)
     |> put_flash(:info, "Worker #{claimed.worker_pid} claimed task")}
  end

  @impl true
  def handle_event("estimate_task", %{"id" => id}, socket) do
    task = Kanban.get_task!(id)
    {:ok, estimated} = Kanban.estimate_effort(task)
    tasks = Kanban.list_tasks(socket.assigns.project.id, socket.assigns.kanban_filter)

    {:noreply,
     socket
     |> assign(:tasks, tasks)
     |> assign(:selected_task, estimated)
     |> put_flash(:info, "Effort estimated: #{estimated.estimate}")}
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
  def handle_event("submit_prompt", %{"prompt" => prompt_text}, socket) do
    text = String.trim(prompt_text)

    if text != "" do
      session_id = socket.assigns.session.id
      SessionServer.send_prompt(session_id, text)

      tab =
        cond do
          String.starts_with?(text, "/swarm") -> "swarm"
          String.starts_with?(text, "/kanban") -> "kanban"
          true -> socket.assigns.active_tab
        end

      {:noreply,
       socket
       |> assign(:active_tab, tab)
       |> assign(:prompt_form, to_form(%{"prompt" => ""}))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_swarm", _params, socket) do
    session_id = socket.assigns.session.id
    {:ok, new_mode} = SessionServer.toggle_swarm(session_id)
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

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Coding Session #{count}",
        swarm_mode: socket.assigns.session.swarm_mode,
        model_provider: socket.assigns.session.model_provider,
        model_name: socket.assigns.session.model_name
      })

    {:noreply,
     socket
     |> assign(:sessions, Sessions.list_sessions_for_project(project.id))
     |> push_patch(to: ~p"/sessions/#{session.id}?project_id=#{project.id}")}
  end

  @impl true
  def handle_event("delete_session", %{"id" => session_id}, socket) do
    session = Sessions.get_session!(session_id)
    Sessions.delete_session(session)

    remaining = Sessions.list_sessions_for_project(socket.assigns.project.id)

    if remaining == [] do
      {:ok, new_s} =
        Sessions.create_session(%{
          project_id: socket.assigns.project.id,
          title: "Coding Session 1"
        })

      {:noreply, push_patch(socket, to: ~p"/sessions/#{new_s.id}")}
    else
      [next | _] = remaining
      {:noreply, push_patch(socket, to: ~p"/sessions/#{next.id}")}
    end
  end

  @impl true
  def handle_event("set_diff_mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, :diff_mode, mode)}
  end

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
    root = socket.assigns.project.root_path
    expanded_root = Path.expand(root)
    full_path = Path.expand(Path.join(root, rel_path))

    if String.starts_with?(full_path, expanded_root <> "/") or full_path == expanded_root do
      content =
        case File.read(full_path) do
          {:ok, text} -> text
          {:error, reason} -> "Could not read file: #{inspect(reason)}"
        end

      {:noreply,
       socket
       |> assign(:selected_file, rel_path)
       |> assign(:file_content, content)
       |> assign(:active_tab, "files")}
    else
      {:noreply, put_flash(socket, :error, "Invalid file path")}
    end
  end

  @impl true
  def handle_event("refresh_files", _params, socket) do
    files = list_project_files(socket.assigns.project.root_path)
    {:noreply, assign(socket, :project_files, files)}
  end

  @impl true
  def handle_event("run_terminal", %{"command" => cmd}, socket) do
    handle_event("run_terminal_command", %{"command" => cmd}, socket)
  end

  @impl true
  def handle_event("quick_terminal", %{"cmd" => cmd}, socket) do
    handle_event("run_terminal_command", %{"command" => cmd}, socket)
  end

  @impl true
  def handle_event("clear_terminal", _params, socket) do
    {:noreply, assign(socket, :terminal_output, "")}
  end

  @impl true
  def handle_event("run_terminal_command", %{"command" => cmd}, socket) do
    full_cmd = String.trim(cmd)
    root = socket.assigns.project.root_path

    out =
      case System.shell("cd \"#{root}\" && #{full_cmd} 2>&1") do
        {output, 0} -> "$ #{full_cmd}\n#{output}\n[Exit 0: OK]"
        {output, code} -> "$ #{full_cmd}\n#{output}\n[Exit #{code}: Error]"
      end

    new_output =
      if socket.assigns.terminal_output in [
           "",
           nil,
           "Ready. Type a command or click a quick action above."
         ] do
        out
      else
        socket.assigns.terminal_output <> "\n\n" <> out
      end

    {:noreply,
     socket
     |> assign(:terminal_output, new_output)
     |> assign(:terminal_form, to_form(%{"command" => ""}))}
  end

  @impl true
  def handle_event("toggle_settings_modal", _params, socket) do
    {:noreply, assign(socket, :show_settings_modal, !socket.assigns.show_settings_modal)}
  end

  @impl true
  def handle_event("save_settings", %{"settings" => params}, socket) do
    case Settings.update_settings(params) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:settings, updated)
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

    {:ok, project} = Projects.get_or_create_project(trimmed_path, proj_name)

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Coding Session 1",
        swarm_mode: true
      })

    {:noreply,
     socket
     |> assign(:show_project_modal, false)
     |> assign(:show_workspace_menu, false)
     |> push_patch(to: ~p"/sessions/#{session.id}?project_id=#{project.id}")}
  end

  @impl true
  def handle_event("switch_project", %{"id" => project_id}, socket) do
    project = Projects.get_project!(project_id)
    sessions = Sessions.list_sessions_for_project(project.id)

    session =
      case sessions do
        [first | _] ->
          first

        [] ->
          {:ok, s} = Sessions.create_session(%{project_id: project.id, title: "Coding Session 1"})
          s
      end

    {:noreply,
     socket
     |> assign(:show_workspace_menu, false)
     |> push_patch(to: ~p"/sessions/#{session.id}?project_id=#{project.id}")}
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
    messages = socket.assigns.messages ++ [message]
    {:noreply, assign(socket, :messages, messages)}
  end

  @impl true
  def handle_info({:operation_started, op}, socket) do
    operations = [op | Enum.reject(socket.assigns.operations, &(&1.id == op.id))]
    {:noreply, socket |> assign(:operations, operations) |> assign(:active_agent, op.agent_name)}
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

    {:noreply, assign(socket, :active_stage, stage)}
  end

  @impl true
  def handle_info({:terminal_output, _session_id, text}, socket)
      when is_binary(text) and text != "" do
    new_output =
      if socket.assigns.terminal_output in ["", nil] do
        text
      else
        socket.assigns.terminal_output <> "\n" <> text
      end

    {:noreply, assign(socket, :terminal_output, new_output)}
  end

  @impl true
  def handle_info({:terminal_output, _session_id, _}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(:operations_cleared, socket) do
    {:noreply, assign(socket, :operations, [])}
  end

  @impl true
  def handle_info({:session_status_changed, status}, socket) do
    updated_session = %{socket.assigns.session | status: status}
    {:noreply, assign(socket, :session, updated_session)}
  end

  @impl true
  def handle_info({:task_created, task}, socket) do
    if Enum.any?(socket.assigns.tasks, &(&1.id == task.id)) do
      {:noreply, socket}
    else
      {:noreply, assign(socket, :tasks, [task | socket.assigns.tasks])}
    end
  end

  @impl true
  def handle_info({:task_updated, updated_task}, socket) do
    tasks =
      Enum.map(socket.assigns.tasks, fn t ->
        if t.id == updated_task.id, do: updated_task, else: t
      end)

    selected =
      if socket.assigns.selected_task && socket.assigns.selected_task.id == updated_task.id,
        do: updated_task,
        else: socket.assigns.selected_task

    {:noreply, socket |> assign(:tasks, tasks) |> assign(:selected_task, selected)}
  end

  @impl true
  def handle_info({:task_deleted, deleted_task}, socket) do
    tasks = Enum.reject(socket.assigns.tasks, &(&1.id == deleted_task.id))
    {:noreply, assign(socket, :tasks, tasks)}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # ============================================================================
  # Helpers & Seeders
  # ============================================================================

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

  defp tasks_for_day(tasks, day) do
    Enum.filter(tasks, fn task ->
      (task.scheduled_at && task.scheduled_at.day == day) ||
        (task.metadata && task.metadata["day"] == day)
    end)
  end

  defp list_project_files(root_path) do
    if File.dir?(root_path) do
      root_path
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.reject(&String.contains?(&1, ["_build", "deps", ".git", ".elixir_ls"]))
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.relative_to(&1, root_path))
      |> Enum.sort()
      |> Enum.take(100)
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

  defp format_date_display(nil), do: "08/20/2026"
  defp format_date_display(""), do: "08/20/2026"

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

    today = Date.new!(2026, 8, 20)

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
end
