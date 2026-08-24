defmodule IexCode.Settings do
  @moduledoc """
  Context for managing application settings and LLM API credentials.
  Guarantees crash-free singleton retrieval and idempotent updates.

  A blank stored API key means "no key configured" — no key is ever injected
  here. Concurrency is delegated to SQLite's `busy_timeout`; there are no
  sleep-based retry loops.
  """
  import Ecto.Query, warn: false
  require Logger
  alias IexCode.Repo
  alias IexCode.Settings.AppSettings

  @default_openai_base "https://cli.llmotions.com/v1"
  @default_provider "openai"
  @default_model "gemini-3.7-flash-high"
  @search_provider_order ~w(tavily brave exa serper google bing searxng duckduckgo)

  @doc """
  Returns the active application settings.
  Safely fetches the most recently updated or created settings record.
  If no settings exist, creates default settings. If the database is
  unavailable, logs the error and falls back to volatile in-memory defaults
  (an unpersisted struct).
  """
  def get_settings do
    case fetch_latest_settings() do
      {:ok, %AppSettings{} = settings} ->
        ensure_default_endpoints(settings)

      {:ok, nil} ->
        create_default_settings()

      {:error, reason} ->
        Logger.error(
          "Settings.get_settings falling back to volatile defaults: #{inspect(reason)}"
        )

        ensure_default_endpoints(volatile_defaults())
    end
  end

  @doc """
  Updates the active application settings.
  Persists updates to the database; relies on `busy_timeout` for lock contention.
  """
  def update_settings(attrs) do
    retry_on_busy(fn ->
      settings =
        case fetch_latest_settings() do
          {:ok, %AppSettings{} = s} -> s
          _ -> get_settings()
        end

      changeset = AppSettings.changeset(settings, attrs)

      if changeset.valid? do
        result =
          if settings.__meta__.state == :built do
            Repo.insert(changeset)
          else
            Repo.update(changeset)
          end

        case result do
          {:ok, struct} ->
            {:ok, ensure_default_endpoints(struct)}

          {:error, %Ecto.Changeset{} = error_changeset} ->
            {:error, error_changeset}
        end
      else
        {:error, changeset}
      end
    end)
  rescue
    e in [Exqlite.Error, DBConnection.ConnectionError] ->
      Logger.error("Settings.update_settings failed: #{Exception.message(e)}")
      {:error, {:db_error, Exception.message(e)}}
  end

  @doc """
  Returns a changeset for tracking settings changes.
  """
  def change_settings(%AppSettings{} = settings, attrs \\ %{}) do
    AppSettings.changeset(settings, attrs)
  end

  @doc "Returns the normalized, ordered configuration consumed by the research gateway."
  def search_config(%AppSettings{} = settings \\ get_settings()) do
    providers = settings.search_providers || default_search_providers()
    configured_order = settings.search_provider_order || @search_provider_order

    order =
      Enum.filter(configured_order, fn provider ->
        config = Map.get(providers, provider, %{})
        Map.get(config, "enabled", Map.get(config, :enabled, false)) == true
      end)

    %{
      providers: providers,
      order: Enum.filter(order, &Map.has_key?(providers, &1)),
      depth: settings.research_depth || "standard",
      max_sources: settings.research_max_sources || 12,
      parallelism: settings.research_parallelism || 4
    }
  end

  defp default_settings_attrs do
    %{
      anthropic_api_key: System.get_env("ANTHROPIC_API_KEY") || "",
      anthropic_base_url: System.get_env("ANTHROPIC_BASE_URL") || "https://api.anthropic.com",
      openai_api_key: System.get_env("OPENAI_API_KEY") || "",
      openai_base_url: System.get_env("OPENAI_BASE_URL") || @default_openai_base,
      default_model_provider: @default_provider,
      default_model: @default_model,
      swarm_agent_count: 4,
      auto_save: true,
      temperature: 0.2,
      max_tokens: 4096,
      search_providers: default_search_providers(),
      search_provider_order: @search_provider_order,
      research_depth: "standard",
      research_max_sources: 12,
      research_parallelism: 4
    }
  end

  defp default_search_providers do
    %{
      "tavily" => provider_config("TAVILY_API_KEY", "https://api.tavily.com"),
      "brave" => provider_config("BRAVE_SEARCH_API_KEY", "https://api.search.brave.com/res/v1"),
      "exa" => provider_config("EXA_API_KEY", "https://api.exa.ai"),
      "serper" => provider_config("SERPER_API_KEY", "https://google.serper.dev"),
      "google" =>
        provider_config("GOOGLE_SEARCH_API_KEY", "https://customsearch.googleapis.com")
        |> Map.put("engine_id", System.get_env("GOOGLE_SEARCH_ENGINE_ID") || ""),
      "bing" => provider_config("BING_SEARCH_API_KEY", "https://api.bing.microsoft.com/v7.0"),
      "searxng" => %{
        "enabled" => present_env?("SEARXNG_BASE_URL"),
        "base_url" => System.get_env("SEARXNG_BASE_URL") || ""
      },
      "duckduckgo" => %{
        "enabled" => true,
        "base_url" => "https://html.duckduckgo.com"
      }
    }
  end

  defp provider_config(key_env, base_url) do
    %{
      "enabled" => present_env?(key_env),
      "api_key" => System.get_env(key_env) || "",
      "base_url" => base_url
    }
  end

  defp present_env?(name), do: System.get_env(name) not in [nil, ""]

  # Unpersisted defaults used only when the database cannot be reached.
  defp volatile_defaults do
    struct(AppSettings, default_settings_attrs())
  end

  defp retry_on_busy(fun, attempts \\ 5, delay_ms \\ 50) do
    fun.()
  rescue
    e in [Exqlite.Error, DBConnection.ConnectionError] ->
      msg = Exception.message(e)

      if attempts > 1 and
           (String.contains?(String.downcase(msg), "busy") or
              String.contains?(String.downcase(msg), "locked")) do
        Process.sleep(delay_ms)
        retry_on_busy(fun, attempts - 1, delay_ms * 2)
      else
        reraise e, __STACKTRACE__
      end
  end

  defp create_default_settings do
    retry_on_busy(fn ->
      case %AppSettings{}
           |> AppSettings.changeset(default_settings_attrs())
           |> Repo.insert() do
        {:ok, settings} ->
          ensure_default_endpoints(settings)

        {:error, _changeset} ->
          case fetch_latest_settings() do
            {:ok, %AppSettings{} = settings} ->
              ensure_default_endpoints(settings)

            _ ->
              Logger.error("Settings.create_default_settings could not persist or fetch settings")
              ensure_default_endpoints(volatile_defaults())
          end
      end
    end)
  rescue
    # Concurrent creation raced past the singleton unique index — refetch.
    _ in Ecto.ConstraintError ->
      case fetch_latest_settings() do
        {:ok, %AppSettings{} = settings} ->
          ensure_default_endpoints(settings)

        _ ->
          Logger.error("Settings.create_default_settings lost insert race and refetch failed")
          ensure_default_endpoints(volatile_defaults())
      end

    e in [Exqlite.Error, DBConnection.ConnectionError] ->
      Logger.error("Settings.create_default_settings failed: #{Exception.message(e)}")

      case fetch_latest_settings() do
        {:ok, %AppSettings{} = settings} -> ensure_default_endpoints(settings)
        _ -> ensure_default_endpoints(volatile_defaults())
      end
  end

  defp fetch_latest_settings do
    result =
      retry_on_busy(fn ->
        Repo.one(
          from(s in AppSettings,
            order_by: [desc: s.updated_at, desc: s.inserted_at, desc: s.id],
            limit: 1
          )
        )
      end)

    {:ok, result}
  rescue
    e in [Exqlite.Error, DBConnection.ConnectionError] ->
      Logger.error("Settings.fetch_latest_settings failed: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  defp ensure_default_endpoints(%AppSettings{} = settings) do
    %{
      settings
      | openai_base_url:
          if(is_nil(settings.openai_base_url) or settings.openai_base_url == "",
            do: @default_openai_base,
            else: settings.openai_base_url
          ),
        default_model_provider:
          if(is_nil(settings.default_model_provider) or settings.default_model_provider == "",
            do: @default_provider,
            else: settings.default_model_provider
          ),
        default_model:
          if(is_nil(settings.default_model) or settings.default_model == "",
            do: @default_model,
            else: settings.default_model
          ),
        search_providers:
          if(is_map(settings.search_providers) and map_size(settings.search_providers) > 0,
            do: hydrate_search_providers(settings.search_providers),
            else: default_search_providers()
          ),
        search_provider_order:
          normalize_search_provider_order(
            settings.search_provider_order,
            settings.search_providers || default_search_providers()
          ),
        research_depth: settings.research_depth || "standard",
        research_max_sources: settings.research_max_sources || 12,
        research_parallelism: settings.research_parallelism || 4
    }
  end

  defp normalize_search_provider_order(order, providers) do
    existing = if is_list(order), do: order, else: []
    known = Enum.filter(@search_provider_order, &Map.has_key?(providers, &1))
    Enum.uniq(existing ++ known)
  end

  defp hydrate_search_providers(stored) do
    Map.merge(default_search_providers(), stored, fn _provider, defaults, current ->
      # Stored values are authoritative. Defaults only fill fields added by a
      # newer release; in particular, an explicit `enabled: false` must never
      # be replaced by an environment-derived/default `true` value.
      Map.merge(defaults, current)
    end)
  end
end
