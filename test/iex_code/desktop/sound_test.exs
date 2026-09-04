defmodule IexCode.Desktop.SoundTest do
  use ExUnit.Case, async: false

  alias IexCode.Desktop.Sound

  setup do
    original_enabled = Application.get_env(:iex_code, :desktop_sound_enabled)
    original_executable = Application.get_env(:iex_code, :afplay_executable)

    on_exit(fn ->
      Application.put_env(:iex_code, :desktop_sound_enabled, original_enabled)
      Application.put_env(:iex_code, :afplay_executable, original_executable)
    end)

    :ok
  end

  describe "Sound Mappings for Swarm Lifecycle Events" do
    test "resolves all four required swarm lifecycle events to valid macOS system sounds" do
      assert Sound.resolve_path(:swarm_completed) == "/System/Library/Sounds/Hero.aiff"
      assert Sound.resolve_path(:verification_rejected) == "/System/Library/Sounds/Sosumi.aiff"
      assert Sound.resolve_path(:step_failed) == "/System/Library/Sounds/Basso.aiff"
      assert Sound.resolve_path(:approval_requested) == "/System/Library/Sounds/Ping.aiff"
    end

    test "resolves direct sound names to standard system sound paths" do
      assert Sound.resolve_path(:hero) == "/System/Library/Sounds/Hero.aiff"
      assert Sound.resolve_path(:sosumi) == "/System/Library/Sounds/Sosumi.aiff"
      assert Sound.resolve_path(:basso) == "/System/Library/Sounds/Basso.aiff"
      assert Sound.resolve_path(:ping) == "/System/Library/Sounds/Ping.aiff"
      assert Sound.resolve_path(:glass) == "/System/Library/Sounds/Glass.aiff"
      assert Sound.resolve_path(:bottle) == "/System/Library/Sounds/Bottle.aiff"
      assert Sound.resolve_path(:funk) == "/System/Library/Sounds/Funk.aiff"
    end

    test "resolves arbitrary binary sound file path if file exists" do
      temp_path =
        Path.join(System.tmp_dir!(), "test_sound_#{System.unique_integer([:positive])}.aiff")

      File.write!(temp_path, "mock_audio_data")

      try do
        assert Sound.resolve_path(temp_path) == temp_path
      after
        File.rm(temp_path)
      end
    end

    test "returns nil for non-existent file or unknown atom" do
      assert Sound.resolve_path(:non_existent_sound_key) == nil
      assert Sound.resolve_path("/invalid/path/that/does/not/exist.aiff") == nil
      assert Sound.resolve_path(12345) == nil
    end

    test "verifies that the target system sound files exist on macOS filesystem" do
      if Sound.macos?() do
        for event <- [:swarm_completed, :verification_rejected, :step_failed, :approval_requested] do
          sound_path = Sound.resolve_path(event)
          assert sound_path != nil
          assert File.exists?(sound_path), "Expected #{sound_path} to exist on macOS"
        end
      end
    end
  end

  describe "Headless and Test Environment Fallback" do
    test "test_env?/0 detects the test environment" do
      assert Sound.test_env?()
    end

    test "should_play?/0 returns false during tests to prevent unmuted audio" do
      refute Sound.should_play?()
    end

    test "should_play?/0 returns false when desktop_sound_enabled is false" do
      Application.put_env(:iex_code, :desktop_sound_enabled, false)
      refute Sound.should_play?()
    end

    test "play/2 returns :ok silently in test mode without spawning afplay" do
      assert :ok == Sound.play(:swarm_completed)
      assert :ok == Sound.play(:verification_rejected)
      assert :ok == Sound.play(:step_failed)
      assert :ok == Sound.play(:approval_requested)
    end
  end

  describe "Supervised Playback Task Spawning" do
    test "spawns background task under TaskSupervisor when forced" do
      # Use /usr/bin/true as a benign mock executable to verify background task spawning
      mock_bin = System.find_executable("true") || "/usr/bin/true"
      Application.put_env(:iex_code, :afplay_executable, mock_bin)

      # Ensure TaskSupervisor is running
      assert Process.whereis(IexCode.TaskSupervisor) != nil

      assert :ok == Sound.play(:swarm_completed, force: true)
      assert :ok == Sound.play(:verification_rejected, force: true)
      assert :ok == Sound.play(:step_failed, force: true)
      assert :ok == Sound.play(:approval_requested, force: true)
    end

    test "spawns playback with volume option" do
      mock_bin = System.find_executable("true") || "/usr/bin/true"
      Application.put_env(:iex_code, :afplay_executable, mock_bin)

      assert :ok == Sound.play("hero", force: true, volume: 50)
      assert :ok == Sound.play(:ping, force: true, volume: 0)
    end
  end

  describe "PubSub Broadcast & Volume Ergonomics" do
    test "broadcasts {:play_sound, chime, volume} on desktop:sound topic" do
      Phoenix.PubSub.subscribe(IexCode.PubSub, "desktop:sound")

      Sound.play(:hero, volume: 65)

      assert_receive {:play_sound, "hero", 65}
    end

    test "should_play?/1 returns false when volume is 0" do
      refute Sound.should_play?(volume: 0)
    end

    test "resolves string chime names" do
      assert Sound.resolve_path("hero") == "/System/Library/Sounds/Hero.aiff"
      assert Sound.resolve_path("ping") == "/System/Library/Sounds/Ping.aiff"
      assert Sound.resolve_path("basso") == "/System/Library/Sounds/Basso.aiff"
    end
  end
end
