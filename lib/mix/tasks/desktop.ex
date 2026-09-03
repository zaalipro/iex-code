defmodule Mix.Tasks.Desktop do
  @shortdoc "Launches IexCode in native macOS desktop window"
  @moduledoc """
  Starts the Phoenix endpoint server and opens the native Desktop window.

  Usage:
      mix desktop
      iex -S mix desktop
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Application.put_env(:iex_code, :start_desktop_window, true)
    Application.put_env(:iex_code, IexCodeWeb.Endpoint, server: true)

    Mix.Task.run("phx.server", args)
  end
end
