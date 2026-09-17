defmodule IexCode.LatchingAgentLLMStub do
  @moduledoc false

  # Blocks inside chat until the test releases the latch, then answers
  # based on the cooperative cancelled? flag — mirroring real LLM clients.
  # The test registers itself under its session id before starting work.
  def register(session_id, test_pid) do
    :persistent_term.put({__MODULE__, session_id}, test_pid)
  end

  def unregister(session_id) do
    :persistent_term.erase({__MODULE__, session_id})
  end

  def chat(_messages, _system_prompt, session, _on_chunk, opts) do
    session_id = session.id
    test_pid = :persistent_term.get({__MODULE__, session_id})
    send(test_pid, {:latch_llm_entered, self()})

    receive do
      :latch_llm_release -> :ok
    after
      15_000 -> :timeout
    end

    cancelled? = Keyword.get(opts, :cancelled?, fn -> false end)

    if is_function(cancelled?, 0) and cancelled?.() do
      {:error, :cancelled}
    else
      {:ok, %{text: "latched plan completed"}}
    end
  end
end
