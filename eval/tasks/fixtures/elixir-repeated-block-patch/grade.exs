Code.require_file("lib/rate_limiter.ex", __DIR__)

ExUnit.start(autorun: false)

defmodule RateLimiterGradeTest do
  use ExUnit.Case

  test "allow_api?/2 stays strict at limit" do
    assert RateLimiter.allow_api?(9, 10) == {:allow, 1}
    assert RateLimiter.allow_api?(10, 10) == {:deny, 0}
    assert RateLimiter.allow_api?(-1, 10) == {:error, :invalid_count}
  end

  test "allow_webhook?/2 permits count == limit and denies count > limit" do
    assert RateLimiter.allow_webhook?(9, 10) == {:allow, 1}
    assert RateLimiter.allow_webhook?(10, 10) == {:allow, 0}
    assert RateLimiter.allow_webhook?(11, 10) == {:deny, 0}
    assert RateLimiter.allow_webhook?(-1, 10) == {:error, :invalid_count}
  end

  test "allow_admin?/2 stays strict at limit" do
    assert RateLimiter.allow_admin?(9, 10) == {:allow, 1}
    assert RateLimiter.allow_admin?(10, 10) == {:deny, 0}
    assert RateLimiter.allow_admin?(-1, 10) == {:error, :invalid_count}
  end
end

case ExUnit.run() do
  %{failures: 0} -> System.halt(0)
  _ -> System.halt(1)
end
