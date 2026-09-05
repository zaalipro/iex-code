defmodule IexCode.Repo.Migrations.AddAppearanceSettings do
  use Ecto.Migration

  def change do
    alter table(:app_settings) do
      add :ui_theme, :string,
        null: false,
        default: "midnight",
        check: %{
          name: "app_settings_ui_theme_check",
          expr: "ui_theme IN ('midnight', 'graphite', 'aurora', 'porcelain', 'sandstone')"
        }

      add :shadows_3d, :boolean, null: false, default: true
      add :effects_3d, :boolean, null: false, default: true
    end
  end
end
