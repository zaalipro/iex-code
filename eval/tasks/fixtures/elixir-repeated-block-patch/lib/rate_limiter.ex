defmodule RateLimiter do
  @moduledoc """
  Endpoint-specific rate limit bucket checks.
  """

  def allow_api?(count, limit) when is_integer(count) and is_integer(limit) and limit >= 0 do
    cond do
      count < 0 -> {:error, :invalid_count}
      count >= limit -> {:deny, 0}
      true -> {:allow, limit - count}
    end
  end

  def allow_webhook?(count, limit) when is_integer(count) and is_integer(limit) and limit >= 0 do
    cond do
      count < 0 -> {:error, :invalid_count}
      count >= limit -> {:deny, 0}
      true -> {:allow, limit - count}
    end
  end

  def allow_admin?(count, limit) when is_integer(count) and is_integer(limit) and limit >= 0 do
    cond do
      count < 0 -> {:error, :invalid_count}
      count >= limit -> {:deny, 0}
      true -> {:allow, limit - count}
    end
  end
end
