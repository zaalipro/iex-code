defmodule IexCode.Engine.AgentLoopRolloutTest do
  use IexCode.DataCase, async: false

  alias IexCode.Engine.AgentLoop
  alias IexCode.Session.Rollout
  alias IexCode.{Projects, Runs, Sessions}

  setup do
    root = Path.join(System.tmp_dir!(), "iex-loop-rollout-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    {:ok, project} = Projects.create_project(%{name: "Loop rollout", root_path: root})

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Loop rollout",
        model_provider: "openai",
        model_name: "live-model",
        temperature: 0.2
      })

    Process.put(:agent_loop_receiver, self())
    Process.put(:agent_loop_tool_result, {:ok, "tool output"})

    rollout_path =
      Path.join(System.tmp_dir!(), "rollout-log-#{System.unique_integer([:positive])}.jsonl")

    on_exit(fn ->
      File.rm_rf(root)
      File.rm(rollout_path)
      Process.delete(:agent_loop_responses)
      Process.delete(:agent_loop_tool_result)
    end)

    %{project: project, session: session, root: root, rollout_path: rollout_path}
  end

  test "loop records user, assistant, tool, and final events", context do
    run = running_run(context)

    Process.put(:agent_loop_responses, [
      {:ok,
       %{
         text: "Reading.",
         tool_calls: [%{id: "call-1", name: "read_file", args: %{"path" => "mix.exs"}}],
         usage: %{}
       }},
      {:ok, %{text: "Done.", tool_calls: [], usage: %{}}}
    ])

    assert {:ok, _result} = execute(run, context.root, context.rollout_path)
    assert {:ok, records} = Rollout.load(context.rollout_path)

    assert Enum.map(records, & &1["type"]) == ["user", "assistant", "tool", "assistant", "final"]

    assert {:ok, messages} = Rollout.resume_messages(context.rollout_path)

    assert [%{role: "user"}, %{role: "assistant"}, %{role: "tool"}, %{role: "assistant"}] =
             messages

    assert Enum.at(messages, 2).content == "tool output"
  end

  test "loop without rollout configured writes nothing", context do
    run = running_run(context)

    Process.put(:agent_loop_responses, [
      {:ok, %{text: "Done.", tool_calls: [], usage: %{}}}
    ])

    assert {:ok, _result} =
             AgentLoop.execute(run, context.root, fn _percent, _message -> :ok end,
               llm: IexCode.AgentLoopLLMStub,
               tool_executor: IexCode.AgentLoopToolStub,
               run_lease_owner: run.lease_owner,
               run_attempt: run.attempt,
               run_lease_generation: run.lease_generation,
               run_terminal_lease_ms: 30_000
             )

    refute File.exists?(context.rollout_path)
  end

  defp running_run(context) do
    attrs = %{
      project_id: context.project.id,
      session_id: context.session.id,
      objective: "Record rollout",
      kind: "coding_agent",
      mode: "single",
      metadata: %{"source" => "rollout_test", "execution_policy" => %{"agent_max_turns" => 5}}
    }

    {:ok, _queued} = Runs.create_run(attrs)
    owner = "rollout-test:#{System.unique_integer([:positive])}"
    {:ok, run} = Runs.claim_next_run(owner, lease_ms: 300_000)
    run
  end

  defp execute(run, root, rollout_path) do
    AgentLoop.execute(run, root, fn _percent, _message -> :ok end,
      llm: IexCode.AgentLoopLLMStub,
      tool_executor: IexCode.AgentLoopToolStub,
      run_lease_owner: run.lease_owner,
      run_attempt: run.attempt,
      run_lease_generation: run.lease_generation,
      run_terminal_lease_ms: 30_000,
      rollout_path: rollout_path
    )
  end
end
