defmodule IexCode.Adversarial.GoalEdgeCasesAdversarialTest do
  @moduledoc """
  Empirical verification of backend Goal Lifecycle & Steering edge case vulnerabilities:
  1. Duplicate Pause Mailbox Accumulation & Premature Re-Pause
  2. Send Prompt during Paused state causing Split-Brain Duplicate Swarm
  3. Re-entrant Goal Creation without Stopping Previous Task Subagents
  4. SessionServer in-memory status desynchronization
  """
  use IexCode.DataCase, async: false
  @moduletag timeout: 120_000

  alias IexCode.{Projects, Sessions}
  alias IexCode.Engine.{SessionServer, SwarmCoordinator, AgentSupervisor, AgentRegistry}

  setup do
    test_root = Path.join(System.tmp_dir!(), "edge_goal_#{Ecto.UUID.generate()}")
    File.mkdir_p!(test_root)

    {:ok, project} =
      Projects.create_project(%{name: "Edge Case Goal Project", root_path: test_root})

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Edge Case Goal Session",
        swarm_mode: true,
        status: "idle"
      })

    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")
    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session.id}:steer")

    on_exit(fn ->
      AgentSupervisor.stop_all_agents(session.id)
      File.rm_rf(test_root)
    end)

    %{session: session, project: project, test_root: test_root}
  end

  describe "Vulnerability 1: Duplicate Pause Mailbox Accumulation" do
    test "repeated pause_session calls queue duplicate :pause messages in SwarmCoordinator mailbox", %{
      session: session,
      test_root: test_root
    } do
      File.write!(
        Path.join(test_root, "pause_dup.ex"),
        "defmodule PauseDup do\n  def run, do: :ok\nend"
      )

      # Start swarm via SessionServer
      {:ok, goal} =
        SessionServer.create_goal(session.id, "Duplicate Pause Test",
          project_root: test_root,
          auto_start: true
        )

      assert is_pid(goal.task_pid)
      assert_receive {:session_status_changed, "running"}, 5000

      # Pause the session twice in a row
      assert {:ok, :paused} = SessionServer.pause_session(session.id)
      assert {:ok, :paused} = SessionServer.pause_session(session.id)

      # Resume once
      assert {:ok, :running} = SessionServer.resume_session(session.id)

      # Because of duplicate :pause in mailbox, check if SwarmCoordinator finishes or gets stuck
      # A resilient system should finish to completion
      assert_receive {:session_status_changed, "idle"}, 25_000

      AgentSupervisor.stop_all_agents(session.id)
    end
  end

  describe "Vulnerability 2: Send Prompt during Paused State Split-Brain" do
    test "send_prompt while paused triggers new swarm task instead of steering existing paused swarm", %{
      session: session,
      test_root: test_root
    } do
      File.write!(
        Path.join(test_root, "split_brain.ex"),
        "defmodule SplitBrain do\n  def v, do: 1\nend"
      )

      {:ok, goal1} =
        SessionServer.create_goal(session.id, "Base Task for Split Brain",
          project_root: test_root,
          auto_start: true
        )

      assert_receive {:session_status_changed, "running"}, 5000
      task1_pid = goal1.task_pid

      # Pause session
      assert {:ok, :paused} = SessionServer.pause_session(session.id)
      assert_receive {:session_status_changed, "paused"}, 5000

      # While paused, user submits a prompt thinking it will steer or resume
      SessionServer.send_prompt(session.id, "Steering guidance sent via prompt box")

      # Observe SessionServer state: status is set to running, but did it launch a second task?
      state = SessionServer.get_state(session.id)
      task2_pid = state.current_task

      # If task2_pid != task1_pid, it spawned a split-brain duplicate task while task1 was still alive!
      # We record whether task1 and task2 are distinct concurrent processes
      assert is_pid(task2_pid)
      if task2_pid != task1_pid do
        # Empirical proof of split-brain: both task1 and task2 are simultaneously alive
        assert Process.alive?(task1_pid)
        assert Process.alive?(task2_pid)
      end

      # Cleanup
      SessionServer.cancel_session(session.id, action: :rollback)
    end
  end

  describe "Vulnerability 3: Goal Re-entrance Subagent Collision" do
    test "creating goal while previous goal is running causes subagent collision", %{
      session: session,
      test_root: test_root
    } do
      File.write!(
        Path.join(test_root, "collision.ex"),
        "defmodule Collision do\n  def test, do: true\nend"
      )

      {:ok, goal1} =
        SessionServer.create_goal(session.id, "Goal 1 - Initial",
          project_root: test_root,
          auto_start: true
        )

      assert_receive {:session_status_changed, "running"}, 5000

      # Immediately launch Goal 2 without cancelling Goal 1
      {:ok, goal2} =
        SessionServer.create_goal(session.id, "Goal 2 - Override",
          project_root: test_root,
          auto_start: true
        )

      assert goal1.id != goal2.id
      assert goal1.task_pid != goal2.task_pid

      # Both tasks compete for the same registered agent GenServers in AgentRegistry
      agents = AgentRegistry.list_agents(session.id)
      assert length(agents) > 0

      # Cleanup
      SessionServer.cancel_session(session.id, action: :rollback)
    end
  end
end
