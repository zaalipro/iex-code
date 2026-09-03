defmodule IexCode.Desktop.DockTest do
  use ExUnit.Case, async: false

  alias IexCode.Desktop.Dock
  alias Phoenix.PubSub

  setup do
    original_window_id = Application.get_env(:iex_code, :desktop_window_id)
    original_badge_enabled = Application.get_env(:iex_code, :desktop_dock_badge_enabled)

    # Subscribe to desktop:activity topic
    if Process.whereis(IexCode.PubSub) do
      PubSub.subscribe(IexCode.PubSub, "desktop:activity")
    end

    on_exit(fn ->
      Application.put_env(:iex_code, :desktop_window_id, original_window_id)
      Application.put_env(:iex_code, :desktop_dock_badge_enabled, original_badge_enabled)
      Dock.clear()
    end)

    :ok
  end

  describe "Pure Computation Helpers" do
    test "compute_title/3 returns base title when 0 running and 0 waiting" do
      assert Dock.compute_title(0, 0) == "IexCode - Desktop AI Coding Harness"
      assert Dock.compute_title(-1, -5) == "IexCode - Desktop AI Coding Harness"
      assert Dock.compute_title(0, 0, "Custom Workspace") == "Custom Workspace"
    end

    test "compute_title/3 formats title with running and waiting counts" do
      assert Dock.compute_title(3, 1) == "IexCode - 3 running, 1 waiting"
      assert Dock.compute_title(5, 0) == "IexCode - 5 running, 0 waiting"
      assert Dock.compute_title(0, 2) == "IexCode - 0 running, 2 waiting"
      assert Dock.compute_title(10, 4, "Ignored Base") == "IexCode - 10 running, 4 waiting"
    end

    test "compute_badge/2 formats badge string according to specification" do
      # 0 running, 0 waiting -> empty badge
      assert Dock.compute_badge(0, 0) == ""
      assert Dock.compute_badge(-2, -3) == ""

      # Both positive -> #{running}R/#{waiting}W
      assert Dock.compute_badge(3, 1) == "3R/1W"
      assert Dock.compute_badge(1, 1) == "1R/1W"
      assert Dock.compute_badge(12, 4) == "12R/4W"

      # Only running positive -> #{running}
      assert Dock.compute_badge(3, 0) == "3"
      assert Dock.compute_badge(1, 0) == "1"
      assert Dock.compute_badge(15, -1) == "15"

      # Only waiting positive -> #{waiting}
      assert Dock.compute_badge(0, 2) == "2"
      assert Dock.compute_badge(0, 1) == "1"
      assert Dock.compute_badge(-5, 7) == "7"
    end
  end

  describe "Client API & State Updates" do
    test "get_activity/0 returns default initial activity" do
      Dock.clear()
      activity = Dock.get_activity()

      assert activity.running == 0
      assert activity.waiting == 0
      assert activity.badge == ""
      assert activity.title == "IexCode - Desktop AI Coding Harness"
    end

    test "set_activity/2 updates activity state and broadcasts over PubSub" do
      assert :ok = Dock.set_activity(3, 1)

      activity = Dock.get_activity()
      assert activity.running == 3
      assert activity.waiting == 1
      assert activity.badge == "3R/1W"
      assert activity.title == "IexCode - 3 running, 1 waiting"

      assert_receive {:dock_activity_updated,
                      %{
                        running: 3,
                        waiting: 1,
                        badge: "3R/1W",
                        title: "IexCode - 3 running, 1 waiting"
                      }},
                     1000
    end

    test "set_activity/2 with 2 running and 0 waiting" do
      assert :ok = Dock.set_activity(2, 0)

      activity = Dock.get_activity()
      assert activity.running == 2
      assert activity.waiting == 0
      assert activity.badge == "2"
      assert activity.title == "IexCode - 2 running, 0 waiting"

      assert_receive {:dock_activity_updated,
                      %{
                        running: 2,
                        waiting: 0,
                        badge: "2",
                        title: "IexCode - 2 running, 0 waiting"
                      }},
                     1000
    end

    test "set_activity/2 with 0 running and 4 waiting" do
      assert :ok = Dock.set_activity(0, 4)

      activity = Dock.get_activity()
      assert activity.running == 0
      assert activity.waiting == 4
      assert activity.badge == "4"
      assert activity.title == "IexCode - 0 running, 4 waiting"

      assert_receive {:dock_activity_updated,
                      %{
                        running: 0,
                        waiting: 4,
                        badge: "4",
                        title: "IexCode - 0 running, 4 waiting"
                      }},
                     1000
    end

    test "clear/0 resets activity to 0 running and 0 waiting" do
      Dock.set_activity(5, 2)
      assert :ok = Dock.clear()

      activity = Dock.get_activity()
      assert activity.running == 0
      assert activity.waiting == 0
      assert activity.badge == ""
      assert activity.title == "IexCode - Desktop AI Coding Harness"

      assert_receive {:dock_activity_updated,
                      %{
                        running: 0,
                        waiting: 0,
                        badge: "",
                        title: "IexCode - Desktop AI Coding Harness"
                      }},
                     1000
    end
  end

  describe "Window Title & Desktop Integration" do
    test "calls Desktop.Window.set_title/2 when Desktop.Window is alive" do
      test_pid = self()

      mock_window =
        spawn_link(fn ->
          mock_window_loop(test_pid)
        end)

      mock_name = :"mock_window_#{System.unique_integer([:positive])}"
      Process.register(mock_window, mock_name)
      Application.put_env(:iex_code, :desktop_window_id, mock_name)

      Dock.set_activity(4, 2)

      expected_title = "IexCode - 4 running, 2 waiting"
      assert_receive {:"$gen_cast", {:set_title, ^expected_title}}, 1000
    end

    test "safely handles title update when Desktop.Window is dead or unstarted" do
      Application.put_env(:iex_code, :desktop_window_id, :unstarted_window_atom)

      # Should not crash or raise ArgumentError
      assert :ok = Dock.set_activity(1, 1)
      assert :ok = Dock.apply_window_title("Arbitrary Title")
    end
  end

  describe "Dock Badging & Headless Safety" do
    test "apply_dock_badge/2 does not execute external osascript in test env" do
      # In test mode, should_apply_dock_badge? is false, returning :ok safely
      assert :ok = Dock.apply_dock_badge("3R/1W")
      assert :ok = Dock.apply_dock_badge("")
    end

    test "apply_dock_badge/2 safely executes with force option" do
      assert :ok = Dock.apply_dock_badge("test_badge", force: true)
      assert :ok = Dock.apply_dock_badge("", force: true)
    end
  end

  describe "Isolated Dock Instance" do
    test "supports isolated GenServer with custom base title and name" do
      custom_name = :"custom_dock_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        start_supervised(
          {Dock, [name: custom_name, base_title: "Custom Engine", running: 0, waiting: 0]},
          id: custom_name
        )

      assert Dock.get_activity(pid) == %{
               running: 0,
               waiting: 0,
               badge: "",
               title: "Custom Engine"
             }

      assert :ok = Dock.set_activity(pid, 2, 3)

      assert Dock.get_activity(pid) == %{
               running: 2,
               waiting: 3,
               badge: "2R/3W",
               title: "IexCode - 2 running, 3 waiting"
             }

      assert :ok = Dock.clear(pid)

      assert Dock.get_activity(pid) == %{
               running: 0,
               waiting: 0,
               badge: "",
               title: "Custom Engine"
             }
    end
  end

  defp mock_window_loop(parent) do
    receive do
      {:"$gen_cast", {:set_title, _title}} = msg ->
        send(parent, msg)
        mock_window_loop(parent)

      _other ->
        mock_window_loop(parent)
    end
  end
end
