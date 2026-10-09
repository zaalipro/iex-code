defmodule IexCode.LLM.RequestPreparation do
  @moduledoc """
  Budgets the adapter's outgoing JSON, not a second provider serializer.

  Estimate: ceil(serialized bytes / 4 * 1.25) + 128 protocol tokens.
  The independent byte guard permits at most 3 bytes per available input token
  and 2 MB overall. These conservative estimates are not provider tokenization.
  The effective output field includes reasoning for OpenAI and thinking for
  Anthropic; neither is reserved twice. Unknown models use the configured
  window, while local requests are also capped by their actual num_ctx.
  """
  alias IexCode.LLM.{ContextCompactor, RequestBudgetError}

  def prepare(adapter, messages, system, opts) do
    settings = Keyword.get(opts, :budget_settings, %{})
    configured = setting(settings, :context_window_tokens, 128_000)

    builder = fn transcript ->
      transcript =
        Enum.map(transcript, fn
          message when is_map(message) ->
            Map.drop(message, [
              :budget_mandatory,
              :budget_objective,
              :legacy_steering_content,
              "budget_mandatory",
              "budget_objective",
              "legacy_steering_content"
            ])

          message ->
            message
        end)

      adapter.build_body(transcript, system, opts)
    end

    body = builder.(messages)
    limit = min(configured, get_in(body, ["options", "num_ctx"]) || configured)
    reserve = body["max_completion_tokens"] || body["max_tokens"] || 4_096
    byte_limit = min(2_000_000, max(limit - reserve - 128, 0) * 3)
    measure = fn body -> measure(body, limit, reserve, byte_limit) end

    fits? = fn body ->
      metrics = measure.(body)
      metrics.estimated_tokens + reserve <= limit and metrics.bytes <= byte_limit
    end

    case ContextCompactor.compact_request(messages, settings, builder, fits?) do
      {:ok, transcript, body} ->
        {:ok, %{messages: transcript, body: body, metrics: measure.(body)}}

      {:error, body} ->
        error =
          struct!(
            RequestBudgetError,
            Map.take(measure.(body), [:limit, :reserve, :estimated_tokens, :bytes, :byte_limit])
          )

        {:error, %{error | message: Exception.message(error)}}
    end
  end

  defp measure(body, limit, reserve, byte_limit) do
    instruction_body = Map.take(body, ["system"])
    messages = body["messages"] || []

    {instructions, transcript} =
      Enum.split_with(messages, &(&1["role"] in ["system", "developer"]))

    instructions = bytes(instruction_body) + bytes(instructions)
    tools = bytes(body["tools"] || [])
    transcript = bytes(transcript)
    total = bytes(body)

    %{
      limit: limit,
      reserve: reserve,
      bytes: total,
      byte_limit: byte_limit,
      estimated_tokens: div(total * 5 + 15, 16) + 128,
      instructions: instructions,
      tools: tools,
      transcript: transcript,
      protocol: max(total - instructions - tools - transcript, 0),
      protocol_tokens: 128
    }
  end

  defp bytes(value), do: byte_size(Jason.encode!(value))

  defp setting(settings, key, default),
    do: Map.get(settings, key) || Map.get(settings, Atom.to_string(key)) || default
end
