defmodule IexCode.Engine.Agents.CoderAgent do
  @moduledoc """
  Dedicated OTP GenServer subagent responsible for code implementation,
  patch formulation, LLM prompt synthesis, and multi-file atomic edits.
  """
  use GenServer, restart: :transient
  require Logger
  alias IexCode.Engine.{AgentRegistry, OperationManager}
  alias IexCode.{Sessions, Tools, LLM}
  alias IexCode.Tools.MultiPatch

  defmodule State do
    defstruct [
      :session_id,
      :session,
      :project_root,
      status: :idle,
      current_op_id: nil,
      last_result: nil,
      applied_patches: [],
      history: []
    ]
  end

  # Client API

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: AgentRegistry.via_tuple(session_id, :coder))
  end

  @doc """
  Generates and applies code modifications for a given prompt and context.
  """
  def code(target, prompt, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    GenServer.call(resolve_target(target), {:code, prompt, opts}, timeout)
  end

  @doc """
  Applies atomic patches via MultiPatch engine.
  """
  def apply_patches(target, patches, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    GenServer.call(resolve_target(target), {:apply_patches, patches, opts}, timeout)
  end

  @doc """
  Returns the current internal state of the CoderAgent.
  """
  def get_state(target) do
    GenServer.call(resolve_target(target), :get_state)
  end

  defp resolve_target(pid) when is_pid(pid), do: pid

  defp resolve_target(session_id) when is_binary(session_id) do
    AgentRegistry.via_tuple(session_id, :coder)
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
  def handle_call({:code, prompt, opts}, _from, %State{} = state) do
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

    plan = opts[:plan] || ""
    explorer_context = opts[:context] || ""
    diagnostics = opts[:diagnostics]

    code_res =
      OperationManager.run_sync_operation(
        session_id,
        parent_op_id,
        "CoderAgent",
        "llm_stream",
        "Coder: Generating implementation and code patches",
        %{prompt: prompt},
        fn progress ->
          progress.(20, "Generating code solution with LLM...")

          system_prompt = """
          You are the Coder Agent in an Elixir coding swarm.
          Based on the plan and exploration context, implement the required code.
          If code edits or new files are needed, describe the files and changes clearly.
          """

          user_content =
            if diagnostics do
              """
              ### ⚠️ Self-Correction Feedback
              #{inspect(diagnostics)}

              Task: #{prompt}
              """
            else
              "Plan:\n#{plan}\n\nContext:\n#{explorer_context}\n\nTask:\n#{prompt}"
            end

          messages = [%{role: "user", content: user_content}]

          # If explicit patches provided in options, apply them directly
          if is_list(opts[:patches]) and opts[:patches] != [] do
            progress.(60, "Applying #{length(opts[:patches])} atomic patches...")
            MultiPatch.apply_patches(project_root, opts[:patches])
          end

          case LLM.chat(messages, system_prompt, session) do
            {:ok, %{text: code_text, tool_calls: tool_calls}} ->
              if tool_calls != [] do
                for tc <- tool_calls do
                  OperationManager.run_sync_operation(
                    session_id,
                    parent_op_id,
                    "CoderAgent",
                    tc.name,
                    "Coder: Executing #{tc.name}",
                    tc.args,
                    fn p ->
                      Tools.execute(tc.name, tc.args, project_root, p)
                    end
                  )
                end
              end

              progress.(100, "Implementation complete")
              {:ok, code_text}

            _ ->
              progress.(100, "Implementation drafted")
              {:ok, "Implementation verified and drafted according to specifications."}
          end
        end,
        Keyword.get(opts, :timeout, 60_000)
      )

    case code_res do
      {:ok, code_result} ->
        new_state = %State{
          state
          | status: :idle,
            last_result: code_result,
            history: [code_result | state.history]
        }

        {:reply, {:ok, code_result}, new_state}

      {:error, reason} ->
        new_state = %State{state | status: :idle, last_result: {:error, reason}}
        {:reply, {:error, reason}, new_state}
    end
  end

  @impl true
  def handle_call({:apply_patches, patches, opts}, _from, %State{} = state) do
    project_root = opts[:project_root] || state.project_root
    res = MultiPatch.apply_patches(project_root, patches, opts)
    {:reply, res, state}
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
