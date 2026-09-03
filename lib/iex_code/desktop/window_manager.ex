defmodule IexCode.Desktop.WindowManager do
  @moduledoc """
  Manages independent native macOS `Desktop.Window` instances for detached workspace tools:
  - Dedicated Terminal Multiplexer (`IexCodeTerminalWindow`)
  - Git Changes & Diff Inspector (`IexCodeDiffWindow`)
  - DAG Research Visualizer (`IexCodeDagWindow`)

  All detached tool windows are configured with `on_close: :hide` so that closing a
  secondary window never terminates the BEAM runtime or primary application window.
  """

  require Logger
  alias IexCode.Desktop.WindowSupervisor

  @windows %{
    terminal: %{
      id: IexCodeTerminalWindow,
      title: "IexCode - Terminal Multiplexer",
      size: {1040, 720},
      min_size: {640, 480},
      slug: "terminal"
    },
    diff: %{
      id: IexCodeDiffWindow,
      title: "IexCode - Git Changes & Diff Inspector",
      size: {1280, 840},
      min_size: {800, 600},
      slug: "diff"
    },
    dag: %{
      id: IexCodeDagWindow,
      title: "IexCode - DAG Execution & Deep Research",
      size: {1360, 880},
      min_size: {850, 600},
      slug: "dag"
    }
  }

  @doc """
  Returns the canonical window configuration map for all detached tools.
  """
  def window_configs, do: @windows

  @doc """
  Returns the window configuration for a given tool name or slug.
  """
  def get_config(tool) when is_binary(tool) do
    case String.downcase(tool) do
      "terminal" -> @windows.terminal
      "diff" -> @windows.diff
      "dag" -> @windows.dag
      _ -> nil
    end
  end

  def get_config(tool) when is_atom(tool) do
    Map.get(@windows, tool)
  end

  @doc """
  Returns the atom ID for a given tool.
  """
  def window_id(tool) do
    case get_config(tool) do
      %{id: id} -> id
      _ -> nil
    end
  end

  @doc """
  Returns relative and full URL for a detached tool window.
  """
  def window_path(tool, session_id) do
    case get_config(tool) do
      %{slug: slug} -> "/sessions/#{session_id}/detached/#{slug}"
      _ -> "/sessions/#{session_id}"
    end
  end

  def window_url(tool, session_id) do
    path = window_path(tool, session_id)
    endpoint_url = IexCodeWeb.Endpoint.url()
    endpoint_url <> path
  end

  @doc """
  Opens, restores, or launches the detached tool window.
  - If running in native desktop mode and wx is active, brings the window to front.
  - If running in browser or headless mode, returns `{:ok, :web, path}` so the client
    can open the URL directly or navigate to it.
  """
  def open_window(tool, session_id) do
    case get_config(tool) do
      nil ->
        {:error, :unknown_tool}

      config ->
        path = window_path(tool, session_id)
        full_url = window_url(tool, session_id)

        if native_desktop_active?() do
          open_native_window(config, full_url)
        else
          {:ok, :web, path}
        end
    end
  end

  @doc """
  Hides the detached window if it is running.
  """
  def hide_window(tool) do
    case window_id(tool) do
      nil ->
        {:error, :unknown_tool}

      id ->
        case Process.whereis(id) do
          pid when is_pid(pid) ->
            try do
              Desktop.Window.hide(id)
              :ok
            rescue
              e -> {:error, e}
            end

          nil ->
            :ok
        end
    end
  end

  @doc """
  Closes (hides) the detached window. Alias for hide_window/1.
  """
  def close_window(tool), do: hide_window(tool)

  @doc """
  Checks if a window process is alive and running.
  """
  def window_alive?(tool) do
    case window_id(tool) do
      nil -> false
      id -> is_pid(Process.whereis(id))
    end
  end

  @doc """
  Lists the status of all managed detached windows.
  """
  def list_windows do
    Enum.into(@windows, %{}, fn {key, cfg} ->
      pid = Process.whereis(cfg.id)
      status = if is_pid(pid), do: :running, else: :stopped

      {key,
       %{
         id: cfg.id,
         title: cfg.title,
         status: status,
         pid: pid
       }}
    end)
  end

  # ============================================================================
  # Internal Helpers
  # ============================================================================

  defp native_desktop_active? do
    desktop_flag = Application.get_env(:iex_code, :start_desktop_window, false)
    wx_running = is_pid(Process.whereis(Desktop.Env)) or is_pid(Process.whereis(IexCodeWindow))
    desktop_flag and wx_running
  end

  defp open_native_window(config, full_url) do
    window_id = config.id

    case Process.whereis(window_id) do
      pid when is_pid(pid) ->
        try do
          Desktop.Window.load_url(window_id, full_url)
          Desktop.Window.show(window_id, full_url)
          {:ok, :native, window_id}
        rescue
          _ ->
            {:ok, :native, window_id}
        end

      nil ->
        child_spec = {
          Desktop.Window,
          [
            app: :iex_code,
            id: window_id,
            title: config.title,
            size: config.size,
            min_size: config.min_size,
            menubar: IexCodeWeb.MenuBar,
            on_close: :hide,
            url: fn -> full_url end
          ]
        }

        case WindowSupervisor.start_window(child_spec) do
          {:ok, _pid} ->
            {:ok, :native, window_id}

          {:error, {:already_started, _pid}} ->
            try do
              Desktop.Window.load_url(window_id, full_url)
              Desktop.Window.show(window_id, full_url)
            rescue
              _ -> :ok
            end

            {:ok, :native, window_id}

          {:error, reason} ->
            Logger.error(
              "Failed to start detached window #{inspect(window_id)}: #{inspect(reason)}"
            )

            {:error, reason}
        end
    end
  end
end
