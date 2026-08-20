defmodule IexCode.Engine.SessionServer do
  @moduledoc """
  GenServer process managing the active execution state of a coding session.
  Handles incoming prompts, tool executions, and swarm dispatching.
  """
  use GenServer, restart: :transient
  require Logger
  alias IexCode.{Sessions, Tools, LLM}
  alias IexCode.Engine.{SwarmCoordinator, OperationManager}
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

  def send_prompt(session_id, content) do
    ensure_started(session_id)
    GenServer.cast(via_tuple(session_id), {:send_prompt, content})
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
    {:ok,
     %{
       session_id: session_id,
       session: %Sessions.Session{id: session_id, swarm_mode: false},
       status: :idle,
       current_task: nil
     }}
  end

  @impl true
  def handle_call(:toggle_swarm, _from, %{session: session, session_id: session_id} = state) do
    current_session =
      try do
        Sessions.get_session(session_id) || session
      rescue
        _ -> session
      end

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
  def handle_call(:get_state, _from, state) do
    current_session =
      try do
        Sessions.get_session(state.session_id) || state.session
      rescue
        _ -> state.session
      end

    {:reply, %{state | session: current_session}, %{state | session: current_session}}
  end

  @impl true
  def handle_cast({:send_prompt, raw_prompt}, %{session_id: session_id, session: session} = state) do
    prompt = String.trim(raw_prompt)
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
    {:ok, user_msg} =
      Sessions.create_message(%{
        session_id: session_id,
        role: "user",
        agent_name: "User",
        content: prompt
      })

    broadcast(session_id, {:message_created, user_msg})

    use_swarm? = is_swarm_cmd or session.swarm_mode

    project_root =
      if Ecto.assoc_loaded?(session.project) and session.project do
        session.project.root_path
      else
        File.cwd!()
      end

    if use_swarm? do
      # Run Swarm Coordinator
      {:ok, _pid} = SwarmCoordinator.run_swarm(session_id, actual_prompt, project_root)
      {:noreply, %{state | status: :running}}
    else
      # Run Single Agent Async Task
      Task.Supervisor.start_child(IexCode.TaskSupervisor, fn ->
        run_single_agent(session_id, session, actual_prompt, project_root)
      end)

      {:noreply, %{state | status: :running}}
    end
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
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp run_single_agent(session_id, session, user_prompt, project_root) do
    broadcast(session_id, {:session_status_changed, "running"})

    # Fetch previous messages
    prev_messages =
      Sessions.list_messages(session_id)
      |> Enum.map(fn m -> %{role: m.role, content: m.content} end)

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
          progress.(20, "Querying model (#{session.model_provider}: #{session.model_name})...")
          LLM.chat(prev_messages, system_prompt, session)
        end
      )

    try do
      case op_result do
        {:ok, %{text: response_text, tool_calls: tool_calls}} ->
          # If there are tool calls, execute each in a dedicated process!
          tool_results =
            for tc <- tool_calls do
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

      broadcast(session_id, {:session_status_changed, "idle"})
    rescue
      _ -> :ok
    end
  end

  defp broadcast(session_id, event) do
    PubSub.broadcast(IexCode.PubSub, "session:#{session_id}", event)
  end
end
