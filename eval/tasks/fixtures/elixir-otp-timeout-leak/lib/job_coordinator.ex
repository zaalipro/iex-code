defmodule JobCoordinator do
  @moduledoc """
  Coordinates asynchronous zero-arity jobs with bounded wall-clock timeouts.

  Contract:
    * `run_with_timeout(server, fun, timeout_ms)` executes `fun.()` in a dedicated
      monitored worker process without blocking other callers.
    * On completion within `timeout_ms`, cancels the timeout timer, cleans up
      monitors and job state, increments `:completed`, and returns `{:ok, value}`.
    * On timeout, terminates the worker process (`Process.exit(worker_pid, :kill)`),
      demonitors with `:flush`, cleans up job state, increments `:timed_out`, and
      returns `{:error, :timeout}`.
    * If the worker exits abnormally before completing, cleans up job state and
      timer, increments `:failed`, and returns `{:error, {:worker_exit, reason}}`.
  """

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.take(opts, [:name]))
  end

  def run_with_timeout(server, fun, timeout_ms \\ 1_000)
      when is_function(fun, 0) and is_integer(timeout_ms) and timeout_ms > 0 do
    GenServer.call(server, {:run, fun, timeout_ms}, :infinity)
  end

  def active_count(server) do
    GenServer.call(server, :active_count)
  end

  def stats(server) do
    GenServer.call(server, :stats)
  end

  @impl true
  def init(:ok) do
    {:ok,
     %{
       next_id: 1,
       jobs: %{},
       stats: %{completed: 0, timed_out: 0, failed: 0}
     }}
  end

  @impl true
  def handle_call({:run, fun, timeout_ms}, from, state) do
    job_id = state.next_id
    parent = self()

    # BUG 1: unmonitored spawn; worker crashes are never observed so caller hangs
    worker_pid =
      spawn(fn ->
        result = fun.()
        send(parent, {:job_done, job_id, result})
      end)

    timer_ref = Process.send_after(self(), {:job_timeout, job_id}, timeout_ms)

    job = %{
      from: from,
      worker_pid: worker_pid,
      timer_ref: timer_ref
    }

    new_state = %{
      state
      | next_id: job_id + 1,
        jobs: Map.put(state.jobs, job_id, job)
    }

    {:noreply, new_state}
  end

  def handle_call(:active_count, _from, state) do
    {:reply, map_size(state.jobs), state}
  end

  def handle_call(:stats, _from, state) do
    {:reply, state.stats, state}
  end

  @impl true
  def handle_info({:job_done, job_id, result}, state) do
    case Map.pop(state.jobs, job_id) do
      {nil, _jobs} ->
        {:noreply, state}

      {job, remaining_jobs} ->
        Process.cancel_timer(job.timer_ref)
        GenServer.reply(job.from, {:ok, result})
        stats = Map.update!(state.stats, :completed, &(&1 + 1))
        {:noreply, %{state | jobs: remaining_jobs, stats: stats}}
    end
  end

  def handle_info({:job_timeout, job_id}, state) do
    case Map.get(state.jobs, job_id) do
      nil ->
        {:noreply, state}

      job ->
        # BUG 2: replies timeout without killing worker_pid or removing job from state.jobs
        GenServer.reply(job.from, {:error, :timeout})
        stats = Map.update!(state.stats, :timed_out, &(&1 + 1))
        {:noreply, %{state | stats: stats}}
    end
  end
end
