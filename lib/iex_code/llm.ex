defmodule IexCode.LLM do
  @moduledoc """
  Unified LLM gateway coordinating OpenAI, Anthropic, custom endpoints,
  and fallback provider routing with exponential backoff resilience.
  """
  alias IexCode.Settings
  alias IexCode.LLM.{Anthropic, OpenAI, Resilience}

  @doc """
  Dispatches chat requests across OpenAI / Anthropic models with retry resilience
  and provider fallback routing.
  """
  def chat(messages, system_prompt, session, on_chunk \\ fn _c -> :ok end) do
    settings = Settings.get_settings()

    raw_provider =
      (session && session.model_provider) || settings.default_model_provider || "openai"

    raw_model =
      (session && session.model_name) || settings.default_model || "gemini-3.7-flash-high"

    temperature = (session && session.temperature) || 0.2
    tools = IexCode.Tools.tool_definitions()

    # Smart auto-detection if anthropic key is missing but openai/proxy key is configured
    primary_provider =
      cond do
        String.starts_with?(raw_model, "gemini") or String.starts_with?(raw_model, "gpt") or
          String.starts_with?(raw_model, "o1") or String.starts_with?(raw_model, "o3") ->
          "openai"

        raw_provider == "anthropic" and
          (settings.anthropic_api_key == nil or settings.anthropic_api_key == "") and
            (settings.openai_api_key != nil and settings.openai_api_key != "") ->
          "openai"

        true ->
          raw_provider
      end

    openai_opts = [
      api_key: settings.openai_api_key || "sk-zaali-secret",
      base_url: settings.openai_base_url || "https://cli.llmotions.com/v1",
      model:
        if(String.starts_with?(raw_model, "claude"), do: "gemini-3.7-flash-high", else: raw_model),
      temperature: temperature,
      tools: tools
    ]

    anthropic_opts = [
      api_key: settings.anthropic_api_key,
      base_url: settings.anthropic_base_url || "https://api.anthropic.com",
      model:
        if(String.starts_with?(raw_model, "claude"), do: raw_model, else: "claude-3-7-sonnet"),
      temperature: temperature,
      tools: tools
    ]

    openai_fn = fn -> OpenAI.chat(messages, system_prompt, openai_opts, on_chunk) end
    anthropic_fn = fn -> Anthropic.chat(messages, system_prompt, anthropic_opts, on_chunk) end

    providers =
      if primary_provider == "openai" do
        [{"openai", openai_fn}, {"anthropic", anthropic_fn}]
      else
        [{"anthropic", anthropic_fn}, {"openai", openai_fn}]
      end

    case Resilience.with_fallback(providers) do
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
