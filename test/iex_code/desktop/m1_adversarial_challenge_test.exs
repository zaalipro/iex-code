defmodule IexCode.Desktop.M1AdversarialChallengeTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias IexCode.Desktop.{Notifier, Sound, SwarmHooks}
  alias Phoenix.PubSub

  setup do
    original_window_id = Application.get_env(:iex_code, :desktop_window_id)
    original_notifications = Application.get_env(:iex_code, :desktop_notifications_enabled)
    original_sound = Application.get_env(:iex_code, :desktop_sound_enabled)
    original_executable = Application.get_env(:iex_code, :afplay_executable)

    on_exit(fn ->
      Application.put_env(:iex_code, :desktop_window_id, original_window_id)
      Application.put_env(:iex_code, :desktop_notifications_enabled, original_notifications)
      Application.put_env(:iex_code, :desktop_sound_enabled, original_sound)
      Application.put_env(:iex_code, :afplay_executable, original_executable)
    end)

    :ok
  end

  describe "1. Headless Safety and ArgumentError Prevention" do
    test "desktop_window_alive?/0 returns false safely for unregistered atom without ArgumentError" do
      Application.put_env(:iex_code, :desktop_window_id, :unregistered_ghost_window_999)
      refute Notifier.desktop_window_alive?()
    end

    test "notify/2 returns {:ok, :fallback} and never raises ArgumentError in headless mode" do
      Application.put_env(:iex_code, :desktop_window_id, :unregistered_ghost_window_999)

      # Test standard calls
      assert {:ok, :fallback} = Notifier.notify("Headless check", title: "Info", type: :info)
      assert {:ok, :fallback} = Notifier.notify("Headless warning", title: "Warn", type: :warning)
      assert {:ok, :fallback} = Notifier.notify("Headless error", title: "Err", type: :error)

      # Test extreme and edge case payloads
      assert {:ok, :fallback} = Notifier.notify("", title: "", type: :info)
      huge_text = String.duplicate("Massive Swarm Payload ", 1000)
      assert {:ok, :fallback} = Notifier.notify(huge_text, title: "Huge", type: :error)

      # Non-standard options
      assert {:ok, :fallback} =
               Notifier.notify("Edge opts", type: :unrecognized_type, timeout: -500)

      assert {:ok, :fallback} = Notifier.notify("Nil title", title: nil, sound: :hero)
    end

    test "dismiss/1 never raises ArgumentError when window is not running" do
      Application.put_env(:iex_code, :desktop_window_id, :unregistered_ghost_window_999)
      assert :ok == Notifier.dismiss(:any_id)
      assert :ok == Notifier.dismiss("string_id")
      assert :ok == Notifier.dismiss(nil)
    end

    test "fallback logging works correctly across all severities without failing" do
      Application.put_env(:iex_code, :desktop_window_id, :unregistered_ghost_window_999)

      log =
        capture_log(fn ->
          Notifier.notify("Error msg", type: :error, title: "ErrTitle")
          Notifier.notify("Warning msg", type: :warning, title: "WarnTitle")
          Notifier.notify("Warn alias msg", type: :warn, title: "WarnAlias")
        end)

      assert log =~ "[Desktop Notification Fallback] [error] ErrTitle: Error msg"
      assert log =~ "[Desktop Notification Fallback] [warning] WarnTitle: Warning msg"
      assert log =~ "[Desktop Notification Fallback] [warn] WarnAlias: Warn alias msg"
    end

    test "concurrent burst of 100 events in headless mode updates state without crash" do
      Application.put_env(:iex_code, :desktop_window_id, :unregistered_ghost_window_999)

      tasks =
        for i <- 1..100 do
          Task.async(fn ->
            event =
              case rem(i, 4) do
                0 -> :swarm_completed
                1 -> :verification_rejected
                2 -> :step_failed
                3 -> :approval_requested
              end

            SwarmHooks.dispatch_event(event, %{
              title: "Task #{i}",
              reason: "Reason #{i}",
              action: "Action #{i}"
            })
          end)
        end

      results = Task.await_many(tasks, 5000)

      for res <- results do
        assert {:ok, event} = res

        assert event in [
                 :swarm_completed,
                 :verification_rejected,
                 :step_failed,
                 :approval_requested
               ]
      end

      counts = SwarmHooks.get_event_counts()

      total =
        counts.swarm_completed + counts.verification_rejected + counts.step_failed +
          counts.approval_requested

      assert total >= 100
    end
  end

  describe "2. Test Isolation and Audio Silence Guarantee" do
    test "test_env?/0 returns true during ExUnit test run" do
      assert Sound.test_env?() == true
    end

    test "should_play?/0 strictly returns false during tests even if desktop_sound_enabled is true" do
      Application.put_env(:iex_code, :desktop_sound_enabled, true)
      assert Sound.sound_enabled?() == true
      # Must still return false because test_env?() takes priority
      refute Sound.should_play?()
    end

    test "should_play?/0 strictly returns false if desktop_sound_enabled is false" do
      Application.put_env(:iex_code, :desktop_sound_enabled, false)
      refute Sound.should_play?()
    end

    test "play/2 returns :ok silently for all lifecycle events without playing audio" do
      for event <- [:swarm_completed, :verification_rejected, :step_failed, :approval_requested] do
        assert :ok == Sound.play(event)
      end
    end

    test "play/2 returns :ok silently for direct sound names and invalid inputs" do
      for sound <- [:hero, :sosumi, :basso, :ping, :glass, :bottle, :funk, :unknown, nil, 1234] do
        assert :ok == Sound.play(sound)
      end
    end

    test "only force: true bypasses test silence" do
      refute Sound.should_play?(force: false)
      refute Sound.should_play?([])
      assert Sound.should_play?(force: true)
    end

    test "forced playback handles missing binary or execution failure gracefully without crashing" do
      Application.put_env(:iex_code, :afplay_executable, "/bin/non_existent_binary_xyz")

      assert :ok == Sound.play(:swarm_completed, force: true)
      assert :ok == Sound.play("/path/to/missing/audio.aiff", force: true)
    end
  end

  describe "3. Mock Desktop Window Behavior and Contract Verification" do
    setup do
      test_pid = self()

      mock_window =
        spawn_link(fn ->
          mock_receiver(test_pid)
        end)

      mock_name = :"mock_window_m1_adv_#{System.unique_integer([:positive])}"
      Process.register(mock_window, mock_name)
      Application.put_env(:iex_code, :desktop_window_id, mock_name)
      Application.put_env(:iex_code, :desktop_notifications_enabled, true)

      {:ok, mock_window: mock_window, mock_name: mock_name}
    end

    test "delivers :info notification with title 'Swarm Goal Completed' and timeout -1 on swarm_completed" do
      SwarmHooks.dispatch_event(:swarm_completed, %{title: "All tests green"})

      assert_receive {:"$gen_cast",
                      {:show_notification, "Swarm goal completed: All tests green", :default,
                       :info, "Swarm Goal Completed", nil, -1}},
                     1000
    end

    test "delivers :warning notification with title 'Verification Rejected' and timeout -1 on verification_rejected" do
      SwarmHooks.dispatch_event(:verification_rejected, %{reason: "Assertion failed on line 42"})

      assert_receive {:"$gen_cast",
                      {:show_notification, "Verification rejected: Assertion failed on line 42",
                       :default, :warning, "Verification Rejected", nil, -1}},
                     1000
    end

    test "delivers :error notification with title 'Swarm Step Failed' and timeout -1 on step_failed" do
      SwarmHooks.dispatch_event(:step_failed, %{error_message: "Compilation error: syntax error"})

      assert_receive {:"$gen_cast",
                      {:show_notification, "Step failed: Compilation error: syntax error",
                       :default, :error, "Swarm Step Failed", nil, -1}},
                     1000
    end

    test "delivers :warning notification with title 'Approval Required' and timeout -1 on approval_requested" do
      SwarmHooks.dispatch_event(:approval_requested, %{
        action: "Deploy to production",
        reason: "Milestone complete"
      })

      assert_receive {:"$gen_cast",
                      {:show_notification,
                       "Approval needed for Deploy to production: Milestone complete", :default,
                       :warning, "Approval Required", nil, -1}},
                     1000
    end

    test "preserves custom title, severity type, id, and timeout options in Notifier.notify/2" do
      assert :ok ==
               Notifier.notify("Custom notification text",
                 title: "Custom Title",
                 type: :error,
                 id: :unique_notice_42,
                 timeout: 4500
               )

      assert_receive {:"$gen_cast",
                      {:show_notification, "Custom notification text", :unique_notice_42, :error,
                       "Custom Title", nil, 4500}},
                     1000
    end

    test "maps timeout: :never to 0 and timeout: :auto to -1" do
      Notifier.notify("Never dismiss", title: "NeverTitle", timeout: :never, id: :notice_never)

      assert_receive {:"$gen_cast",
                      {:show_notification, "Never dismiss", :notice_never, :info, "NeverTitle",
                       nil, 0}},
                     1000

      Notifier.notify("Auto dismiss", title: "AutoTitle", timeout: :auto, id: :notice_auto)

      assert_receive {:"$gen_cast",
                      {:show_notification, "Auto dismiss", :notice_auto, :info, "AutoTitle", nil,
                       -1}},
                     1000
    end

    test "dismiss/1 dispatches dismiss_notification cast to window" do
      assert :ok == Notifier.dismiss(:unique_notice_42)
      assert_receive {:"$gen_cast", {:dismiss_notification, :unique_notice_42}}, 1000
    end

    test "handles string-keyed payload maps across all 4 events" do
      # String-keyed title
      SwarmHooks.dispatch_event(:swarm_completed, %{"title" => "String key completed"})

      assert_receive {:"$gen_cast",
                      {:show_notification, "Swarm goal completed: String key completed", :default,
                       :info, "Swarm Goal Completed", nil, -1}},
                     1000

      # String-keyed summary
      SwarmHooks.dispatch_event(:verification_rejected, %{"summary" => "String key reject"})

      assert_receive {:"$gen_cast",
                      {:show_notification, "Verification rejected: String key reject", :default,
                       :warning, "Verification Rejected", nil, -1}},
                     1000

      # String-keyed error_message
      SwarmHooks.dispatch_event(:step_failed, %{"error_message" => "String key step error"})

      assert_receive {:"$gen_cast",
                      {:show_notification, "Step failed: String key step error", :default, :error,
                       "Swarm Step Failed", nil, -1}},
                     1000

      # String-keyed action & reason
      SwarmHooks.dispatch_event(:approval_requested, %{
        "action" => "String key action",
        "reason" => "String key reason"
      })

      assert_receive {:"$gen_cast",
                      {:show_notification,
                       "Approval needed for String key action: String key reason", :default,
                       :warning, "Approval Required", nil, -1}},
                     1000
    end

    test "handles raw string and malformed/empty payloads safely" do
      # Raw string payload
      SwarmHooks.dispatch_event(:swarm_completed, "Direct string completion message")

      assert_receive {:"$gen_cast",
                      {:show_notification, "Direct string completion message", :default, :info,
                       "Swarm Goal Completed", nil, -1}},
                     1000

      # Empty map payload uses default fallback text
      SwarmHooks.dispatch_event(:verification_rejected, %{})

      assert_receive {:"$gen_cast",
                      {:show_notification,
                       "Verification checks failed. Triggering diagnostic and self-healing phase.",
                       :default, :warning, "Verification Rejected", nil, -1}},
                     1000

      # Arbitrary unexpected payload
      SwarmHooks.dispatch_event(:step_failed, 9999)

      assert_receive {:"$gen_cast",
                      {:show_notification, "A step in the swarm execution pipeline failed.",
                       :default, :error, "Swarm Step Failed", nil, -1}},
                     1000
    end

    test "strips sound option before sending cast to Desktop.Window" do
      Notifier.notify("Audio cue notification",
        title: "SoundTest",
        sound: :hero,
        id: :audio_notice
      )

      assert_receive {:"$gen_cast",
                      {:show_notification, "Audio cue notification", :audio_notice, :info,
                       "SoundTest", nil, -1}},
                     1000
    end
  end

  describe "4. PubSub Lifecycle Event Routing" do
    test "subscribes and handles events across swarm:lifecycle and desktop:lifecycle" do
      log =
        capture_info_log(fn ->
          PubSub.broadcast(
            IexCode.PubSub,
            "swarm:lifecycle",
            {:swarm_completed, %{title: "PubSub complete"}}
          )

          PubSub.broadcast(
            IexCode.PubSub,
            "desktop:lifecycle",
            {:verification_rejected, %{reason: "PubSub reject"}}
          )

          PubSub.broadcast(
            IexCode.PubSub,
            "desktop:lifecycle",
            {:step_failed, %{error_message: "PubSub step fail"}}
          )

          PubSub.broadcast(
            IexCode.PubSub,
            "desktop:lifecycle",
            {:approval_requested, %{action: "PubSub approval"}}
          )

          _ = :sys.get_state(Process.whereis(SwarmHooks))
        end)

      assert log =~ "Swarm goal completed: PubSub complete"
      assert log =~ "Verification rejected: PubSub reject"
      assert log =~ "Step failed: PubSub step fail"
      assert log =~ "Approval needed for PubSub approval"
    end

    test "ignores unhandled messages without crashing SwarmHooks GenServer" do
      pid = Process.whereis(SwarmHooks)
      assert Process.alive?(pid)

      send(pid, :unexpected_atom)
      send(pid, {:unexpected_tuple, 1, 2})
      send(pid, "unexpected_string")

      _ = :sys.get_state(pid)
      assert Process.alive?(pid)
    end
  end

  defp mock_receiver(forward_to) do
    receive do
      msg ->
        send(forward_to, msg)
        mock_receiver(forward_to)
    end
  end

  defp capture_info_log(fun) do
    prev = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log(fun)
    after
      Logger.configure(level: prev)
    end
  end
end
