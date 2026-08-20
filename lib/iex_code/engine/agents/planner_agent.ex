defmodule IexCode.Engine.Agents.PlannerAgent do
  @moduledoc """
  Dedicated OTP GenServer subagent responsible for goal decomposition,
  architectural analysis, and task planning for Explorer, Coder, and Verifier.
  """
  use GenServer, restart: :transient
  require Logger
  alias IexCode.Engine.{AgentRegistry, OperationManager}
  alias IexCode.{Sessions, Tools, LLM}

  defmodule State do
    defstruct [
      :session_id,
      :session,
      :project_root,
      status: :idle,
      current_op_id: nil,
      last_result: nil,
      history: []
    ]
  end

  # Client API

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: AgentRegistry.via_tuple(session_id, :planner))
  end

  @doc """
  Decomposes a user goal into an actionable architecture and execution plan.
  Accepts a session_id string or direct PID.
  """
  def plan(target, prompt, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    GenServer.call(resolve_target(target), {:plan, prompt, opts}, timeout)
  end

  @doc """
  Returns the current internal state of the PlannerAgent.
  """
  def get_state(target) do
    GenServer.call(resolve_target(target), :get_state)
  end

  defp resolve_target(pid) when is_pid(pid), do: pid

  defp resolve_target(session_id) when is_binary(session_id) do
    AgentRegistry.via_tuple(session_id, :planner)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    session = opts[:session]

    project_root =
      opts[:project_root] || (session && session.project && session.project.root_path) ||
        File.cwd!()

    state = %State{
      session_id: session_id,
      session: session,
      project_root: project_root,
      status: :idle
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:plan, prompt, opts}, _from, %State{} = state) do
    session_id = state.session_id
    project_root = opts[:project_root] || state.project_root
    parent_op_id = opts[:parent_op_id]

    session =
      state.session ||
        try do
          Sessions.get_session!(session_id)
        rescue
          _ -> nil
        end

    plan_res =
      OperationManager.run_sync_operation(
        session_id,
        parent_op_id,
        "PlannerAgent",
        "subagent_plan",
        "Planner: Decomposing architecture & execution plan",
        %{prompt: prompt},
        fn progress ->
          progress.(15, "Analyzing user request and workspace architecture...")

          # Inspect top-level workspace structure
          OperationManager.run_sync_operation(
            session_id,
            parent_op_id,
            "PlannerAgent",
            "list_dir",
            "Planner: Inspecting workspace directory",
            %{path: ""},
            fn p ->
              Tools.execute("list_dir", %{"path" => "", "recursive" => false}, project_root, p)
            end
          )

          progress.(60, "Formulating task decomposition...")

          system_prompt = """
          You are the Master Planner in an Elixir coding swarm.
          Analyze the user's goal, break it down into clear architectural steps for the Explorer, Coder, and Verifier agents.
          Keep the response clear, structured, and action-oriented.
          """

          messages = [%{role: "user", content: "Goal: #{prompt}\nProject root: #{project_root}"}]

          case LLM.chat(messages, system_prompt, session) do
            {:ok, %{text: plan_text}} when is_binary(plan_text) and byte_size(plan_text) > 0 ->
              progress.(100, "Plan ready")
              {:ok, plan_text}

            _ ->
              fallback_plan =
                """
                1. Inspect workspace structure and relevant modules.
                2. Implement required changes or functions.
                3. Run tests and verify code compilation.
                """
                |> String.trim()

              progress.(100, "Default plan created")
              {:ok, fallback_plan}
          end
        end,
        Keyword.get(opts, :timeout, 60_000)
      )

    case plan_res do
      {:ok, plan_text} ->
        new_state = %State{
          state
          | status: :idle,
            last_result: plan_text,
            history: [plan_text | state.history]
        }

        {:reply, {:ok, plan_text}, new_state}

      {:error, reason} ->
        new_state = %State{state | status: :idle, last_result: {:error, reason}}
        {:reply, {:error, reason}, new_state}
    end
  end

  @impl true
  def handle_call(:get_state, _from, %State{} = state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:operation_task_done, _op_id, _result}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
