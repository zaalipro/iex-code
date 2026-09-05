defmodule IexCodeWeb.Appearance do
  @moduledoc "Public appearance preferences shared by every LiveView and the initial document."

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, push_event: 3]

  @themes ~w(midnight graphite aurora porcelain sandstone)

  def from_settings(settings) when is_map(settings) do
    %{
      ui_theme: choice(Map.get(settings, :ui_theme), @themes, "midnight"),
      shadows_3d: boolean(Map.get(settings, :shadows_3d)),
      effects_3d: boolean(Map.get(settings, :effects_3d)),
      layout_density:
        choice(Map.get(settings, :layout_density), ~w(comfortable compact), "comfortable")
    }
  end

  def color_scheme(%{ui_theme: theme}) when theme in ["porcelain", "sandstone"], do: "light"
  def color_scheme(_), do: "dark"

  def on_mount(:default, _params, _session, socket) do
    appearance = from_settings(IexCode.Settings.get_settings())
    socket = assign(socket, :appearance, appearance)

    socket =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(IexCode.PubSub, "appearance:settings")

        socket
        |> push_event("appearance_changed", appearance)
        |> attach_hook(:appearance_preferences, :handle_info, fn
          {:appearance_updated, settings}, socket ->
            appearance = from_settings(settings)

            {:halt,
             socket
             |> assign(:appearance, appearance)
             |> push_event("appearance_changed", appearance)}

          _message, socket ->
            {:cont, socket}
        end)
      else
        socket
      end

    {:cont, socket}
  end

  defp choice(value, choices, default), do: if(value in choices, do: value, else: default)
  defp boolean(value) when is_boolean(value), do: value
  defp boolean(_value), do: true
end
