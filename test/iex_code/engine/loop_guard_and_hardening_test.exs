defmodule IexCode.Engine.LoopGuardAndHardeningTest do
  use IexCode.DataCase, async: false

  alias IexCode.Engine.{AgentLoop, LoopGuard, SwarmCoordinator}
  alias IexCode.Engine.Agents.{CoderAgent, ExplorerAgent, PlannerAgent}
  alias IexCode.{CoderAgentLoopLLMStub, Projects, Runs, Sessions, Settings}

  setup do
    root =
      Path.join(System.tmp_dir!(), "iex-engine-hardening-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    File.write!(Path.join(root, "sample.ex"), "defmodule Sample do\n  def ok, do: :ok\nend\n")

    {:ok, project} = Projects.create_project(%{name: "Engine Hardening", root_path: root})

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Engine Hardening Session",
        model_provider: "openai",
        model_name: "gpt-4o-mini",
        temperature: 0.2
      })

    Process.put(:agent_loop_receiver, self())
    Process.put(:agent_loop_tool_result, {:ok, "ok"})

    on_exit(fn -> File.rm_rf(root) end)

    %{project: project, session: session, root: root}
  end

  describe "LoopGuard pure functional tracker" do
    test "computes canonical args digests invariant to key order, atom/string keys, and internal harness keys" do
      digest_a =
        LoopGuard.canonical_args_digest(%{
          "path" => "lib/foo.ex",
          "target" => "old",
          "replacement" => "new",
          "op_id" => "op-1",
          "__workspace_lock_identity__" => %{owner: "a"}
        })

      digest_b =
        LoopGuard.canonical_args_digest(%{
          replacement: "new",
          path: "lib/foo.ex",
          target: "old",
          op_id: "op-999"
        })

      digest_different =
        LoopGuard.canonical_args_digest(%{
          "path" => "lib/foo.ex",
          "target" => "different_target",
          "replacement" => "new"
        })

      assert digest_a == digest_b
      assert digest_a != digest_different
    end

    test "detects all failure signatures without false positives on successful calls or content reads" do
      assert LoopGuard.failing_result?({:error, :enoent}, "read_file")
      assert LoopGuard.failing_output?("read_file", "Tool failed: :enoent")
      assert LoopGuard.failing_output?("read_file", "ERROR: File not found")
      assert LoopGuard.failing_output?("run_command", "Exit Code 1:\n** (CompileError) boom")
      assert LoopGuard.failing_output?("run_command", "Exit Code 127:\ncommand not found")
      assert LoopGuard.failing_output?("edit_file", "Target content not found in lib/foo.ex")
      assert LoopGuard.failing_output?("multi_patch", "MultiPatch failed: :not_found")
      assert LoopGuard.failing_output?("edit_file", "Ambiguous target in lib/foo.ex")

      refute LoopGuard.failing_output?("run_command", "Exit Code 0:\n12 tests, 0 failures")
      refute LoopGuard.failing_result?({:ok, "ok"}, "read_file")

      # Reading source files that mention error strings must NOT false-positive
      source_snippet =
        "1: {:error, \"Target content not found\"}\n2: \"MultiPatch failed\"\n3: Exit Code 1:"

      refute LoopGuard.failing_output?("read_file", source_snippet)
      refute LoopGuard.failing_output?("grep_search", source_snippet)
    end

    test "records 4-tuples, appends [HARNESS LOOP GUARD] on 3rd identical failure, and halts on 5th consecutive failure" do
      guard = LoopGuard.new()
      args = %{"path" => "lib/sample.ex", "target" => "missing", "replacement" => "fixed"}
      fail_msg = "Tool failed: \"Target content not found in lib/sample.ex\""

      assert {:ok, out1, guard} = LoopGuard.record(guard, "edit_file", args, fail_msg)
      assert out1 == fail_msg

      assert {:ok, out2, guard} = LoopGuard.record(guard, "edit_file", args, fail_msg)
      assert out2 == fail_msg

      assert {:ok, out3, guard} = LoopGuard.record(guard, "edit_file", args, fail_msg)
      assert out3 =~ fail_msg
      assert out3 =~ "[HARNESS LOOP GUARD]"
      assert out3 =~ "edit_file"

      assert {:ok, out4, guard} = LoopGuard.record(guard, "edit_file", args, fail_msg)
      assert out4 =~ "[HARNESS LOOP GUARD]"

      assert {:halt, {:agent_doom_loop_detected, "edit_file"}, guard} =
               LoopGuard.record(guard, "edit_file", args, fail_msg)

      entries = LoopGuard.entries(guard)
      assert length(entries) == 5

      expected_args_digest = LoopGuard.canonical_args_digest(args)
      expected_out_digest = LoopGuard.output_digest(fail_msg)

      assert Enum.all?(entries, fn entry ->
               entry == {"edit_file", expected_args_digest, true, expected_out_digest}
             end)
    end

    test "never alters output or halts across repeated identical successful calls" do
      guard = LoopGuard.new()

      final_guard =
        Enum.reduce(1..12, guard, fn _idx, acc ->
          assert {:ok, "ok", next} =
                   LoopGuard.record(acc, "read_file", %{"path" => "mix.exs"}, "ok")

          next
        end)

      assert length(LoopGuard.entries(final_guard)) == 12
      assert final_guard.consecutive_failures == 0
      assert Enum.all?(LoopGuard.entries(final_guard), fn {_, _, err?, _} -> err? == false end)
    end

    test "intervening context read resets consecutive streak while keeping cumulative warning on 3rd identical failure" do
      guard = LoopGuard.new()
      bad_args = %{"path" => "lib/a.ex", "target" => "nope", "replacement" => "yep"}

      {:ok, out1, guard} =
        LoopGuard.record(guard, "edit_file", bad_args, "Target content not found")

      refute out1 =~ "[HARNESS LOOP GUARD]"

      {:ok, out2, guard} =
        LoopGuard.record(guard, "edit_file", bad_args, "Target content not found")

      refute out2 =~ "[HARNESS LOOP GUARD]"

      # Agent inspects file in between
      {:ok, "file contents", guard} =
        LoopGuard.record(guard, "read_file", %{"path" => "lib/a.ex"}, "file contents")

      assert guard.consecutive_failures == 0

      # 3rd cumulative failure with identical args still gets guidance suffix, not hard halt
      {:ok, out3, guard} =
        LoopGuard.record(guard, "edit_file", bad_args, "Target content not found")

      assert out3 =~ "[HARNESS LOOP GUARD]"
      assert guard.consecutive_failures == 1
    end
  end

  describe "AgentLoop doom-loop guard & deterministic replay" do
    test "injects [HARNESS LOOP GUARD] on 3rd identical failing call and allows recovery on turn 4",
         context do
      run = running_run(context, execution_policy: %{"agent_max_turns" => 6})

      Process.put(:agent_loop_tool_result, fn
        "edit_file", %{"target" => "bad"}, _root ->
          {:error, "Target content not found in sample.ex"}

        "edit_file", %{"target" => "good"}, _root ->
          {:ok, "Edited sample.ex"}
      end)

      bad_call = fn idx ->
        {:ok,
         %{
           text: "attempt #{idx}",
           tool_calls: [
             %{id: "call-#{idx}", name: "edit_file", args: %{"target" => "bad"}}
           ],
           usage: %{}
         }}
      end

      Process.put(:agent_loop_responses, [
        bad_call.(1),
        bad_call.(2),
        bad_call.(3),
        {:ok,
         %{
           text: "adjusting approach after loop guard",
           tool_calls: [
             %{id: "call-4", name: "edit_file", args: %{"target" => "good"}}
           ],
           usage: %{}
         }},
        {:ok, %{text: "Recovered cleanly.", tool_calls: [], usage: %{}}}
      ])

      assert {:ok, result} = execute(run, context.root)
      assert result.content == "Recovered cleanly."
      assert result.turns == 5
      assert result.tool_calls == 4

      # Inspect turn 4 outgoing messages to confirm 3rd failing tool message carried [HARNESS LOOP GUARD]
      assert_receive {:agent_loop_llm_call, _turn1, _, _}
      assert_receive {:agent_loop_llm_call, _turn2, _, _}
      assert_receive {:agent_loop_llm_call, turn3_msgs, _, _}
      assert_receive {:agent_loop_llm_call, turn4_msgs, _, _}

      refute Enum.any?(turn3_msgs, &String.contains?(&1.content, "[HARNESS LOOP GUARD]"))

      tool_3_msg = Enum.find(turn4_msgs, &(Map.get(&1, :tool_call_id) == "call-3"))
      assert tool_3_msg.content =~ "[HARNESS LOOP GUARD]"
    end

    test "halts cleanly with {:agent_doom_loop_detected, tool_name} on 5th consecutive identical failing call",
         context do
      run = running_run(context, execution_policy: %{"agent_max_turns" => 8})

      Process.put(:agent_loop_tool_result, {:ok, "Exit Code 1:\nmix test failed"})

      failing_turn = fn idx ->
        {:ok,
         %{
           text: "retry #{idx}",
           tool_calls: [
             %{
               id: "doom-#{idx}",
               name: "run_tests",
               args: %{"test_path" => "test/sample_test.exs"}
             }
           ],
           usage: %{}
         }}
      end

      Process.put(:agent_loop_responses, Enum.map(1..6, failing_turn))

      assert {:error, {:agent_doom_loop_detected, "run_tests"}} = execute(run, context.root)

      commands =
        run
        |> Runs.list_commands()
        |> Enum.reject(&(&1.tool_name == "__llm_chat__"))

      assert length(commands) == 5
      assert Enum.all?(commands, &(&1.status in ["completed", "failed"]))
    end

    test "never halts or modifies tool outputs for repeated identical successful calls across turns",
         context do
      run = running_run(context, execution_policy: %{"agent_max_turns" => 7})
      Process.put(:agent_loop_tool_result, {:ok, "ok"})

      ok_turn = fn idx ->
        {:ok,
         %{
           text: "ok turn #{idx}",
           tool_calls: [
             %{id: "ok-#{idx}", name: "read_file", args: %{"path" => "sample.ex"}}
           ],
           usage: %{}
         }}
      end

      Process.put(
        :agent_loop_responses,
        Enum.map(1..6, ok_turn) ++ [{:ok, %{text: "All good.", tool_calls: [], usage: %{}}}]
      )

      assert {:ok, result} = execute(run, context.root)
      assert result.content == "All good."
      assert result.tool_calls == 6

      for _ <- 1..7 do
        assert_receive {:agent_loop_llm_call, transcript, _, _}
        refute Enum.any?(transcript, &String.contains?(&1.content, "[HARNESS LOOP GUARD]"))
      end
    end

    test "preserves deterministic command replay across 3 failing turns without context_sha256 conflict",
         context do
      run = running_run(context, execution_policy: %{"agent_max_turns" => 4})

      failing_read = fn idx ->
        {:ok,
         %{
           text: "read #{idx}",
           tool_calls: [
             %{id: "replay-#{idx}", name: "read_file", args: %{"path" => "missing.txt"}}
           ],
           usage: %{}
         }}
      end

      Process.put(:agent_loop_tool_result, fn
        "read_file", %{"path" => "missing.txt"}, _root -> {:error, :enoent}
        "read_file", %{"path" => "sample.ex"}, _root -> {:ok, "defmodule Sample"}
      end)

      Process.put(:agent_loop_responses, [
        failing_read.(1),
        failing_read.(2),
        failing_read.(3),
        {:ok,
         %{
           text: "inspect existing file instead",
           tool_calls: [
             %{id: "replay-4", name: "read_file", args: %{"path" => "sample.ex"}}
           ],
           usage: %{}
         }}
      ])

      assert {:error, {:agent_turn_limit_exceeded, 4}} = execute(run, context.root)

      for _ <- 1..4 do
        assert_receive {:agent_loop_llm_call, _, _, _}
        assert_receive {:agent_loop_tool_call, _, _, _}
      end

      # Replay `run` from scratch on the same attempt: turns 1..4 (including turn 4's
      # context_sha256 computed over turn 3's [HARNESS LOOP GUARD] message) MUST replay
      # deterministically from SQLite receipts with zero `:model_turn_idempotency_conflict`
      # and zero live LLM/tool dispatches.
      Process.put(:agent_loop_responses, [])
      assert {:error, {:agent_turn_limit_exceeded, 4}} = execute(run, context.root)
      refute_receive {:agent_loop_llm_call, _, _, _}
      refute_receive {:agent_loop_tool_call, _, _, _}
    end
  end

  describe "AgentLoop native gemini provider support" do
    test "accepts gemini in effective_session/2 and persists gemini metadata", context do
      gemini_run =
        running_run(context,
          execution_policy: %{
            "agent_max_turns" => 3,
            "model_provider" => "gemini",
            "model_name" => "gemini-2.5-pro",
            "temperature" => 0.3
          }
        )

      persist_completed_model_turn(
        gemini_run,
        "gemini",
        "gemini-2.5-pro",
        "Gemini response ready."
      )

      assert {:ok, result} = execute(gemini_run, context.root)
      assert result.content == "Gemini response ready."

      final_msg = Sessions.get_run_final_message(gemini_run)
      assert final_msg.metadata["model_provider"] == "gemini"
      assert final_msg.metadata["model_name"] == "gemini-2.5-pro"
    end

    test "rejects unsupported providers with :invalid_execution_model_provider", context do
      invalid_run =
        running_run(context,
          execution_policy: %{
            "agent_max_turns" => 3,
            "model_provider" => "unsupported_provider",
            "model_name" => "some-model"
          }
        )

      assert {:error, :invalid_execution_model_provider} = execute(invalid_run, context.root)
    end
  end

  describe "CoderAgent doom-loop guard" do
    test "appends [HARNESS LOOP GUARD] on 3rd identical failing call and halts on 5th consecutive failure",
         context do
      responses =
        Enum.map(1..6, fn idx ->
          {:ok,
           %{
             text: "attempt #{idx}",
             tool_calls: [
               %{
                 id: "coder-fail-#{idx}",
                 name: "patch_file",
                 args: %{
                   "path" => "sample.ex",
                   "target_content" => "non_existent_snippet",
                   "replacement_content" => "updated"
                 }
               }
             ]
           }}
        end)

      start_supervised!({CoderAgentLoopLLMStub, responses})

      assert {:ok, high_settings} = Settings.update_settings(%{agent_max_turns: 8})
      high_policy = Settings.execution_policy(high_settings, context.session)

      pid =
        start_supervised!(
          {CoderAgent,
           session_id: context.session.id,
           session: context.session,
           project_root: context.root,
           llm: CoderAgentLoopLLMStub}
        )

      assert {:error, {:agent_doom_loop_detected, "patch_file"}} =
               CoderAgent.code(pid, "Update sample.ex",
                 execution_policy: high_policy,
                 allowed_tools: ["patch_file", "read_file"]
               )

      assert CoderAgentLoopLLMStub.calls() == 5

      requests = CoderAgentLoopLLMStub.requests()
      turn4_messages = Enum.at(requests, 3)
      tool_3 = Enum.find(turn4_messages, &(Map.get(&1, :tool_call_id) == "coder-fail-3"))
      assert tool_3.content =~ "[HARNESS LOOP GUARD]"
    end
  end

  describe "Bounded OTP agent & SwarmCoordinator histories (@history_limit 20)" do
    test "CoderAgent caps state.history at 20 entries", context do
      responses =
        Enum.map(1..25, fn idx ->
          {:ok, %{text: "code-result-#{idx}", tool_calls: []}}
        end)

      start_supervised!({CoderAgentLoopLLMStub, responses})

      pid =
        start_supervised!(
          {CoderAgent,
           session_id: context.session.id,
           session: context.session,
           project_root: context.root,
           llm: CoderAgentLoopLLMStub}
        )

      for idx <- 1..25 do
        assert {:ok, _} = CoderAgent.code(pid, "Task #{idx}", allowed_tools: [])
      end

      state = CoderAgent.get_state(pid)
      assert length(state.history) == 20
      assert hd(state.history) == "code-result-25"
      assert List.last(state.history) == "code-result-6"
    end

    test "PlannerAgent caps state.history at 20 entries", context do
      responses =
        Enum.map(1..25, fn idx ->
          {:ok, %{text: "plan-result-#{idx}"}}
        end)

      start_supervised!({CoderAgentLoopLLMStub, responses})

      pid =
        start_supervised!(
          {PlannerAgent,
           session_id: context.session.id,
           session: context.session,
           project_root: context.root,
           llm: CoderAgentLoopLLMStub}
        )

      for idx <- 1..25 do
        assert {:ok, _} = PlannerAgent.plan(pid, "Plan #{idx}", allowed_tools: [])
      end

      state = PlannerAgent.get_state(pid)
      assert length(state.history) == 20
      assert hd(state.history) == "plan-result-25"
      assert List.last(state.history) == "plan-result-6"
    end

    test "ExplorerAgent caps state.history at 20 entries", context do
      pid =
        start_supervised!(
          {ExplorerAgent,
           session_id: context.session.id, session: context.session, project_root: context.root}
        )

      for idx <- 1..25 do
        assert {:ok, _} = ExplorerAgent.explore(pid, "Explore #{idx}", allowed_tools: [])
      end

      state = ExplorerAgent.get_state(pid)
      assert length(state.history) == 20
    end

    test "SwarmCoordinator caps state.history at 20 entries" do
      initial = %SwarmCoordinator.State{session_id: "sess-1", history: []}

      final =
        Enum.reduce(1..25, initial, fn idx, acc ->
          SwarmCoordinator.record_history_entry(acc, {idx, %{status: :failed}, nil})
        end)

      assert length(final.history) == 20
      assert hd(final.history) == {25, %{status: :failed}, nil}
      assert List.last(final.history) == {6, %{status: :failed}, nil}
    end
  end

  defp running_run(context, options) do
    policy = Keyword.get(options, :execution_policy, %{"agent_max_turns" => 5})

    attrs = %{
      project_id: context.project.id,
      session_id: context.session.id,
      objective: "Inspect and repair workspace",
      kind: "coding_agent",
      mode: "single",
      metadata: %{
        "source" => "loop_guard_and_hardening_test",
        "execution_policy" => policy
      }
    }

    {:ok, _queued} = Runs.create_run(attrs)
    owner = "hardening-test:#{System.unique_integer([:positive])}"
    {:ok, run} = Runs.claim_next_run(owner, lease_ms: 300_000)
    run
  end

  defp execute(run, root) do
    AgentLoop.execute(run, root, fn _percent, _message -> :ok end,
      llm: IexCode.AgentLoopLLMStub,
      tool_executor: IexCode.AgentLoopToolStub,
      run_lease_owner: run.lease_owner,
      run_attempt: run.attempt,
      run_lease_generation: run.lease_generation,
      run_terminal_lease_ms: 30_000
    )
  end

  defp persist_completed_model_turn(run, provider, model_name, text) do
    authority = [
      lease_owner: run.lease_owner,
      run_attempt: run.attempt,
      lease_generation: run.lease_generation,
      terminal_lease_ms: 30_000
    ]

    context_sha =
      [%{role: "user", content: run.objective}]
      |> Jason.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    arguments = %{
      "turn" => 1,
      "context_sha256" => context_sha,
      "steering_control_ids" => [],
      "model_provider" => provider,
      "model_name" => model_name,
      "max_tokens" => nil
    }

    assert {:ok, queued} =
             Runs.enqueue_command_worker(
               run,
               "agent-loop:model:#{run.attempt}:turn:1",
               %{tool_name: "__llm_chat__", arguments: arguments, max_attempts: 1},
               authority
             )

    assert {:ok, running} =
             Runs.transition_command_worker(
               queued,
               "running",
               %{attempt: queued.attempt + 1},
               authority
             )

    receipt = Jason.encode!(%{"text" => text, "tool_calls" => [], "usage" => %{}})

    assert {:ok, _completed} =
             Runs.transition_command_worker(
               running,
               "completed",
               %{output: receipt},
               authority
             )
  end
end
