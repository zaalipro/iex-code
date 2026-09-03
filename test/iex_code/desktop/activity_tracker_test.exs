defmodule IexCode.Desktop.ActivityTrackerTest do
  use ExUnit.Case, async: false

  alias IexCode.Desktop.{ActivityTracker, Dock}
  alias Phoenix.PubSub

  setup do
    # Ensure PubSub subscription to observe dock updates
    if Process.whereis(IexCode.PubSub) do
      PubSub.subscribe(IexCode.PubSub, "desktop:activity")
    end

    # Reset ActivityTracker and Dock before each test
    ActivityTracker.clear()
    Dock.clear()

    on_exit(fn ->
      ActivityTracker.clear()
      Dock.clear()
    end)

    :ok
  end

  describe "Manual Client API Tracking" do
    test "track_worker_start/1 and track_worker_finish/1 update running count and Dock" do
      assert :ok = ActivityTracker.track_worker_start("worker_1")

      counts = ActivityTracker.get_counts()
      assert counts.running == 1
      assert counts.waiting == 0

      activity = Dock.get_activity()
      assert activity.running == 1
      assert activity.waiting == 0
      assert activity.badge == "1"
      assert activity.title == "IexCode - 1 running, 0 waiting"

      assert_receive {:dock_activity_updated,
                      %{
                        running: 1,
                        waiting: 0,
                        badge: "1",
                        title: "IexCode - 1 running, 0 waiting"
                      }},
                     1000

      # Start second worker
      assert :ok = ActivityTracker.track_worker_start("worker_2")
      assert ActivityTracker.get_counts().running == 2

      # Finish first worker
      assert :ok = ActivityTracker.track_worker_finish("worker_1")
      assert ActivityTracker.get_counts().running == 1

      # Finish second worker
      assert :ok = ActivityTracker.track_worker_finish("worker_2")
      assert ActivityTracker.get_counts().running == 0
      assert Dock.get_activity().running == 0
    end

    test "track_approval_request/1 and track_approval_resolve/1 update waiting count and Dock" do
      assert :ok = ActivityTracker.track_approval_request("approval_1")

      counts = ActivityTracker.get_counts()
      assert counts.running == 0
      assert counts.waiting == 1

      activity = Dock.get_activity()
      assert activity.running == 0
      assert activity.waiting == 1
      assert activity.badge == "1"
      assert activity.title == "IexCode - 0 running, 1 waiting"

      assert_receive {:dock_activity_updated,
                      %{
                        running: 0,
                        waiting: 1,
                        badge: "1",
                        title: "IexCode - 0 running, 1 waiting"
                      }},
                     1000

      # Resolve approval
      assert :ok = ActivityTracker.track_approval_resolve("approval_1")
      assert ActivityTracker.get_counts().waiting == 0
      assert Dock.get_activity().waiting == 0
    end

    test "combined running workers and waiting approvals generate combined badge" do
      ActivityTracker.track_worker_start("w1")
      ActivityTracker.track_worker_start("w2")
      ActivityTracker.track_worker_start("w3")
      ActivityTracker.track_approval_request("a1")

      counts = ActivityTracker.get_counts()
      assert counts.running == 3
      assert counts.waiting == 1

      activity = Dock.get_activity()
      assert activity.running == 3
      assert activity.waiting == 1
      assert activity.badge == "3R/1W"
      assert activity.title == "IexCode - 3 running, 1 waiting"
    end

    test "idempotency: duplicate worker start does not double count" do
      ActivityTracker.track_worker_start("w_same")
      ActivityTracker.track_worker_start("w_same")

      assert ActivityTracker.get_counts().running == 1

      # Finishing unknown worker does not drop below 0
      ActivityTracker.track_worker_finish("unknown_worker")
      assert ActivityTracker.get_counts().running == 1

      ActivityTracker.track_worker_finish("w_same")
      assert ActivityTracker.get_counts().running == 0
    end

    test "sync_now/0 triggers recount without errors" do
      ActivityTracker.track_worker_start("w_sync_1")
      assert :ok = ActivityTracker.sync_now()

      counts = ActivityTracker.get_counts()
      assert counts.running >= 1
    end

    test "clear/0 resets all tracked state" do
      ActivityTracker.track_worker_start("w_temp")
      ActivityTracker.track_approval_request("a_temp")

      assert :ok = ActivityTracker.clear()

      counts = ActivityTracker.get_counts()
      assert counts.running == 0
      assert counts.waiting == 0

      activity = Dock.get_activity()
      assert activity.running == 0
      assert activity.waiting == 0
      assert activity.badge == ""
      assert activity.title == "IexCode - Desktop AI Coding Harness"
    end
  end

  describe "PubSub Event Handling" do
    test "handles :run_updated events for starting and completing runs" do
      # Run starts
      send(
        Process.whereis(ActivityTracker),
        {:run_updated, %{id: "run-pub-1", status: "running"}}
      )

      _ = :sys.get_state(Process.whereis(ActivityTracker))

      assert ActivityTracker.get_counts().running == 1

      # Run completes
      send(
        Process.whereis(ActivityTracker),
        {:run_updated, %{id: "run-pub-1", status: "completed"}}
      )

      _ = :sys.get_state(Process.whereis(ActivityTracker))

      assert ActivityTracker.get_counts().running == 0
    end

    test "handles :run_step_updated events" do
      send(
        Process.whereis(ActivityTracker),
        {:run_step_updated, %{run_id: "run-step-1", status: "running"}}
      )

      _ = :sys.get_state(Process.whereis(ActivityTracker))

      assert ActivityTracker.get_counts().running == 1
    end

    test "handles :run_approval_requested and :approval_resolved events" do
      # Approval requested
      send(Process.whereis(ActivityTracker), {:run_approval_requested, %{id: "app-pub-1"}})
      _ = :sys.get_state(Process.whereis(ActivityTracker))

      assert ActivityTracker.get_counts().waiting == 1

      # Approval resolved
      send(Process.whereis(ActivityTracker), {:approval_resolved, %{id: "app-pub-1"}})
      _ = :sys.get_state(Process.whereis(ActivityTracker))

      assert ActivityTracker.get_counts().waiting == 0
    end

    test "handles :worker_started and :worker_finished events" do
      send(Process.whereis(ActivityTracker), {:worker_started, %{id: "worker-pub-1"}})
      _ = :sys.get_state(Process.whereis(ActivityTracker))

      assert ActivityTracker.get_counts().running == 1

      send(Process.whereis(ActivityTracker), {:worker_finished, %{id: "worker-pub-1"}})
      _ = :sys.get_state(Process.whereis(ActivityTracker))

      assert ActivityTracker.get_counts().running == 0
    end

    test "safely ignores unhandled messages" do
      send(Process.whereis(ActivityTracker), {:unknown_event, %{foo: "bar"}})
      _ = :sys.get_state(Process.whereis(ActivityTracker))

      # Process remains healthy and counts unchanged
      assert is_map(ActivityTracker.get_counts())
    end
  end

  describe "Isolated ActivityTracker with Dedicated Dock" do
    test "can be run as isolated instance pointing to custom Dock" do
      unique_id = System.unique_integer([:positive])
      dock_name = :"dock_iso_#{unique_id}"
      tracker_name = :"tracker_iso_#{unique_id}"

      {:ok, dock_pid} =
        start_supervised({Dock, [name: dock_name, base_title: "Isolated Dock"]}, id: dock_name)

      {:ok, tracker_pid} =
        start_supervised(
          {ActivityTracker, [name: tracker_name, dock_server: dock_pid, topics: []]},
          id: tracker_name
        )

      assert ActivityTracker.track_worker_start(tracker_pid, "iso_w1") == :ok
      assert ActivityTracker.track_approval_request(tracker_pid, "iso_a1") == :ok

      counts = ActivityTracker.get_counts(tracker_pid)
      assert counts.running == 1
      assert counts.waiting == 1

      dock_state = Dock.get_activity(dock_pid)
      assert dock_state.running == 1
      assert dock_state.waiting == 1
      assert dock_state.badge == "1R/1W"
      assert dock_state.title == "IexCode - 1 running, 1 waiting"
    end
  end
end
