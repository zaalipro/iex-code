defmodule IexCode.SettingsAppearanceTest do
  use IexCode.DataCase, async: false

  alias IexCode.Repo
  alias IexCode.Settings
  alias IexCode.Settings.AppSettings

  setup do
    IexCode.DataCase.drain_all_processes()
    Repo.delete_all(AppSettings)
    :ok
  end

  test "appearance defaults are canonical in new structs and persisted settings" do
    assert %AppSettings{ui_theme: "midnight", shadows_3d: true, effects_3d: true} =
             %AppSettings{}

    settings = Settings.get_settings()

    assert settings.ui_theme == "midnight"
    assert settings.shadows_3d
    assert settings.effects_3d
  end

  test "appearance preferences persist while omitted credentials remain unchanged" do
    assert :ok = Phoenix.PubSub.subscribe(IexCode.PubSub, "appearance:settings")

    assert {:ok, settings} =
             Settings.update_settings(%{
               openai_api_key: "appearance-secret",
               ui_theme: "graphite",
               shadows_3d: true,
               effects_3d: true
             })

    assert {:ok, updated} =
             Settings.update_settings_from_form(settings, %{
               "ui_theme" => "porcelain",
               "shadows_3d" => "false",
               "effects_3d" => "false"
             })

    refute updated.shadows_3d
    refute updated.effects_3d
    assert updated.ui_theme == "porcelain"
    assert updated.openai_api_key == "appearance-secret"

    assert_receive {:appearance_updated,
                    %{
                      ui_theme: "porcelain",
                      shadows_3d: false,
                      effects_3d: false,
                      layout_density: "comfortable"
                    }}

    reloaded = Settings.get_settings()
    assert reloaded.ui_theme == "porcelain"
    refute reloaded.shadows_3d
    refute reloaded.effects_3d
    assert reloaded.openai_api_key == "appearance-secret"
  end

  test "appearance booleans normalize independently from browser checkbox values" do
    settings = Settings.get_settings()

    assert %{
             "shadows_3d" => false,
             "effects_3d" => true
           } =
             Settings.normalize_form_params(
               %{"shadows_3d" => "false", "effects_3d" => "on"},
               settings
             )
  end

  test "only supported named themes validate and appearance fallback is safe" do
    settings = Settings.get_settings()

    invalid = Settings.change_settings(settings, %{ui_theme: "neon-rainbow"})
    refute invalid.valid?
    assert %{ui_theme: _} = errors_on(invalid)

    assert Settings.appearance(%AppSettings{
             ui_theme: "future-theme",
             shadows_3d: nil,
             effects_3d: nil
           }) == %{
             ui_theme: "midnight",
             shadows_3d: true,
             effects_3d: true
           }
  end
end
