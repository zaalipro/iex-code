defmodule IexCode.Engine.SwarmCoordinator do
  @moduledoc """
  Coordinates multi-agent autonomous swarm workflows using isolated OTP GenServers
  (PlannerAgent, ExplorerAgent, CoderAgent, VerifierAgent) managed by AgentSupervisor.
  Implements real-time steering message ingestion, pause/resume/cancel lifecycle control,
  and autonomous self-healing error feedback loop (up to 3 retries) with cycle detection.
  """
  require Logger

  alias IexCode.Engine.{
    AgentRegistry,
    AgentSupervisor,
    FleetManager,
    FleetRuntime,
    FleetSupervisor
  }

  alias IexCode.Engine.Agents.{PlannerAgent, ExplorerAgent, CoderAgent, VerifierAgent}
  alias IexCode.Tools
  alias IexCode.Tools.{AutoFix, MultiPatch}
  alias IexCode.{Runs, Sessions}
  alias Phoenix.PubSub

  defmodule State do
    defstruct [
      :session_id,
      :run_id,
      :session,
      :project_root,
      :user_prompt,
      :root_op_id,
      :allowed_tools,
      :workspace_lock_delegation,
      fleet_agents: [],
      stage: :init,
      iteration: 0,
      max_retries: 3,
      start_time_ms: 0,
      stage_start_ms: 0,
      plan: nil,
      explorer_context: nil,
      coder_result: nil,
      verifier_result: nil,
      applied_patches: [],
      applied_snapshots: [],
      steer_directives: [],
      error_signatures: MapSet.new(),
      history: [],
      status: :running
    ]
  end

  @doc """
  Runs the full swarm lifecycle asynchronously for a session and prompt under TaskSupervisor.
  Supports `run_swarm(session_id, prompt)`, `run_swarm(session_id, prompt, project_root)`,
  and `run_swarm(session_id, prompt, project_root, opts)`.
  Returns `{:ok, task_pid}`.
  """
  def run_swarm(session_id, user_prompt, project_root_or_opts \\ [], opts \\ []) do
    {project_root, options} =
      cond do
        is_binary(project_root_or_opts) ->
          {project_root_or_opts, opts}

        is_list(project_root_or_opts) ->
          {Keyword.get(project_root_or_opts, :project_root), project_root_or_opts}

        true ->
          {nil, opts}
      end

    run_opts =
      if project_root do
        Keyword.put(options, :project_root, project_root)
      else
        options
      end

    if project_root do
      IexCode.Tools.MultiPatch.Snapshot.claim_unscoped(project_root, session_id)
    end

    parent = self()

    task =
      Task.Supervisor.async_nolink(IexCode.TaskSupervisor, fn ->
        allow_sandbox(parent, self())
        run(session_id, user_prompt, run_opts)
      end)

    {:ok, task.pid}
  end

  @doc """
  Sends real-time steering text directly to the coordinator via PubSub.
  """
  def send_steering(session_id, steer_text) do
    PubSub.broadcast(IexCode.PubSub, "session:#{session_id}:steer", {:steer_message, steer_text})
  end

  @doc """
  Pauses the swarm coordinator.

  Persists "paused" before broadcasting: if the coordinator task has not
  subscribed yet, the broadcast is lost, so the persisted status is the
  reliable signal (the coordinator re-checks it right after subscribing).
  """
  def pause(session_id) do
    update_db_session_status(session_id, "paused")
    PubSub.broadcast(IexCode.PubSub, "session:#{session_id}:steer", {:pause, session_id})
  end

  @doc """
  Resumes the paused swarm coordinator.
  """
  def resume(session_id) do
    PubSub.broadcast(IexCode.PubSub, "session:#{session_id}:steer", {:resume, session_id})
  end

  @doc """
  Cancels the active swarm coordinator.
  """
  def cancel(session_id, opts \\ []) do
    PubSub.broadcast(IexCode.PubSub, "session:#{session_id}:steer", {:cancel, session_id, opts})
  end

  @doc """
  Reverts working tree modifications recorded in this session's MultiPatch snapshots.
  When no session is scoped (default `%State{}`), falls back to all snapshots.
  Never touches unrelated files or git state.
  """
  def perform_rollback(_project_root, state \\ %State{}) do
    session_id = Map.get(state, :session_id)
    run_id = Map.get(state, :run_id)

    if is_binary(session_id) and session_id != "" do
      snapshots =
        if is_binary(run_id) and run_id != "" do
          MultiPatch.Snapshot.list_run_snapshots(run_id)
        else
          MultiPatch.Snapshot.list_snapshots(session_id)
        end

      lock_opts = [
        project_id: trusted_project_id(state),
        run_id: run_id,
        session_id: session_id
      ]

      results =
        Enum.map(snapshots, fn snapshot ->
          Tools.rollback_multi_patch(snapshot.transaction_id, snapshot.project_root, lock_opts)
        end)

      case Enum.filter(results, &match?({:error, _}, &1)) do
        [] -> {:ok, :rolled_back}
        errors -> {:error, errors}
      end
    else
      {:error, :missing_session_scope}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Stages and commits working changes in the target project repository.
  """
  def perform_commit(project_root, opts \\ []) do
    if project_root != File.cwd!() and git_repo?(project_root) do
      commit_msg = Keyword.get(opts, :message, "chore: session cancelled checkpoint commit")

      with :ok <- Tools.git_stage(:all, project_root, opts),
           {:ok, _} <-
             Tools.git_commit(commit_msg, project_root, Keyword.put(opts, :allow_empty, true)) do
        {:ok, :committed}
      else
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, :committed}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # True when `path` is a git repository. `.git` may be a directory (normal clone)
  # or a file (linked worktree); bare checkouts have no `.git` entry at all,
  # so fall back to `git rev-parse`.
  defp git_repo?(path) do
    if File.exists?(Path.join(path, ".git")) do
      true
    else
      match?(
        {_, 0},
        System.cmd("git", ["rev-parse", "--git-dir"], cd: path, stderr_to_stdout: true)
      )
    end
  rescue
    _ -> false
  end

  defp trusted_project_id(%State{session: %{project_id: project_id}}), do: project_id

  defp trusted_project_id(%State{session_id: session_id}) do
    case Sessions.get_session(session_id) do
      %{project_id: project_id} -> project_id
      _ -> nil
    end
  end

  @doc """
  Executes the synchronous swarm coordination state machine.
  Returns `{:ok, final_message}` or `{:error, reason}`.
  """
  def run(session_id, user_prompt, opts \\ []) do
    session =
      try do
        Sessions.get_session!(session_id)
      rescue
        _ ->
          Sessions.get_session(session_id) || %Sessions.Session{id: session_id, status: "running"}
      end

    project_root =
      opts[:project_root] || (session.project && session.project.root_path) || File.cwd!()

    max_retries = Keyword.get(opts, :max_retries, 3)

    # Subscribe to steering topic for mid-flight steering/control
    unless is_binary(opts[:run_id]) do
      PubSub.subscribe(IexCode.PubSub, "session:#{session_id}:steer")
    end

    if is_binary(opts[:run_id]) do
      PubSub.subscribe(IexCode.PubSub, "run:#{opts[:run_id]}:control")
    end

    # Honor a pause requested between task spawn and this subscribe — the early
    # {:pause, _} broadcast had no subscriber yet, so the persisted status is
    # the only reliable signal.
    pre_paused? =
      case opts[:run_id] && Runs.get_run(opts[:run_id]) do
        %{status: "paused"} ->
          true

        _ ->
          case Sessions.get_session(session_id) do
            %{status: "paused"} -> true
            _ -> false
          end
      end

    if pre_paused? do
      broadcast(session_id, {:session_status_changed, "paused"})
    else
      broadcast(session_id, {:session_status_changed, "running"})
      update_db_session_status(session_id, "running")
    end

    start_time_ms = System.monotonic_time(:millisecond)

    state = %State{
      session_id: session_id,
      run_id: opts[:run_id],
      session: session,
      project_root: project_root,
      user_prompt: user_prompt,
      allowed_tools: Keyword.get(opts, :allowed_tools, :all),
      workspace_lock_delegation: opts[:workspace_lock_delegation],
      max_retries: max_retries,
      start_time_ms: start_time_ms,
      stage_start_ms: start_time_ms,
      stage: :init,
      status: if(pre_paused?, do: :paused, else: :running)
    }

    state = attach_durable_fleet(state)

    # 1. Root Swarm Operation — created before the guarded region below so the
    # crash handler can still mark it failed (try-body bindings don't leak to catch).
    {:ok, root_op} = create_root_operation(session_id, user_prompt)
    state = %State{state | root_op_id: root_op.id}

    try do
      state = ensure_legacy_agents(state)

      broadcast_stage(
        state,
        :init,
        5,
        "Swarm initialized with #{fleet_size(state)} isolated OTP subagents."
      )

      # A pause that landed before subscribe: block until resumed (or cancelled;
      # cancellation throws {:swarm_cancelled, _, _} from inside the wait).
      state = state |> replay_claimed_controls() |> align_durable_control_state()

      state =
        if state.status == :paused do
          wait_for_resume_or_cancel(state)
        else
          check_steering_and_control(state)
        end

      # 2. Planning Phase
      state = run_planning_phase(state)
      state = check_steering_and_control(state)

      # 3. Exploration Phase
      state = run_exploration_phase(state)
      state = check_steering_and_control(state)

      # 4. Coding & Verification Phase with Self-Healing Feedback Loop
      state = run_coding_and_verification_loop(state)

      # 5. Final Synthesis & Assistant Message
      finish_swarm(state)
    catch
      {:swarm_agent_phase_interrupted, role, reason, final_state} ->
        {:error, {:agent_phase_interrupted, role, reason, final_state.stage}}

      {:swarm_cancelled, action, final_state} ->
        {:ok, %{status: :stopped, action: action, cancelled: true, state: final_state}}

      # Any other throw, error or exit: clean up loudly instead of dying silently.
      kind, payload ->
        stacktrace = __STACKTRACE__
        handle_swarm_crash(session_id, state, kind, payload, stacktrace)

        case kind do
          :exit -> exit(payload)
          :throw -> throw(payload)
          _ -> reraise(payload, stacktrace)
        end
    end
  end

  defp handle_swarm_crash(session_id, state, kind, reason, stacktrace) do
    reason_str = Exception.format(kind, reason, stacktrace)

    Logger.error("[SwarmCoordinator] Swarm run crashed for session #{session_id}: #{reason_str}")

    stop_state_agents(state, "failed")
    perform_rollback(state.project_root, state)
    update_db_session_status(session_id, "failed")

    if state.root_op_id do
      Sessions.update_operation(state.root_op_id, %{
        status: "failed",
        progress: 100,
        result: "Swarm execution crashed: #{String.slice(reason_str, 0, 500)}",
        completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
    end

    broadcast_stage(%State{state | stage: :failed}, :failed, 100, "Swarm execution crashed.")
    broadcast(session_id, {:session_status_changed, "failed"})
  rescue
    e ->
      Logger.error(
        "[SwarmCoordinator] Crash cleanup itself failed for session #{session_id}: #{Exception.message(e)}"
      )
  end

  # ============================================================================
  # Real-Time Steering & Control Engine
  # ============================================================================

  defp check_steering_and_control(%State{session_id: session_id} = state) do
    state = ensure_durable_run_active!(state)

    receive do
      {:run_control, run_id, control_id, :steer, %{"guidance" => steer_text}}
      when run_id == state.run_id ->
        next_state =
          if acknowledge_control(control_id, state, "steer") == :ok,
            do: ingest_steering(state, steer_text, "durable run control"),
            else: state

        check_steering_and_control(next_state)

      {:run_control, run_id, control_id, :pause, _payload} when run_id == state.run_id ->
        if acknowledge_control(control_id, state, "pause") == :ok do
          Logger.info("[SwarmCoordinator] Durable run #{run_id} paused.")
          broadcast(session_id, {:session_status_changed, "paused"})
          wait_for_resume_or_cancel(%State{state | status: :paused})
        else
          check_steering_and_control(state)
        end

      {:run_control, run_id, control_id, :resume, _payload} when run_id == state.run_id ->
        next_state =
          if acknowledge_control(control_id, state, "resume") == :ok,
            do: %State{state | status: :running},
            else: state

        check_steering_and_control(next_state)

      {:run_control, run_id, :cancel, _payload} when run_id == state.run_id ->
        Logger.info("[SwarmCoordinator] Durable run #{run_id} cancelled.")
        handle_cancel_and_terminate(state, action: :rollback)

      {:steer_message, steer_text} ->
        Logger.info(
          "[SwarmCoordinator] Ingested steering for session #{session_id}: #{steer_text}"
        )

        new_prompt = state.user_prompt <> "\n\n[Real-time User Guidance]: " <> steer_text
        new_directives = [steer_text | state.steer_directives]

        broadcast(
          session_id,
          {:swarm_steered,
           %{
             session_id: session_id,
             steering: steer_text,
             updated_prompt: new_prompt
           }}
        )

        check_steering_and_control(%State{
          state
          | user_prompt: new_prompt,
            steer_directives: new_directives
        })

      {:steer, steer_text} ->
        Logger.info(
          "[SwarmCoordinator] Ingested steering (direct) for session #{session_id}: #{steer_text}"
        )

        new_prompt = state.user_prompt <> "\n\n[Real-time User Guidance]: " <> steer_text
        new_directives = [steer_text | state.steer_directives]

        broadcast(
          session_id,
          {:swarm_steered,
           %{
             session_id: session_id,
             steering: steer_text,
             updated_prompt: new_prompt
           }}
        )

        check_steering_and_control(%State{
          state
          | user_prompt: new_prompt,
            steer_directives: new_directives
        })

      {:pause, ^session_id} ->
        Logger.info("[SwarmCoordinator] Session #{session_id} paused.")
        update_db_session_status(session_id, "paused")
        broadcast(session_id, {:session_status_changed, "paused"})
        state = %State{state | status: :paused}
        wait_for_resume_or_cancel(state)

      {:cancel, ^session_id, opts} ->
        Logger.info("[SwarmCoordinator] Session #{session_id} cancelled.")
        handle_cancel_and_terminate(state, opts)
    after
      0 ->
        case state |> replay_claimed_controls() |> align_durable_control_state() do
          %State{status: :paused} = paused -> wait_for_resume_or_cancel(paused)
          next_state -> next_state
        end
    end
  end

  defp wait_for_resume_or_cancel(%State{session_id: session_id} = state) do
    receive do
      {:run_control, run_id, control_id, :resume, _payload} when run_id == state.run_id ->
        if acknowledge_control(control_id, state, "resume") == :ok do
          Logger.info("[SwarmCoordinator] Durable run #{run_id} resumed.")
          broadcast(session_id, {:session_status_changed, "running"})

          case %State{state | status: :running}
               |> replay_claimed_controls()
               |> align_durable_control_state() do
            %State{status: :paused} = paused -> wait_for_resume_or_cancel(paused)
            resumed -> resumed
          end
        else
          wait_for_resume_or_cancel(state)
        end

      {:run_control, run_id, control_id, :pause, _payload} when run_id == state.run_id ->
        acknowledge_control(control_id, state, "pause")
        wait_for_resume_or_cancel(state)

      {:run_control, run_id, :cancel, _payload} when run_id == state.run_id ->
        Logger.info("[SwarmCoordinator] Durable run #{run_id} cancelled while paused.")
        handle_cancel_and_terminate(state, action: :rollback)

      {:run_control, run_id, control_id, :steer, %{"guidance" => steer_text}}
      when run_id == state.run_id ->
        if acknowledge_control(control_id, state, "steer") == :ok do
          state
          |> ingest_steering(steer_text, "durable run control while paused")
          |> wait_for_resume_or_cancel()
        else
          wait_for_resume_or_cancel(state)
        end

      {:resume, ^session_id} ->
        Logger.info("[SwarmCoordinator] Session #{session_id} resumed.")
        update_db_session_status(session_id, "running")
        broadcast(session_id, {:session_status_changed, "running"})
        %State{state | status: :running}

      # Swallow duplicate pause messages buffered while already paused, so a
      # stale pause cannot re-pause the swarm after a single resume.
      {:pause, ^session_id} ->
        Logger.info(
          "[SwarmCoordinator] Ignoring duplicate pause while already paused for session #{session_id}."
        )

        wait_for_resume_or_cancel(state)

      {:cancel, ^session_id, opts} ->
        Logger.info("[SwarmCoordinator] Session #{session_id} cancelled while paused.")
        handle_cancel_and_terminate(state, opts)

      {:steer_message, steer_text} ->
        Logger.info("[SwarmCoordinator] Ingested steering while paused: #{steer_text}")
        new_prompt = state.user_prompt <> "\n\n[Real-time User Guidance]: " <> steer_text
        new_directives = [steer_text | state.steer_directives]

        broadcast(
          session_id,
          {:swarm_steered,
           %{
             session_id: session_id,
             steering: steer_text,
             updated_prompt: new_prompt
           }}
        )

        wait_for_resume_or_cancel(%State{
          state
          | user_prompt: new_prompt,
            steer_directives: new_directives
        })

      {:steer, steer_text} ->
        new_prompt = state.user_prompt <> "\n\n[Real-time User Guidance]: " <> steer_text
        new_directives = [steer_text | state.steer_directives]

        broadcast(
          session_id,
          {:swarm_steered,
           %{
             session_id: session_id,
             steering: steer_text,
             updated_prompt: new_prompt
           }}
        )

        wait_for_resume_or_cancel(%State{
          state
          | user_prompt: new_prompt,
            steer_directives: new_directives
        })
    after
      200 ->
        case state |> replay_claimed_controls() |> align_durable_control_state() do
          %State{status: :running} = resumed -> resumed
          next_state -> wait_for_resume_or_cancel(next_state)
        end
    end
  end

  defp ingest_steering(%State{session_id: session_id} = state, steer_text, source) do
    steer_text = to_string(steer_text)
    Logger.info("[SwarmCoordinator] Ingested steering from #{source}: #{steer_text}")
    new_prompt = state.user_prompt <> "\n\n[Real-time User Guidance]: " <> steer_text

    broadcast(
      session_id,
      {:swarm_steered,
       %{session_id: session_id, steering: steer_text, updated_prompt: new_prompt}}
    )

    %State{
      state
      | user_prompt: new_prompt,
        steer_directives: [steer_text | state.steer_directives]
    }
  end

  defp acknowledge_control(control_id, state, action) do
    with %{run_id: run_id, kind: kind, worker_id: worker_id} = control <-
           Runs.get_control(control_id),
         true <- run_id == state.run_id and kind == action,
         %{lease_owner: lease_owner} when is_binary(lease_owner) <- Runs.get_run(run_id),
         true <- worker_id == lease_owner,
         {:ok, _resolved} <-
           Runs.resolve_control(
             control,
             "applied",
             %{
               "action" => action,
               "stage" => to_string(state.stage),
               "acknowledged_by" => "swarm_coordinator"
             },
             run_id: run_id,
             worker_id: worker_id,
             kind: kind
           ) do
      :ok
    else
      _ -> :stale
    end
  end

  defp replay_claimed_controls(%State{run_id: run_id} = state) when is_binary(run_id) do
    case Runs.list_controls(run_id, status: "claimed", limit: 1) do
      [%{kind: "steer", payload: payload} = control] ->
        guidance = value(payload, "guidance")
        applied? = acknowledge_control(control.id, state, "steer") == :ok

        next_state =
          if applied? and is_binary(guidance),
            do: ingest_steering(state, guidance, "durable control poll"),
            else: state

        replay_claimed_controls(next_state)

      [%{kind: "pause"} = control] ->
        next_state =
          if acknowledge_control(control.id, state, "pause") == :ok,
            do: %State{state | status: :paused},
            else: state

        replay_claimed_controls(next_state)

      [%{kind: "resume"} = control] ->
        next_state =
          if acknowledge_control(control.id, state, "resume") == :ok,
            do: %State{state | status: :running},
            else: state

        replay_claimed_controls(next_state)

      _ ->
        state
    end
  end

  defp replay_claimed_controls(state), do: state

  defp align_durable_control_state(%State{run_id: run_id} = state) when is_binary(run_id) do
    case Runs.get_run(run_id) do
      %{status: "paused"} -> %State{state | status: :paused}
      %{status: "running"} -> %State{state | status: :running}
      _ -> state
    end
  end

  defp align_durable_control_state(state), do: state

  defp ensure_durable_run_active!(%State{run_id: run_id} = state) when is_binary(run_id) do
    case Runs.get_run(run_id) do
      %IexCode.Runs.Run{status: status} when status in ["failed", "cancelled", "interrupted"] ->
        stop_state_agents(state, status)
        _ = perform_rollback(state.project_root, state)
        throw({:swarm_cancelled, :durable_run_terminal, state})

      _ ->
        state
    end
  end

  defp ensure_durable_run_active!(state), do: state

  defp value(map, key), do: Map.get(map || %{}, key) || Map.get(map || %{}, to_string(key))

  defp attach_durable_fleet(%State{run_id: run_id} = state) when is_binary(run_id) do
    run = Runs.get_run!(run_id)

    case FleetSupervisor.attach(run,
           session: state.session,
           project_root: state.project_root,
           allowed_tools: state.allowed_tools,
           workspace_lock_delegation: state.workspace_lock_delegation
         ) do
      {:ok, agents} -> %State{state | fleet_agents: agents}
      {:error, reason} -> raise "durable fleet failed to attach: #{inspect(reason)}"
    end
  end

  defp attach_durable_fleet(state), do: state

  defp ensure_legacy_agents(%State{run_id: run_id, fleet_agents: agents} = state)
       when is_binary(run_id) and agents != [],
       do: state

  defp ensure_legacy_agents(%State{run_id: run_id}) when is_binary(run_id),
    do: raise("durable run has no active fleet")

  defp ensure_legacy_agents(%State{} = state) do
    for role <- [:planner, :explorer, :coder, :verifier] do
      {:ok, _pid} =
        AgentSupervisor.start_agent(state.session_id, role,
          session: state.session,
          project_root: state.project_root
        )
    end

    state
  end

  defp fleet_size(%State{fleet_agents: []}), do: 4
  defp fleet_size(%State{fleet_agents: agents}), do: length(agents)

  defp invoke_role(state, role, fun), do: invoke_role(state, role, fun, true)

  defp invoke_role(%State{run_id: run_id, fleet_agents: agents}, role, fun, drain_steering?)
       when is_binary(run_id) and is_function(fun, 2) and is_boolean(drain_steering?) do
    case Enum.find(agents, &(&1.role == role)) do
      %{agent_id: agent_id} ->
        FleetRuntime.invoke_agent(run_id, agent_id, fn current ->
          directives =
            if drain_steering?, do: FleetManager.drain_steering(run_id, agent_id), else: []

          fun.(current.pid, directives)
        end)

      nil ->
        {:error, {:agent_missing, role}}
    end
  end

  defp invoke_role(%State{session_id: session_id}, _role, fun, _drain_steering?)
       when is_function(fun, 2) do
    safe_agent_invocation(fn -> fun.(session_id, []) end)
  end

  defp safe_agent_invocation(fun) do
    fun.()
  catch
    :exit, _reason -> {:error, :agent_invocation_interrupted}
  end

  defp explorer_targets(%State{fleet_agents: []} = state),
    do: [%{pid: state.session_id, agent_id: nil, position: 0}]

  defp explorer_targets(%State{fleet_agents: agents}) do
    agents
    |> Enum.filter(&(&1.role == :explorer))
    |> Enum.sort_by(& &1.position)
  end

  defp stop_state_agents(%State{run_id: run_id}, status) when is_binary(run_id) do
    case AgentRegistry.whereis_fleet(run_id, :manager) do
      nil -> :ok
      _pid -> FleetManager.stop(run_id, status)
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp stop_state_agents(%State{session_id: session_id}, _status),
    do: AgentSupervisor.stop_all_agents(session_id)

  defp handle_cancel_and_terminate(%State{session_id: session_id} = state, opts) do
    action = Keyword.get(opts, :action, :rollback)
    project_root = state.project_root

    # Cleanly stop all subagents
    stop_state_agents(state, "cancelled")

    case action do
      :rollback ->
        case perform_rollback(project_root, state) do
          {:ok, :rolled_back} ->
            :ok

          {:error, reason} ->
            Logger.error(
              "[SwarmCoordinator] Rollback failed during cancel for session #{session_id}: #{inspect(reason)}"
            )
        end

      :commit ->
        commit_opts =
          opts
          |> Keyword.put(:project_id, trusted_project_id(state))
          |> Keyword.put(:run_id, state.run_id)
          |> Keyword.put(:session_id, state.session_id)

        case perform_commit(project_root, commit_opts) do
          {:ok, :committed} ->
            :ok

          {:error, reason} ->
            Logger.error(
              "[SwarmCoordinator] Commit failed during cancel for session #{session_id}: #{inspect(reason)}"
            )
        end

      _ ->
        :ok
    end

    if state.root_op_id do
      Sessions.update_operation(state.root_op_id, %{
        status: "failed",
        progress: 100,
        result: "Swarm execution cancelled by user (#{action})",
        completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
    end

    update_db_session_status(session_id, "stopped")

    case Sessions.create_message(%{
           session_id: session_id,
           role: "assistant",
           agent_name: "Swarm Coordinator",
           content:
             "🛑 **Session Stopped**: Swarm execution cancelled by user with action `#{action}`."
         }) do
      {:ok, cancel_msg} -> broadcast(session_id, {:message_created, cancel_msg})
      _ -> :ok
    end

    broadcast(session_id, {:session_status_changed, "stopped"})
    broadcast(session_id, {:session_cancelled, %{session_id: session_id, action: action}})

    throw({:swarm_cancelled, action, %State{state | status: :stopped}})
  end

  # ============================================================================
  # Swarm Stages
  # ============================================================================

  defp run_planning_phase(%State{user_prompt: prompt, root_op_id: root_op_id} = state) do
    broadcast_stage(state, :planning, 15, "Planner: Decomposing architecture & execution plan...")

    plan_res =
      invoke_role(state, :planner, fn target, targeted_steering ->
        PlannerAgent.plan(
          target,
          prompt,
          parent_op_id: root_op_id,
          project_root: state.project_root,
          run_id: state.run_id,
          steer_directives: state.steer_directives ++ targeted_steering,
          allowed_tools: state.allowed_tools,
          workspace_lock_delegation: state.workspace_lock_delegation
        )
      end)

    plan_text =
      case plan_res do
        {:ok, text} -> text
        {:error, reason} -> abort_durable_agent_phase!(state, :planner, reason)
      end

    broadcast_stage(state, :planning, 25, "Planner: Execution plan formulated.")
    %State{state | plan: plan_text, stage: :planning}
  end

  defp run_exploration_phase(%State{user_prompt: prompt, root_op_id: root_op_id} = state) do
    broadcast_stage(
      state,
      :exploring,
      35,
      "Explorer: Scanning codebase for relevant files & AST symbols..."
    )

    targets = explorer_targets(state)

    summary_text =
      targets
      |> Enum.with_index()
      |> Task.async_stream(
        fn {entry, index} ->
          focus =
            "Explorer shard #{index + 1}/#{length(targets)}: inspect a distinct relevant area."

          invoke_explorer(state, entry, fn target, targeted_steering ->
            guidance =
              (state.steer_directives ++ targeted_steering)
              |> Enum.map_join("\n", &"- #{&1}")

            ExplorerAgent.explore(
              target,
              prompt <> "\n\n" <> focus <> "\n" <> guidance,
              parent_op_id: root_op_id,
              project_root: state.project_root,
              run_id: state.run_id,
              allowed_tools: state.allowed_tools,
              workspace_lock_delegation: state.workspace_lock_delegation
            )
          end)
        end,
        max_concurrency: max(length(targets), 1),
        ordered: true,
        timeout: :infinity
      )
      |> Enum.with_index()
      |> Enum.map_join("\n\n", fn
        {{:ok, {:ok, text}}, index} ->
          "Explorer #{index + 1}:\n#{text}"

        {{:ok, {:error, reason}}, _index} ->
          abort_durable_agent_phase!(state, :explorer, reason)

        {{:exit, reason}, _index} ->
          abort_durable_agent_phase!(state, :explorer, reason)
      end)

    broadcast_stage(state, :exploring, 45, "Explorer: Codebase context synthesized.")
    %State{state | explorer_context: summary_text, stage: :exploring}
  end

  defp invoke_explorer(%State{run_id: run_id}, %{agent_id: agent_id}, fun)
       when is_binary(run_id) do
    FleetRuntime.invoke_agent(run_id, agent_id, fn current ->
      fun.(current.pid, FleetManager.drain_steering(run_id, agent_id))
    end)
  end

  defp invoke_explorer(_state, %{pid: target}, fun) do
    safe_agent_invocation(fn -> fun.(target, []) end)
  end

  defp run_coding_and_verification_loop(%State{} = state) do
    do_coding_and_verification_loop(state, 0)
  end

  defp do_coding_and_verification_loop(%State{} = state, iteration) do
    state = check_steering_and_control(state)
    session_id = state.session_id
    project_root = state.project_root
    root_op_id = state.root_op_id
    prompt = state.user_prompt

    progress_pct = min(75, 45 + iteration * 10)

    # Step A: Coder Phase
    msg =
      if iteration == 0 do
        "Coder: Generating implementation and atomic patches..."
      else
        "Coder: Self-healing iteration #{iteration}/#{state.max_retries}: Applying targeted fixes..."
      end

    broadcast_stage(%State{state | iteration: iteration}, :coding, progress_pct, msg)

    coder_opts = [
      session_id: session_id,
      run_id: state.run_id,
      parent_op_id: root_op_id,
      project_root: project_root,
      plan: state.plan,
      context: state.explorer_context,
      diagnostics: state.verifier_result,
      steer_directives: state.steer_directives,
      allowed_tools: state.allowed_tools,
      workspace_lock_delegation: state.workspace_lock_delegation
    ]

    coder_res =
      invoke_role(state, :coder, fn coder_target, coder_steering ->
        CoderAgent.code(
          coder_target,
          prompt,
          Keyword.update!(coder_opts, :steer_directives, &(&1 ++ coder_steering))
        )
      end)

    coder_text =
      case coder_res do
        {:ok, text} -> text
        {:error, reason} -> abort_durable_agent_phase!(state, :coder, reason)
      end

    state = %State{state | coder_result: coder_text, iteration: iteration}
    state = check_steering_and_control(state)

    # Step B: Verifier Phase
    verify_progress = min(95, 75 + iteration * 5)

    broadcast_stage(
      state,
      :verifying,
      verify_progress,
      "Verifier: Checking compilation and test suite..."
    )

    verify_res = invoke_verifier(state, root_op_id, project_root)

    state = check_steering_and_control(state)

    case verify_res do
      {:ok, summary_map} ->
        # Verification Cleanly Passed!
        broadcast_stage(
          state,
          :complete,
          100,
          "Verification passed: All tests and compilation clean."
        )

        %State{state | verifier_result: summary_map, status: :completed, stage: :complete}

      {:error, {:verification_failed, diagnostics}} ->
        # Verification failed! Check retry condition & cycle detection
        # Hash deterministic semantic fields so recurring errors with duration
        # jitter are detected as cycles immediately.
        err_signature = compute_error_signature(diagnostics)

        if MapSet.member?(state.error_signatures, err_signature) or iteration >= state.max_retries do
          # Terminate loop (cycle detected or exceeded max retries)
          term_msg =
            if iteration >= state.max_retries do
              "Verification failed after #{state.max_retries} self-healing retries."
            else
              "Self-healing cycle detected. Halting loop."
            end

          broadcast_stage(state, :failed, 100, term_msg)
          %State{state | verifier_result: diagnostics, status: :failed, stage: :failed}
        else
          # Apply instant auto-fix heuristics if applicable
          auto_fix_res =
            AutoFix.apply_auto_fix(project_root, diagnostics,
              session_id: session_id,
              project_id: trusted_project_id(state),
              run_id: state.run_id,
              allowed_tools: state.allowed_tools
            )

          auto_fix_summary =
            case auto_fix_res do
              {:ok, summary} -> "AutoFix applied #{summary.applied} patch(es)"
              _ -> nil
            end

          new_sigs = MapSet.put(state.error_signatures, err_signature)

          new_state = %State{
            state
            | verifier_result: diagnostics,
              error_signatures: new_sigs,
              history: [{iteration, diagnostics, auto_fix_summary} | state.history]
          }

          case auto_fix_res do
            {:ok, %{applied: applied}} when applied > 0 ->
              # Direct re-verification optimization: AutoFix applied candidate proposals directly,
              # immediately verify to save latency if clean.
              broadcast_stage(
                new_state,
                :verifying,
                min(95, 75 + (iteration + 1) * 5),
                "AutoFix applied #{applied} fix(es). Re-verifying directly..."
              )

              verify_res = invoke_verifier(state, root_op_id, project_root)

              case verify_res do
                {:ok, summary_map} ->
                  broadcast_stage(
                    new_state,
                    :complete,
                    100,
                    "Verification passed: All tests and compilation clean."
                  )

                  %State{
                    new_state
                    | verifier_result: summary_map,
                      status: :completed,
                      stage: :complete,
                      iteration: iteration + 1
                  }

                {:error, {:verification_failed, new_diagnostics}} ->
                  new_err_sig = compute_error_signature(new_diagnostics)

                  if MapSet.member?(new_state.error_signatures, new_err_sig) or
                       iteration + 1 >= new_state.max_retries do
                    term_msg =
                      if iteration + 1 >= new_state.max_retries do
                        "Verification failed after #{new_state.max_retries} self-healing retries."
                      else
                        "Self-healing cycle detected. Halting loop."
                      end

                    broadcast_stage(new_state, :failed, 100, term_msg)

                    %State{
                      new_state
                      | verifier_result: new_diagnostics,
                        status: :failed,
                        stage: :failed,
                        iteration: iteration + 1
                    }
                  else
                    do_coding_and_verification_loop(
                      %State{
                        new_state
                        | verifier_result: new_diagnostics,
                          error_signatures: MapSet.put(new_state.error_signatures, new_err_sig)
                      },
                      iteration + 1
                    )
                  end

                {:error, reason} ->
                  broadcast_stage(
                    new_state,
                    :failed,
                    100,
                    "Verifier encountered unexpected error: #{inspect(reason)}"
                  )

                  %State{
                    new_state
                    | verifier_result: %{summary: inspect(reason)},
                      status: :failed,
                      stage: :failed,
                      iteration: iteration + 1
                  }
              end

            _ ->
              do_coding_and_verification_loop(new_state, iteration + 1)
          end
        end

      {:error, reason} ->
        broadcast_stage(
          state,
          :failed,
          100,
          "Verifier encountered unexpected error: #{inspect(reason)}"
        )

        %State{
          state
          | verifier_result: %{summary: inspect(reason)},
            status: :failed,
            stage: :failed
        }
    end
  end

  defp invoke_verifier(state, root_op_id, project_root) do
    invoke_role(
      state,
      :verifier,
      fn target, _targeted_steering ->
        VerifierAgent.verify(
          target,
          parent_op_id: root_op_id,
          project_root: project_root,
          run_id: state.run_id,
          allowed_tools: state.allowed_tools,
          workspace_lock_delegation: state.workspace_lock_delegation
        )
      end,
      false
    )
  end

  # Interactive legacy sessions historically degrade missing agent responses into notes.
  # Durable runs must instead stop at the phase boundary: continuing after an agent lease
  # or invocation was interrupted could let a later mutating phase run without its declared
  # prerequisite. An explicit targeted restart can service a later invocation, but this
  # interrupted call is never replayed implicitly.
  defp abort_durable_agent_phase!(%State{run_id: run_id} = state, role, reason)
       when is_binary(run_id) do
    stop_state_agents(state, "interrupted")
    _ = perform_rollback(state.project_root, state)

    broadcast_stage(
      %State{state | stage: :failed, status: :failed},
      :failed,
      100,
      "#{String.capitalize(to_string(role))} invocation was interrupted; explicit retry is required."
    )

    throw({:swarm_agent_phase_interrupted, role, reason, state})
  end

  defp abort_durable_agent_phase!(_state, role, reason),
    do: "#{String.capitalize(to_string(role))} note: #{inspect(reason)}"

  defp finish_swarm(%State{session_id: session_id} = state) do
    # Cleanup subagent processes for this session
    stop_state_agents(state, if(state.status == :completed, do: "completed", else: "failed"))

    verifier_summary =
      case state.verifier_result do
        %{summary: s} -> s
        other -> inspect(other)
      end

    steer_summary =
      if state.steer_directives != [] do
        guidance =
          state.steer_directives
          |> Enum.reverse()
          |> Enum.map(&"- #{&1}")
          |> Enum.join("\n")

        "\n\n**🧭 User Steering Applied**:\n#{guidance}"
      else
        ""
      end

    final_content =
      """
      ### 🐝 Swarm Execution Complete

      **🎯 Plan & Objective**:
      #{state.plan}

      **🔍 Exploration Findings**:
      #{state.explorer_context}

      **💻 Implementation**:
      #{state.coder_result}

      **🧪 Verification & Quality Check**:
      #{verifier_summary}#{steer_summary}
      """

    final_msg =
      case Sessions.create_message(%{
             session_id: session_id,
             role: "assistant",
             agent_name: "Swarm Coordinator",
             content: final_content,
             metadata: %{
               swarm_mode: true,
               status: state.status,
               iterations: state.iteration,
               steering_count: length(state.steer_directives)
             }
           }) do
        {:ok, msg} ->
          broadcast(session_id, {:message_created, msg})
          msg

        {:error, reason} ->
          Logger.error(
            "[SwarmCoordinator] Failed to persist final swarm message for session #{session_id}: #{inspect(reason)}"
          )

          %{id: nil, role: "assistant", content: final_content}
      end

    # Complete root operation
    if state.root_op_id do
      duration = System.monotonic_time(:millisecond) - state.start_time_ms

      case Sessions.update_operation(state.root_op_id, %{
             status: if(state.status == :completed, do: "completed", else: "failed"),
             progress: 100,
             result:
               if(state.status == :completed,
                 do: "Swarm execution completed",
                 else: "Swarm execution halted with diagnostics"
               ),
             completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
             duration_ms: duration
           }) do
        {:ok, updated_root} ->
          broadcast(session_id, {:operation_completed, updated_root})

        _ ->
          :ok
      end
    end

    update_db_session_status(
      session_id,
      if(state.status == :completed, do: "completed", else: "idle")
    )

    broadcast(session_id, {:session_status_changed, "idle"})

    broadcast(
      session_id,
      {:goal_lifecycle_changed, %{session_id: session_id, status: state.status}}
    )

    {:ok, final_msg}
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp create_root_operation(session_id, user_prompt) do
    case Sessions.create_operation(%{
           session_id: session_id,
           agent_name: "SwarmOrchestrator",
           op_type: "swarm_root",
           title: "Swarm Goal: #{String.slice(user_prompt, 0, 60)}...",
           status: "running",
           progress: 0,
           started_at: DateTime.utc_now() |> DateTime.truncate(:second),
           params: %{prompt: user_prompt}
         }) do
      {:ok, op} ->
        broadcast(session_id, {:operation_started, op})
        {:ok, op}

      _ ->
        {:ok, %{id: Ecto.UUID.generate()}}
    end
  end

  defp broadcast_stage(
         %State{session_id: session_id, start_time_ms: start_time} = state,
         stage,
         progress,
         message
       ) do
    latency_ms = System.monotonic_time(:millisecond) - start_time
    pid_str = inspect(self())

    event =
      {:swarm_stage_changed,
       %{
         session_id: session_id,
         stage: stage,
         progress: progress,
         latency_ms: latency_ms,
         agent_pid: pid_str,
         message: message
       }}

    broadcast(session_id, event)
    persist_run_stage(state, stage, progress, message)
  end

  defp persist_run_stage(%State{run_id: run_id}, stage, progress, message)
       when is_binary(run_id) do
    _ = Runs.record_progress(run_id, progress, message, "swarm.#{stage}")
    :ok
  rescue
    error ->
      Logger.warning(
        "[SwarmCoordinator] Could not persist run stage #{stage}: #{Exception.message(error)}"
      )

      :ok
  end

  defp persist_run_stage(_state, _stage, _progress, _message), do: :ok

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

  defp broadcast(session_id, event) do
    PubSub.broadcast(IexCode.PubSub, "session:#{session_id}", event)
  rescue
    _ -> :ok
  end

  defp compute_error_signature(diagnostics) when is_map(diagnostics) do
    # Extract deterministic semantic fields: status, failures, compilation_errors
    status = Map.get(diagnostics, :status)
    failures = Map.get(diagnostics, :failures, [])
    compilation_errors = Map.get(diagnostics, :compilation_errors, [])

    if failures != [] or compilation_errors != [] do
      :erlang.phash2({status, failures, compilation_errors})
    else
      # If structured failures/compilation_errors are empty, fall back to normalized text
      raw = Map.get(diagnostics, :summary) || Map.get(diagnostics, :raw_output)

      clean_text =
        case raw do
          text when is_binary(text) ->
            Regex.replace(~r/Finished in [0-9.]+ seconds.*?\n/, text, "")

          other ->
            other
        end

      :erlang.phash2({status, clean_text})
    end
  end

  defp compute_error_signature(other) do
    :erlang.phash2(other)
  end
end
