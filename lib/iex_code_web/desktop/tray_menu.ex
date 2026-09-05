defmodule IexCodeWeb.TrayMenu do
  @moduledoc """
  Taskbar / Dock tray popup menu for IexCode.
  """
  use Desktop.Menu
  alias Desktop.Window
  alias IexCode.Desktop.Lifecycle
  alias Phoenix.PubSub

  @pubsub IexCode.PubSub

  @impl true
  def mount(menu), do: {:ok, menu}

  @impl true
  def render(assigns) do
    ~H"""
    <menu>
      <item onclick="show_window">Open IexCode</item>
      <item onclick="new_session">New Workspace Session</item>
      <hr />
      <item onclick="quit">Quit IexCode</item>
    </menu>
    """
  end

  @impl true
  def handle_event(command, menu) do
    case command do
      "show_window" ->
        if Process.whereis(IexCodeWindow), do: Window.show(IexCodeWindow)

      "new_session" ->
        PubSub.broadcast(@pubsub, "desktop:events", {:desktop_action, :new_session})

      "quit" ->
        Lifecycle.request_quit()

      _ ->
        :ok
    end

    {:noreply, menu}
  end

  @impl true
  def handle_info(_msg, menu), do: {:noreply, menu}
end
