defmodule IexCode.Test.LeanHarnessLLM do
  @moduledoc false

  alias IexCode.{LLM.OpenAI, Runs, Tools}

  def chat(messages, system, session, on_chunk, opts) do
    fixture = Process.get(:lean_fixture)
    started = System.monotonic_time(:microsecond)
    Process.put(:lean_callback_count, 0)
    Process.put(:lean_cancel_checks, 0)
    Process.delete(:lean_first_callback_us)

    cancelled? = fn ->
      Process.put(:lean_cancel_checks, Process.get(:lean_cancel_checks) + 1)
      cancelled = opts[:cancelled?].()
      if cancelled, do: send(Agent.get(fixture.sync, & &1), :halt)
      cancelled
    end

    callback = fn text ->
      count = Process.get(:lean_callback_count) + 1
      Process.put(:lean_callback_count, count)

      if is_nil(Process.get(:lean_first_callback_us)) do
        Process.put(:lean_first_callback_us, System.monotonic_time(:microsecond) - started)
      end

      if fixture[:cancel_after] == count do
        {:ok, _} = Runs.request_cancellation(fixture.run_id)
      end

      on_chunk.(text)
      send(Agent.get(fixture.sync, & &1), :ack)
    end

    tools = Tools.tool_definitions(opts[:allowed_tools])

    result =
      OpenAI.chat(
        messages,
        system,
        [
          provider: "openai",
          model: session.model_name,
          base_url: fixture.url,
          api_key: "synthetic-local-only",
          temperature: opts[:temperature],
          max_tokens: opts[:max_tokens],
          tools: tools,
          cancelled?: cancelled?,
          receive_timeout: 2_000
        ],
        callback
      )

    send(
      fixture.receiver,
      {:lean_callbacks,
       %{
         text_callback_count: Process.get(:lean_callback_count),
         cancellation_check_count: Process.get(:lean_cancel_checks),
         first_text_callback_us: Process.get(:lean_first_callback_us),
         request_message_rows: length(messages),
         request_retained_message_bytes: byte_size(Jason.encode!(messages))
       }}
    )

    result
  end
end
