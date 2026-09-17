defmodule IexCode.Engine.AgentCancellationTest do
  use IexCode.DataCase, async: false

  alias IexCode.{Projects, Sessions}
  alias IexCode.Engine.AgentCancellation
  alias IexCode.Engine.Agents.{CoderAgent, ExplorerAgent, PlannerAgent, VerifierAgent}
  alias IexCode.Engine.{AgentSupervisor, SwarmCoordinator}
  alias IexCode.LatchingAgentLLMStub

  setup do
    {:ok, project} = Projects.create_project(%{name: "Cancel Test", root_path: File.cwd!()})
    {:ok, session} = Sessions.create_session(%{project_id: project.id, title: "Cancel Test"})

    on_exit(fn ->
      AgentCancellation.resume(session.id)
      LatchingAgentLLMStub.unregister(session.id)
    end)

    %{session: session, project: project}
  end

  describe "flag ownership" do
    test "cancel sets and resume clears every agent flag", %{session: session} do
      assert AgentCancellation.agents() == [
               CoderAgent,
               ExplorerAgent,
               PlannerAgent,
               VerifierAgent
             ]

      for agent <- AgentCancellation.agents() do
        refute AgentCancellation.cancelled?(session.id, agent)
      end

      assert :ok = AgentCancellation.cancel(session.id)

      for agent <- AgentCancellation.agents() do
        assert AgentCancellation.cancelled?(session.id, agent)
      end

      assert :ok = AgentCancellation.resume(session.id)

      for agent <- AgentCancellation.agents() do
        refute AgentCancellation.cancelled?(session.id, agent)
      end
    end

    test "flags are isolated per agent and per session", %{session: session} do
      assert :ok = AgentCancellation.set(PlannerAgent, session.id, true)
      assert AgentCancellation.cancelled?(session.id, PlannerAgent)
      refute AgentCancellation.cancelled?(session.id, CoderAgent)
      refute AgentCancellation.cancelled?(session.id, ExplorerAgent)
      refute AgentCancellation.cancelled?(session.id, VerifierAgent)

      other = Ecto.UUID.generate()
      refute AgentCancellation.cancelled?(other, PlannerAgent)
    end

    test "unknown sessions default to not cancelled" do
      refute AgentCancellation.cancelled?(Ecto.UUID.generate(), PlannerAgent)
    end
  end

  describe "sender integration" do
    test "coordinator cancel/pause/resume write flags directly", %{session: session} do
      SwarmCoordinator.cancel(session.id)
      assert AgentCancellation.cancelled?(session.id, PlannerAgent)
      assert AgentCancellation.cancelled?(session.id, CoderAgent)

      SwarmCoordinator.resume(session.id)
      refute AgentCancellation.cancelled?(session.id, PlannerAgent)

      SwarmCoordinator.pause(session.id)
      assert AgentCancellation.cancelled?(session.id, ExplorerAgent)

      SwarmCoordinator.resume(session.id)
      refute AgentCancellation.cancelled?(session.id, ExplorerAgent)
    end
  end

  describe "prompt cancellation of blocked agents" do
    test "cancel lands while the planner is blocked inside plan", %{
      session: session,
      project: project
    } do
      {:ok, pid} =
        AgentSupervisor.start_agent(session.id, :planner,
          project_root: project.root_path,
          llm: LatchingAgentLLMStub
        )

      Ecto.Adapters.SQL.Sandbox.allow(IexCode.Repo, self(), pid)
      LatchingAgentLLMStub.register(session.id, self())

      plan_task = Task.async(fn -> PlannerAgent.plan(pid, "Long blocking plan") end)
      assert_receive {:latch_llm_entered, task_pid}, 5_000

      # The agent is stuck inside handle_call; the old broadcast-only path
      # could not flip the flag until the plan finished.
      AgentCancellation.cancel(session.id)
      assert AgentCancellation.cancelled?(session.id, PlannerAgent)

      send(task_pid, :latch_llm_release)
      assert Task.await(plan_task, 10_000) == {:error, :cancelled}
      assert PlannerAgent.get_state(pid).last_result == {:error, :cancelled}

      AgentSupervisor.stop_agent(session.id, :planner)
    end
  end
end
