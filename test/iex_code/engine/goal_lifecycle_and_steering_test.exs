defmodule IexCode.Engine.GoalLifecycleAndSteeringTest do
  use IexCode.DataCase, async: false
  @moduletag timeout: 120_000
  alias IexCode.{Projects, Sessions}
  alias IexCode.Engine.{SessionServer, SwarmCoordinator, AgentSupervisor, AgentRegistry}
  alias IexCode.Tools.{MultiPatch, Git}

  setup do
    test_root = Path.join(System.tmp_dir!(), "goal_lifecycle_#{Ecto.UUID.generate()}")
    File.mkdir_p!(test_root)

    {:ok, project} =
      Projects.create_project(%{name: "Goal Lifecycle Test Proj", root_path: test_root})

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Goal Lifecycle Session",
        swarm_mode: true,
        status: "idle"
      })

    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")
    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session.id}:steer")

    on_exit(fn ->
      File.rm_rf(test_root)
    end)

    %{session: session, project: project, test_root: test_root}
  end

  describe "1. Autonomous Goal Lifecycle Creation & State Machine" do
    @tag :tmp_dir
    test "create_goal with auto_start: false creates goal and remains idle", %{
      session: session,
      tmp_dir: tmp_dir
    } do
      File.write!(
        Path.join(tmp_dir, "lib_sample.ex"),
        "defmodule LibSample do\n  def ok, do: :ok\nend"
      )

      {:ok, goal} =
        SessionServer.create_goal(
          session.id,
          %{title: "Refactor Sample Module", prompt: "Add new helper function to sample module"},
          project_root: tmp_dir,
          auto_start: false
        )

      assert goal.title == "Refactor Sample Module"
      assert goal.status == :idle
      assert is_binary(goal.id)

      assert_receive {:goal_created, %{title: "Refactor Sample Module", status: :idle}}, 5000
      assert_receive {:session_status_changed, "idle"}, 5000

      state = SessionServer.get_state(session.id)
      assert state.status == :idle
      assert state.active_goal.title == "Refactor Sample Module"
    end

    @tag :tmp_dir
    test "create_goal with string prompt auto-starts swarm and sets status to running", %{
      session: session,
      tmp_dir: tmp_dir
    } do
      File.write!(
        Path.join(tmp_dir, "lib_auto.ex"),
        "defmodule LibAuto do\n  def run, do: :done\nend"
      )

      {:ok, goal} =
        SessionServer.create_goal(
          session.id,
          "Inspect and optimize LibAuto module",
          project_root: tmp_dir,
          auto_start: true
        )

      assert String.contains?(goal.title, "Inspect and optimize")
      assert is_pid(goal.task_pid)
      assert Process.alive?(goal.task_pid)

      assert_receive {:session_status_changed, "running"}, 5000
      assert_receive {:goal_created, _}, 5000

      # Await swarm completion
      assert_receive {:session_status_changed, "idle"}, 25_000

      AgentSupervisor.stop_all_agents(session.id)
    end
  end

  describe "2. Pause & Resume Session Lifecycle" do
    test "pause_session and resume_session update DB and broadcast status events", %{
      session: session
    } do
      {:ok, _pid} = SessionServer.ensure_started(session.id)

      # Pause session
      assert {:ok, :paused} = SessionServer.pause_session(session.id)

      assert_receive {:session_status_changed, "paused"}, 5000
      assert_receive {:pause, _}, 5000

      state = SessionServer.get_state(session.id)
      assert state.status == :paused

      db_session = Sessions.get_session!(session.id)
      assert db_session.status == "paused"

      # Resume session
      assert {:ok, :running} = SessionServer.resume_session(session.id)

      assert_receive {:session_status_changed, "running"}, 5000
      assert_receive {:resume, _}, 5000

      state = SessionServer.get_state(session.id)
      assert state.status == :running

      db_session = Sessions.get_session!(session.id)
      assert db_session.status == "running"
    end

    @tag :tmp_dir
    test "SwarmCoordinator pauses mid-loop and resumes upon resume signal", %{
      session: session,
      tmp_dir: tmp_dir
    } do
      File.write!(
        Path.join(tmp_dir, "lib_pause.ex"),
        "defmodule LibPause do\n  def test_val, do: 123\nend"
      )

      {:ok, _pid} = SwarmCoordinator.run_swarm(session.id, "Coordinate pause test", tmp_dir)
      assert_receive {:session_status_changed, "running"}, 5000

      # Pause the running swarm
      SwarmCoordinator.pause(session.id)
      assert_receive {:session_status_changed, "paused"}, 5000

      # Resume the paused swarm
      SwarmCoordinator.resume(session.id)
      assert_receive {:session_status_changed, "running"}, 5000

      # Verify it finishes to completion
      assert_receive {:session_status_changed, "idle"}, 25_000

      messages = Sessions.list_messages(session.id)

      final_msg =
        Enum.find(messages, fn m ->
          m.role == "assistant" and String.contains?(m.content, "Swarm Execution Complete")
        end)

      assert final_msg != nil

      AgentSupervisor.stop_all_agents(session.id)
    end
  end

  describe "3. Cancel Session with OTP Worker Cleanup & Rollback/Commit" do
    @tag :tmp_dir
    test "cancel_session stops all subagent OTP workers and records stopped state", %{
      session: session,
      tmp_dir: tmp_dir
    } do
      {:ok, _} = AgentSupervisor.start_agent(session.id, :planner, project_root: tmp_dir)
      {:ok, _} = AgentSupervisor.start_agent(session.id, :explorer, project_root: tmp_dir)
      {:ok, _} = AgentSupervisor.start_agent(session.id, :coder, project_root: tmp_dir)
      {:ok, _} = AgentSupervisor.start_agent(session.id, :verifier, project_root: tmp_dir)

      # Verify agents exist
      assert length(AgentRegistry.list_agents(session.id)) == 4

      # Cancel session
      {:ok, res} =
        SessionServer.cancel_session(session.id, project_root: tmp_dir, action: :rollback)

      assert res.status == :stopped
      assert res.action == :rollback

      assert_receive {:session_status_changed, "stopped"}, 5000
      assert_receive {:session_cancelled, %{action: :rollback}}, 5000

      # Verify subagents are stopped cleanly
      assert AgentRegistry.list_agents(session.id) == []

      # Verify DB message created
      messages = Sessions.list_messages(session.id)
      assert Enum.any?(messages, fn m -> String.contains?(m.content, "Session Stopped") end)
    end

    @tag :tmp_dir
    test "cancel_session with rollback reverts MultiPatch snapshots and git changes", %{
      session: session,
      tmp_dir: tmp_dir
    } do
      test_file = Path.join(tmp_dir, "lib_rollback.ex")
      File.write!(test_file, "defmodule LibRollback do\n  def original_val, do: 1\nend")

      # Apply a patch that creates a snapshot
      {:ok, patch_summary} =
        MultiPatch.apply_patches(tmp_dir, [
          %{
            path: "lib_rollback.ex",
            target: "def original_val, do: 1",
            replacement: "def original_val, do: 999"
          }
        ])

      assert patch_summary.applied == 1
      assert File.read!(test_file) =~ "999"

      # Cancel session with rollback
      {:ok, res} =
        SessionServer.cancel_session(session.id, project_root: tmp_dir, action: :rollback)

      assert res.action == :rollback

      # Verify file was rolled back
      assert File.read!(test_file) =~ "def original_val, do: 1"
      refute File.read!(test_file) =~ "999"
    end

    @tag :tmp_dir
    test "cancel_session with commit stages and commits changes in git repo", %{
      session: session,
      tmp_dir: tmp_dir
    } do
      # Initialize a temporary git repository
      {_, 0} = System.cmd("git", ["init"], cd: tmp_dir)
      {_, 0} = System.cmd("git", ["config", "user.name", "Tester"], cd: tmp_dir)
      {_, 0} = System.cmd("git", ["config", "user.email", "tester@iexcode.local"], cd: tmp_dir)

      test_file = Path.join(tmp_dir, "lib_commit.ex")
      File.write!(test_file, "defmodule LibCommit do\n  def v, do: 1\nend")

      {:ok, res} =
        SessionServer.cancel_session(session.id,
          project_root: tmp_dir,
          action: :commit,
          message: "test: checkpoint commit on cancel"
        )

      assert res.action == :commit

      # Verify git log contains the commit
      {:ok, log_entries} = Git.log(tmp_dir)

      assert Enum.any?(log_entries, fn entry ->
               String.contains?(entry.subject, "checkpoint commit on cancel")
             end)
    end
  end

  describe "4. Real-Time Steering Engine Ingestion" do
    @tag :tmp_dir
    test "send_steering ingests guidance into active swarm loop without restarting session", %{
      session: session,
      tmp_dir: tmp_dir
    } do
      File.write!(
        Path.join(tmp_dir, "lib_steer.ex"),
        "defmodule LibSteer do\n  def greeting, do: :hi\nend"
      )

      # Launch asynchronous swarm
      {:ok, _pid} = SwarmCoordinator.run_swarm(session.id, "Coordinate base task", tmp_dir)

      assert_receive {:session_status_changed, "running"}, 5000

      # Send real-time steering directive mid-flight
      {:ok, text} =
        SessionServer.send_steering(
          session.id,
          "Ensure all public functions have @spec and docstrings"
        )

      assert text == "Ensure all public functions have @spec and docstrings"

      assert_receive {:steer_message, "Ensure all public functions have @spec and docstrings"},
                     5000

      assert_receive {:swarm_steered,
                      %{steering: "Ensure all public functions have @spec and docstrings"}},
                     5000

      # Send second steering directive
      {:ok, _} =
        SessionServer.send_steering(session.id, "Verify compliance with Elixir guidelines")

      assert_receive {:swarm_steered, %{steering: "Verify compliance with Elixir guidelines"}},
                     5000

      # Await finish
      assert_receive {:session_status_changed, "idle"}, 25_000

      messages = Sessions.list_messages(session.id)

      final_msg =
        Enum.find(messages, fn m ->
          m.role == "assistant" and String.contains?(m.content, "Swarm Execution Complete")
        end)

      assert final_msg != nil
      assert String.contains?(final_msg.content, "User Steering Applied")
      assert final_msg.metadata["steering_count"] >= 1

      AgentSupervisor.stop_all_agents(session.id)
    end

    @tag :tmp_dir
    test "send_prompt while running delegates directly to real-time steering", %{
      session: session,
      tmp_dir: tmp_dir
    } do
      File.write!(
        Path.join(tmp_dir, "lib_prompt_steer.ex"),
        "defmodule LibPromptSteer do\n  def test, do: true\nend"
      )

      {:ok, _} =
        SessionServer.create_goal(
          session.id,
          "Initial Goal Workflow",
          project_root: tmp_dir,
          auto_start: true
        )

      assert_receive {:session_status_changed, "running"}, 5000

      # Send a second prompt while session is running
      SessionServer.send_prompt(
        session.id,
        "Prioritize comprehensive type specs and pure functions"
      )

      assert_receive {:swarm_steered,
                      %{steering: "Prioritize comprehensive type specs and pure functions"}},
                     5000

      assert_receive {:session_status_changed, "idle"}, 25_000
      AgentSupervisor.stop_all_agents(session.id)
    end

    @tag :tmp_dir
    test "steer guidance received while paused is applied upon resume", %{
      session: session,
      tmp_dir: tmp_dir
    } do
      File.write!(
        Path.join(tmp_dir, "lib_pause_steer.ex"),
        "defmodule LibPauseSteer do\n  def x, do: 1\nend"
      )

      {:ok, _pid} = SwarmCoordinator.run_swarm(session.id, "Goal with pause and steer", tmp_dir)
      assert_receive {:session_status_changed, "running"}, 5000

      # Pause swarm
      SwarmCoordinator.pause(session.id)
      assert_receive {:session_status_changed, "paused"}, 5000

      # Steer while paused
      SessionServer.send_steering(session.id, "Added requirement during pause: add test suite")

      assert_receive {:swarm_steered,
                      %{steering: "Added requirement during pause: add test suite"}},
                     5000

      # Resume
      SwarmCoordinator.resume(session.id)
      assert_receive {:session_status_changed, "running"}, 5000

      assert_receive {:session_status_changed, "idle"}, 25_000

      messages = Sessions.list_messages(session.id)

      final_msg =
        Enum.find(messages, fn m ->
          m.role == "assistant" and String.contains?(m.content, "Swarm Execution Complete")
        end)

      assert final_msg != nil
      assert String.contains?(final_msg.content, "User Steering Applied")
      assert String.contains?(final_msg.content, "Added requirement during pause")

      AgentSupervisor.stop_all_agents(session.id)
    end
  end

  describe "5. Edge Cases & Resilience" do
    test "cancel_session when idle or with non-existent tasks is safe and idempotent", %{
      session: session
    } do
      {:ok, res} = SessionServer.cancel_session(session.id, action: :rollback)
      assert res.status == :stopped

      # Calling cancel a second time is safe
      {:ok, res2} = SessionServer.cancel_session(session.id, action: :rollback)
      assert res2.status == :stopped
    end

    test "send_steering with empty text is a no-op", %{session: session} do
      {:ok, _} = SessionServer.ensure_started(session.id)
      assert {:ok, ""} = SessionServer.send_steering(session.id, "   ")
      refute_receive {:steer_message, _}, 500
    end
  end
end
