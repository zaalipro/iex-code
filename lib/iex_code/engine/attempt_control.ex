defmodule IexCode.Engine.AttemptControl do
  @moduledoc """
  Attempt-local cancellation with independently supervised durable refresh.

  The executing process remains the effect owner (including direct callers).
  A failed read, lost authority or expiry invalidates its token irreversibly and
  kills uncooperative work after the grace period. This guard never renews the
  durable lease or releases workspace reservations.
  """
  use GenServer, restart: :temporary

  alias IexCode.Engine.FleetControlToken
  alias IexCode.Runs
  alias IexCode.Runs.Run

  @refresh_ms 1_000
  @refresh_timeout_ms 1_000
  @cancel_grace_ms 1_500

  def with_control(%Run{} = run, authority, opts, fun) do
    args = [run: run, authority: authority, owner: self(), opts: opts]

    with {:ok, guard} <-
           DynamicSupervisor.start_child(
             IexCode.Engine.AttemptControlSupervisor,
             {__MODULE__, args}
           ) do
      Process.link(guard)

      try do
        case GenServer.call(guard, :token, :infinity) do
          {:ok, token} -> fun.(guard, token)
          {:error, _} = error -> error
        end
      after
        Process.unlink(guard)
        if Process.alive?(guard), do: GenServer.call(guard, :finished)
      end
    end
  end

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl true
  def init(args) do
    Process.flag(:trap_exit, true)
    run = args[:run]
    opts = args[:opts]
    token = FleetControlToken.new_authority()
    guard = self()
    owner = args[:owner]

    # A monitor outside the guard covers untrappable guard death even when a
    # direct caller traps exits. It holds no authority and performs no DB work.
    {:ok, watchdog} =
      Task.Supervisor.start_child(IexCode.TaskSupervisor, fn ->
        guard_ref = Process.monitor(guard)
        owner_ref = Process.monitor(owner)
        send(guard, {:watchdog_ready, self()})

        receive do
          {:DOWN, ^guard_ref, :process, ^guard, reason} ->
            FleetControlToken.cancel(token)
            if reason != :normal, do: Process.exit(owner, :kill)

          {:DOWN, ^owner_ref, :process, ^owner, _} ->
            FleetControlToken.cancel(token)
        end
      end)

    receive do
      {:watchdog_ready, ^watchdog} -> :ok
    after
      1_000 -> exit(:watchdog_start_timeout)
    end

    Phoenix.PubSub.subscribe(IexCode.PubSub, "run:#{run.id}")

    state = %{
      run_id: run.id,
      authority: args[:authority],
      owner: args[:owner],
      owner_ref: Process.monitor(args[:owner]),
      token: token,
      watchdog: watchdog,
      reader: Keyword.get(opts, :run_reader, &Runs.get_run/1),
      refresh_ms: bounded(opts[:control_refresh_ms], @refresh_ms),
      refresh_timeout_ms: bounded(opts[:control_refresh_timeout_ms], @refresh_timeout_ms),
      grace_ms: bounded(opts[:control_cancel_grace_ms], @cancel_grace_ms),
      initialized?: false,
      confirmed_expiry: nil,
      invalid: nil,
      waiting: nil,
      refresh: nil,
      refresh_timer: nil,
      expiry_timer: nil,
      cancel_timer: nil
    }

    {:ok, state, {:continue, :refresh}}
  end

  @impl true
  def handle_continue(:refresh, state), do: {:noreply, refresh(state)}

  @impl true
  def handle_call(:token, from, %{initialized?: false, invalid: nil} = state),
    do: {:noreply, %{state | waiting: from}}

  def handle_call(:token, _from, %{invalid: reason} = state) when not is_nil(reason),
    do: {:reply, {:error, reason}, state}

  def handle_call(:token, _from, state), do: {:reply, {:ok, state.token}, state}

  def handle_call(:finished, _from, state),
    do: {:stop, :normal, :ok, Map.put(state, :finished?, true)}

  @impl true
  def handle_info(:refresh, state), do: {:noreply, refresh(%{state | refresh_timer: nil})}

  def handle_info({ref, result}, %{refresh: %{ref: ref} = task} = state) do
    Process.demonitor(ref, [:flush])
    Process.cancel_timer(task.timeout)
    state = %{state | refresh: nil}

    state =
      case result do
        {:ok, run, started, wall} ->
          with {:ok, deadline} <- confirmed_authority(run, state.authority, started, wall),
               false <- state.initialized? and FleetControlToken.cancelled?(state.token) do
            confirm(state, run, deadline)
          else
            {:error, reason} -> invalidate(state, reason)
            true -> invalidate(state, :run_lease_expired)
          end

        {:error, _} ->
          invalidate(state, :run_control_unavailable)
      end

    {:noreply, state}
  end

  def handle_info({:refresh_timeout, ref}, %{refresh: %{ref: ref}} = state),
    do: {:noreply, invalidate(state, :run_control_unavailable)}

  def handle_info({:expiry, deadline}, state) do
    if :atomics.get(state.token.expiry, 1) == deadline do
      {:noreply, invalidate(state, :run_lease_expired)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:run_updated, %Run{} = run}, state) do
    # Notifications may invalidate but never extend the confirmed deadline.
    # A late notification from an older generation cannot touch a replacement.
    state =
      if same_attempt?(run, state.authority) and run.id == state.run_id do
        case authority_status(run) do
          :ok -> state
          {:error, reason} -> invalidate(state, reason)
        end
      else
        state
      end

    {:noreply, state}
  end

  def handle_info(:force_stop, state) do
    Process.exit(state.owner, :kill)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{refresh: %{ref: ref}} = state),
    do: {:noreply, invalidate(state, :run_control_unavailable)}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    FleetControlToken.cancel(state.token)
    Enum.each([state.refresh_timer, state.expiry_timer, state.cancel_timer], &cancel_timer/1)
    stop_refresh(state.refresh)
    unless state[:finished?], do: Process.exit(state.owner, :kill)
  end

  defp refresh(%{invalid: reason} = state) when not is_nil(reason), do: state
  defp refresh(%{refresh: task} = state) when not is_nil(task), do: state

  defp refresh(state) do
    reader = state.reader
    id = state.run_id
    owner = state.owner

    task =
      Task.Supervisor.async(IexCode.TaskSupervisor, fn ->
        Process.put(:"$callers", [owner])
        started = System.monotonic_time(:millisecond)
        wall = DateTime.utc_now()

        try do
          {:ok, reader.(id), started, wall}
        rescue
          _ -> {:error, :storage}
        catch
          _, _ -> {:error, :storage}
        end
      end)

    timeout = Process.send_after(self(), {:refresh_timeout, task.ref}, state.refresh_timeout_ms)
    %{state | refresh: Map.put(task, :timeout, timeout)}
  end

  defp confirm(state, run, deadline) do
    deadline =
      if state.confirmed_expiry do
        # Only a durable extension can advance the previous monotonic ceiling.
        # Repeated reads must not gain time from a backward wall-clock jump.
        ceiling =
          :atomics.get(state.token.expiry, 1) +
            DateTime.diff(run.lease_expires_at, state.confirmed_expiry, :millisecond)

        min(deadline, ceiling)
      else
        deadline
      end

    cancel_timer(state.expiry_timer)
    :atomics.put(state.token.expiry, 1, deadline)

    if run.status == "paused",
      do: FleetControlToken.pause(state.token),
      else: FleetControlToken.resume(state.token)

    if state.waiting, do: GenServer.reply(state.waiting, {:ok, state.token})

    expiry =
      Process.send_after(
        self(),
        {:expiry, deadline},
        max(deadline - System.monotonic_time(:millisecond), 0)
      )

    refresh = Process.send_after(self(), :refresh, state.refresh_ms)

    %{
      state
      | initialized?: true,
        confirmed_expiry: run.lease_expires_at,
        waiting: nil,
        expiry_timer: expiry,
        refresh_timer: refresh
    }
  end

  defp invalidate(%{invalid: reason} = state, _reason) when not is_nil(reason), do: state

  defp invalidate(state, reason) do
    FleetControlToken.cancel(state.token)
    if state.waiting, do: GenServer.reply(state.waiting, {:error, reason})
    send(state.owner, {:attempt_control_invalid, state.token.identity, reason})
    timer = Process.send_after(self(), :force_stop, state.grace_ms)
    cancel_timer(state.refresh_timer)
    cancel_timer(state.expiry_timer)
    stop_refresh(state.refresh)
    %{state | invalid: reason, waiting: nil, refresh: nil, cancel_timer: timer}
  end

  defp confirmed_authority(%Run{} = run, authority, started, wall) do
    with :ok <- authority_status(run),
         true <- same_attempt?(run, authority) or {:error, :run_lease_lost},
         %DateTime{} = expires <- run.lease_expires_at do
      # Start-of-read wall/monotonic pair is conservative even if SQLite stalls.
      deadline = started + DateTime.diff(expires, wall, :millisecond)

      if deadline > System.monotonic_time(:millisecond),
        do: {:ok, deadline},
        else: {:error, :run_lease_expired}
    else
      nil -> {:error, :run_lease_lost}
      {:error, _} = error -> error
    end
  end

  defp confirmed_authority(_, _, _, _), do: {:error, :run_not_found}

  defp same_attempt?(run, authority),
    do:
      run.attempt == authority.run_attempt and run.lease_generation == authority.lease_generation and
        run.lease_owner == authority.lease_owner

  defp authority_status(%Run{cancellation_requested_at: %DateTime{}}), do: {:error, :cancelled}

  defp authority_status(%Run{status: status}) when status in ["cancelled", "interrupted"],
    do: {:error, :cancelled}

  defp authority_status(%Run{status: "failed"}), do: {:error, :run_failed}
  defp authority_status(%Run{status: status}) when status in ["running", "paused"], do: :ok
  defp authority_status(_), do: {:error, :run_lease_lost}

  defp stop_refresh(nil), do: :ok

  defp stop_refresh(task) do
    cancel_timer(task.timeout)
    Task.shutdown(Map.delete(task, :timeout), :brutal_kill)
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)
  defp bounded(value, _default) when is_integer(value) and value > 0, do: min(value, 60_000)
  defp bounded(_, default), do: default
end
