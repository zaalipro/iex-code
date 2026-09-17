defmodule IexCode.Engine.AgentLoopAutonomyTest do
  use IexCode.DataCase, async: false

  alias IexCode.Engine.AgentLoop
  alias IexCode.Engine.PlanStore
  alias IexCode.{Projects, Runs, Sessions, Tools}

  setup do
    root = Path.join(System.tmp_dir!(), "iex-loop-autonomy-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    {:ok, project} = Projects.create_project(%{name: "Loop autonomy", root_path: root})

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Loop autonomy",
        model_provider: "openai",
        model_name: "live-model",
        temperature: 0.2
      })

    Process.put(:agent_loop_receiver, self())

    on_exit(fn ->
      File.rm_rf(root)
      Process.delete(:agent_loop_responses)
      Process.delete(:agent_loop_tool_result)
    end)

    %{project: project, session: session, root: root}
  end

  test "request_input pauses and resume continues with the answer", context do
    run = running_run(context)

    Process.put(:agent_loop_responses, [
      {:ok,
       %{
         text: "Need a decision.",
         tool_calls: [
           %{id: "call-ask", name: "request_input", args: %{"question" => "Ship it?"}}
         ],
         usage: %{}
       }},
      {:ok, %{text: "Shipping now.", tool_calls: [], usage: %{}}}
    ])

    assert {:paused, paused} = execute(run, context.root, tool_executor: Tools)
    assert paused.run_id == run.id
    assert paused.turn == 1
    assert paused.request["question"] == "Ship it?"
    assert paused.request["tool_call_id"] == "call-ask"

    assert %{} = PlanStore.take_pause(run.id) |> tap(&PlanStore.put_pause(run.id, &1))

    assert {:ok, result} = resume(run, context.root, "yes", tool_executor: Tools)
    assert result.turns == 2

    all = collect_llm_messages(2)
    assert Enum.any?(List.flatten(all), &(&1.content == "User answer: yes"))
    assert PlanStore.take_pause(run.id) == nil
  end

  test "resume without a pause bundle fails", context do
    run = running_run(context)

    assert {:error, :no_pause_bundle} =
             resume(run, context.root, "answer", tool_executor: Tools)
  end

  test "update_plan records steps visible to later turns", context do
    run = running_run(context)

    Process.put(:agent_loop_responses, [
      {:ok,
       %{
         text: "Planning.",
         tool_calls: [
           %{
             id: "call-plan",
             name: "update_plan",
             args: %{"steps" => [%{"title" => "Explore"}, %{"title" => "Build"}]}
           }
         ],
         usage: %{}
       }},
      {:ok, %{text: "Planned.", tool_calls: [], usage: %{}}}
    ])

    assert {:ok, _result} = execute(run, context.root, tool_executor: Tools)

    all = collect_llm_messages(2)

    assert Enum.any?(List.flatten(all), fn message ->
             message.role == "tool" and String.contains?(message.content, "2")
           end)
  end

  test "spawn_agent runs a bounded child loop and reports back", context do
    run = running_run(context)

    Process.put(:agent_loop_responses, [
      {:ok,
       %{
         text: "Delegating.",
         tool_calls: [
           %{
             id: "call-spawn",
             name: "spawn_agent",
             args: %{"objective" => "Summarize the repo", "max_turns" => 2}
           }
         ],
         usage: %{}
       }},
      {:ok, %{text: "Child summary here.", tool_calls: [], usage: %{}}},
      {:ok, %{text: "Parent done.", tool_calls: [], usage: %{}}}
    ])

    assert {:ok, _result} = execute(run, context.root, tool_executor: Tools)

    children =
      context.session.id
      |> Runs.list_runs()
      |> Enum.filter(&(&1.metadata["sub_agent"] == true))

    assert [child] = children
    assert child.metadata["parent_run_id"] == run.id
    assert child.metadata["spawn_depth"] == 1
    assert child.objective == "Summarize the repo"

    all = collect_llm_messages(3)

    assert Enum.any?(List.flatten(all), fn message ->
             message.role == "tool" and String.contains?(message.content, child.id)
           end)
  end

  test "retriable tool errors are retried then settled", context do
    run = running_run(context)

    Process.put(:agent_loop_tool_result, fn _name, _args, _root ->
      count = Process.get(:retry_probe_count, 0)
      Process.put(:retry_probe_count, count + 1)

      if count == 0, do: {:error, {:retriable, "flaky"}}, else: {:ok, "recovered"}
    end)

    Process.put(:agent_loop_responses, [
      {:ok,
       %{
         text: "Reading.",
         tool_calls: [%{id: "call-r", name: "read_file", args: %{"path" => "mix.exs"}}],
         usage: %{}
       }},
      {:ok, %{text: "Read.", tool_calls: [], usage: %{}}}
    ])

    assert {:ok, _result} = execute(run, context.root)
    assert Process.get(:retry_probe_count) == 2

    all = collect_llm_messages(2)

    assert Enum.any?(List.flatten(all), fn message ->
             message.role == "tool" and message.content == "recovered"
           end)
  end

  defp running_run(context, options \\ []) do
    policy = Keyword.get(options, :execution_policy, %{"agent_max_turns" => 5})

    attrs = %{
      project_id: context.project.id,
      session_id: context.session.id,
      objective: "Exercise autonomy tools",
      kind: "coding_agent",
      mode: "single",
      metadata: %{"source" => "autonomy_test", "execution_policy" => policy}
    }

    {:ok, _queued} = Runs.create_run(attrs)
    owner = "autonomy-test:#{System.unique_integer([:positive])}"
    {:ok, run} = Runs.claim_next_run(owner, lease_ms: 300_000)
    run
  end

  defp execute(run, root, options \\ []) do
    AgentLoop.execute(run, root, fn _percent, _message -> :ok end,
      llm: IexCode.AgentLoopLLMStub,
      tool_executor: Keyword.get(options, :tool_executor, IexCode.AgentLoopToolStub),
      run_lease_owner: run.lease_owner,
      run_attempt: run.attempt,
      run_lease_generation: run.lease_generation,
      run_terminal_lease_ms: 30_000
    )
  end

  defp resume(run, root, answer, options) do
    AgentLoop.resume(run, root, fn _percent, _message -> :ok end, answer,
      llm: IexCode.AgentLoopLLMStub,
      tool_executor: Keyword.get(options, :tool_executor, IexCode.AgentLoopToolStub),
      run_lease_owner: run.lease_owner,
      run_attempt: run.attempt,
      run_lease_generation: run.lease_generation,
      run_terminal_lease_ms: 30_000
    )
  end

  defp collect_llm_messages(count) do
    for _ <- 1..count do
      assert_receive {:agent_loop_llm_call, messages, _system, _policy}, 5_000
      messages
    end
  end
end
