defmodule IexCode.LLM do
  @moduledoc """
  Unified LLM gateway coordinating OpenAI, Anthropic, custom endpoints,
  and fallback provider routing with exponential backoff resilience.

  There is no mock/local mode: a missing API key returns `{:error, :no_api_key}`
  and a provider failure returns an error — content is never fabricated.
  """
  alias IexCode.Settings
  alias IexCode.LLM.{Anthropic, OpenAI, Resilience}

  @doc """
  Dispatches chat requests across OpenAI / Anthropic models with retry resilience
  and provider fallback routing.

  ## Options
  - `:cancelled?` - zero-arg fun polled by the stream client between chunks; when
    truthy the stream aborts cleanly (forwarded to providers / `StreamClient`)
  - `:max_tokens` - overrides the provider default max token count
  - `:temperature` - overrides the session/settings temperature
  - `:on_retry` - fn (attempt, reason, sleep_ms) invoked by the resilience engine
    on every retry
  - `:receive_timeout` - HTTP receive timeout in ms forwarded to providers
  """
  def chat(messages, system_prompt, session, on_chunk \\ fn _c -> :ok end, opts \\ []) do
    settings = Settings.get_settings()

    raw_provider =
      (session && session.model_provider) || settings.default_model_provider || "openai"

    raw_model =
      (session && session.model_name) || settings.default_model || "claude-3-7-sonnet"

    do_chat(messages, system_prompt, session, on_chunk, opts, settings, raw_provider, raw_model)
  end

  defp do_chat(
         messages,
         system_prompt,
         session,
         on_chunk,
         opts,
         settings,
         raw_provider,
         raw_model
       ) do
    temperature = Keyword.get(opts, :temperature) || (session && session.temperature) || 0.2
    tools = IexCode.Tools.tool_definitions(Keyword.get(opts, :allowed_tools, :all))
    max_tokens = Keyword.get(opts, :max_tokens) || settings.max_tokens

    # Route GPT/o1/o3 model families to OpenAI even when the provider is set to
    # anthropic. Model names are otherwise passed through to the provider as-is.
    primary_provider =
      cond do
        String.starts_with?(raw_model, "gpt") or String.starts_with?(raw_model, "o1") or
            String.starts_with?(raw_model, "o3") ->
          "openai"

        raw_provider == "anthropic" and blank?(settings.anthropic_api_key) and
            present?(settings.openai_api_key) ->
          "openai"

        true ->
          raw_provider
      end

    passthrough_opts =
      opts
      |> Keyword.take([:cancelled?, :receive_timeout])
      |> Keyword.put(:max_tokens, max_tokens)
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    openai_fn = fn ->
      OpenAI.chat(
        messages,
        system_prompt,
        [
          api_key: settings.openai_api_key,
          base_url: settings.openai_base_url || "https://cli.llmotions.com/v1",
          model: raw_model,
          temperature: temperature,
          tools: tools
        ] ++ passthrough_opts,
        on_chunk
      )
    end

    anthropic_fn = fn ->
      Anthropic.chat(
        messages,
        system_prompt,
        [
          api_key: settings.anthropic_api_key,
          base_url: settings.anthropic_base_url || "https://api.anthropic.com",
          model: raw_model,
          temperature: temperature,
          tools: tools
        ] ++ passthrough_opts,
        on_chunk
      )
    end

    providers =
      [
        {"openai", openai_fn, settings.openai_api_key},
        {"anthropic", anthropic_fn, settings.anthropic_api_key}
      ]
      |> Enum.filter(fn {_name, _fn, key} -> present?(key) end)
      |> Enum.sort_by(fn
        {^primary_provider, _fn, _key} -> 0
        {_other, _fn, _key} -> 1
      end)
      |> Enum.map(fn {name, fn_, _key} -> {name, fn_} end)

    cond do
      providers == [] ->
        {:error, :no_api_key}

      true ->
        case Resilience.with_fallback(providers,
               on_chunk: on_chunk,
               on_retry: Keyword.get(opts, :on_retry, fn _a, _r, _s -> :ok end)
             ) do
          {:ok, result, _meta} ->
            {:ok, result}

          {:ok, result} ->
            {:ok, result}

          {:error, {:all_providers_failed, errors}} ->
            first_err = List.first(errors) |> elem(1)
            {:error, first_err}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp blank?(key), do: is_nil(key) or key == ""
  defp present?(key), do: not blank?(key)
end
