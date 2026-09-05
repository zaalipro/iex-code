defmodule IexCodeWeb.AppearanceSyncTest do
  use IexCode.E2E.Case, async: false

  alias IexCode.Settings

  test "the initial document uses saved light theme and independent depth preferences", %{
    conn: conn
  } do
    assert {:ok, _settings} =
             Settings.update_settings(%{
               ui_theme: "porcelain",
               shadows_3d: false,
               effects_3d: true
             })

    document =
      conn |> get(~p"/settings/appearance") |> html_response(200) |> LazyHTML.from_document()

    assert LazyHTML.attribute(LazyHTML.filter(document, "html"), "data-ui-theme") == ["porcelain"]
    assert LazyHTML.attribute(LazyHTML.filter(document, "html"), "data-theme") == ["light"]

    assert LazyHTML.attribute(LazyHTML.filter(document, "html"), "data-depth-shadows") == [
             "false"
           ]

    assert LazyHTML.attribute(LazyHTML.filter(document, "html"), "data-depth-effects") == ["true"]
  end

  test "saved preferences reach an open LiveView through a public-only appearance event", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/workflows")

    assert {:ok, _settings} =
             Settings.update_settings(%{
               ui_theme: "aurora",
               shadows_3d: true,
               effects_3d: false,
               layout_density: "compact",
               openai_api_key: "private-provider-key"
             })

    _ = render(view)

    assert_push_event(view, "appearance_changed", %{
      ui_theme: "aurora",
      shadows_3d: true,
      effects_3d: false,
      layout_density: "compact"
    })
  end
end
