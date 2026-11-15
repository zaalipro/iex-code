defmodule IexCode.Engine.SwarmCoordinatorTest do
  use IexCode.DataCase, async: false
  @moduletag timeout: 120_000
  alias IexCode.{Projects, Sessions}
  alias IexCode.CoderAgentLoopLLMStub
  alias IexCode.Engine.{SwarmCoordinator, AgentSupervisor}

  setup context do
    root_path = Map.get(context, :tmp_dir, File.cwd!())

    {:ok, project} =
      Projects.create_project(%{name: "SwarmCoord Test Proj", root_path: root_path})

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "SwarmCoord Session",
        swarm_mode: true
      })

    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")
    %{session: session, project: project}
  end

  describe "SwarmCoordinator State Machine & PubSub Telemetry" do
    @tag :tmp_dir
    test "executes full swarm lifecycle and streams stage transitions", %{
      session: session,
      tmp_dir: tmp_dir
    } do
      File.write!(
        Path.join(tmp_dir, "lib_main.ex"),
        "defmodule LibMain do\n  def hello, do: :world\nend"
      )

      {:ok, final_msg} =
        SwarmCoordinator.run(
          session.id,
          "Inspect workspace and verify hello module",
          project_root: tmp_dir
        )

      assert is_map(final_msg)
      assert final_msg.role == "assistant"
      assert String.contains?(final_msg.content, "Swarm Execution Complete")

      # Collect PubSub stage transitions
      assert_receive {:swarm_stage_changed, %{stage: :init, progress: 5}}, 5000
      assert_receive {:swarm_stage_changed, %{stage: :planning, progress: 15}}, 5000
      assert_receive {:swarm_stage_changed, %{stage: :exploring, progress: 35}}, 5000
      assert_receive {:swarm_stage_changed, %{stage: :coding, progress: 45}}, 5000
      assert_receive {:swarm_stage_changed, %{stage: :verifying, progress: 75}}, 5000
      assert_receive {:session_status_changed, "idle"}, 5000

      # Clean up subagents
      AgentSupervisor.stop_all_agents(session.id)
    end

    @tag :tmp_dir
    test "run_swarm runs asynchronously under TaskSupervisor", %{
      session: session,
      tmp_dir: tmp_dir
    } do
      File.write!(
        Path.join(tmp_dir, "lib_async.ex"),
        "defmodule LibAsync do\n  def val, do: 1\nend"
      )

      {:ok, pid} = SwarmCoordinator.run_swarm(session.id, "Analyze async files", tmp_dir)
      assert is_pid(pid)
      ref = Process.monitor(pid)

      assert_receive {:session_status_changed, "running"}, 5000
      assert_receive {:session_status_changed, "idle"}, 20_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5000

      AgentSupervisor.stop_all_agents(session.id)
    end
  end

  describe "Autonomous Error Feedback Loop & Retries" do
    @tag :tmp_dir
    test "handles verification failure with max retries cap", %{
      session: session,
      tmp_dir: tmp_dir
    } do
      # Write a file with an intentional compile/syntax error
      File.write!(
        Path.join(tmp_dir, "lib_error.ex"),
        "defmodule LibError do\n  def broken_syntax, do :error\nend"
      )

      {:ok, final_msg} =
        SwarmCoordinator.run(
          session.id,
          "Attempt to fix broken syntax",
          project_root: tmp_dir,
          max_retries: 2
        )

      assert is_map(final_msg)
      # Assert message indicates completion of swarm attempt
      assert String.contains?(final_msg.content, "Swarm Execution Complete")

      AgentSupervisor.stop_all_agents(session.id)
    end

    @tag :tmp_dir
    test "direct re-verification optimization heals syntax error via AutoFix and completes",
         %{session: session, tmp_dir: tmp_dir} do
      lib_path = Path.join(tmp_dir, "lib")
      File.mkdir_p!(lib_path)

      file = Path.join(lib_path, "calc.ex")

      File.write!(file, """
      defmodule Calc do
        def hello(name), do "world"
      end
      """)

      {:ok, final_msg} =
        SwarmCoordinator.run(
          session.id,
          "Fix syntax error in calc.ex",
          project_root: tmp_dir,
          max_retries: 3
        )

      assert final_msg.metadata.status == :completed
      assert String.contains?(final_msg.content, "Swarm Execution Complete")

      # Confirm AutoFix healed the syntax error
      assert File.read!(file) =~ ~s(do: "world")

      AgentSupervisor.stop_all_agents(session.id)
    end

    @tag :tmp_dir
    test "verifier rejection triggers planner replanning stage in feedback loop",
         %{session: session, tmp_dir: tmp_dir} do
      lib_path = Path.join(tmp_dir, "lib")
      File.mkdir_p!(lib_path)

      # Unfixable syntax error that fails verification
      file = Path.join(lib_path, "syntax_err.ex")
      File.write!(file, "defmodule SyntaxErr do\n  def unclosed do\nend")

      {:ok, final_msg} =
        SwarmCoordinator.run(
          session.id,
          "Replan on verification rejection",
          project_root: tmp_dir,
          max_retries: 2
        )

      assert is_map(final_msg)
      # Assert stage transitions include initial planning and replanning on verifier rejection
      assert_receive {:swarm_stage_changed, %{stage: :planning, progress: 15}}, 5000
      assert_receive {:swarm_stage_changed, %{stage: :planning, progress: 25}}, 5000
      assert_receive {:swarm_stage_changed, %{stage: :exploring}}, 5000
      assert_receive {:swarm_stage_changed, %{stage: :coding}}, 5000
      assert_receive {:swarm_stage_changed, %{stage: :verifying}}, 5000
      # Verifier failure leads to replanning stage broadcast
      assert_receive {:swarm_stage_changed, %{stage: :planning, message: msg}}, 5000
      assert String.contains?(msg, "Replanning") or String.contains?(msg, "Refined")

      AgentSupervisor.stop_all_agents(session.id)
    end

    @tag :tmp_dir
    test "durable swarm coordinates scaled fleet (8 workers with 5 explorers)",
         %{project: project, session: session, tmp_dir: tmp_dir} do
      {:ok, _queued} =
        IexCode.Runs.create_run(%{
          project_id: project.id,
          session_id: session.id,
          objective: "scaled fleet coordination",
          kind: "coding_swarm",
          mode: "swarm",
          metadata: %{
            "execution_policy" => %{
              "swarm_agent_count" => 8
            }
          }
        })

      owner = "scaled-swarm:#{System.unique_integer([:positive])}"
      {:ok, run} = IexCode.Runs.claim_next_run(owner, lease_ms: 300_000)
      on_exit(fn -> IexCode.Engine.FleetSupervisor.stop(run.id) end)

      assert {:ok, agents} =
               IexCode.Engine.FleetSupervisor.attach(run, project_root: tmp_dir)

      assert length(agents) == 8
      assert Enum.count(agents, &(&1.role == :explorer)) == 5
      assert Enum.count(agents, &(&1.role == :planner)) == 1
      assert Enum.count(agents, &(&1.role == :coder)) == 1
      assert Enum.count(agents, &(&1.role == :verifier)) == 1

      # Verify all 8 agent processes respond synchronously via OTP :sys.get_state/1
      assert Enum.all?(agents, fn agent -> is_map(:sys.get_state(agent.pid)) end)
    end
  end

  describe "Opt-in Worktree Isolation & Arbitrated Self-Healing" do
    @tag :tmp_dir
    test "isolate_worktree: true syncs verified changes on pass and leaves project_root untouched on failure",
         %{session: session, tmp_dir: tmp_dir} do
      init_git_repo!(tmp_dir)

      lib_dir = Path.join(tmp_dir, "lib")
      File.mkdir_p!(lib_dir)
      target_file = Path.join(lib_dir, "isolated_mod.ex")
      original_source = "defmodule IsolatedMod do\n  def version, do: :v1\nend\n"
      File.write!(target_file, original_source)
      git_commit_all!(tmp_dir, "initial commit")

      # 1. Failed swarm run inside isolated worktree must NOT mutate project_root
      broken_source = "defmodule IsolatedMod do\n  def unclosed do\nend\n"

      fail_responses = [
        {:ok, %{text: "Plan: introduce change", tool_calls: []}},
        {:ok,
         %{
           text: "Writing broken file in worktree",
           tool_calls: [
             %{
               id: "wt-fail-1",
               name: "write_file",
               args: %{"path" => "lib/isolated_mod.ex", "content" => broken_source}
             },
             %{
               id: "wt-fail-2",
               name: "write_file",
               args: %{
                 "path" => "lib/leaked_artifact.ex",
                 "content" => "defmodule LeakedArtifact, do: nil\n"
               }
             }
           ]
         }},
        {:ok, %{text: "Done turn 0", tool_calls: []}}
      ]

      start_supervised!({CoderAgentLoopLLMStub, fail_responses})

      {:ok, planner_pid} =
        AgentSupervisor.start_agent(session.id, :planner,
          project_root: tmp_dir,
          llm: CoderAgentLoopLLMStub
        )

      {:ok, coder_pid} =
        AgentSupervisor.start_agent(session.id, :coder,
          project_root: tmp_dir,
          llm: CoderAgentLoopLLMStub
        )

      Ecto.Adapters.SQL.Sandbox.allow(IexCode.Repo, self(), planner_pid)
      Ecto.Adapters.SQL.Sandbox.allow(IexCode.Repo, self(), coder_pid)

      assert {:ok, failed_msg} =
               SwarmCoordinator.run(
                 session.id,
                 "Attempt risky edit in isolated worktree",
                 project_root: tmp_dir,
                 isolate_worktree: true,
                 max_retries: 0
               )

      assert failed_msg.metadata.status == :failed
      assert File.read!(target_file) == original_source
      refute File.exists?(Path.join(lib_dir, "leaked_artifact.ex"))
      assert git_worktree_count(tmp_dir) == 1

      stop_supervised!(CoderAgentLoopLLMStub)

      # 2. Successful swarm run inside isolated worktree syncs verified changes back to project_root
      valid_v2 = "defmodule IsolatedMod do\n  def version, do: :v2\nend\n"

      pass_responses = [
        {:ok, %{text: "Plan: upgrade IsolatedMod to :v2", tool_calls: []}},
        {:ok,
         %{
           text: "Updating IsolatedMod in worktree",
           tool_calls: [
             %{
               id: "wt-pass-1",
               name: "write_file",
               args: %{"path" => "lib/isolated_mod.ex", "content" => valid_v2}
             }
           ]
         }},
        {:ok, %{text: "Updated cleanly", tool_calls: []}}
      ]

      start_supervised!({CoderAgentLoopLLMStub, pass_responses})

      {:ok, planner_pid2} =
        AgentSupervisor.start_agent(session.id, :planner,
          project_root: tmp_dir,
          llm: CoderAgentLoopLLMStub
        )

      {:ok, coder_pid2} =
        AgentSupervisor.start_agent(session.id, :coder,
          project_root: tmp_dir,
          llm: CoderAgentLoopLLMStub
        )

      Ecto.Adapters.SQL.Sandbox.allow(IexCode.Repo, self(), planner_pid2)
      Ecto.Adapters.SQL.Sandbox.allow(IexCode.Repo, self(), coder_pid2)

      assert {:ok, passed_msg} =
               SwarmCoordinator.run(
                 session.id,
                 "Upgrade IsolatedMod to v2",
                 project_root: tmp_dir,
                 isolate_worktree: true,
                 max_retries: 1
               )

      assert passed_msg.metadata.status == :completed
      assert File.read!(target_file) == valid_v2
      assert git_worktree_count(tmp_dir) == 1

      AgentSupervisor.stop_all_agents(session.id)
    end

    @tag :tmp_dir
    test "isolate_worktree: true gracefully falls back on non-git workspace",
         %{session: session, tmp_dir: tmp_dir} do
      File.write!(
        Path.join(tmp_dir, "plain.ex"),
        "defmodule Plain do\n  def ok?, do: true\nend\n"
      )

      assert {:ok, final_msg} =
               SwarmCoordinator.run(
                 session.id,
                 "Verify non-git fallback",
                 project_root: tmp_dir,
                 isolate_worktree: true
               )

      assert final_msg.metadata.status == :completed
      AgentSupervisor.stop_all_agents(session.id)
    end
  end

  defp init_git_repo!(dir) do
    {_, 0} = System.cmd("git", ["init"], cd: dir, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["config", "user.email", "swarm@test.local"], cd: dir)
    {_, 0} = System.cmd("git", ["config", "user.name", "Swarm Test"], cd: dir)
  end

  defp git_commit_all!(dir, message) do
    {_, 0} = System.cmd("git", ["add", "."], cd: dir, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["commit", "-m", message], cd: dir, stderr_to_stdout: true)
  end

  defp git_worktree_count(dir) do
    {out, 0} = System.cmd("git", ["worktree", "list", "--porcelain"], cd: dir)

    out
    |> String.split("\n")
    |> Enum.count(&String.starts_with?(&1, "worktree "))
  end
end
