defmodule IexCode.RunDispatcherTestExecutor do
  @moduledoc false

  @behaviour IexCode.Runs.Executor

  @impl true
  def execute(run, progress), do: execute(run, progress, [])

  def execute(run, progress, opts) do
    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{run.session_id}:steer")
    Phoenix.PubSub.subscribe(IexCode.PubSub, "run:#{run.id}:control")
    progress.(20, "test worker ready")

    receiver = Process.whereis(IexCode.RunDispatcherTestReceiver)

    if receiver && opts[:workspace_lock_delegation] do
      send(receiver, {:test_run_delegation, run.id, :present})
    end

    if receiver, do: send(receiver, {:test_run_started, run.id, self()})
    await_control(run, receiver)
  end

  defp await_control(run, receiver) do
    receive do
      {:finish, run_id, result} when run_id == run.id ->
        result

      {:pause, session_id} when session_id == run.session_id ->
        if receiver, do: send(receiver, {:test_run_paused, run.id})
        await_control(run, receiver)

      {:resume, session_id} when session_id == run.session_id ->
        if receiver, do: send(receiver, {:test_run_resumed, run.id})
        await_control(run, receiver)

      {:cancel, session_id, _opts} when session_id == run.session_id ->
        if receiver, do: send(receiver, {:test_run_cancelled, run.id})
        await_control(run, receiver)

      {:run_control, run_id, control_id, :pause, _payload} when run_id == run.id ->
        _ = resolve_control(run, control_id, "pause")
        if receiver, do: send(receiver, {:test_run_paused, run.id})
        await_control(run, receiver)

      {:run_control, run_id, control_id, :resume, _payload} when run_id == run.id ->
        _ = resolve_control(run, control_id, "resume")
        if receiver, do: send(receiver, {:test_run_resumed, run.id})
        await_control(run, receiver)

      {:run_control, run_id, :cancel, _payload} when run_id == run.id ->
        if receiver, do: send(receiver, {:test_run_cancelled, run.id})
        await_control(run, receiver)

      {:run_control, run_id, control_id, :steer, %{"guidance" => guidance}}
      when run_id == run.id ->
        _ = resolve_control(run, control_id, "steer")
        if receiver, do: send(receiver, {:test_run_steered, run.id, guidance})
        await_control(run, receiver)
    end
  end

  defp resolve_control(run, control_id, kind) do
    case IexCode.Runs.get_control(control_id) do
      %{worker_id: worker_id} = control ->
        IexCode.Runs.resolve_control(control, "applied", %{"worker" => "test"},
          run_id: run.id,
          worker_id: worker_id,
          kind: kind
        )

      nil ->
        {:error, :not_found}
    end
  end
end
