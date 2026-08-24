defmodule IexCode.Engine.Agents.CoderAgent do
  @moduledoc """
  Dedicated OTP GenServer subagent responsible for code implementation,
  patch formulation, LLM prompt synthesis, and multi-file atomic edits.
  """
  use GenServer, restart: :transient
  require Logger
  alias IexCode.Engine.{AgentRegistry, OperationManager}
  alias IexCode.{Sessions, Tools, LLM}
  alias IexCode.Tools.{MultiPatch, AutoFix}

  @outer_timeout 90_000
  @inner_timeout 60_000
  @max_tool_iterations 5

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
    timeout = Keyword.get(opts, :timeout, @outer_timeout)
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

    set_cancelled?(session_id, false)
    subscribe_steering(session_id)

    {:ok, state}
  end

  @impl true
  def handle_call({:code, prompt, opts}, _from, %State{} = state) do
    session_id = state.session_id
    opts = Keyword.put_new(opts, :session_id, session_id)
    project_root = opts[:project_root] || state.project_root
    parent_op_id = opts[:parent_op_id]

    session =
      opts[:session] || state.session ||
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
          progress.(15, "Generating code solution with LLM...")

          steer_directives = Keyword.get(opts, :steer_directives, [])

          system_prompt = """
          You are the Coder Agent in an Elixir coding swarm.
          Based on the plan and exploration context, implement the required code.
          If code edits or new files are needed, describe the files and changes clearly.
          """

          base_content =
            if diagnostics do
              diag_str = AutoFix.format_diagnostics(diagnostics)

              """
              ### ⚠️ Self-Correction Feedback
              #{diag_str}

              Task: #{prompt}
              """
            else
              "Plan:\n#{plan}\n\nContext:\n#{explorer_context}\n\nTask:\n#{prompt}"
            end

          messages = [
            %{role: "user", content: append_steer_directives(base_content, steer_directives)}
          ]

          with :ok <- apply_explicit_patches(opts, project_root, progress),
               {:ok, code_text} <-
                 run_tool_loop(
                   session_id,
                   messages,
                   system_prompt,
                   session,
                   project_root,
                   parent_op_id,
                   opts[:run_id],
                   Keyword.get(opts, :allowed_tools, :all),
                   progress,
                   0
                 ) do
            progress.(100, "Implementation complete")
            {:ok, code_text}
          else
            {:error, reason} = err ->
              progress.(100, "Implementation failed: #{format_reason(reason)}")
              err
          end
        end,
        Keyword.get(opts, :inner_timeout, @inner_timeout)
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
    opts = Keyword.put_new(opts, :session_id, state.session_id)
    project_root = opts[:project_root] || state.project_root
    res = MultiPatch.apply_patches(project_root, patches, opts)
    {:reply, res, state}
  end

  @impl true
  def handle_call(:get_state, _from, %State{} = state) do
    {:reply, state, state}
  end

  # Tool loop helpers

  defp apply_explicit_patches(opts, project_root, progress) do
    patches = opts[:patches]

    if is_list(patches) and patches != [] do
      progress.(30, "Applying #{length(patches)} atomic patches...")

      case MultiPatch.apply_patches(project_root, patches, opts) do
        {:ok, _summary} -> :ok
        {:error, reason} -> {:error, {:patch_application_failed, reason}}
      end
    else
      :ok
    end
  end

  defp run_tool_loop(
         session_id,
         messages,
         system_prompt,
         session,
         project_root,
         parent_op_id,
         run_id,
         allowed_tools,
         progress,
         iteration
       ) do
    if iteration >= @max_tool_iterations do
      {:error, {:tool_iteration_limit_reached, @max_tool_iterations}}
    else
      progress.(
        min(90, 40 + iteration * 10),
        "LLM iteration #{iteration + 1}/#{@max_tool_iterations}..."
      )

      case LLM.chat(messages, system_prompt, session, fn _c -> :ok end,
             cancelled?: cancelled_fun(session_id),
             allowed_tools: allowed_tools
           ) do
        {:ok, %{text: text, tool_calls: tool_calls} = response} when tool_calls != [] ->
          with :ok <- persist_run_usage(run_id, response) do
            progress.(60, "Executing #{length(tool_calls)} tool call(s)...")

            tool_messages =
              Enum.map(
                tool_calls,
                &execute_tool_call(
                  &1,
                  session_id,
                  project_root,
                  parent_op_id,
                  run_id,
                  allowed_tools
                )
              )

            run_tool_loop(
              session_id,
              messages ++ assistant_messages(text) ++ tool_messages,
              system_prompt,
              session,
              project_root,
              parent_op_id,
              run_id,
              allowed_tools,
              progress,
              iteration + 1
            )
          end

        {:ok, %{text: text} = response} ->
          with :ok <- persist_run_usage(run_id, response), do: {:ok, text || ""}

        {:ok, other} ->
          {:error, {:unexpected_llm_response, other}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp execute_tool_call(tc, session_id, project_root, parent_op_id, run_id, allowed_tools) do
    args =
      if is_map(tc.args) do
        Map.merge(
          tc.args,
          %{
            "session_id" => session_id,
            "run_id" => run_id,
            "agent_name" => "CoderAgent",
            "op_id" => parent_op_id
          }
        )
      else
        tc.args
      end

    res =
      if tool_allowed?(tc.name, allowed_tools) do
        OperationManager.run_sync_operation(
          session_id,
          parent_op_id,
          "CoderAgent",
          tc.name,
          "Coder: Executing #{tc.name}",
          args,
          fn p ->
            Tools.execute(tc.name, args, project_root, p)
          end
        )
      else
        {:error, {:tool_not_allowed, tc.name}}
      end

    content =
      case res do
        {:ok, output} -> format_tool_output(output)
        {:error, reason} -> "ERROR: #{format_reason(reason)}"
      end

    %{role: "tool", content: content, tool_call_id: tc.id}
  end

  defp assistant_messages(text) when text in [nil, ""], do: []

  defp assistant_messages(text) when is_binary(text),
    do: [%{role: "assistant", content: text}]

  defp format_tool_output(output) when is_binary(output) do
    if byte_size(output) > 4000 do
      String.slice(output, 0, 4000) <> "\n...(truncated)"
    else
      output
    end
  end

  defp format_tool_output(other), do: inspect(other)

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp tool_allowed?(_tool_name, :all), do: true
  defp tool_allowed?(_tool_name, nil), do: true

  defp tool_allowed?(tool_name, allowed_tools) when is_list(allowed_tools),
    do: to_string(tool_name) in Enum.map(allowed_tools, &to_string/1)

  defp tool_allowed?(_tool_name, _allowed_tools), do: false

  defp persist_run_usage(nil, _response), do: :ok

  defp persist_run_usage(run_id, response) do
    usage = Map.get(response, :usage) || Map.get(response, "usage")

    if is_map(usage) do
      case IexCode.Runs.record_usage(run_id, usage, "coder.llm") do
        {:ok, _run} -> :ok
        {:error, {:token_budget_exhausted, _run}} -> {:error, :token_budget_exhausted}
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  # Steering / cancellation helpers

  defp subscribe_steering(session_id) do
    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session_id}:steer")
  end

  defp set_cancelled?(session_id, value) do
    :persistent_term.put({__MODULE__, :cancelled?, session_id}, value)
  end

  defp cancelled_fun(session_id) do
    fn -> :persistent_term.get({__MODULE__, :cancelled?, session_id}, false) end
  end

  defp append_steer_directives(content, []), do: content

  defp append_steer_directives(content, directives) when is_list(directives) do
    content <>
      "\n\n### Steering Directives (highest priority, apply to this step)\n" <>
      Enum.map_join(directives, "\n", &"- #{&1}")
  end

  @impl true
  def handle_info({:cancel, session_id, _opts}, state) do
    set_cancelled?(session_id, true)
    {:noreply, state}
  end

  @impl true
  def handle_info({:pause, session_id}, state) do
    set_cancelled?(session_id, true)
    {:noreply, state}
  end

  @impl true
  def handle_info({:resume, session_id}, state) do
    set_cancelled?(session_id, false)
    {:noreply, state}
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
