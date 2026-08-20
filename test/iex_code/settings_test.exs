defmodule IexCode.SettingsTest do
  use IexCode.DataCase, async: false
  @moduletag timeout: 120_000
  alias IexCode.Settings
  alias IexCode.Settings.AppSettings
  alias IexCode.Repo

  setup do
    IexCode.DataCase.drain_all_processes()
    :ok
  end

  describe "get_settings/0 and update_settings/1" do
    test "initializes default settings when database is empty" do
      settings = Settings.get_settings()
      assert %AppSettings{} = settings
      assert settings.default_model == "gemini-3.7-flash-high"
      assert settings.openai_base_url == "https://cli.llmotions.com/v1"
      assert settings.openai_api_key == "sk-zaali-secret"
    end

    test "safely handles multiple AppSettings rows without raising MultipleResultsError" do
      # Insert multiple rows directly into repo
      {:ok, s1} = Repo.insert(%AppSettings{default_model: "model-1", openai_api_key: "k1"})
      {:ok, s2} = Repo.insert(%AppSettings{default_model: "model-2", openai_api_key: "k2"})

      # Must return latest without crashing
      settings = Settings.get_settings()
      assert %AppSettings{} = settings
      assert settings.id in [s1.id, s2.id]
      assert settings.openai_api_key in ["k1", "k2"]
    end

    test "updates existing settings idempotently" do
      {:ok, updated} =
        Settings.update_settings(%{default_model: "claude-3-5-sonnet", swarm_agent_count: 6})

      assert updated.default_model == "claude-3-5-sonnet"
      assert updated.swarm_agent_count == 6

      fetched = Settings.get_settings()
      assert fetched.default_model == "claude-3-5-sonnet"
      assert fetched.swarm_agent_count == 6
    end

    test "change_settings/2 returns a valid changeset" do
      settings = Settings.get_settings()
      changeset = Settings.change_settings(settings, %{default_model: "o3-mini"})
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :default_model) == "o3-mini"
    end
  end
end
