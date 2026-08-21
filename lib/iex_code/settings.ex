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
    settings = get_settings()
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

  defp default_settings_attrs do
    %{
      anthropic_api_key: System.get_env("ANTHROPIC_API_KEY") || "",
      anthropic_base_url: System.get_env("ANTHROPIC_BASE_URL") || "https://api.anthropic.com",
      openai_api_key: System.get_env("OPENAI_API_KEY") || "",
      openai_base_url: System.get_env("OPENAI_BASE_URL") || @default_openai_base,
      default_model_provider: @default_provider,
      default_model: @default_model,
      swarm_agent_count: 4,
      auto_save: true
    }
  end

  # Unpersisted defaults used only when the database cannot be reached.
  defp volatile_defaults do
    struct(AppSettings, default_settings_attrs())
  end

  defp create_default_settings do
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
    {:ok,
     Repo.one(
       from(s in AppSettings,
         order_by: [desc: s.updated_at, desc: s.inserted_at, desc: s.id],
         limit: 1
       )
     )}
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
          )
    }
  end
end
