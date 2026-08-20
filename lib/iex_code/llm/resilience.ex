defmodule IexCode.LLM.Resilience do
  @moduledoc """
  Resilience and auto-retry engine with exponential backoff, jitter,
  network timeout classification, and fallback provider routing.
  """
  require Logger

  @default_max_retries 3
  @default_base_backoff_ms 500
  @default_max_backoff_ms 10_000
  @default_retryable_statuses [429, 500, 502, 503, 504]

  @doc """
  Executes `fun` with exponential backoff and jitter upon retryable errors.

  ## Options
  - `:max_retries` (integer, default: 3)
  - `:base_backoff_ms` (integer, default: 500)
  - `:max_backoff_ms` (integer, default: 10_000)
  - `:retryable_statuses` (list of integers, default: [429, 500, 502, 503, 504])
  - `:jitter` (:full | :equal | :none, default: :full)
  - `:on_retry` (fn attempt, reason, sleep_ms -> any(), default: no-op)
  """
  @spec with_retry((-> {:ok, term()} | {:error, term()}), keyword()) ::
          {:ok, term()} | {:error, term()}
  def with_retry(fun, opts \\ []) when is_function(fun, 0) do
    max_retries = Keyword.get(opts, :max_retries, @default_max_retries)
    base_backoff = Keyword.get(opts, :base_backoff_ms, @default_base_backoff_ms)
    max_backoff = Keyword.get(opts, :max_backoff_ms, @default_max_backoff_ms)
    retryable_statuses = Keyword.get(opts, :retryable_statuses, @default_retryable_statuses)
    jitter = Keyword.get(opts, :jitter, :full)
    on_retry = Keyword.get(opts, :on_retry, fn _attempt, _reason, _sleep -> :ok end)

    do_retry(fun, 1, max_retries, base_backoff, max_backoff, retryable_statuses, jitter, on_retry)
  end

  @doc """
  Executes a sequence of provider functions in fallback order.
  Each provider is attempted with `with_retry/2`.

  ## Example
      providers = [
        {"openai", fn -> OpenAI.chat(...) end},
        {"anthropic", fn -> Anthropic.chat(...) end}
      ]
      {:ok, result, meta} = Resilience.with_fallback(providers)
  """
  @spec with_fallback([{name :: String.t(), (-> {:ok, term()} | {:error, term()})}], keyword()) ::
          {:ok, result :: term(), meta :: %{provider: String.t(), fallback_used?: boolean()}}
          | {:error, {:all_providers_failed, list()}}
  def with_fallback(providers, opts \\ []) when is_list(providers) do
    do_fallback(providers, opts, [])
  end

  # --- Internal Helpers ---

  defp do_retry(
         fun,
         attempt,
         max_retries,
         base_backoff,
         max_backoff,
         retryable_statuses,
         jitter,
         on_retry
       ) do
    try do
      case fun.() do
        {:ok, _} = success ->
          success

        {:error, reason} = err ->
          if attempt <= max_retries and retryable_error?(reason, retryable_statuses) do
            sleep_ms = compute_backoff(attempt, base_backoff, max_backoff, jitter)

            Logger.warning(
              "[Resilience] Retry #{attempt}/#{max_retries} in #{sleep_ms}ms due to: #{inspect(reason)}"
            )

            on_retry.(attempt, reason, sleep_ms)
            if sleep_ms > 0, do: :timer.sleep(sleep_ms)

            do_retry(
              fun,
              attempt + 1,
              max_retries,
              base_backoff,
              max_backoff,
              retryable_statuses,
              jitter,
              on_retry
            )
          else
            err
          end
      end
    rescue
      ex ->
        if attempt <= max_retries and retryable_exception?(ex) do
          sleep_ms = compute_backoff(attempt, base_backoff, max_backoff, jitter)

          Logger.warning(
            "[Resilience] Exception retry #{attempt}/#{max_retries} in #{sleep_ms}ms: #{inspect(ex)}"
          )

          on_retry.(attempt, ex, sleep_ms)
          if sleep_ms > 0, do: :timer.sleep(sleep_ms)

          do_retry(
            fun,
            attempt + 1,
            max_retries,
            base_backoff,
            max_backoff,
            retryable_statuses,
            jitter,
            on_retry
          )
        else
          {:error, {:exception, ex}}
        end
    end
  end

  defp do_fallback([], _opts, errors) do
    {:error, {:all_providers_failed, Enum.reverse(errors)}}
  end

  defp do_fallback([{provider_name, provider_fn} | rest], opts, errors) do
    case with_retry(provider_fn, opts) do
      {:ok, result} ->
        {:ok, result, %{provider: provider_name, fallback_used?: errors != []}}

      {:error, reason} ->
        Logger.warning(
          "[Resilience] Provider #{provider_name} failed: #{inspect(reason)}. Routing to fallback."
        )

        do_fallback(rest, opts, [{provider_name, reason} | errors])
    end
  end

  @doc """
  Calculates exponential backoff with jitter.
  """
  def compute_backoff(_attempt, 0, _max_b, _jitter), do: 0

  def compute_backoff(attempt, base, max_b, :full) do
    exp = min(max_b, round(base * :math.pow(2, attempt - 1)))
    if exp <= 0, do: 0, else: Enum.random(0..exp)
  end

  def compute_backoff(attempt, base, max_b, :equal) do
    exp = min(max_b, round(base * :math.pow(2, attempt - 1)))
    half = div(exp, 2)
    if half <= 0, do: 0, else: half + Enum.random(0..half)
  end

  def compute_backoff(attempt, base, max_b, :none) do
    min(max_b, round(base * :math.pow(2, attempt - 1)))
  end

  @doc """
  Determines if an error reason represents a transient/retryable condition.
  """
  def retryable_error?(%{status: status}, statuses) when is_integer(status),
    do: status in statuses

  def retryable_error?({:status, status}, statuses) when is_integer(status),
    do: status in statuses

  def retryable_error?(status, statuses) when is_integer(status), do: status in statuses

  def retryable_error?("OpenAI API returned status " <> rest, statuses) do
    case Integer.parse(rest) do
      {code, _} -> code in statuses
      _ -> false
    end
  end

  def retryable_error?("Anthropic API returned status " <> rest, statuses) do
    case Integer.parse(rest) do
      {code, _} -> code in statuses
      _ -> false
    end
  end

  def retryable_error?(:timeout, _), do: true
  def retryable_error?(:connect_timeout, _), do: true
  def retryable_error?(:recv_timeout, _), do: true
  def retryable_error?(:closed, _), do: true
  def retryable_error?(:econnrefused, _), do: true
  def retryable_error?(%Req.TransportError{}, _), do: true
  def retryable_error?(%{reason: r}, statuses) when is_atom(r), do: retryable_error?(r, statuses)
  def retryable_error?({:error, r}, statuses), do: retryable_error?(r, statuses)
  def retryable_error?(_, _), do: false

  def retryable_exception?(%Req.TransportError{}), do: true
  def retryable_exception?(%Mint.TransportError{}), do: true
  def retryable_exception?(_), do: false
end
