defmodule IexCode.Engine.SessionServer do
  @moduledoc """
  GenServer process managing the active execution state of a coding session.
  Handles incoming prompts, tool executions, autonomous goal lifecycles,
  real-time steering message ingestion, and swarm dispatching.
  """
  use GenServer, restart: :transient
  require Logger
  alias IexCode.{Sessions, Tools, LLM}
  alias IexCode.Engine.{SwarmCoordinator, OperationManager, AgentSupervisor}
  alias Phoenix.PubSub

  # Client API

  def start_link(session_id) do
    GenServer.start_link(__MODULE__, session_id, name: via_tuple(session_id))
  end

  def ensure_started(session_id) do
    case GenServer.whereis(via_tuple(session_id)) do
      nil ->
        case DynamicSupervisor.start_child(
               IexCode.Engine.SessionSupervisor,
               {__MODULE__, session_id}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end

      pid ->
        {:ok, pid}
    end
  end

  @doc """
  Creates and starts an autonomous goal for the session.
  """
  def create_goal(session_id, goal_prompt_or_params, opts \\ []) do
    ensure_started(session_id)
    GenServer.call(via_tuple(session_id), {:create_goal, goal_prompt_or_params, opts}, 30_000)
  end

  @doc """
  Sends a user prompt to the active session. If session is running, ingests as real-time steering.
  """
  def send_prompt(session_id, content) do
    ensure_started(session_id)
    GenServer.cast(via_tuple(session_id), {:send_prompt, content})
  end

  @doc """
  Sends real-time steering guidance into an active swarm loop.
  Broadcasts to session:SESSION_ID:steer and session:SESSION_ID.
  """
  def send_steering(session_id, steer_text) do
    ensure_started(session_id)
    GenServer.call(via_tuple(session_id), {:send_steering, steer_text})
  end

  @doc """
  Alias for send_steering/2.
  """
  def steer_swarm(session_id, steer_text) do
    send_steering(session_id, steer_text)
  end

  @doc """
  Pauses the active swarm or single-agent execution without losing context.
  """
  def pause_session(session_id) do
    ensure_started(session_id)
    GenServer.call(via_tuple(session_id), :pause_session)
  end

  @doc """
  Resumes execution of a paused session.
  """
  def resume_session(session_id) do
    ensure_started(session_id)
    GenServer.call(via_tuple(session_id), :resume_session)
  end

  @doc """
  Cancels the active session execution, stops all subagent OTP workers,
  and executes :rollback or :commit action.
  """
  def cancel_session(session_id, opts \\ []) do
    ensure_started(session_id)
    GenServer.call(via_tuple(session_id), {:cancel_session, opts}, 30_000)
  end

  def toggle_swarm(session_id) do
    ensure_started(session_id)
    GenServer.call(via_tuple(session_id), :toggle_swarm)
  end

  def clear_operations(session_id) do
    ensure_started(session_id)
    GenServer.call(via_tuple(session_id), :clear_operations)
  end

  def get_state(session_id) do
    ensure_started(session_id)
    GenServer.call(via_tuple(session_id), :get_state)
  end

  defp via_tuple(session_id) do
    {:via, Registry, {IexCode.SessionRegistry, session_id}}
  end

  # Server Callbacks

  @impl true
  def init(session_id) do
    session =
      try do
        Sessions.get_session(session_id) ||
          %Sessions.Session{id: session_id, swarm_mode: false, status: "idle"}
      rescue
        _ -> %Sessions.Session{id: session_id, swarm_mode: false, status: "idle"}
      end

    status = normalize_status(session.status)

    state = %{
      session_id: session_id,
      session: session,
      status: status,
      current_task: nil,
      task_ref: nil,
      run_mode: nil,
      active_goal: nil
    }

    # Rehydrate: a DB row left in "running" is phantom-running after a restart
    # (no live task exists in this fresh process), so normalize it.
    state =
      if status == :running do
        Logger.warning(
          "Session #{session_id} restarted while marked running; marking interrupted"
        )

        update_db_session_status(session_id, "idle")
        broadcast(session_id, {:session_status_changed, "idle"})
        broadcast(session_id, {:session_interrupted, %{session_id: session_id}})

        %{state | status: :idle, session: %{session | status: "idle"}}
      else
        state
      end

    {:ok, state}
  end

  @impl true
  def handle_call(
        {:create_goal, _goal_prompt_or_params, _opts},
        _from,
        %{status: :running} = state
      ) do
    {:reply, {:error, :already_running}, state}
  end

  @impl true
  def handle_call(
        {:create_goal, goal_prompt_or_params, opts},
        _from,
        %{session_id: session_id, session: session} = state
      ) do
    {title, prompt} =
      cond do
        is_binary(goal_prompt_or_params) ->
          {String.slice(goal_prompt_or_params, 0, 60), goal_prompt_or_params}

        is_map(goal_prompt_or_params) ->
          t =
            Map.get(goal_prompt_or_params, :title) || Map.get(goal_prompt_or_params, "title") ||
              "Autonomous Goal"

          p =
            Map.get(goal_prompt_or_params, :prompt) || Map.get(goal_prompt_or_params, "prompt") ||
              t

          {t, p}

        true ->
          {"Autonomous Goal", "Analyze workspace and coordinate goal"}
      end

    current_session = fetch_current_session(session_id, session)

    project_root = resolve_project_root(current_session, opts)
    auto_start = Keyword.get(opts, :auto_start, true)

    goal_record = %{
      id: Ecto.UUID.generate(),
      session_id: session_id,
      title: title,
      prompt: prompt,
      status: if(auto_start, do: :running, else: :idle),
      created_at: DateTime.utc_now()
    }

    # Save Goal User message in DB
    {user_msg, _msg_error} =
      case Sessions.create_message(%{
             session_id: session_id,
             role: "user",
             agent_name: "User (Goal)",
             content: "🎯 **Goal**: #{title}\n\n#{prompt}"
           }) do
        {:ok, msg} ->
          {msg, nil}

        error ->
          Logger.error(
            "Failed to persist goal message for session #{session_id}: #{inspect(error)}"
          )

          broadcast(session_id, {:run_failed, %{session_id: session_id, reason: inspect(error)}})

          {%{
             id: Ecto.UUID.generate(),
             session_id: session_id,
             role: "user",
             agent_name: "User (Goal)",
             content: "🎯 **Goal**: #{title}\n\n#{prompt}"
           }, error}
      end

    broadcast(session_id, {:message_created, user_msg})
    broadcast(session_id, {:goal_created, goal_record})

    if auto_start do
      update_db_session_status(session_id, "running")
      broadcast(session_id, {:session_status_changed, "running"})

      case SwarmCoordinator.run_swarm(session_id, prompt, project_root, opts) do
        {:ok, task_pid} ->
          task_ref = Process.monitor(task_pid)

          new_state = %{
            state
            | session: %{current_session | status: "running"},
              status: :running,
              current_task: task_pid,
              task_ref: task_ref,
              run_mode: :swarm,
              active_goal: goal_record
          }

          {:reply, {:ok, Map.put(goal_record, :task_pid, task_pid)}, new_state}
      end
    else
      update_db_session_status(session_id, "idle")
      broadcast(session_id, {:session_status_changed, "idle"})

      new_state = %{
        state
        | session: %{current_session | status: "idle"},
          status: :idle,
          current_task: nil,
          active_goal: goal_record
      }

      {:reply, {:ok, goal_record}, new_state}
    end
  end

  @impl true
  def handle_call({:send_steering, steer_text}, _from, %{session_id: session_id} = state) do
    cleaned = String.trim(steer_text)

    if cleaned != "" do
      # Create message in DB
      case Sessions.create_message(%{
             session_id: session_id,
             role: "user",
             agent_name: "User (Steer)",
             content: "🧭 **Steering Guidance**: #{cleaned}"
           }) do
        {:ok, msg} -> broadcast(session_id, {:message_created, msg})
        _ -> :ok
      end

      # Broadcast to steering topic and main session topic
      PubSub.broadcast(IexCode.PubSub, "session:#{session_id}:steer", {:steer_message, cleaned})
      broadcast(session_id, {:swarm_steered, %{session_id: session_id, steering: cleaned}})
    end

    {:reply, {:ok, cleaned}, state}
  end

  @impl true
  def handle_call(:pause_session, _from, %{session_id: session_id, session: session} = state) do
    current_session = fetch_current_session(session_id, session)

    update_db_session_status(session_id, "paused")

    PubSub.broadcast(IexCode.PubSub, "session:#{session_id}:steer", {:pause, session_id})
    broadcast(session_id, {:session_status_changed, "paused"})

    new_state = %{state | status: :paused, session: %{current_session | status: "paused"}}
    {:reply, {:ok, :paused}, new_state}
  end

  @impl true
  def handle_call(:resume_session, _from, %{session_id: session_id, session: session} = state) do
    task_alive? =
      case task_pid(state.current_task) do
        nil -> false
        pid -> Process.alive?(pid)
      end

    if state.status == :paused and task_alive? do
      current_session = fetch_current_session(session_id, session)

      update_db_session_status(session_id, "running")

      PubSub.broadcast(IexCode.PubSub, "session:#{session_id}:steer", {:resume, session_id})
      broadcast(session_id, {:session_status_changed, "running"})

      new_state = %{state | status: :running, session: %{current_session | status: "running"}}
      {:reply, {:ok, :running}, new_state}
    else
      # No live task to resume - never phantom-resume into :running.
      new_state =
        if task_alive? do
          state
        else
          update_db_session_status(session_id, "idle")
          broadcast(session_id, {:session_status_changed, "idle"})
          %{state | status: :idle, current_task: nil, task_ref: nil}
        end

      {:reply, {:error, :no_active_run}, new_state}
    end
  end

  @impl true
  def handle_call(
        {:cancel_session, opts},
        _from,
        %{session_id: session_id, session: session} = state
      ) do
    # Honor legacy `commit: true` while letting an explicit `:action` win.
    default_action = if Keyword.get(opts, :commit, false), do: :commit, else: :rollback
    action = Keyword.get(opts, :action, default_action)

    current_session = fetch_current_session(session_id, session)

    project_root = resolve_project_root(current_session, opts)

    # 1. Signal all workers via PubSub. A live swarm coordinator subscribes to
    #    this topic and performs its own rollback/commit + termination, so the
    #    server must NOT roll back again for that path (avoid double-delivery).
    PubSub.broadcast(IexCode.PubSub, "session:#{session_id}:steer", {:cancel, session_id, opts})

    # 2. Wait briefly for the running task to die on its own (it also observes
    #    the {:cancel, ...} message), then escalate shutdown -> kill.
    swarm_handled_cancel? =
      case task_pid(state.current_task) do
        nil ->
          false

        pid ->
          if Process.alive?(pid) do
            await_task_exit(pid)

            # The swarm coordinator cleans up on its own; the single-agent task
            # does not, so the server performs the rollback/commit for it.
            state.run_mode == :swarm
          else
            false
          end
      end

    if state.task_ref, do: Process.demonitor(state.task_ref, [:flush])

    # 3. Cleanly terminate all subagent OTP workers
    AgentSupervisor.stop_all_agents(session_id)

    # 4. Perform rollback or commit (only if the swarm coordinator didn't already)
    unless swarm_handled_cancel? do
      case action do
        :rollback ->
          SwarmCoordinator.perform_rollback(project_root)

        :commit ->
          SwarmCoordinator.perform_commit(project_root, opts)

        _ ->
          :ok
      end
    end

    # 5. Update DB status
    update_db_session_status(session_id, "stopped")

    # 6. Create assistant cancellation message in DB
    case Sessions.create_message(%{
           session_id: session_id,
           role: "assistant",
           agent_name: "Swarm Coordinator",
           content: "🛑 **Session Stopped**: Execution cancelled by user with action `#{action}`."
         }) do
      {:ok, cancel_msg} -> broadcast(session_id, {:message_created, cancel_msg})
      _ -> :ok
    end

    broadcast(session_id, {:session_status_changed, "stopped"})
    broadcast(session_id, {:session_cancelled, %{session_id: session_id, action: action}})

    new_state = %{
      state
      | status: :stopped,
        current_task: nil,
        task_ref: nil,
        run_mode: nil,
        session: %{current_session | status: "stopped"}
    }

    {:reply, {:ok, %{status: :stopped, action: action}}, new_state}
  end

  @impl true
  def handle_call(:toggle_swarm, _from, %{session: session, session_id: session_id} = state) do
    current_session = fetch_current_session(session_id, session)

    new_mode = !current_session.swarm_mode

    case Sessions.update_session(current_session, %{swarm_mode: new_mode}) do
      {:ok, updated_session} ->
        broadcast(session_id, {:session_updated, updated_session})
        {:reply, {:ok, new_mode}, %{state | session: updated_session}}

      _ ->
        updated = %{current_session | swarm_mode: new_mode}
        broadcast(session_id, {:session_updated, updated})
        {:reply, {:ok, new_mode}, %{state | session: updated}}
    end
  end

  @impl true
  def handle_call(:clear_operations, _from, %{session_id: session_id} = state) do
    try do
      Sessions.clear_session_operations(session_id)
    rescue
      _ -> :ok
    end

    broadcast(session_id, :operations_cleared)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, %{status: status} = state)
      when status in [:running, :paused, :stopped] do
    # While a run is actively managed by this process, the cached state is
    # authoritative - skip the blocking DB read.
    {:reply, state, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    current_session = fetch_current_session(state.session_id, state.session)

    status = normalize_status(current_session.status)

    result_state = %{
      state
      | session: current_session,
        status: status
    }

    {:reply, result_state, result_state}
  end

  @impl true
  def handle_cast({:send_prompt, raw_prompt}, %{session_id: session_id, session: session} = state) do
    prompt = String.trim(raw_prompt)

    if state.status == :running do
      # If already running, ingest as real-time steering
      {:reply, _, new_state} = handle_call({:send_steering, prompt}, nil, state)
      {:noreply, new_state}
    else
      is_swarm_cmd = String.starts_with?(prompt, "/swarm")

      cleaned_prompt =
        if is_swarm_cmd do
          prompt |> String.replace_prefix("/swarm", "") |> String.trim()
        else
          prompt
        end

      actual_prompt =
        if cleaned_prompt == "", do: "Analyze workspace and coordinate task", else: cleaned_prompt

      # Save User message
      {user_msg, _} =
        case Sessions.create_message(%{
               session_id: session_id,
               role: "user",
               agent_name: "User",
               content: prompt
             }) do
          {:ok, msg} ->
            {msg, nil}

          error ->
            Logger.error(
              "Failed to persist user message for session #{session_id}: #{inspect(error)}"
            )

            broadcast(
              session_id,
              {:run_failed, %{session_id: session_id, reason: inspect(error)}}
            )

            {%{
               id: Ecto.UUID.generate(),
               session_id: session_id,
               role: "user",
               agent_name: "User",
               content: prompt
             }, error}
        end

      broadcast(session_id, {:message_created, user_msg})

      current_session = fetch_current_session(session_id, session)

      update_db_session_status(session_id, "running")
      broadcast(session_id, {:session_status_changed, "running"})

      use_swarm? = is_swarm_cmd or current_session.swarm_mode
      project_root = resolve_project_root(current_session)

      if use_swarm? do
        # Run Swarm Coordinator
        case SwarmCoordinator.run_swarm(session_id, actual_prompt, project_root) do
          {:ok, task_pid} ->
            task_ref = Process.monitor(task_pid)

            {:noreply,
             %{
               state
               | status: :running,
                 current_task: task_pid,
                 task_ref: task_ref,
                 run_mode: :swarm,
                 session: %{current_session | status: "running"}
             }}
        end
      else
        # Run Single Agent Async Task
        parent = self()

        case Task.Supervisor.start_child(IexCode.TaskSupervisor, fn ->
               allow_sandbox(parent, self())
               run_single_agent(session_id, current_session, actual_prompt, project_root)
             end) do
          {:ok, task_pid} ->
            task_ref = Process.monitor(task_pid)

            {:noreply,
             %{
               state
               | status: :running,
                 current_task: task_pid,
                 task_ref: task_ref,
                 run_mode: :single_agent,
                 session: %{current_session | status: "running"}
             }}

          {:error, reason} ->
            Logger.error(
              "Failed to start single-agent task for session #{session_id}: #{inspect(reason)}"
            )

            update_db_session_status(session_id, "idle")
            broadcast(session_id, {:session_status_changed, "idle"})

            broadcast(
              session_id,
              {:run_failed, %{session_id: session_id, reason: inspect(reason)}}
            )

            {:noreply, %{state | status: :idle}}
        end
      end
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: task_ref} = state)
      when ref == task_ref do
    status =
      case reason do
        :normal -> :idle
        :noproc -> :idle
        :shutdown -> :stopped
        :killed -> :stopped
        _ -> :failed
      end

    session_id = state.session_id
    update_db_session_status(session_id, to_string(status))
    broadcast(session_id, {:session_status_changed, to_string(status)})

    if status == :failed do
      Logger.error("Session #{session_id} run crashed: #{inspect(reason)}")
      broadcast(session_id, {:run_failed, %{session_id: session_id, reason: inspect(reason)}})

      case Sessions.create_message(%{
             session_id: session_id,
             role: "assistant",
             agent_name: "Swarm Coordinator",
             content: "❌ **Run Failed**: The session run crashed with `#{inspect(reason)}`."
           }) do
        {:ok, err_msg} -> broadcast(session_id, {:message_created, err_msg})
        _ -> :ok
      end
    end

    {:noreply, %{state | status: status, current_task: nil, task_ref: nil, run_mode: nil}}
  end

  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp run_single_agent(session_id, session, user_prompt, project_root) do
    subscribe_steering(session_id)
    broadcast(session_id, {:session_status_changed, "running"})

    # Zero-arg fun polled by the LLM stream between chunks (contract: `:cancelled?`)
    cancelled? = fn -> steering_cancelled?() end

    try do
      case control_checkpoint() do
        :cancel ->
          finish_cancelled(session_id)

        :go ->
          # Fetch previous messages
          prev_messages =
            try do
              Sessions.list_messages(session_id)
              |> Enum.map(fn m -> %{role: m.role, content: m.content} end)
            rescue
              _ -> []
            end

          system_prompt = """
          You are an intelligent, proactive coding assistant in IexCode desktop environment.
          You have tools to read, search, modify, and run code in the user's project workspace (#{project_root}).
          When using tools, you can execute them directly.
          """

          # Spawn root LLM operation
          op_result =
            OperationManager.run_sync_operation(
              session_id,
              nil,
              "AssistantAgent",
              "llm_stream",
              "Agent: Planning response & tool execution",
              %{prompt: user_prompt},
              fn progress ->
                progress.(
                  20,
                  "Querying model (#{session.model_provider}: #{session.model_name})..."
                )

                LLM.chat(prev_messages, system_prompt, session, fn _c -> :ok end,
                  cancelled?: cancelled?
                )
              end
            )

          # The stream may have been aborted by a cancel that the `cancelled?`
          # fun observed - honor it before processing the result.
          case control_checkpoint() do
            :cancel -> throw({:session_cancelled, session_id})
            :go -> :ok
          end

          case op_result do
            {:ok, %{text: response_text, tool_calls: tool_calls}} ->
              # If there are tool calls, execute each in a dedicated process!
              tool_results =
                Enum.map(tool_calls, fn tc ->
                  case control_checkpoint() do
                    :cancel ->
                      throw({:session_cancelled, session_id})

                    :go ->
                      case OperationManager.run_sync_operation(
                             session_id,
                             nil,
                             "AssistantAgent",
                             tc.name,
                             "Tool: #{tc.name} (#{Map.get(tc.args, "path", Map.get(tc.args, "command", ""))})",
                             tc.args,
                             fn progress ->
                               Tools.execute(tc.name, tc.args, project_root, progress)
                             end
                           ) do
                        {:ok, out} -> %{name: tc.name, result: out}
                        {:error, err} -> %{name: tc.name, error: err}
                      end
                  end
                end)

              final_content =
                if tool_results != [] and response_text == "" do
                  summarized =
                    Enum.map(tool_results, fn tr ->
                      "**Tool `#{tr.name}` completed:**\n```\n#{String.slice(to_string(tr[:result] || tr[:error]), 0, 1000)}\n```"
                    end)
                    |> Enum.join("\n\n")

                  "Executed #{length(tool_results)} operations:\n\n" <> summarized
                else
                  response_text
                end

              case Sessions.create_message(%{
                     session_id: session_id,
                     role: "assistant",
                     agent_name: "Assistant",
                     content: final_content
                   }) do
                {:ok, asst_msg} -> broadcast(session_id, {:message_created, asst_msg})
                _ -> :ok
              end

            {:error, reason} ->
              case Sessions.create_message(%{
                     session_id: session_id,
                     role: "assistant",
                     agent_name: "Assistant",
                     content: "⚠️ Error during execution: #{inspect(reason)}"
                   }) do
                {:ok, err_msg} -> broadcast(session_id, {:message_created, err_msg})
                _ -> :ok
              end
          end

          update_db_session_status(session_id, "idle")
          broadcast(session_id, {:session_status_changed, "idle"})
      end
    rescue
      error ->
        Logger.error(
          "Single-agent run failed for session #{session_id}: #{Exception.format(:error, error)}"
        )

        update_db_session_status(session_id, "failed")
        broadcast(session_id, {:session_status_changed, "failed"})

        broadcast(
          session_id,
          {:run_failed, %{session_id: session_id, reason: Exception.message(error)}}
        )

        case Sessions.create_message(%{
               session_id: session_id,
               role: "assistant",
               agent_name: "Assistant",
               content: "❌ **Run Failed**: #{Exception.message(error)}"
             }) do
          {:ok, err_msg} -> broadcast(session_id, {:message_created, err_msg})
          _ -> :ok
        end
    catch
      :throw, {:session_cancelled, ^session_id} ->
        finish_cancelled(session_id)
    after
      unsubscribe_steering(session_id)
    end
  end

  # Blocks while paused and drains control messages. Returns :go or :cancel.
  defp control_checkpoint do
    receive do
      {:pause, _session_id} ->
        wait_while_paused()

      {:resume, _session_id} ->
        control_checkpoint()

      {:cancel, _session_id, _opts} ->
        :cancel

      _msg ->
        control_checkpoint()
    after
      0 -> :go
    end
  end

  defp wait_while_paused do
    receive do
      {:resume, _session_id} ->
        control_checkpoint()

      {:cancel, _session_id, _opts} ->
        :cancel

      _msg ->
        wait_while_paused()
    end
  end

  # Non-blocking cancel check for the LLM stream; re-queues any other message
  # so pause/resume/steer deliveries are not lost.
  defp steering_cancelled? do
    receive do
      {:cancel, _session_id, _opts} ->
        true

      msg ->
        send(self(), msg)
        false
    after
      0 -> false
    end
  end

  defp finish_cancelled(session_id) do
    update_db_session_status(session_id, "stopped")
    broadcast(session_id, {:session_status_changed, "stopped"})
  end

  defp subscribe_steering(session_id) do
    PubSub.subscribe(IexCode.PubSub, "session:#{session_id}:steer")
  rescue
    _ -> :ok
  end

  defp unsubscribe_steering(session_id) do
    PubSub.unsubscribe(IexCode.PubSub, "session:#{session_id}:steer")
  rescue
    _ -> :ok
  end

  defp fetch_current_session(session_id, fallback) do
    try do
      Sessions.get_session(session_id) || fallback
    rescue
      _ -> fallback
    end
  end

  # Accepts a raw pid or a %Task{} struct (Task.Supervisor.async_nolink returns
  # a %Task{}; start_child returns a pid).
  defp task_pid(pid) when is_pid(pid), do: pid
  defp task_pid(%Task{pid: pid}) when is_pid(pid), do: pid
  defp task_pid(_), do: nil

  # Waits for a task to exit on its own (it may be handling a cancel message),
  # then escalates shutdown -> kill. Always returns once the process is down.
  defp await_task_exit(pid, grace_ms \\ 3_000) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} ->
        :ok
    after
      grace_ms ->
        Process.exit(pid, :shutdown)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} ->
            :ok
        after
          1_000 ->
            Process.exit(pid, :kill)

            receive do
              {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
            after
              500 -> Process.demonitor(ref, [:flush])
            end
        end
    end
  end

  defp resolve_project_root(session, opts \\ []) do
    opts[:project_root] ||
      (((session && Ecto.assoc_loaded?(session.project)) and session.project) &&
         session.project.root_path) ||
      File.cwd!()
  end

  defp update_db_session_status(session_id, status_str) do
    case Sessions.get_session(session_id) do
      nil -> :ok
      s -> Sessions.update_session(s, %{status: status_str})
    end
  rescue
    _ -> :ok
  end

  defp allow_sandbox(parent, child) do
    if Code.ensure_loaded?(Ecto.Adapters.SQL.Sandbox) do
      try do
        Ecto.Adapters.SQL.Sandbox.allow(IexCode.Repo, parent, child)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end
  end

  defp normalize_status("running"), do: :running
  defp normalize_status("paused"), do: :paused
  defp normalize_status("stopped"), do: :stopped
  defp normalize_status("completed"), do: :completed
  defp normalize_status("failed"), do: :failed
  defp normalize_status(:running), do: :running
  defp normalize_status(:paused), do: :paused
  defp normalize_status(:stopped), do: :stopped
  defp normalize_status(:completed), do: :completed
  defp normalize_status(:failed), do: :failed
  defp normalize_status(_), do: :idle

  defp broadcast(session_id, event) do
    PubSub.broadcast(IexCode.PubSub, "session:#{session_id}", event)
  rescue
    _ -> :ok
  end
end
