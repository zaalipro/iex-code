defmodule IexCodeWeb.AppearanceTest do
  use ExUnit.Case, async: true

  alias IexCodeWeb.Appearance

  test "exposes only public appearance preferences and preserves independent false values" do
    assert Appearance.from_settings(%{
             ui_theme: "porcelain",
             shadows_3d: false,
             effects_3d: true,
             layout_density: "compact",
             openai_api_key: "must-not-leave-the-server"
           }) == %{
             ui_theme: "porcelain",
             shadows_3d: false,
             effects_3d: true,
             layout_density: "compact"
           }

    assert %{shadows_3d: true, effects_3d: false} =
             Appearance.from_settings(%{shadows_3d: true, effects_3d: false})
  end

  test "normalizes missing or unsupported settings without arbitrary theme attributes" do
    assert Appearance.from_settings(%{ui_theme: "unknown", shadows_3d: nil}) == %{
             ui_theme: "midnight",
             shadows_3d: true,
             effects_3d: true,
             layout_density: "comfortable"
           }
  end
end
