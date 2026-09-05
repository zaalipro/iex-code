defmodule IexCodeWeb.SettingsAppearanceLiveTest do
  use IexCode.E2E.Case, async: false

  alias IexCode.Settings

  test "appearance studio exposes five native palette choices and independent depth controls", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/settings/appearance")

    assert has_element?(view, "#settings-appearance-studio")
    assert has_element?(view, "#settings-appearance-preview[data-ui-theme='midnight']")

    for theme <- ~w(midnight graphite aurora porcelain sandstone) do
      assert has_element?(
               view,
               "#settings-ui-theme-#{theme}[type='radio'][name='settings[ui_theme]'][value='#{theme}']"
             )
    end

    assert has_element?(view, "#settings-ui-theme-midnight[checked]")
    assert has_element?(view, "label[for='settings-shadows-3d']", "3D shadows")
    assert has_element?(view, "label[for='settings-effects-3d']", "3D effects")
    assert has_element?(view, "#settings-shadows-3d[type='checkbox'][checked]")
    assert has_element?(view, "#settings-effects-3d[type='checkbox'][checked]")

    # Existing appearance and sound controls retain their stable integration IDs.
    assert has_element?(view, "#settings-theme-accent")
    assert has_element?(view, "#settings-layout-density")
    assert has_element?(view, "#settings-sound-enabled")
    assert has_element?(view, "#settings-completion-chime")
  end

  test "palette and depth drafts update the miniature preview before saving", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/appearance")

    view
    |> form("#settings-form", %{
      "settings" => %{
        "ui_theme" => "aurora",
        "shadows_3d" => "false",
        "effects_3d" => "true"
      }
    })
    |> render_change()

    assert has_element?(
             view,
             "#settings-appearance-preview[data-ui-theme='aurora'][data-depth-shadows='false'][data-depth-effects='true']"
           )

    assert has_element?(view, "#settings-ui-theme-aurora[checked]")
    refute has_element?(view, "#settings-shadows-3d[checked]")
    assert has_element?(view, "#settings-effects-3d[checked]")
    assert has_element?(view, "#settings-save:not([disabled])")
  end

  test "saving the appearance form persists unchecked false values", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/appearance")

    view
    |> form("#settings-form", %{
      "settings" => %{
        "ui_theme" => "sandstone",
        "shadows_3d" => "false",
        "effects_3d" => "false"
      }
    })
    |> render_submit()

    saved = Settings.get_settings()
    assert saved.ui_theme == "sandstone"
    refute saved.shadows_3d
    refute saved.effects_3d

    assert has_element?(
             view,
             "#settings-appearance-preview[data-ui-theme='sandstone'][data-depth-shadows='false'][data-depth-effects='false']"
           )

    assert has_element?(view, "#settings-save[disabled]")
  end

  test "a crafted unsupported theme is rejected and described at the radio group", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/appearance")

    render_submit(view, "save_settings", %{"settings" => %{"ui_theme" => "unsupported"}})

    assert has_element?(
             view,
             "#settings-theme-choices[aria-invalid='true'][aria-describedby='settings-ui-theme-error']"
           )

    assert has_element?(view, "#settings-ui-theme-error[role='alert']")
    assert Settings.get_settings().ui_theme == "midnight"
  end
end
