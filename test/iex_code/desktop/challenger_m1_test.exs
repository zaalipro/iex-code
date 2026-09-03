defmodule IexCode.Desktop.ChallengerM1Test do
  @moduledoc """
  Empirical stress and edge-case challenge suite for Milestone 1:
  Native macOS System Notifications & Sound Cues on Swarm Lifecycle Events.
  """
  use ExUnit.Case, async: false

  alias IexCode.Desktop.{Notifier, Sound, SwarmHooks}
  alias Phoenix.PubSub

  setup do
    original_window_id = Application.get_env(:iex_code, :desktop_window_id)
    original_notifications = Application.get_env(:iex_code, :desktop_notifications_enabled)
    original_sound = Application.get_env(:iex_code, :desktop_sound_enabled)
    original_exec = Application.get_env(:iex_code, :afplay_executable)

    on_exit(fn ->
      Application.put_env(:iex_code, :desktop_window_id, original_window_id)
      Application.put_env(:iex_code, :desktop_notifications_enabled, original_notifications)
      Application.put_env(:iex_code, :desktop_sound_enabled, original_sound)
      Application.put_env(:iex_code, :afplay_executable, original_exec)
    end)

    :ok
  end

  # ===========================================================================
  # 1. NOTIFIER STRESS & EDGE CASES
  # ===========================================================================

  describe "1. Notifier Edge Cases & Stress" do
    test "rapid-fire fallback notifications under high volume (1,000 dispatches)" do
      Application.put_env(:iex_code, :desktop_window_id, :non_existent_window)

      tasks =
        for i <- 1..1000 do
          Task.async(fn ->
            Notifier.notify("Rapid message #{i}",
              title: "Burst Test",
              type: if(rem(i, 2) == 0, do: :info, else: :warning)
            )
          end)
        end

      results = Task.await_many(tasks, 10_000)

      assert length(results) == 1000
      assert Enum.all?(results, &(&1 == {:ok, :fallback}))
    end

    test "rapid-fire active window notifications (1,000 dispatches to mock window)" do
      test_pid = self()

      mock_window =
        spawn_link(fn ->
          mock_drain_loop(test_pid, 0)
        end)

      mock_name = :"mock_rapid_window_#{System.unique_integer([:positive])}"
      Process.register(mock_window, mock_name)
      Application.put_env(:iex_code, :desktop_window_id, mock_name)
      Application.put_env(:iex_code, :desktop_notifications_enabled, true)

      tasks =
        for i <- 1..1000 do
          Task.async(fn ->
            Notifier.notify("Active rapid message #{i}",
              title: "Window Burst",
              type: :info,
              id: :"burst_#{i}"
            )
          end)
        end

      results = Task.await_many(tasks, 10_000)
      assert Enum.all?(results, &(&1 == :ok))

      send(mock_window, {:get_count, self()})
      assert_receive {:received_count, 1000}, 5000
    end

    test "empty message string is safely accepted" do
      Application.put_env(:iex_code, :desktop_window_id, :non_existent_window)
      assert {:ok, :fallback} = Notifier.notify("")
      assert {:ok, :fallback} = Notifier.notify("", title: "")
    end

    test "nil message string raises FunctionClauseError" do
      assert_raise FunctionClauseError, fn ->
        Notifier.notify(nil)
      end
    end

    test "nil or non-list options raise FunctionClauseError" do
      assert_raise FunctionClauseError, fn ->
        Notifier.notify("Valid text", nil)
      end

      assert_raise FunctionClauseError, fn ->
        Notifier.notify("Valid text", %{title: "bad map opts"})
      end
    end

    test "invalid option types and exotic flags are sanitized for Desktop.Window" do
      test_pid = self()

      mock_window =
        spawn_link(fn ->
          mock_drain_loop(test_pid, 0)
        end)

      mock_name = :"mock_opt_window_#{System.unique_integer([:positive])}"
      Process.register(mock_window, mock_name)
      Application.put_env(:iex_code, :desktop_window_id, mock_name)
      Application.put_env(:iex_code, :desktop_notifications_enabled, true)

      assert :ok ==
               Notifier.notify("Exotic type",
                 title: "Sanitize Test",
                 type: :super_critical_fatal,
                 custom_unknown_flag: 12345
               )

      assert_receive {:"$gen_cast",
                      {:show_notification, "Exotic type", :default, :info, "Sanitize Test", nil,
                       -1}},
                     1000
    end

    test "desktop_window_alive? safely handles live and dead PIDs without crashing" do
      live_pid = spawn_link(fn -> receive do: (_ -> :ok) end)
      Application.put_env(:iex_code, :desktop_window_id, live_pid)
      assert Notifier.desktop_window_alive?()

      dead_pid = spawn(fn -> :ok end)
      ref = Process.monitor(dead_pid)
      assert_receive {:DOWN, ^ref, :process, ^dead_pid, :normal}

      Application.put_env(:iex_code, :desktop_window_id, dead_pid)
      refute Notifier.desktop_window_alive?()

      # Arbitrary non-atom types safely return false
      Application.put_env(:iex_code, :desktop_window_id, "window_as_string")
      refute Notifier.desktop_window_alive?()

      Application.put_env(:iex_code, :desktop_window_id, 12345)
      refute Notifier.desktop_window_alive?()
    end

    test "finding 4: unsanitized timeout option raises CaseClauseError when window is active" do
      test_pid = self()
      mock_window = spawn_link(fn -> mock_drain_loop(test_pid, 0) end)
      mock_name = :"mock_timeout_win_#{System.unique_integer([:positive])}"
      Process.register(mock_window, mock_name)
      Application.put_env(:iex_code, :desktop_window_id, mock_name)
      Application.put_env(:iex_code, :desktop_notifications_enabled, true)

      assert_raise CaseClauseError, fn ->
        Notifier.notify("Invalid timeout text", timeout: :invalid_timeout)
      end
    end

    test "non-existent window registered atoms safely return fallback" do
      Application.put_env(:iex_code, :desktop_window_id, :absolutely_non_existent_atom_xyz)
      refute Notifier.desktop_window_alive?()
      assert {:ok, :fallback} = Notifier.notify("Safe fallback")
    end
  end

  # ===========================================================================
  # 2. SOUND STRESS & EDGE CASES
  # ===========================================================================

  describe "2. Sound Edge Cases & Stress" do
    test "rapid-fire sound calls in unmuted test mode (1,000 calls)" do
      tasks =
        for _ <- 1..1000 do
          Task.async(fn ->
            Sound.play(:swarm_completed)
          end)
        end

      results = Task.await_many(tasks, 5000)
      assert Enum.all?(results, &(&1 == :ok))
    end

    test "invalid sound events and malformed arguments do not crash" do
      assert :ok == Sound.play(:completely_unknown_event_type)
      assert :ok == Sound.play(nil)
      assert :ok == Sound.play(12345)
      assert :ok == Sound.play(%{bad: "argument"})
      assert :ok == Sound.play("")
      assert :ok == Sound.play("/path/to/non_existent_file.aiff")
    end

    test "force playback mode with mock executable under TaskSupervisor load (200 tasks)" do
      mock_bin = System.find_executable("true") || "/usr/bin/true"
      Application.put_env(:iex_code, :afplay_executable, mock_bin)

      assert Process.whereis(IexCode.TaskSupervisor) != nil

      tasks =
        for i <- 1..200 do
          event =
            Enum.at(
              [:swarm_completed, :verification_rejected, :step_failed, :approval_requested],
              rem(i, 4)
            )

          Task.async(fn ->
            Sound.play(event, force: true)
          end)
        end

      results = Task.await_many(tasks, 10_000)
      assert Enum.all?(results, &(&1 == :ok))

      Process.sleep(50)
      assert Process.alive?(Process.whereis(IexCode.TaskSupervisor))
    end

    test "force playback mode with failing/crashing executable recovers cleanly" do
      Application.put_env(:iex_code, :afplay_executable, "/usr/bin/false")
      assert :ok == Sound.play(:swarm_completed, force: true)

      Application.put_env(:iex_code, :afplay_executable, "/non_existent/path/to/binary")
      assert :ok == Sound.play(:swarm_completed, force: true)
    end

    test "playback degrades gracefully when TaskSupervisor is not registered" do
      mock_bin = System.find_executable("true") || "/usr/bin/true"
      Application.put_env(:iex_code, :afplay_executable, mock_bin)
      Application.put_env(:iex_code, :task_supervisor, :unregistered_task_supervisor)

      assert :ok == Sound.play(:swarm_completed, force: true)
    end
  end

  # ===========================================================================
  # 3. SWARM HOOKS STRESS & EDGE CASES
  # ===========================================================================

  describe "3. SwarmHooks PubSub Burst & Concurrency Stress" do
    test "finding 1: subscribe_to_session/1 subscribes caller instead of SwarmHooks GenServer" do
      session_id = "repro_session_#{System.unique_integer([:positive])}"
      before_counts = SwarmHooks.get_event_counts()

      # Caller invokes subscribe_to_session
      assert :ok == SwarmHooks.subscribe_to_session(session_id)

      # Broadcast on session topic
      PubSub.broadcast(
        IexCode.PubSub,
        "runs:session:#{session_id}",
        {:run_updated, %{status: "completed", id: "repro_run"}}
      )

      _ = :sys.get_state(Process.whereis(SwarmHooks))
      after_counts = SwarmHooks.get_event_counts()

      # BUG DEMONSTRATION: SwarmHooks never received the broadcast event!
      assert after_counts.swarm_completed == before_counts.swarm_completed

      # Meanwhile, the CALLER process erroneously received the message in its mailbox!
      assert_receive {:run_updated, %{status: "completed", id: "repro_run"}}, 1000
    end

    test "finding 2: malformed :id with nested map raises Protocol.UndefinedError and crashes SwarmHooks" do
      hooks_pid = Process.whereis(SwarmHooks)
      ref = Process.monitor(hooks_pid)

      assert catch_exit(SwarmHooks.dispatch_event(:swarm_completed, %{id: %{nested: "id"}}))

      # The GenServer process died due to String.Chars not implemented for Map
      assert_receive {:DOWN, ^ref, :process, ^hooks_pid, {%Protocol.UndefinedError{}, _}}, 2000
    end

    test "burst of 1,000 PubSub events across all default topics" do
      hooks_pid = Process.whereis(SwarmHooks)
      assert is_pid(hooks_pid)

      initial_counts = SwarmHooks.get_event_counts()

      topics = ["swarm:lifecycle", "desktop:lifecycle", "desktop:events"]

      tasks =
        for i <- 1..1000 do
          topic = Enum.at(topics, rem(i, length(topics)))

          event =
            case rem(i, 4) do
              0 -> {:swarm_event, :swarm_completed, %{title: "Burst #{i}"}}
              1 -> {:verification_rejected, %{summary: "Reject #{i}"}}
              2 -> {:step_failed, %{reason: "Fail #{i}"}}
              3 -> {:approval_requested, %{action: "Approve #{i}"}}
            end

          Task.async(fn ->
            PubSub.broadcast(IexCode.PubSub, topic, event)
          end)
        end

      Task.await_many(tasks, 10_000)

      _ = :sys.get_state(hooks_pid)

      new_counts = SwarmHooks.get_event_counts()

      total_handled =
        new_counts.swarm_completed - initial_counts.swarm_completed +
          (new_counts.verification_rejected - initial_counts.verification_rejected) +
          (new_counts.step_failed - initial_counts.step_failed) +
          (new_counts.approval_requested - initial_counts.approval_requested)

      assert total_handled == 1000
      assert Process.alive?(hooks_pid)
    end

    test "concurrent dispatches via dispatch_event/2 (500 concurrent callers)" do
      tasks =
        for i <- 1..500 do
          event_type =
            Enum.at(
              [:swarm_completed, :verification_rejected, :step_failed, :approval_requested],
              rem(i, 4)
            )

          Task.async(fn ->
            SwarmHooks.dispatch_event(event_type, %{test_id: i})
          end)
        end

      results = Task.await_many(tasks, 10_000)
      assert Enum.all?(results, &match?({:ok, _}, &1))

      hooks_pid = Process.whereis(SwarmHooks)
      assert Process.alive?(hooks_pid)
    end

    test "handles malformed string and empty payloads without crashing GenServer" do
      hooks_pid = Process.whereis(SwarmHooks)

      malformed_payloads = [
        nil,
        "",
        %{},
        %{title: nil, message: nil, reason: nil},
        12345,
        [:a, :b, :c],
        {:tuple, :payload},
        "raw string without map",
        %{action: nil, reason: nil},
        %{error_message: nil},
        %{id: "run-string-id"}
      ]

      for event_type <- [
            :swarm_completed,
            :verification_rejected,
            :step_failed,
            :approval_requested,
            :unknown_exotic_event
          ] do
        for payload <- malformed_payloads do
          assert match?({:ok, _}, SwarmHooks.dispatch_event(event_type, payload))
        end
      end

      _ = :sys.get_state(hooks_pid)
      assert Process.alive?(hooks_pid)
    end

    test "handles malformed codebase-level PubSub messages without crashing GenServer" do
      hooks_pid = Process.whereis(SwarmHooks)

      malformed_messages = [
        {:run_updated, nil},
        {:run_updated, %{status: "completed", id: nil}},
        {:run_updated, %{status: "waiting_approval"}},
        {:swarm_stage_changed, %{stage: :complete}},
        {:goal_lifecycle_changed, %{status: :completed}},
        {:error, {:verification_failed, nil}},
        {:error, {:verification_failed, "plain string failure"}},
        {:run_step_updated, %{kind: "verify", status: "failed"}},
        {:run_step_updated, %{status: "failed"}},
        {:run_event, %{type: "run.step_failed"}},
        {:operation_failed, nil},
        {:run_approval_requested, nil},
        {:completely_unknown_tag, %{foo: "bar"}},
        :random_atom_message
      ]

      for msg <- malformed_messages do
        send(hooks_pid, msg)
      end

      _ = :sys.get_state(hooks_pid)
      assert Process.alive?(hooks_pid)
    end
  end

  # ===========================================================================
  # Helper Loop
  # ===========================================================================

  defp mock_drain_loop(collector, count) do
    receive do
      {:"$gen_cast", {:show_notification, _text, _id, _type, _title, _cb, _timeout}} = msg ->
        send(collector, msg)
        mock_drain_loop(collector, count + 1)

      {:get_count, reply_to} ->
        send(reply_to, {:received_count, count})
        mock_drain_loop(collector, count)

      _other ->
        mock_drain_loop(collector, count)
    end
  end
end
