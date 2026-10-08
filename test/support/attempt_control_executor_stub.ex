defmodule IexCode.AttemptControlExecutorStub do
  @moduledoc false

  def execute(run, progress, opts) do
    receiver = Process.whereis(IexCode.AttemptControlTestReceiver)
    Process.put(:agent_loop_receiver, receiver)

    Process.put(:agent_loop_responses, [
      {:ok, %{text: "Must not settle", tool_calls: [], usage: %{}}}
    ])

    Process.put(:agent_loop_before_chat, fn ->
      send(receiver, {:guarded_effect_ready, self()})
      await_finish(receiver)
    end)

    IexCode.Runs.Executor.execute(
      run,
      progress,
      Keyword.put(opts, :llm, IexCode.AgentLoopLLMStub)
    )
  end

  defp await_finish(receiver) do
    receive do
      :finish_effect ->
        :ok

      :effect_probe ->
        send(receiver, {:effect_probe, self()})
        await_finish(receiver)
    end
  end
end
