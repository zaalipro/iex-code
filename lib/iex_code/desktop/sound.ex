defmodule IexCode.Desktop.Sound do
  @moduledoc """
  Plays native macOS sound cues for swarm lifecycle events via `/usr/bin/afplay`.

  Gracefully falls back to a silent `:ok` in test, headless, and non-macOS environments.
  """
  require Logger

  @sound_map %{
    # Swarm lifecycle events
    swarm_completed: "/System/Library/Sounds/Hero.aiff",
    verification_rejected: "/System/Library/Sounds/Sosumi.aiff",
    step_failed: "/System/Library/Sounds/Basso.aiff",
    approval_requested: "/System/Library/Sounds/Ping.aiff",
    # Direct sound names
    hero: "/System/Library/Sounds/Hero.aiff",
    sosumi: "/System/Library/Sounds/Sosumi.aiff",
    basso: "/System/Library/Sounds/Basso.aiff",
    ping: "/System/Library/Sounds/Ping.aiff",
    glass: "/System/Library/Sounds/Glass.aiff",
    bottle: "/System/Library/Sounds/Bottle.aiff",
    funk: "/System/Library/Sounds/Funk.aiff"
  }

  @doc """
  Plays an auditory cue corresponding to a swarm event type or sound name.

  Options:
    * `:force` - overrides test and environment checks (useful for testing execution)
    * `:executable` - custom path to afplay or mock binary
  """
  @spec play(atom() | String.t(), keyword()) :: :ok
  def play(event_type, opts \\ []) do
    if should_play?(opts) do
      sound_path = resolve_path(event_type)

      if sound_path && File.exists?(sound_path) do
        afplay = Keyword.get(opts, :executable) || resolve_afplay()

        if afplay do
          spawn_playback(afplay, sound_path)
        end
      end
    end

    :ok
  end

  @doc """
  Resolves the path to the sound file for a given event type, sound name, or file path.
  """
  @spec resolve_path(atom() | String.t()) :: String.t() | nil
  def resolve_path(event_type) when is_atom(event_type) do
    Map.get(@sound_map, event_type)
  end

  def resolve_path(path) when is_binary(path) do
    if File.exists?(path), do: path, else: nil
  end

  def resolve_path(_), do: nil

  @doc """
  Resolves the path to the sound file for a given swarm lifecycle event.
  Alias for `resolve_path/1`.
  """
  @spec sound_path_for_event(atom() | String.t()) :: String.t() | nil
  def sound_path_for_event(event_type), do: resolve_path(event_type)

  @doc """
  Returns the mapping of swarm events to sound files.
  """
  @spec sound_map() :: %{optional(atom()) => String.t()}
  def sound_map, do: @sound_map

  @doc """
  Checks whether sound cues should be played based on platform, test environment, and config.
  Accepts either options keyword list, an event atom, or both: `should_play?(event, opts)`.
  """
  @spec should_play?(atom() | keyword(), keyword()) :: boolean()
  def should_play?(event_or_opts \\ [], opts \\ [])

  def should_play?(event, opts) when is_atom(event) and not is_nil(event) and is_list(opts) do
    should_play?(opts)
  end

  def should_play?(opts, _extra) when is_list(opts) do
    cond do
      Keyword.get(opts, :force, false) ->
        true

      test_env?() ->
        false

      not sound_enabled?() ->
        false

      not macos?() ->
        false

      true ->
        true
    end
  end

  @doc """
  Returns true if running on macOS (Darwin).
  """
  @spec macos?() :: boolean()
  def macos? do
    match?({:unix, :darwin}, :os.type())
  end

  @doc """
  Returns true if executing inside the Mix test environment.
  """
  @spec test_env?() :: boolean()
  def test_env? do
    if Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) do
      Mix.env() == :test
    else
      System.get_env("MIX_ENV") == "test"
    end
  end

  @doc """
  Checks if desktop sound is enabled in application configuration.
  """
  @spec sound_enabled?() :: boolean()
  def sound_enabled? do
    Application.get_env(:iex_code, :desktop_sound_enabled, true)
  end

  defp resolve_afplay do
    Application.get_env(:iex_code, :afplay_executable) ||
      cond do
        File.exists?("/usr/bin/afplay") -> "/usr/bin/afplay"
        exec = System.find_executable("afplay") -> exec
        true -> nil
      end
  end

  defp spawn_playback(executable, path) do
    supervisor = Application.get_env(:iex_code, :task_supervisor, IexCode.TaskSupervisor)
    args = ["-t", "5", path]

    if Process.whereis(supervisor) do
      Task.Supervisor.start_child(supervisor, fn ->
        try do
          System.cmd(executable, args, stderr_to_stdout: true)
        rescue
          e ->
            Logger.debug("Desktop sound playback error: #{inspect(e)}")
            :ok
        end
      end)
    else
      Task.start(fn ->
        try do
          System.cmd(executable, args, stderr_to_stdout: true)
        rescue
          _ -> :ok
        end
      end)
    end
  end
end
