defmodule IexCode.Desktop.SwarmHooks do
  @moduledoc """
  Subscribes to swarm and run lifecycle events, dispatching native desktop
  notifications and auditory cues for key milestones:
    * `:swarm_completed` -> Info notification + Hero sound
    * `:verification_rejected` -> Warning notification + Sosumi sound
    * `:step_failed` -> Error notification + Basso sound
    * `:approval_requested` -> Warning notification + Ping sound
  """
  use GenServer
  require Logger

  alias IexCode.Desktop.{Notifier, Sound}
  alias Phoenix.PubSub

  @default_topics [
    "swarm:lifecycle",
    "desktop:lifecycle",
    "desktop:events",
    "runs:events"
  ]

  # --- Client API ---

  @doc """
  Starts the SwarmHooks GenServer.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Dispatches a swarm lifecycle event directly to the hooks engine.
  Exposed for direct invocation, orchestrator steering, and testing.
  """
  def dispatch_event(event_type, payload \\ %{})

  def dispatch_event(event_type, payload) when is_atom(event_type) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:dispatch_event, event_type, payload})
    else
      handle_event_action(event_type, payload)
      {:ok, event_type}
    end
  end

  @doc """
  Dispatches a swarm lifecycle event to a specific GenServer process.
  """
  def dispatch_event(server, event_type, payload)
      when is_pid(server) or (is_atom(server) and not is_nil(server)) do
    GenServer.call(server, {:dispatch_event, event_type, payload})
  end

  @doc """
  Returns the most recently processed event from the GenServer state.
  """
  def get_last_event(server \\ __MODULE__) do
    GenServer.call(server, :get_last_event)
  end

  @doc """
  Returns the count of events handled by type.
  """
  def get_event_counts(server \\ __MODULE__) do
    GenServer.call(server, :get_event_counts)
  end

  @doc """
  Subscribes the running hooks GenServer to a specific session's PubSub topics.
  """
  def subscribe_to_session(session_id) when is_binary(session_id) do
    if Process.whereis(IexCode.PubSub) do
      PubSub.subscribe(IexCode.PubSub, "session:#{session_id}")
      PubSub.subscribe(IexCode.PubSub, "runs:session:#{session_id}")
    end

    :ok
  end

  @doc """
  Subscribes the running hooks GenServer to a specific run's PubSub topic.
  """
  def subscribe_to_run(run_id) when is_binary(run_id) do
    if Process.whereis(IexCode.PubSub) do
      PubSub.subscribe(IexCode.PubSub, "run:#{run_id}")
    end

    :ok
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    topics = Keyword.get(opts, :topics, @default_topics)

    if Process.whereis(IexCode.PubSub) do
      Enum.each(topics, fn topic ->
        PubSub.subscribe(IexCode.PubSub, topic)
      end)
    end

    state = %{
      last_event: nil,
      event_counts: %{
        swarm_completed: 0,
        verification_rejected: 0,
        step_failed: 0,
        approval_requested: 0
      }
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:dispatch_event, event_type, payload}, _from, state) do
    handle_event_action(event_type, payload)
    new_state = record_event(state, event_type, payload)
    {:reply, {:ok, event_type}, new_state}
  end

  def handle_call(:get_last_event, _from, state) do
    {:reply, state.last_event, state}
  end

  def handle_call(:get_event_counts, _from, state) do
    {:reply, state.event_counts, state}
  end

  # PubSub Message Handlers

  @impl true
  def handle_info({:swarm_event, event_type, payload}, state) do
    handle_event_action(event_type, payload)
    {:noreply, record_event(state, event_type, payload)}
  end

  def handle_info({:swarm_completed, payload}, state) do
    handle_event_action(:swarm_completed, payload)
    {:noreply, record_event(state, :swarm_completed, payload)}
  end

  def handle_info({:verification_rejected, payload}, state) do
    handle_event_action(:verification_rejected, payload)
    {:noreply, record_event(state, :verification_rejected, payload)}
  end

  def handle_info({:step_failed, payload}, state) do
    handle_event_action(:step_failed, payload)
    {:noreply, record_event(state, :step_failed, payload)}
  end

  def handle_info({:approval_requested, payload}, state) do
    handle_event_action(:approval_requested, payload)
    {:noreply, record_event(state, :approval_requested, payload)}
  end

  # Codebase Real-World Messages: Swarm Completion
  def handle_info({:run_updated, %{status: "completed"} = run}, state) do
    handle_event_action(:swarm_completed, run)
    {:noreply, record_event(state, :swarm_completed, run)}
  end

  def handle_info({:swarm_stage_changed, %{stage: :complete} = payload}, state) do
    handle_event_action(:swarm_completed, payload)
    {:noreply, record_event(state, :swarm_completed, payload)}
  end

  def handle_info({:goal_lifecycle_changed, %{status: :completed} = payload}, state) do
    handle_event_action(:swarm_completed, payload)
    {:noreply, record_event(state, :swarm_completed, payload)}
  end

  # Codebase Real-World Messages: Verification Rejection
  def handle_info({:error, {:verification_failed, diagnostics}}, state) do
    handle_event_action(:verification_rejected, diagnostics)
    {:noreply, record_event(state, :verification_rejected, diagnostics)}
  end

  def handle_info({:run_step_updated, %{kind: "verify", status: "failed"} = step}, state) do
    handle_event_action(:verification_rejected, step)
    {:noreply, record_event(state, :verification_rejected, step)}
  end

  # Codebase Real-World Messages: Step Failure
  def handle_info({:run_step_updated, %{status: "failed"} = step}, state) do
    handle_event_action(:step_failed, step)
    {:noreply, record_event(state, :step_failed, step)}
  end

  def handle_info({:run_event, %{type: "run.step_failed"} = event}, state) do
    handle_event_action(:step_failed, event)
    {:noreply, record_event(state, :step_failed, event)}
  end

  def handle_info({:operation_failed, operation}, state) do
    handle_event_action(:step_failed, operation)
    {:noreply, record_event(state, :step_failed, operation)}
  end

  # Codebase Real-World Messages: Pending Human Approval
  def handle_info({:run_approval_requested, approval}, state) do
    handle_event_action(:approval_requested, approval)
    {:noreply, record_event(state, :approval_requested, approval)}
  end

  def handle_info({:run_updated, %{status: "waiting_approval"} = run}, state) do
    handle_event_action(:approval_requested, run)
    {:noreply, record_event(state, :approval_requested, run)}
  end

  def handle_info(_other, state) do
    {:noreply, state}
  end

  # --- Internal Action Handlers ---

  defp handle_event_action(:swarm_completed, payload) do
    text = format_message(:swarm_completed, payload)
    Notifier.notify(text, title: "Swarm Goal Completed", type: :info)
    Sound.play(:swarm_completed)
  end

  defp handle_event_action(:verification_rejected, payload) do
    text = format_message(:verification_rejected, payload)
    Notifier.notify(text, title: "Verification Rejected", type: :warning)
    Sound.play(:verification_rejected)
  end

  defp handle_event_action(:step_failed, payload) do
    text = format_message(:step_failed, payload)
    Notifier.notify(text, title: "Swarm Step Failed", type: :error)
    Sound.play(:step_failed)
  end

  defp handle_event_action(:approval_requested, payload) do
    text = format_message(:approval_requested, payload)
    Notifier.notify(text, title: "Approval Required", type: :warning)
    Sound.play(:approval_requested)
  end

  defp handle_event_action(_other, payload) do
    text = format_message(:other, payload)
    Notifier.notify(text, title: "Swarm Event", type: :info)
  end

  defp record_event(state, event_type, payload) do
    current_count = Map.get(state.event_counts, event_type, 0)
    updated_counts = Map.put(state.event_counts, event_type, current_count + 1)

    %{
      state
      | last_event: {event_type, payload, DateTime.utc_now()},
        event_counts: updated_counts
    }
  end

  defp format_message(:swarm_completed, payload) do
    cond do
      is_binary(payload) and byte_size(payload) > 0 ->
        payload

      is_map(payload) and is_binary(Map.get(payload, :message)) ->
        Map.get(payload, :message)

      is_map(payload) and is_binary(Map.get(payload, :title)) ->
        "Swarm goal completed: #{Map.get(payload, :title)}"

      is_map(payload) and is_binary(Map.get(payload, "title")) ->
        "Swarm goal completed: #{Map.get(payload, "title")}"

      is_map(payload) and Map.has_key?(payload, :id) ->
        "Swarm run #{Map.get(payload, :id)} completed successfully."

      true ->
        "Swarm goal execution finished successfully."
    end
  end

  defp format_message(:verification_rejected, payload) do
    cond do
      is_binary(payload) and byte_size(payload) > 0 ->
        payload

      is_map(payload) and is_binary(Map.get(payload, :reason)) ->
        "Verification rejected: #{Map.get(payload, :reason)}"

      is_map(payload) and is_binary(Map.get(payload, :summary)) ->
        "Verification rejected: #{Map.get(payload, :summary)}"

      is_map(payload) and is_binary(Map.get(payload, "summary")) ->
        "Verification rejected: #{Map.get(payload, "summary")}"

      is_map(payload) and is_binary(Map.get(payload, :message)) ->
        Map.get(payload, :message)

      true ->
        "Verification checks failed. Triggering diagnostic and self-healing phase."
    end
  end

  defp format_message(:step_failed, payload) do
    cond do
      is_binary(payload) and byte_size(payload) > 0 ->
        payload

      is_map(payload) and is_binary(Map.get(payload, :reason)) ->
        "Step failed: #{Map.get(payload, :reason)}"

      is_map(payload) and is_binary(Map.get(payload, :error)) ->
        "Step failed: #{Map.get(payload, :error)}"

      is_map(payload) and is_binary(Map.get(payload, :error_message)) ->
        "Step failed: #{Map.get(payload, :error_message)}"

      is_map(payload) and is_binary(Map.get(payload, "error_message")) ->
        "Step failed: #{Map.get(payload, "error_message")}"

      is_map(payload) and is_binary(Map.get(payload, :title)) ->
        "Step '#{Map.get(payload, :title)}' execution failed."

      true ->
        "A step in the swarm execution pipeline failed."
    end
  end

  defp format_message(:approval_requested, payload) do
    cond do
      is_binary(payload) and byte_size(payload) > 0 ->
        payload

      is_map(payload) and is_binary(Map.get(payload, :action)) and
          is_binary(Map.get(payload, :reason)) ->
        "Approval needed for #{Map.get(payload, :action)}: #{Map.get(payload, :reason)}"

      is_map(payload) and is_binary(Map.get(payload, "action")) and
          is_binary(Map.get(payload, "reason")) ->
        "Approval needed for #{Map.get(payload, "action")}: #{Map.get(payload, "reason")}"

      is_map(payload) and is_binary(Map.get(payload, "action")) ->
        "Approval needed for #{Map.get(payload, "action")}"

      is_map(payload) and is_binary(Map.get(payload, :action)) ->
        "Approval needed for #{Map.get(payload, :action)}"

      is_map(payload) and is_binary(Map.get(payload, :reason)) ->
        "Approval required: #{Map.get(payload, :reason)}"

      true ->
        "Action awaiting human approval to proceed."
    end
  end

  defp format_message(_other, payload) do
    if is_binary(payload), do: payload, else: "Swarm lifecycle event triggered."
  end
end
