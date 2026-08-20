defmodule IexCode.Settings do
  @moduledoc """
  Context for managing application settings and LLM API credentials.
  Guarantees crash-free singleton retrieval and idempotent updates.
  """
  import Ecto.Query, warn: false
  alias IexCode.Repo
  alias IexCode.Settings.AppSettings

  @default_openai_key "sk-zaali-secret"
  @default_openai_base "https://cli.llmotions.com/v1"
  @default_provider "openai"
  @default_model "gemini-3.7-flash-high"

  @doc """
  Returns the active application settings.
  Safely fetches the most recently updated or created settings record.
  If no settings exist, creates default settings.
  """
  def get_settings do
    case fetch_latest_settings() do
      nil ->
        create_default_settings()

      settings ->
        ensure_default_endpoints(settings)
    end
  end

  @doc """
  Updates the active application settings.
  Persists updates to the database with resilient retries for SQLite lock contention.
  """
  def update_settings(attrs) do
    update_settings_with_retry(attrs, 20)
  end

  @doc """
  Returns a changeset for tracking settings changes.
  """
  def change_settings(%AppSettings{} = settings, attrs \\ %{}) do
    AppSettings.changeset(settings, attrs)
  end

  defp update_settings_with_retry(attrs, retries) do
    settings = get_settings()
    changeset = AppSettings.changeset(settings, attrs)

    if changeset.valid? do
      result =
        if is_nil(settings.id) or settings.__meta__.state == :built do
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
    e in [Exqlite.Error, DBConnection.ConnectionError, Ecto.StaleEntryError] ->
      if retries > 0 do
        backoff = min(150, 20 + :rand.uniform(30) + (20 - retries) * 10)
        :timer.sleep(backoff)
        update_settings_with_retry(attrs, retries - 1)
      else
        reraise e, __STACKTRACE__
      end
  end

  defp default_settings_attrs do
    %{
      anthropic_api_key: System.get_env("ANTHROPIC_API_KEY") || "",
      anthropic_base_url: System.get_env("ANTHROPIC_BASE_URL") || "https://api.anthropic.com",
      openai_api_key: System.get_env("OPENAI_API_KEY") || @default_openai_key,
      openai_base_url: System.get_env("OPENAI_BASE_URL") || @default_openai_base,
      default_model_provider: @default_provider,
      default_model: @default_model,
      swarm_agent_count: 4,
      auto_save: true
    }
  end

  defp create_default_settings(retries \\ 20) do
    attrs = default_settings_attrs()

    case %AppSettings{}
         |> AppSettings.changeset(attrs)
         |> Repo.insert() do
      {:ok, settings} ->
        ensure_default_endpoints(settings)

      {:error, _changeset} ->
        case fetch_latest_settings() do
          %AppSettings{} = settings ->
            ensure_default_endpoints(settings)

          nil ->
            if retries > 0 do
              backoff = min(150, 20 + :rand.uniform(30) + (20 - retries) * 10)
              :timer.sleep(backoff)
              create_default_settings(retries - 1)
            else
              ensure_default_endpoints(struct(AppSettings, attrs))
            end
        end
    end
  rescue
    _ in [Exqlite.Error, DBConnection.ConnectionError] ->
      case fetch_latest_settings() do
        %AppSettings{} = settings ->
          ensure_default_endpoints(settings)

        nil ->
          if retries > 0 do
            backoff = min(150, 20 + :rand.uniform(30) + (20 - retries) * 10)
            :timer.sleep(backoff)
            create_default_settings(retries - 1)
          else
            attrs = default_settings_attrs()
            ensure_default_endpoints(struct(AppSettings, attrs))
          end
      end
  end

  defp fetch_latest_settings(retries \\ 5) do
    Repo.one(
      from(s in AppSettings,
        order_by: [desc: s.updated_at, desc: s.inserted_at, desc: s.id],
        limit: 1
      )
    )
  rescue
    _ in [Exqlite.Error, DBConnection.ConnectionError] ->
      if retries > 0 do
        :timer.sleep(20)
        fetch_latest_settings(retries - 1)
      else
        nil
      end

    _ ->
      nil
  catch
    _, _ -> nil
  end

  defp ensure_default_endpoints(%AppSettings{} = settings) do
    %{
      settings
      | openai_api_key:
          if(is_nil(settings.openai_api_key) or settings.openai_api_key == "",
            do: @default_openai_key,
            else: settings.openai_api_key
          ),
        openai_base_url:
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
