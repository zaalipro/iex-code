defmodule IexCode.LLM.RequestBudgetError do
  @moduledoc "A nonretryable, pretransport failure. Contains counts only, never request content."
  defexception [:message, :limit, :reserve, :estimated_tokens, :bytes, :byte_limit]

  def message(error) do
    "Request exceeds the context budget (#{error.estimated_tokens} estimated input tokens + " <>
      "#{error.reserve} output tokens, limit #{error.limit}; #{error.bytes}/#{error.byte_limit} bytes). " <>
      "Reduce the objective, steering, required instructions or output/thinking allowance, " <>
      "or increase the configured context limit. No model request was sent."
  end
end
