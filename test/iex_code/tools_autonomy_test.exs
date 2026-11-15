defmodule IexCode.ToolsAutonomyTest do
  use IexCode.DataCase, async: false

  alias IexCode.Engine.PlanStore
  alias IexCode.{Projects, Runs, Sessions, Settings, Tools, WorkspacePath}

  setup do
    run_id = "autonomy-#{System.unique_integer([:positive])}"
    on_exit(fn -> PlanStore.clear(run_id) end)
    %{run_id: run_id}
  end

  test "update_plan persists normalized steps", %{run_id: run_id} do
    args = %{
      "run_id" => run_id,
      "steps" => [%{"title" => "Explore"}, %{"title" => "Implement", "status" => "done"}]
    }

    assert {:ok, %{"steps" => 2, "run_id" => ^run_id}} =
             Tools.execute("update_plan", args, System.tmp_dir!())

    assert [%{"title" => "Explore", "status" => "pending"}, %{"title" => "Implement"}] =
             PlanStore.get_plan(run_id)
  end

  test "update_plan requires run context and steps", %{run_id: run_id} do
    assert {:error, :missing_run_context} =
             Tools.execute("update_plan", %{"steps" => []}, System.tmp_dir!())

    assert {:error, :plan_steps_must_be_a_list} =
             Tools.execute("update_plan", %{"run_id" => run_id}, System.tmp_dir!())
  end

  test "request_input pauses and records the question", %{run_id: run_id} do
    args = %{"run_id" => run_id, "question" => "Ship it?", "options" => ["yes", "no"]}

    assert {:pause, request} = Tools.execute("request_input", args, System.tmp_dir!())
    assert request["type"] == "input_request"
    assert request["question"] == "Ship it?"
    assert request["options"] == ["yes", "no"]
    assert PlanStore.take_input_request(run_id) == request
  end

  test "request_input requires a question", %{run_id: run_id} do
    assert {:error, :input_question_required} =
             Tools.execute("request_input", %{"run_id" => run_id}, System.tmp_dir!())
  end

  test "spawn_agent outside the loop is rejected", %{run_id: run_id} do
    assert {:error, :requires_agent_loop} =
             Tools.execute(
               "spawn_agent",
               %{"run_id" => run_id, "objective" => "do things"},
               System.tmp_dir!()
             )
  end

  test "spawn_agent requires an objective", %{run_id: run_id} do
    assert {:error, :spawn_objective_required} =
             Tools.execute("spawn_agent", %{"run_id" => run_id}, System.tmp_dir!())
  end

  test "autonomy tools are advertised with definitions" do
    defs = Tools.tool_definitions() |> Map.new(&{&1.name, &1})
    assert Map.has_key?(defs, "update_plan")
    assert Map.has_key?(defs, "request_input")
    assert Map.has_key?(defs, "spawn_agent")

    spawn_props = defs["spawn_agent"].parameters.properties
    assert spawn_props.mode.type == "string"
    assert spawn_props.mode.enum == ["coder", "research", "read_only"]
    assert spawn_props.isolate_worktree.type == "boolean"
    refute "mode" in defs["spawn_agent"].parameters.required
    refute "isolate_worktree" in defs["spawn_agent"].parameters.required
  end

  describe "spawn_agent mode and isolate_worktree pass-through" do
    setup do
      raw_root =
        Path.join(System.tmp_dir!(), "iex-tools-spawn-#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(raw_root, "lib"))
      {:ok, root} = WorkspacePath.resolve(raw_root, "")

      File.write!(
        Path.join(root, "lib/sample.ex"),
        "defmodule Sample do\n  def ping, do: :pong\nend\n"
      )

      {_, 0} = System.cmd("git", ["-C", root, "init", "-q"], stderr_to_stdout: true)

      {_, 0} =
        System.cmd("git", ["-C", root, "config", "user.email", "test@example.com"],
          stderr_to_stdout: true
        )

      {_, 0} =
        System.cmd("git", ["-C", root, "config", "user.name", "Tester"], stderr_to_stdout: true)

      {_, 0} = System.cmd("git", ["-C", root, "add", "."], stderr_to_stdout: true)

      {_, 0} =
        System.cmd("git", ["-C", root, "commit", "-q", "-m", "initial"], stderr_to_stdout: true)

      prior_settings = Settings.get_settings()

      {:ok, _} =
        Settings.update_settings(%{
          tool_approval_mode: "full_auto",
          tool_category_overrides: %{
            "shell_execution" => "auto",
            "file_mutations" => "auto",
            "git_push" => "auto",
            "web_search" => "auto"
          }
        })

      {:ok, project} =
        Projects.create_project(%{name: "Tools Spawn PassThrough", root_path: root})

      {:ok, session} =
        Sessions.create_session(%{
          project_id: project.id,
          title: "Tools Spawn PassThrough",
          model_provider: "openai",
          model_name: "live-model",
          temperature: 0.2
        })

      {:ok, _queued} =
        Runs.create_run(%{
          project_id: project.id,
          session_id: session.id,
          objective: "Parent run",
          kind: "coding_agent",
          mode: "single",
          metadata: %{"execution_policy" => %{"agent_max_turns" => 5}}
        })

      owner = "tools-spawn:#{System.unique_integer([:positive])}"
      {:ok, parent} = Runs.claim_next_run(owner, lease_ms: 300_000)

      sub_ctx = %{
        llm: IexCode.AgentLoopLLMStub,
        tool_executor: Tools,
        lease_owner: parent.lease_owner,
        run_attempt: parent.attempt,
        run_lease_generation: parent.lease_generation
      }

      Process.put(:agent_loop_receiver, self())

      on_exit(fn ->
        _ =
          Settings.update_settings(%{
            tool_approval_mode: prior_settings.tool_approval_mode,
            tool_category_overrides: prior_settings.tool_category_overrides
          })

        File.rm_rf(root)
        Process.delete(:agent_loop_responses)
        Process.delete(:agent_loop_receiver)
      end)

      %{root: root, parent: parent, sub_ctx: sub_ctx}
    end

    test "passes mode and isolate_worktree through Tools.execute(\"spawn_agent\", ...)", %{
      root: root,
      parent: parent,
      sub_ctx: sub_ctx
    } do
      # 1. Read-only mode restricts allowed_tools
      Process.put(:agent_loop_responses, [
        {:ok, %{text: "Read-only summary.", tool_calls: [], usage: %{}}}
      ])

      assert {:ok, ro_res} =
               Tools.execute(
                 "spawn_agent",
                 %{
                   "run_id" => parent.id,
                   "objective" => "Inspect repo",
                   "mode" => "read_only",
                   "max_turns" => 2,
                   "__sub_agent__" => sub_ctx
                 },
                 root
               )

      assert ro_res["mode"] == "read_only"
      assert ro_res["max_turns"] == 2
      assert ro_res["summary"] == "Read-only summary."
      assert_receive {:agent_loop_llm_call, _msgs, _sys, ro_policy}, 5_000
      assert ro_policy.allowed_tools == IexCode.Engine.SubAgent.read_only_tools()

      # 2. Isolated worktree runs in detached worktree without mutating parent root
      Process.put(:agent_loop_responses, [
        {:ok,
         %{
           text: "Writing isolated file.",
           tool_calls: [
             %{
               id: "wt-write",
               name: "write_file",
               args: %{"path" => "lib/isolated.ex", "content" => "defmodule Isolated, do: nil\n"}
             }
           ],
           usage: %{}
         }},
        {:ok, %{text: "Isolated edit finished.", tool_calls: [], usage: %{}}}
      ])

      assert {:ok, wt_res} =
               Tools.execute(
                 "spawn_agent",
                 %{
                   "run_id" => parent.id,
                   "objective" => "Edit in worktree",
                   "mode" => "coder",
                   "isolate_worktree" => true,
                   "__sub_agent__" => sub_ctx
                 },
                 root
               )

      assert wt_res["mode"] == "coder"
      assert wt_res["summary"] == "Isolated edit finished."
      assert "lib/isolated.ex" in wt_res["changed_files"]
      assert wt_res["diff_stat"] =~ "lib/isolated.ex"
      refute File.exists?(Path.join(root, "lib/isolated.ex"))

      # 3. Invalid mode / isolate_worktree rejected cleanly
      assert {:error, :invalid_sub_agent_mode} =
               Tools.execute(
                 "spawn_agent",
                 %{
                   "run_id" => parent.id,
                   "objective" => "Bad mode",
                   "mode" => "bogus",
                   "__sub_agent__" => sub_ctx
                 },
                 root
               )

      assert {:error, :invalid_isolate_worktree} =
               Tools.execute(
                 "spawn_agent",
                 %{
                   "run_id" => parent.id,
                   "objective" => "Bad worktree flag",
                   "isolate_worktree" => "not_bool",
                   "__sub_agent__" => sub_ctx
                 },
                 root
               )
    end
  end
end
