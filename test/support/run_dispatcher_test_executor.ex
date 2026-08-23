defmodule IexCode.RunDispatcherTestExecutor do
  @moduledoc false

  @behaviour IexCode.Runs.Executor

  @impl true
  def execute(run, progress) do
    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{run.session_id}:steer")
    progress.(20, "test worker ready")

    receiver = Process.whereis(IexCode.RunDispatcherTestReceiver)
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
    end
  end
end
