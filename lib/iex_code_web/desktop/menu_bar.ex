defmodule IexCodeWeb.MenuBar do
  @moduledoc """
  Native macOS Menu Bar for IexCode Desktop Application.
  """
  use Desktop.Menu
  alias Desktop.Window
  alias IexCode.Desktop.Lifecycle
  alias Phoenix.PubSub

  @pubsub IexCode.PubSub

  @impl true
  def mount(%Desktop.Menu{} = menu) do
    {:ok, assign(menu, active_tab: "kanban")}
  end

  def mount(_menu) do
    {:ok, assign(%Desktop.Menu{assigns: %{}}, active_tab: "kanban")}
  end

  @impl true
  # wx uses Ctrl for the platform command modifier (Command on macOS).
  def render(assigns) do
    ~H"""
    <menubar>
      <menu label="File">
        <item onclick="new_session">New Session&#x09;Ctrl+Shift+N</item>
        <item onclick="open_settings">Settings&#x09;Ctrl+,</item>
        <hr />
        <item onclick="close_window">Close Window&#x09;Ctrl+W</item>
        <item onclick="quit">Quit IexCode&#x09;Ctrl+Q</item>
      </menu>
      <menu label="Edit">
        <item onclick="undo">Undo&#x09;Ctrl+Z</item>
        <item onclick="redo">Redo&#x09;Ctrl+Shift+Z</item>
        <hr />
        <item onclick="cut">Cut&#x09;Ctrl+X</item>
        <item onclick="copy">Copy&#x09;Ctrl+C</item>
        <item onclick="paste">Paste&#x09;Ctrl+V</item>
      </menu>
      <menu label="View">
        <item onclick="reload_window">Reload Window&#x09;Ctrl+R</item>
        <hr />
        <item onclick="toggle_sidebar">Toggle Sidebar&#x09;Ctrl+N</item>
        <item onclick="toggle_terminal">Toggle Terminal Panel&#x09;Ctrl+J</item>
        <item onclick="focus_command_palette">Command Palette&#x09;Ctrl+K</item>
        <hr />
        <item onclick="detach_terminal">Detach Terminal&#x09;Ctrl+Shift+T</item>
        <item onclick="detach_diff">Detach Git / Diff&#x09;Ctrl+Shift+D</item>
        <item onclick="detach_dag">Detach DAG Map&#x09;Ctrl+Shift+M</item>
      </menu>
      <menu label="Workspace">
        <item onclick="tab_kanban">Kanban Board&#x09;Ctrl+1</item>
        <item onclick="tab_swarm">Agent Swarm&#x09;Ctrl+2</item>
        <item onclick="tab_research">Deep Research&#x09;Ctrl+3</item>
        <item onclick="tab_changes">File Changes / Diff&#x09;Ctrl+4</item>
        <item onclick="tab_terminal">Terminal&#x09;Ctrl+5</item>
      </menu>
      <menu label="Help">
        <item onclick="help_docs">IexCode Documentation</item>
        <item onclick="help_shortcuts">Keyboard Shortcuts</item>
        <hr />
        <item onclick="help_about">About IexCode</item>
      </menu>
    </menubar>
    """
  end

  @impl true
  def handle_event(command, menu) do
    case command do
      "quit" ->
        Lifecycle.request_quit()

      "close_window" ->
        if Process.whereis(IexCodeWindow), do: Window.hide(IexCodeWindow)

      "reload_window" ->
        if Process.whereis(IexCodeWindow), do: Window.reload(IexCodeWindow)

      "new_session" ->
        PubSub.broadcast(@pubsub, "desktop:events", {:desktop_action, :new_session})

      "open_settings" ->
        PubSub.broadcast(@pubsub, "desktop:events", {:desktop_action, :open_settings})

      "toggle_sidebar" ->
        PubSub.broadcast(@pubsub, "desktop:events", {:desktop_action, :toggle_sidebar})

      "toggle_terminal" ->
        PubSub.broadcast(@pubsub, "desktop:events", {:desktop_action, :toggle_terminal})

      "focus_command_palette" ->
        PubSub.broadcast(@pubsub, "desktop:events", {:desktop_action, :command_palette})

      <<"tab_", tab::binary>> ->
        PubSub.broadcast(@pubsub, "desktop:events", {:desktop_switch_tab, tab})

      "detach_terminal" ->
        PubSub.broadcast(
          @pubsub,
          "desktop:events",
          {:desktop_action, {:detach_window, :terminal}}
        )

      "detach_diff" ->
        PubSub.broadcast(@pubsub, "desktop:events", {:desktop_action, {:detach_window, :diff}})

      "detach_dag" ->
        PubSub.broadcast(@pubsub, "desktop:events", {:desktop_action, {:detach_window, :dag}})

      "help_docs" ->
        Desktop.OS.open_url("https://github.com/zaalipro/iex-code")

      "help_shortcuts" ->
        PubSub.broadcast(@pubsub, "desktop:events", {:desktop_action, :command_palette})

      "help_about" ->
        if Process.whereis(IexCodeWindow) do
          Window.show_notification(
            IexCodeWindow,
            "IexCode v0.1.0 - Local-first Autonomous Coding Harness",
            title: "About IexCode",
            type: :info
          )
        end

      _ ->
        :ok
    end

    {:noreply, menu}
  end

  @impl true
  def handle_info(_msg, menu), do: {:noreply, menu}
end
