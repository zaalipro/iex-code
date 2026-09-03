defmodule IexCode.Desktop.Notifier do
  @moduledoc """
  Dispatches native macOS desktop notifications via `Desktop.Window.show_notification`
  with graceful fallback to `Logger` in headless, test, and browser environments.
  """
  require Logger

  alias IexCode.Desktop.Sound

  @type notification_type :: :info | :warning | :warn | :error

  @doc """
  Dispatches a native desktop notification when the desktop window is running;
  otherwise logs the notification via Logger and returns `{:ok, :fallback}`.

  Options:
    * `:title` - Notification banner title (default: `"IexCode"`)
    * `:type` - Notification severity icon (`:info`, `:warning`, `:warn`, `:error`, default: `:info`)
    * `:sound` - Auditory cue to play along with the notification (e.g. `:hero`, `:sosumi`, `:basso`, `:ping`)
    * `:id` - Unique identifier for replacing or dismissing the notification (default: `:default`)
    * `:timeout` - Auto-dismiss timeout in ms, `:auto`, or `:never` (default: `:auto`)
  """
  @spec notify(String.t(), keyword()) :: :ok | {:ok, :fallback}
  def notify(text, opts \\ []) when is_binary(text) and is_list(opts) do
    # Trigger sound cue if requested in options
    if sound = Keyword.get(opts, :sound) do
      Sound.play(sound)
    end

    if desktop_window_alive?() and notifications_enabled?() do
      window_id = Application.get_env(:iex_code, :desktop_window_id, IexCodeWindow)
      clean_opts = sanitize_desktop_opts(opts)
      Desktop.Window.show_notification(window_id, text, clean_opts)
      :ok
    else
      log_fallback(text, opts)
      {:ok, :fallback}
    end
  end

  @doc """
  Dismisses an active desktop notification by identifier.
  """
  @spec dismiss(term()) :: :ok
  def dismiss(id \\ :default) do
    if desktop_window_alive?() do
      window_id = Application.get_env(:iex_code, :desktop_window_id, IexCodeWindow)
      Desktop.Window.dismiss_notification(window_id, id)
    else
      :ok
    end
  end

  @doc """
  Checks if the desktop window process is currently running and alive.
  """
  @spec desktop_window_alive?() :: boolean()
  def desktop_window_alive? do
    case Application.get_env(:iex_code, :desktop_window_id, IexCodeWindow) do
      pid when is_pid(pid) ->
        Process.alive?(pid)

      name when is_atom(name) ->
        case Process.whereis(name) do
          pid when is_pid(pid) -> Process.alive?(pid)
          _ -> false
        end

      _ ->
        false
    end
  end

  @doc """
  Checks whether desktop notifications are enabled in application configuration.
  """
  @spec notifications_enabled?() :: boolean()
  def notifications_enabled? do
    Application.get_env(:iex_code, :desktop_notifications_enabled, true)
  end

  defp sanitize_desktop_opts(opts) do
    type =
      case Keyword.get(opts, :type, :info) do
        :error -> :error
        t when t in [:warning, :warn] -> :warning
        _ -> :info
      end

    opts
    |> Keyword.put(:type, type)
    |> Keyword.delete(:sound)
  end

  defp log_fallback(text, opts) do
    title = Keyword.get(opts, :title, "IexCode")
    type = Keyword.get(opts, :type, :info)

    message = "[Desktop Notification Fallback] [#{type}] #{title}: #{text}"

    case type do
      :error ->
        Logger.error(message)

      t when t in [:warning, :warn] ->
        Logger.warning(message)

      _ ->
        Logger.info(message)
    end
  end
end
