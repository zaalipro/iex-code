defmodule IexCode.Execution.ModelRoute do
  @moduledoc """
  Secret-free identity and execution-time resolution for durable model routes.

  Durable policies persist only a SHA-256 digest of the effective provider,
  model, and base URL. Credentials remain live so they can be rotated, but the
  non-secret transport route must still match immediately before every model
  effect.
  """

  alias IexCode.Execution.Limits
  alias IexCode.LLM

  @openai_default "https://cli.llmotions.com/v1"
  @anthropic_default "https://api.anthropic.com"
  @digest_key "model_route_sha256"

  @spec put_digest(map(), map() | struct()) :: {:ok, map()} | {:error, term()}
  def put_digest(policy, settings) when is_map(policy) and is_map(settings) do
    with {:ok, projection} <- projection(policy, settings),
         {:ok, digest} <- digest(projection) do
      {:ok, Map.put(policy, @digest_key, digest)}
    end
  end

  def put_digest(_policy, _settings), do: {:error, :invalid_model_route}

  @doc """
  Resolves current credentials only after the non-secret durable route matches.

  Policies created before route digests were introduced remain executable for
  backwards compatibility; every newly normalized policy includes a digest.
  """
  @spec resolve(map(), map() | struct()) :: {:ok, map()} | {:error, term()}
  def resolve(_policy, %IexCode.Settings.AppSettings{__meta__: %{state: state}})
      when state in [:built, :deleted],
      do: {:error, :settings_unavailable}

  def resolve(policy, settings) when is_map(policy) and is_map(settings) do
    with {:ok, projection} <- projection(policy, settings),
         {:ok, current_digest} <- digest(projection),
         :ok <- validate_expected_digest(value(policy, @digest_key), current_digest) do
      provider = projection["provider"]
      model = projection["model"]

      profile_opts =
        [
          temperature: value(policy, "temperature"),
          max_tokens: value(policy, "max_tokens"),
          reasoning_effort: value(policy, "reasoning_effort"),
          thinking_budget: value(policy, "thinking_budget") || value(policy, "budget_tokens")
        ]
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)

      profile = IexCode.LLM.Reasoning.resolve_profile(provider, model, settings, profile_opts)

      {:ok,
       %{
         "provider" => provider,
         "model" => model,
         "base_url" => projection["base_url"],
         "api_key" => credential(settings, provider),
         "temperature" => profile.temperature,
         "max_tokens" => profile.max_tokens,
         "reasoning_effort" => profile.reasoning_effort,
         "thinking_budget" => profile.thinking_budget,
         "budget_tokens" => profile.thinking_budget,
         :provider => provider,
         :model => model,
         :base_url => projection["base_url"],
         :api_key => credential(settings, provider),
         :reasoning_effort => profile.reasoning_effort,
         :thinking_budget => profile.thinking_budget,
         :budget_tokens => profile.thinking_budget,
         :temperature => profile.temperature,
         :max_tokens => profile.max_tokens,
         :reasoning_profile => profile
       }}
    end
  end

  def resolve(_policy, _settings), do: {:error, :invalid_model_route}

  def digest_key, do: @digest_key

  defp projection(policy, settings) do
    selected_provider = value(policy, "model_provider")
    model = value(policy, "model_name")
    provider = LLM.effective_provider(selected_provider, model)
    base_url = base_url(settings, provider)

    cond do
      provider not in ["openai", "anthropic", "ollama", "lm_studio", "llama_cpp"] ->
        {:error, :invalid_model_route}

      not Limits.valid_model_name?(model) ->
        {:error, :invalid_model_route}

      not valid_base_url?(base_url) ->
        {:error, :invalid_model_route}

      true ->
        {:ok, %{"version" => 1, "provider" => provider, "model" => model, "base_url" => base_url}}
    end
  end

  defp digest(projection) do
    with {:ok, canonical} <- IexCode.Runs.DagPayload.canonical_json(projection) do
      {:ok,
       :crypto.hash(:sha256, "iex-code/model-route/v1\0" <> canonical)
       |> Base.encode16(case: :lower)}
    else
      _error -> {:error, :invalid_model_route}
    end
  end

  defp validate_expected_digest(nil, _current), do: :ok

  defp validate_expected_digest(expected, current)
       when is_binary(expected) and byte_size(expected) == 64 do
    if Plug.Crypto.secure_compare(expected, current),
      do: :ok,
      else: {:error, :model_route_configuration_changed}
  end

  defp validate_expected_digest(_expected, _current), do: {:error, :invalid_model_route_digest}

  defp base_url(settings, "openai"),
    do: normalize_url(value(settings, "openai_base_url") || @openai_default)

  defp base_url(settings, "anthropic"),
    do: normalize_url(value(settings, "anthropic_base_url") || @anthropic_default)

  defp base_url(settings, "ollama"),
    do:
      normalize_url(
        value(settings, "ollama_base_url") || IexCode.LLM.Discovery.default_base_url("ollama")
      )

  defp base_url(settings, "lm_studio"),
    do:
      normalize_url(
        value(settings, "lm_studio_base_url") ||
          IexCode.LLM.Discovery.default_base_url("lm_studio")
      )

  defp base_url(settings, "llama_cpp"),
    do:
      normalize_url(
        value(settings, "llama_cpp_base_url") ||
          IexCode.LLM.Discovery.default_base_url("llama_cpp")
      )

  defp credential(settings, "openai") do
    key = value(settings, "openai_api_key")
    base = base_url(settings, "openai")

    if (is_nil(key) or key == "") and IexCode.LLM.Discovery.is_local_endpoint?(base),
      do: "local",
      else: key
  end

  defp credential(settings, "anthropic"), do: value(settings, "anthropic_api_key")

  defp credential(settings, local) when local in ["ollama", "lm_studio", "llama_cpp"] do
    key = value(settings, "#{local}_api_key")
    if is_nil(key) or key == "", do: "local", else: key
  end

  defp normalize_url(url) when is_binary(url), do: String.trim_trailing(String.trim(url), "/")
  defp normalize_url(_url), do: nil

  defp valid_base_url?(url) when is_binary(url) and byte_size(url) in 1..2_048 do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _uri ->
        false
    end
  end

  defp valid_base_url?(_url), do: false

  defp value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, known_atom(key))
  end

  defp known_atom("model_provider"), do: :model_provider
  defp known_atom("model_name"), do: :model_name
  defp known_atom("temperature"), do: :temperature
  defp known_atom("max_tokens"), do: :max_tokens
  defp known_atom("reasoning_effort"), do: :reasoning_effort
  defp known_atom("thinking_budget"), do: :thinking_budget
  defp known_atom("budget_tokens"), do: :budget_tokens
  defp known_atom("model_route_sha256"), do: :model_route_sha256
  defp known_atom("openai_base_url"), do: :openai_base_url
  defp known_atom("anthropic_base_url"), do: :anthropic_base_url
  defp known_atom("ollama_base_url"), do: :ollama_base_url
  defp known_atom("lm_studio_base_url"), do: :lm_studio_base_url
  defp known_atom("llama_cpp_base_url"), do: :llama_cpp_base_url
  defp known_atom("openai_api_key"), do: :openai_api_key
  defp known_atom("anthropic_api_key"), do: :anthropic_api_key
  defp known_atom("ollama_api_key"), do: :ollama_api_key
  defp known_atom("lm_studio_api_key"), do: :lm_studio_api_key
  defp known_atom("llama_cpp_api_key"), do: :llama_cpp_api_key
  defp known_atom(_key), do: :__unknown_model_route_key__
end
