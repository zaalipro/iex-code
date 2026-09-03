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
  def render(assigns) do
    ~H"""
    <menubar>
      <menu label="File">
        <item onclick="new_session">New Session&#x09;Cmd+N</item>
        <item onclick="open_settings">Settings&#x09;Cmd+,</item>
        <hr />
        <item onclick="close_window">Close Window&#x09;Cmd+W</item>
        <item onclick="quit">Quit IexCode&#x09;Cmd+Q</item>
      </menu>
      <menu label="Edit">
        <item onclick="undo">Undo&#x09;Cmd+Z</item>
        <item onclick="redo">Redo&#x09;Cmd+Shift+Z</item>
        <hr />
        <item onclick="cut">Cut&#x09;Cmd+X</item>
        <item onclick="copy">Copy&#x09;Cmd+C</item>
        <item onclick="paste">Paste&#x09;Cmd+V</item>
      </menu>
      <menu label="View">
        <item onclick="reload_window">Reload Window&#x09;Cmd+R</item>
        <hr />
        <item onclick="toggle_sidebar">Toggle Sidebar&#x09;Cmd+B</item>
        <item onclick="focus_command_palette">Command Palette&#x09;Cmd+K</item>
      </menu>
      <menu label="Workspace">
        <item onclick="tab_kanban">Kanban Board&#x09;Cmd+1</item>
        <item onclick="tab_swarm">Agent Swarm&#x09;Cmd+2</item>
        <item onclick="tab_research">Deep Research&#x09;Cmd+3</item>
        <item onclick="tab_changes">File Changes / Diff&#x09;Cmd+4</item>
        <item onclick="tab_terminal">Terminal&#x09;Cmd+5</item>
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
        Lifecycle.teardown()

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

      "focus_command_palette" ->
        PubSub.broadcast(@pubsub, "desktop:events", {:desktop_action, :command_palette})

      <<"tab_", tab::binary>> ->
        PubSub.broadcast(@pubsub, "desktop:events", {:desktop_switch_tab, tab})

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
