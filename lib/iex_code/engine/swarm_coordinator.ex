defmodule IexCode.Engine.SwarmCoordinator do
  @moduledoc """
  Coordinates multi-agent autonomous swarm workflows using isolated OTP GenServers
  (PlannerAgent, ExplorerAgent, CoderAgent, VerifierAgent) managed by AgentSupervisor.
  Implements an autonomous self-healing error feedback loop (up to 3 retries) when
  compilation errors or test failures are detected.
  """
  require Logger
  alias IexCode.Engine.AgentSupervisor
  alias IexCode.Engine.Agents.{PlannerAgent, ExplorerAgent, CoderAgent, VerifierAgent}
  alias IexCode.Tools.AutoFix
  alias IexCode.Sessions
  alias Phoenix.PubSub

  defmodule State do
    defstruct [
      :session_id,
      :session,
      :project_root,
      :user_prompt,
      :root_op_id,
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

    task =
      Task.Supervisor.async_nolink(IexCode.TaskSupervisor, fn ->
        run(session_id, user_prompt, run_opts)
      end)

    {:ok, task.pid}
  end

  @doc """
  Executes the synchronous swarm coordination state machine.
  Returns `{:ok, final_message}` or `{:error, reason}`.
  """
  def run(session_id, user_prompt, opts \\ []) do
    session = Sessions.get_session!(session_id)

    project_root =
      opts[:project_root] || (session.project && session.project.root_path) || File.cwd!()

    max_retries = Keyword.get(opts, :max_retries, 3)

    broadcast(session_id, {:session_status_changed, "running"})

    start_time_ms = System.monotonic_time(:millisecond)

    state = %State{
      session_id: session_id,
      session: session,
      project_root: project_root,
      user_prompt: user_prompt,
      max_retries: max_retries,
      start_time_ms: start_time_ms,
      stage_start_ms: start_time_ms,
      stage: :init,
      status: :running
    }

    # Start or ensure all subagent GenServers are running under AgentSupervisor
    {:ok, _} =
      AgentSupervisor.start_agent(session_id, :planner,
        session: session,
        project_root: project_root
      )

    {:ok, _} =
      AgentSupervisor.start_agent(session_id, :explorer,
        session: session,
        project_root: project_root
      )

    {:ok, _} =
      AgentSupervisor.start_agent(session_id, :coder,
        session: session,
        project_root: project_root
      )

    {:ok, _} =
      AgentSupervisor.start_agent(session_id, :verifier,
        session: session,
        project_root: project_root
      )

    # 1. Root Swarm Operation
    {:ok, root_op} =
      create_root_operation(session_id, user_prompt)

    state = %State{state | root_op_id: root_op.id}

    broadcast_stage(state, :init, 5, "Swarm initialized with 4 specialized OTP subagents.")

    # 2. Planning Phase
    state = run_planning_phase(state)

    # 3. Exploration Phase
    state = run_exploration_phase(state)

    # 4. Coding & Verification Phase with Self-Healing Feedback Loop
    state = run_coding_and_verification_loop(state)

    # 5. Final Synthesis & Assistant Message
    finish_swarm(state)
  end

  # ============================================================================
  # Swarm Stages
  # ============================================================================

  defp run_planning_phase(
         %State{session_id: session_id, user_prompt: prompt, root_op_id: root_op_id} = state
       ) do
    broadcast_stage(state, :planning, 15, "Planner: Decomposing architecture & execution plan...")

    plan_res =
      PlannerAgent.plan(
        session_id,
        prompt,
        parent_op_id: root_op_id,
        project_root: state.project_root
      )

    plan_text =
      case plan_res do
        {:ok, text} -> text
        {:error, reason} -> "Planner note: #{inspect(reason)}"
      end

    broadcast_stage(state, :planning, 25, "Planner: Execution plan formulated.")
    %State{state | plan: plan_text, stage: :planning}
  end

  defp run_exploration_phase(
         %State{session_id: session_id, user_prompt: prompt, root_op_id: root_op_id} = state
       ) do
    broadcast_stage(
      state,
      :exploring,
      35,
      "Explorer: Scanning codebase for relevant files & AST symbols..."
    )

    explore_res =
      ExplorerAgent.explore(
        session_id,
        prompt,
        parent_op_id: root_op_id,
        project_root: state.project_root
      )

    summary_text =
      case explore_res do
        {:ok, text} -> text
        {:error, reason} -> "Explorer note: #{inspect(reason)}"
      end

    broadcast_stage(state, :exploring, 45, "Explorer: Codebase context synthesized.")
    %State{state | explorer_context: summary_text, stage: :exploring}
  end

  defp run_coding_and_verification_loop(%State{} = state) do
    do_coding_and_verification_loop(state, 0)
  end

  defp do_coding_and_verification_loop(%State{} = state, iteration) do
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
      parent_op_id: root_op_id,
      project_root: project_root,
      plan: state.plan,
      context: state.explorer_context,
      diagnostics: state.verifier_result
    ]

    coder_res = CoderAgent.code(session_id, prompt, coder_opts)

    coder_text =
      case coder_res do
        {:ok, text} -> text
        {:error, reason} -> "Coder note: #{inspect(reason)}"
      end

    state = %State{state | coder_result: coder_text, iteration: iteration}

    # Step B: Verifier Phase
    verify_progress = min(95, 75 + iteration * 5)

    broadcast_stage(
      state,
      :verifying,
      verify_progress,
      "Verifier: Checking compilation and test suite..."
    )

    verify_res =
      VerifierAgent.verify(
        session_id,
        parent_op_id: root_op_id,
        project_root: project_root
      )

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
        err_signature = :erlang.phash2(diagnostics.summary || diagnostics)

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
          auto_fix_summary =
            case AutoFix.apply_auto_fix(project_root, diagnostics) do
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

          do_coding_and_verification_loop(new_state, iteration + 1)
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

  defp finish_swarm(%State{session_id: session_id} = state) do
    # Cleanup subagent processes for this session
    AgentSupervisor.stop_all_agents(session_id)

    verifier_summary =
      case state.verifier_result do
        %{summary: s} -> s
        other -> inspect(other)
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
      #{verifier_summary}
      """

    {:ok, final_msg} =
      Sessions.create_message(%{
        session_id: session_id,
        role: "assistant",
        agent_name: "Swarm Coordinator",
        content: final_content,
        metadata: %{
          swarm_mode: true,
          status: state.status,
          iterations: state.iteration
        }
      })

    # Complete root operation
    if state.root_op_id do
      duration = System.monotonic_time(:millisecond) - state.start_time_ms

      case Sessions.update_operation(state.root_op_id, %{
             status: "completed",
             progress: 100,
             result: "Swarm execution completed",
             completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
             duration_ms: duration
           }) do
        {:ok, updated_root} ->
          broadcast(session_id, {:operation_completed, updated_root})

        _ ->
          :ok
      end
    end

    broadcast(session_id, {:message_created, final_msg})
    broadcast(session_id, {:session_status_changed, "idle"})

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
         %State{session_id: session_id, start_time_ms: start_time},
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
  end

  defp broadcast(session_id, event) do
    PubSub.broadcast(IexCode.PubSub, "session:#{session_id}", event)
  rescue
    _ -> :ok
  end
end
