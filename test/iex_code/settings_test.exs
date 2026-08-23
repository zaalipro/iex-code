defmodule IexCode.SettingsTest do
  use IexCode.DataCase, async: false
  @moduletag timeout: 120_000
  alias IexCode.Settings
  alias IexCode.Settings.AppSettings
  alias IexCode.Repo

  setup do
    IexCode.DataCase.drain_all_processes()
    Repo.delete_all(AppSettings)
    :ok
  end

  describe "get_settings/0 and update_settings/1" do
    test "initializes default settings when database is empty" do
      settings = Settings.get_settings()
      assert %AppSettings{} = settings
      assert settings.default_model == "gemini-3.7-flash-high"
      assert settings.openai_base_url == "https://cli.llmotions.com/v1"
      # No default API key is ever injected; it must come from the environment or stay unset.
      assert settings.openai_api_key in [nil, "", System.get_env("OPENAI_API_KEY")]
    end

    test "safely handles multiple AppSettings rows without raising MultipleResultsError" do
      Repo.delete_all(AppSettings)
      # The singleton index (app_settings_singleton_index) now forbids a second row.
      {:ok, s1} = Repo.insert(%AppSettings{default_model: "model-1", openai_api_key: "k1"})

      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert(%AppSettings{default_model: "model-2", openai_api_key: "k2"})
      end

      # get_settings() safely returns the single existing row
      settings = Settings.get_settings()
      assert %AppSettings{} = settings
      assert settings.id == s1.id
    end

    test "updates existing settings idempotently" do
      {:ok, updated} =
        Settings.update_settings(%{
          default_model: "claude-3-5-sonnet",
          default_model_provider: "anthropic",
          anthropic_api_key: "sk-ant-test12345",
          anthropic_base_url: "https://api.anthropic.com",
          openai_api_key: "sk-proj-test12345",
          openai_base_url: "https://api.openai.com/v1",
          swarm_agent_count: 6,
          temperature: 0.7,
          max_tokens: 8192,
          auto_save: true
        })

      assert updated.default_model == "claude-3-5-sonnet"
      assert updated.default_model_provider == "anthropic"
      assert updated.anthropic_api_key == "sk-ant-test12345"
      assert updated.anthropic_base_url == "https://api.anthropic.com"
      assert updated.openai_api_key == "sk-proj-test12345"
      assert updated.openai_base_url == "https://api.openai.com/v1"
      assert updated.swarm_agent_count == 6
      assert updated.temperature == 0.7
      assert updated.max_tokens == 8192
      assert updated.auto_save == true

      fetched = Settings.get_settings()
      assert fetched.default_model == "claude-3-5-sonnet"
      assert fetched.temperature == 0.7
      assert fetched.max_tokens == 8192
    end

    test "validates temperature and max_tokens ranges in changeset" do
      settings = Settings.get_settings()

      # Valid bounds
      valid_cs =
        Settings.change_settings(settings, %{
          temperature: 0.0,
          max_tokens: 128_000,
          swarm_agent_count: 32
        })

      assert valid_cs.valid?

      # Invalid temperature
      invalid_temp = Settings.change_settings(settings, %{temperature: 2.5})
      refute invalid_temp.valid?
      assert %{temperature: _} = errors_on(invalid_temp)

      # Invalid max_tokens
      invalid_tokens = Settings.change_settings(settings, %{max_tokens: 0})
      refute invalid_tokens.valid?
      assert %{max_tokens: _} = errors_on(invalid_tokens)
    end

    test "change_settings/2 returns a valid changeset" do
      settings = Settings.get_settings()
      changeset = Settings.change_settings(settings, %{default_model: "o3-mini"})
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :default_model) == "o3-mini"
    end
  end
end
