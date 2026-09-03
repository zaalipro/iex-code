defmodule IexCode.Desktop.SwarmHooksTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias IexCode.Desktop.SwarmHooks
  alias IexCode.Runs.{Run, RunApproval, RunStep}
  alias Phoenix.PubSub

  setup do
    original_window_id = Application.get_env(:iex_code, :desktop_window_id)
    original_notifications = Application.get_env(:iex_code, :desktop_notifications_enabled)

    on_exit(fn ->
      Application.put_env(:iex_code, :desktop_window_id, original_window_id)
      Application.put_env(:iex_code, :desktop_notifications_enabled, original_notifications)
    end)

    :ok
  end

  describe "Supervision and Process Registration" do
    test "SwarmHooks is started and registered under the main application supervision tree" do
      pid = Process.whereis(SwarmHooks)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end
  end

  describe "Direct Event Dispatching via dispatch_event/2" do
    test "dispatches :swarm_completed with notification and updates state" do
      log =
        capture_info_log(fn ->
          assert {:ok, :swarm_completed} =
                   SwarmHooks.dispatch_event(:swarm_completed, %{
                     title: "Autonomous Coding Refactor",
                     id: "run-complete-1"
                   })
        end)

      assert log =~ "[Desktop Notification Fallback] [info] Swarm Goal Completed"
      assert log =~ "Swarm goal completed: Autonomous Coding Refactor"

      assert {:swarm_completed, %{title: "Autonomous Coding Refactor"}, %DateTime{}} =
               SwarmHooks.get_last_event()

      counts = SwarmHooks.get_event_counts()
      assert counts.swarm_completed >= 1
    end

    test "dispatches :verification_rejected with warning notification and updates state" do
      log =
        capture_log(fn ->
          assert {:ok, :verification_rejected} =
                   SwarmHooks.dispatch_event(:verification_rejected, %{
                     reason: "Mix test failure in auth_test.exs"
                   })
        end)

      assert log =~ "[Desktop Notification Fallback] [warning] Verification Rejected"
      assert log =~ "Verification rejected: Mix test failure in auth_test.exs"

      assert {:verification_rejected, %{reason: "Mix test failure in auth_test.exs"}, %DateTime{}} =
               SwarmHooks.get_last_event()

      counts = SwarmHooks.get_event_counts()
      assert counts.verification_rejected >= 1
    end

    test "dispatches :step_failed with error notification and updates state" do
      log =
        capture_log(fn ->
          assert {:ok, :step_failed} =
                   SwarmHooks.dispatch_event(:step_failed, %{
                     title: "Compile Step",
                     error_message: "Compilation error on line 42"
                   })
        end)

      assert log =~ "[Desktop Notification Fallback] [error] Swarm Step Failed"
      assert log =~ "Step failed: Compilation error on line 42"

      assert {:step_failed, %{error_message: "Compilation error on line 42"}, %DateTime{}} =
               SwarmHooks.get_last_event()

      counts = SwarmHooks.get_event_counts()
      assert counts.step_failed >= 1
    end

    test "dispatches :approval_requested with warning notification and updates state" do
      log =
        capture_log(fn ->
          assert {:ok, :approval_requested} =
                   SwarmHooks.dispatch_event(:approval_requested, %{
                     action: "rm -rf /tmp/scratch",
                     reason: "Clean temporary build artifacts"
                   })
        end)

      assert log =~ "[Desktop Notification Fallback] [warning] Approval Required"
      assert log =~ "Approval needed for rm -rf /tmp/scratch: Clean temporary build artifacts"

      assert {:approval_requested, %{action: "rm -rf /tmp/scratch"}, %DateTime{}} =
               SwarmHooks.get_last_event()

      counts = SwarmHooks.get_event_counts()
      assert counts.approval_requested >= 1
    end
  end

  describe "PubSub Swarm Lifecycle Subscriptions" do
    test "processes :swarm_event broadcast on swarm:lifecycle" do
      log =
        capture_info_log(fn ->
          PubSub.broadcast(
            IexCode.PubSub,
            "swarm:lifecycle",
            {:swarm_event, :swarm_completed, %{title: "Broadcast via PubSub"}}
          )

          # Wait briefly for GenServer message handling
          _ = :sys.get_state(Process.whereis(SwarmHooks))
        end)

      assert log =~ "Swarm goal completed: Broadcast via PubSub"
    end

    test "processes individual lifecycle event tuples on desktop:lifecycle" do
      log =
        capture_log(fn ->
          PubSub.broadcast(
            IexCode.PubSub,
            "desktop:lifecycle",
            {:verification_rejected, %{summary: "PubSub verification reject"}}
          )

          _ = :sys.get_state(Process.whereis(SwarmHooks))
        end)

      assert log =~ "Verification rejected: PubSub verification reject"
    end

    test "processes :step_failed and :approval_requested on desktop:lifecycle" do
      log =
        capture_log(fn ->
          PubSub.broadcast(
            IexCode.PubSub,
            "desktop:lifecycle",
            {:step_failed, %{reason: "Connection timeout"}}
          )

          PubSub.broadcast(
            IexCode.PubSub,
            "desktop:lifecycle",
            {:approval_requested, %{action: "Apply database migration"}}
          )

          _ = :sys.get_state(Process.whereis(SwarmHooks))
        end)

      assert log =~ "Step failed: Connection timeout"
      assert log =~ "Approval needed for Apply database migration"
    end
  end

  describe "Integration with Real-World Codebase Events" do
    test "handles run completion event {:run_updated, %{status: 'completed'}}" do
      log =
        capture_info_log(fn ->
          send(Process.whereis(SwarmHooks), {:run_updated, %{status: "completed", id: "run-99"}})
          _ = :sys.get_state(Process.whereis(SwarmHooks))
        end)

      assert log =~ "Swarm run run-99 completed successfully"
    end

    test "handles verification rejection event {:error, {:verification_failed, diagnostics}}" do
      log =
        capture_log(fn ->
          send(
            Process.whereis(SwarmHooks),
            {:error, {:verification_failed, %{summary: "12 tests failed"}}}
          )

          _ = :sys.get_state(Process.whereis(SwarmHooks))
        end)

      assert log =~ "Verification rejected: 12 tests failed"
    end

    test "handles step failure event {:run_step_updated, %{status: 'failed'}}" do
      log =
        capture_log(fn ->
          send(
            Process.whereis(SwarmHooks),
            {:run_step_updated, %{status: "failed", title: "Lint checks"}}
          )

          _ = :sys.get_state(Process.whereis(SwarmHooks))
        end)

      assert log =~ "Step 'Lint checks' execution failed"
    end

    test "handles approval requested event {:run_approval_requested, approval}" do
      log =
        capture_log(fn ->
          send(
            Process.whereis(SwarmHooks),
            {:run_approval_requested, %{action: "push_git", reason: "Push branch to remote"}}
          )

          _ = :sys.get_state(Process.whereis(SwarmHooks))
        end)

      assert log =~ "Approval needed for push_git: Push branch to remote"
    end

    test "handles real Ecto %Run{} struct on run completion without crashing" do
      run = %Run{id: "run-ecto-123", status: "completed"}

      log =
        capture_info_log(fn ->
          send(Process.whereis(SwarmHooks), {:run_updated, run})
          _ = :sys.get_state(Process.whereis(SwarmHooks))
        end)

      assert log =~ "Swarm run run-ecto-123 completed successfully"
      assert Process.alive?(Process.whereis(SwarmHooks))
    end

    test "handles real Ecto %RunStep{} struct on verification failure without crashing" do
      step = %RunStep{
        id: "step-ecto-verify",
        kind: "verify",
        status: "failed",
        title: "Test Verification Suite"
      }

      log =
        capture_log(fn ->
          send(Process.whereis(SwarmHooks), {:run_step_updated, step})
          _ = :sys.get_state(Process.whereis(SwarmHooks))
        end)

      assert log =~ "Verification checks failed"
      assert Process.alive?(Process.whereis(SwarmHooks))
    end

    test "handles real Ecto %RunStep{} struct on step failure without crashing" do
      step = %RunStep{
        id: "step-ecto-fail",
        kind: "build",
        status: "failed",
        title: "Compile Step"
      }

      log =
        capture_log(fn ->
          send(Process.whereis(SwarmHooks), {:run_step_updated, step})
          _ = :sys.get_state(Process.whereis(SwarmHooks))
        end)

      assert log =~ "Step 'Compile Step' execution failed"
      assert Process.alive?(Process.whereis(SwarmHooks))
    end

    test "handles real Ecto %RunApproval{} struct on approval request without crashing" do
      approval = %RunApproval{
        id: "appr-ecto-456",
        action: "push_code",
        reason: "Deploying updates to production"
      }

      log =
        capture_log(fn ->
          send(Process.whereis(SwarmHooks), {:run_approval_requested, approval})
          _ = :sys.get_state(Process.whereis(SwarmHooks))
        end)

      assert log =~ "Approval needed for push_code: Deploying updates to production"
      assert Process.alive?(Process.whereis(SwarmHooks))
    end
  end

  describe "End-to-End Notification Dispatch with Active Mock Window" do
    setup do
      test_pid = self()

      mock_window =
        spawn_link(fn ->
          mock_receiver(test_pid)
        end)

      mock_name = :"mock_window_hooks_#{System.unique_integer([:positive])}"
      Process.register(mock_window, mock_name)
      Application.put_env(:iex_code, :desktop_window_id, mock_name)
      Application.put_env(:iex_code, :desktop_notifications_enabled, true)

      {:ok, mock_window: mock_window, mock_name: mock_name}
    end

    test "dispatches genuine Desktop.Window notification for all 4 events" do
      # 1. Swarm completed
      SwarmHooks.dispatch_event(:swarm_completed, %{title: "Feature complete"})

      assert_receive {:"$gen_cast",
                      {:show_notification, "Swarm goal completed: Feature complete", :default,
                       :info, "Swarm Goal Completed", nil, -1}},
                     1000

      # 2. Verification rejected
      SwarmHooks.dispatch_event(:verification_rejected, %{reason: "Test failure"})

      assert_receive {:"$gen_cast",
                      {:show_notification, "Verification rejected: Test failure", :default,
                       :warning, "Verification Rejected", nil, -1}},
                     1000

      # 3. Step failed
      SwarmHooks.dispatch_event(:step_failed, %{reason: "Crash in worker"})

      assert_receive {:"$gen_cast",
                      {:show_notification, "Step failed: Crash in worker", :default, :error,
                       "Swarm Step Failed", nil, -1}},
                     1000

      # 4. Approval requested
      SwarmHooks.dispatch_event(:approval_requested, %{
        action: "Deploy",
        reason: "Release to staging"
      })

      assert_receive {:"$gen_cast",
                      {:show_notification, "Approval needed for Deploy: Release to staging",
                       :default, :warning, "Approval Required", nil, -1}},
                     1000
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
