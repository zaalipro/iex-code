defmodule IexCode.Desktop.NotifierTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias IexCode.Desktop.Notifier

  setup do
    original_window_id = Application.get_env(:iex_code, :desktop_window_id)
    original_enabled = Application.get_env(:iex_code, :desktop_notifications_enabled)

    on_exit(fn ->
      Application.put_env(:iex_code, :desktop_window_id, original_window_id)
      Application.put_env(:iex_code, :desktop_notifications_enabled, original_enabled)
    end)

    :ok
  end

  describe "Headless and Unstarted Window Fallback" do
    test "desktop_window_alive?/0 returns false when window process is not registered" do
      Application.put_env(:iex_code, :desktop_window_id, :non_existent_window_process)
      refute Notifier.desktop_window_alive?()
    end

    test "desktop_window_alive?/0 returns false when window_id is a dead PID" do
      {dead_pid, ref} = spawn_monitor(fn -> :ok end)
      assert_receive {:DOWN, ^ref, :process, ^dead_pid, :normal}, 1_000
      Application.put_env(:iex_code, :desktop_window_id, dead_pid)
      refute Notifier.desktop_window_alive?()
    end

    test "notify/2 returns {:ok, :fallback} and does not raise ArgumentError when window is unstarted" do
      Application.put_env(:iex_code, :desktop_window_id, :non_existent_window_process)

      assert {:ok, :fallback} =
               Notifier.notify("Swarm execution completed", title: "Success", type: :info)
    end

    test "notify/2 logs appropriate severity levels to Logger in fallback mode" do
      Application.put_env(:iex_code, :desktop_window_id, :non_existent_window_process)

      # Warning level
      log_warn =
        capture_log(fn ->
          assert {:ok, :fallback} =
                   Notifier.notify("Verification test failed",
                     title: "Verification",
                     type: :warning
                   )
        end)

      assert log_warn =~
               "[Desktop Notification Fallback] [warning] Verification: Verification test failed"

      # Error level
      log_error =
        capture_log(fn ->
          assert {:ok, :fallback} =
                   Notifier.notify("Step syntax error", title: "Step Failure", type: :error)
        end)

      assert log_error =~
               "[Desktop Notification Fallback] [error] Step Failure: Step syntax error"
    end

    test "notify/2 safely falls back when desktop_notifications_enabled is false" do
      Application.put_env(:iex_code, :desktop_notifications_enabled, false)

      log =
        capture_log(fn ->
          assert {:ok, :fallback} =
                   Notifier.notify("Notifications disabled", title: "Notice", type: :warning)
        end)

      assert log =~ "Notifications disabled"
    end

    test "dismiss/1 returns :ok safely when window is not running" do
      Application.put_env(:iex_code, :desktop_window_id, :non_existent_window_process)
      assert :ok == Notifier.dismiss(:custom_id)
    end
  end

  describe "Active Desktop Window Notification Dispatch" do
    setup do
      test_pid = self()

      mock_window =
        spawn_link(fn ->
          mock_receiver_loop(test_pid)
        end)

      mock_name = :"mock_window_#{System.unique_integer([:positive])}"
      Process.register(mock_window, mock_name)
      Application.put_env(:iex_code, :desktop_window_id, mock_name)
      Application.put_env(:iex_code, :desktop_notifications_enabled, true)

      {:ok, mock_window: mock_window, mock_name: mock_name}
    end

    test "notify/2 dispatches show_notification cast to window and returns :ok", %{
      mock_name: _mock_name
    } do
      assert Notifier.desktop_window_alive?()

      assert :ok ==
               Notifier.notify("Swarm finished all goals",
                 title: "Swarm Completed",
                 type: :info,
                 id: :swarm_complete_1,
                 timeout: 3000
               )

      assert_receive {:"$gen_cast",
                      {:show_notification, "Swarm finished all goals", :swarm_complete_1, :info,
                       "Swarm Completed", nil, 3000}},
                     1000
    end

    test "notify/2 normalizes :warn to :warning for Desktop.Window", %{mock_name: _mock_name} do
      assert :ok ==
               Notifier.notify("Requires approval",
                 title: "Approval Needed",
                 type: :warn,
                 id: :approval_1
               )

      assert_receive {:"$gen_cast",
                      {:show_notification, "Requires approval", :approval_1, :warning,
                       "Approval Needed", nil, -1}},
                     1000
    end

    test "dismiss/1 dispatches dismiss_notification cast to window", %{mock_name: _mock_name} do
      assert :ok == Notifier.dismiss(:swarm_complete_1)

      assert_receive {:"$gen_cast", {:dismiss_notification, :swarm_complete_1}}, 1000
    end

    test "notify/2 handles :sound option without passing it to Desktop.Window cast" do
      assert :ok ==
               Notifier.notify("Goal complete with chime",
                 title: "Done",
                 type: :info,
                 sound: :hero,
                 id: :sound_notify_1
               )

      assert_receive {:"$gen_cast",
                      {:show_notification, "Goal complete with chime", :sound_notify_1, :info,
                       "Done", nil, -1}},
                     1000
    end

    test "handles direct PID as window_id", %{mock_window: mock_window} do
      Application.put_env(:iex_code, :desktop_window_id, mock_window)
      assert Notifier.desktop_window_alive?()

      assert :ok ==
               Notifier.notify("Direct PID notification",
                 title: "Direct PID",
                 type: :info,
                 id: :pid_notify_1
               )

      assert_receive {:"$gen_cast",
                      {:show_notification, "Direct PID notification", :pid_notify_1, :info,
                       "Direct PID", nil, -1}},
                     1000
    end
  end

  defp mock_receiver_loop(forward_to) do
    receive do
      msg ->
        send(forward_to, msg)
        mock_receiver_loop(forward_to)
    end
  end
end
