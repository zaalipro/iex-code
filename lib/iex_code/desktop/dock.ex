defmodule IexCode.Desktop.Dock do
  @moduledoc """
  Manages dynamic macOS Dock icon agent activity badging and window title updates.

  Tracks active worker count and waiting approval count, updating:
  - macOS application Dock badge (via Cocoa / OSC terminal escape sequence)
  - Native window title (via `Desktop.Window.set_title/2` when window is alive)
  - Phoenix LiveView page title and subscribers via PubSub topic `"desktop:activity"`
  """
  use GenServer
  require Logger

  alias IexCode.Desktop.Notifier
  alias Phoenix.PubSub

  @default_base_title "IexCode - Desktop AI Coding Harness"
  @pubsub IexCode.PubSub
  @topic "desktop:activity"

  @type activity :: %{
          running: non_neg_integer(),
          waiting: non_neg_integer(),
          badge: String.t(),
          title: String.t()
        }

  defstruct running: 0,
            waiting: 0,
            badge: "",
            title: @default_base_title,
            base_title: @default_base_title

  # --- Client API ---

  @doc """
  Starts the Dock activity manager GenServer.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Sets the active worker count and waiting approval count, updating the
  window title, dock badge, and broadcasting to `"desktop:activity"`.
  """
  @spec set_activity(integer(), integer()) :: :ok
  def set_activity(running_count, waiting_count)
      when is_integer(running_count) and is_integer(waiting_count) do
    set_activity(__MODULE__, running_count, waiting_count)
  end

  @doc """
  Sets the active worker count and waiting approval count on a specific Dock process.
  """
  @spec set_activity(GenServer.server(), integer(), integer()) :: :ok
  def set_activity(server, running_count, waiting_count)
      when is_integer(running_count) and is_integer(waiting_count) do
    if is_pid(server) or (is_atom(server) and Process.whereis(server)) do
      GenServer.call(server, {:set_activity, running_count, waiting_count})
    else
      # If GenServer is not running, compute and apply side-effects directly
      do_apply_activity(running_count, waiting_count, @default_base_title)
      :ok
    end
  end

  @doc """
  Returns the current activity state map:
    %{running: integer(), waiting: integer(), badge: String.t(), title: String.t()}
  """
  @spec get_activity(GenServer.server()) :: activity()
  def get_activity(server \\ __MODULE__) do
    if is_pid(server) or (is_atom(server) and Process.whereis(server)) do
      GenServer.call(server, :get_activity)
    else
      %{
        running: 0,
        waiting: 0,
        badge: "",
        title: @default_base_title
      }
    end
  end

  @doc """
  Resets activity to 0 running, 0 waiting.
  """
  @spec clear(GenServer.server()) :: :ok
  def clear(server \\ __MODULE__) do
    set_activity(server, 0, 0)
  end

  # --- Pure Computation Helpers ---

  @doc """
  Computes the window title based on running and waiting counts.
  """
  @spec compute_title(integer(), integer(), String.t()) :: String.t()
  def compute_title(running, waiting, base_title \\ @default_base_title) do
    r = max(0, running)
    w = max(0, waiting)

    if r == 0 and w == 0 do
      base_title
    else
      "IexCode - #{r} running, #{w} waiting"
    end
  end

  @doc """
  Computes the Dock badge string from running and waiting counts:
  - `""` when 0 running and 0 waiting
  - `"\#{running}R/\#{waiting}W"` when both are positive
  - `"\#{running}"` when only running is positive
  - `"\#{waiting}"` when only waiting is positive
  """
  @spec compute_badge(integer(), integer()) :: String.t()
  def compute_badge(running, waiting) do
    r = max(0, running)
    w = max(0, waiting)

    cond do
      r == 0 and w == 0 ->
        ""

      r > 0 and w > 0 ->
        "#{r}R/#{w}W"

      r > 0 ->
        "#{r}"

      w > 0 ->
        "#{w}"
    end
  end

  # --- System & Window Application Handlers ---

  @doc """
  Updates the native `Desktop.Window` title if running.
  """
  @spec apply_window_title(String.t()) :: :ok
  def apply_window_title(title) when is_binary(title) do
    if Notifier.desktop_window_alive?() do
      window_id = Application.get_env(:iex_code, :desktop_window_id, IexCodeWindow)

      try do
        Desktop.Window.set_title(window_id, title)
      rescue
        _ -> :ok
      end
    end

    :ok
  end

  @doc """
  Applies the Dock badge text via terminal OSC sequence or AppleScript.
  Guarded by headless and test safety checks so it never blocks or fails in tests.
  """
  @spec apply_dock_badge(String.t(), keyword()) :: :ok
  def apply_dock_badge(badge, opts \\ []) when is_binary(badge) do
    if should_apply_dock_badge?(opts) do
      # 1. OSC 1337 terminal escape sequence (supported by modern macOS terminals)
      if terminal_supported?() do
        encoded = Base.encode64(badge)
        IO.write(:stderr, "\e]1337;SetBadgeLabel=#{encoded}\a")
      end

      # 2. AppleScript / osascript background task if running on macOS in desktop mode
      if desktop_mode?() and System.find_executable("osascript") != nil do
        Task.Supervisor.start_child(IexCode.TaskSupervisor, fn ->
          safe_osascript_badge(badge)
        end)
      end
    end

    :ok
  end

  @doc """
  Broadcasts activity state to the `"desktop:activity"` PubSub topic.
  """
  @spec broadcast_activity(activity()) :: :ok
  def broadcast_activity(activity) when is_map(activity) do
    if Process.whereis(@pubsub) do
      PubSub.broadcast(@pubsub, @topic, {:dock_activity_updated, activity})
    end

    :ok
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    base_title = Keyword.get(opts, :base_title, @default_base_title)
    running = Keyword.get(opts, :running, 0)
    waiting = Keyword.get(opts, :waiting, 0)

    badge = compute_badge(running, waiting)
    title = compute_title(running, waiting, base_title)

    state = %__MODULE__{
      running: running,
      waiting: waiting,
      badge: badge,
      title: title,
      base_title: base_title
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:set_activity, running_count, waiting_count}, _from, state) do
    activity = do_apply_activity(running_count, waiting_count, state.base_title)

    new_state = %{
      state
      | running: activity.running,
        waiting: activity.waiting,
        badge: activity.badge,
        title: activity.title
    }

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:get_activity, _from, state) do
    activity = %{
      running: state.running,
      waiting: state.waiting,
      badge: state.badge,
      title: state.title
    }

    {:reply, activity, state}
  end

  @impl true
  def handle_cast({:set_activity, running_count, waiting_count}, state) do
    activity = do_apply_activity(running_count, waiting_count, state.base_title)

    new_state = %{
      state
      | running: activity.running,
        waiting: activity.waiting,
        badge: activity.badge,
        title: activity.title
    }

    {:noreply, new_state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Internal Helpers ---

  defp do_apply_activity(running_count, waiting_count, base_title) do
    r = max(0, running_count)
    w = max(0, waiting_count)
    badge = compute_badge(r, w)
    title = compute_title(r, w, base_title)

    activity = %{
      running: r,
      waiting: w,
      badge: badge,
      title: title
    }

    apply_window_title(title)
    apply_dock_badge(badge)
    broadcast_activity(activity)

    activity
  end

  defp should_apply_dock_badge?(opts) do
    force? = Keyword.get(opts, :force, false)

    if force? do
      true
    else
      macos?() and not test_env?() and not headless?() and dock_badge_enabled?()
    end
  end

  defp macos? do
    match?({:unix, :darwin}, :os.type())
  end

  defp test_env? do
    Application.get_env(:iex_code, :env) == :test or
      System.get_env("MIX_ENV") == "test"
  end

  defp headless? do
    System.get_env("CI") == "true" or
      System.get_env("HEADLESS") == "true"
  end

  defp dock_badge_enabled? do
    Application.get_env(:iex_code, :desktop_dock_badge_enabled, true)
  end

  defp desktop_mode? do
    Notifier.desktop_window_alive?() or
      Application.get_env(:iex_code, :desktop_mode, false)
  end

  defp terminal_supported? do
    term = System.get_env("TERM_PROGRAM")
    term in ["iTerm.app", "ghostty", "Apple_Terminal", "WezTerm"]
  end

  defp safe_osascript_badge(badge) do
    try do
      script =
        if badge == "" do
          "tell application \"System Events\" to set badge of current application to \"\""
        else
          "tell application \"System Events\" to set badge of current application to \"#{escape_applescript(badge)}\""
        end

      System.cmd("osascript", ["-e", script], stderr_to_stdout: true)
    rescue
      _ -> :ok
    end
  end

  defp escape_applescript(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end
end
