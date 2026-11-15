defmodule IexCode.Engine.SubAgentIsolationTest do
  use IexCode.DataCase, async: false

  alias IexCode.Engine.SubAgent
  alias IexCode.{Projects, Runs, Sessions, Settings, Tools, WorkspacePath}

  setup do
    raw_root =
      Path.join(System.tmp_dir!(), "iex-subagent-iso-#{System.unique_integer([:positive])}")

    File.mkdir_p!(raw_root)

    {:ok, root} = WorkspacePath.resolve(raw_root, "")
    init_git_repo!(root)

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

    {:ok, project} = Projects.create_project(%{name: "SubAgent Isolation", root_path: root})

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "SubAgent Isolation",
        model_provider: "openai",
        model_name: "live-model",
        temperature: 0.2
      })

    Process.put(:agent_loop_receiver, self())

    on_exit(fn ->
      _ =
        Settings.update_settings(%{
          tool_approval_mode: prior_settings.tool_approval_mode,
          tool_category_overrides: prior_settings.tool_category_overrides
        })

      File.rm_rf(root)
      Process.delete(:agent_loop_responses)
      Process.delete(:agent_loop_tool_result)
      Process.delete(:agent_loop_receiver)
    end)

    %{project: project, session: session, root: root}
  end

  describe "sub-agent modes (coder vs research / read_only)" do
    test "read_only and research modes restrict allowed_tools and block mutations", context do
      parent = claim_parent_run(context)

      for ro_mode <- ["read_only", "research"] do
        Process.put(:agent_loop_responses, [
          {:ok,
           %{
             text: "Attempting write then reading.",
             tool_calls: [
               %{
                 id: "call-write-#{ro_mode}",
                 name: "write_file",
                 args: %{"path" => "forbidden_#{ro_mode}.txt", "content" => "nope"}
               },
               %{
                 id: "call-read-#{ro_mode}",
                 name: "read_file",
                 args: %{"path" => "lib/sample.ex"}
               }
             ],
             usage: %{}
           }},
          {:ok,
           %{text: "Read-only inspection complete for #{ro_mode}.", tool_calls: [], usage: %{}}}
        ])

        sub_ctx = sub_agent_context(parent, %{mode: ro_mode, max_turns: 3})

        assert {:ok, result} =
                 SubAgent.run(parent.id, "Audit #{ro_mode}", context.root, sub_ctx)

        assert result["mode"] == ro_mode
        assert result["summary"] == "Read-only inspection complete for #{ro_mode}."
        assert is_binary(result["message_id"])
        refute File.exists?(Path.join(context.root, "forbidden_#{ro_mode}.txt"))

        [{_msgs1, policy1}, {msgs2, _policy2}] = collect_llm_calls(2)
        assert policy1.allowed_tools == SubAgent.read_only_tools()
        refute "write_file" in policy1.allowed_tools
        refute "patch_file" in policy1.allowed_tools
        refute "multi_patch" in policy1.allowed_tools
        refute "run_command" in policy1.allowed_tools
        refute "git_commit" in policy1.allowed_tools

        assert Enum.any?(msgs2, fn m ->
                 m.role == "tool" and String.contains?(m.content, "tool_not_allowed")
               end)

        assert Enum.any?(msgs2, fn m ->
                 m.role == "tool" and String.contains?(m.content, "def greet, do: :hello")
               end)

        child = Runs.get_run!(result["child_run_id"])
        assert child.status == "completed"
      end
    end

    test "child never escalates beyond parent allowed_tools restriction", context do
      parent =
        claim_parent_run(context,
          execution_policy: %{
            "agent_max_turns" => 4,
            "allowed_tools" => ["read_file", "spawn_agent"]
          }
        )

      Process.put(:agent_loop_responses, [
        {:ok, %{text: "Scoped child done.", tool_calls: [], usage: %{}}}
      ])

      assert {:ok, _res} =
               SubAgent.run(
                 parent.id,
                 "Scoped research",
                 context.root,
                 sub_agent_context(parent, %{mode: "research"})
               )

      [{_msgs, policy}] = collect_llm_calls(1)
      assert policy.allowed_tools == ["read_file"]
    end

    test "rejects unknown sub-agent mode before creating a child run", context do
      parent = claim_parent_run(context)

      assert {:error, :invalid_sub_agent_mode} =
               SubAgent.run(
                 parent.id,
                 "Invalid mode",
                 context.root,
                 sub_agent_context(parent, %{mode: "unrestricted_root"})
               )
    end
  end

  describe "git worktree isolation (isolate_worktree: true)" do
    test "runs child in detached git worktree, returns changed_files + diff_stat, and leaves parent clean",
         context do
      parent = claim_parent_run(context)
      original_sample = File.read!(Path.join(context.root, "lib/sample.ex"))

      Process.put(:agent_loop_responses, [
        {:ok,
         %{
           text: "Applying isolated edits.",
           tool_calls: [
             %{
               id: "call-patch",
               name: "patch_file",
               args: %{
                 "path" => "lib/sample.ex",
                 "target_content" => "def greet, do: :hello",
                 "replacement_content" => "def greet, do: :isolated_world"
               }
             },
             %{
               id: "call-write",
               name: "write_file",
               args: %{
                 "path" => "lib/new_helper.ex",
                 "content" => "defmodule Sample.Helper do\n  def ok?, do: true\nend\n"
               }
             }
           ],
           usage: %{}
         }},
        {:ok, %{text: "Implemented isolated prototype.", tool_calls: [], usage: %{}}}
      ])

      assert {:ok, result} =
               SubAgent.run(
                 parent.id,
                 "Prototype changes safely",
                 context.root,
                 sub_agent_context(parent, %{isolate_worktree: true, max_turns: 4})
               )

      _ = collect_llm_calls(2)

      assert result["summary"] == "Implemented isolated prototype."
      assert is_binary(result["message_id"])
      assert Enum.sort(result["changed_files"]) == ["lib/new_helper.ex", "lib/sample.ex"]
      assert result["diff_stat"] =~ "lib/sample.ex"
      assert result["diff_stat"] =~ "lib/new_helper.ex"
      assert result["diff_stat"] =~ "2 files changed"

      # Parent workspace is completely untouched
      assert File.read!(Path.join(context.root, "lib/sample.ex")) == original_sample
      refute File.exists?(Path.join(context.root, "lib/new_helper.ex"))
      assert git!(context.root, ["status", "--porcelain"]) == ""

      # Temporary git worktree and temporary Project registration are cleaned up
      worktrees = git!(context.root, ["worktree", "list", "--porcelain"])
      assert length(Regex.scan(~r/^worktree /m, worktrees)) == 1
      assert Enum.map(Projects.list_projects(), & &1.id) == [context.project.id]

      child = Runs.get_run!(result["child_run_id"])
      assert child.status == "completed"
    end

    test "cleans up isolated worktree via fallback even when child deletes .git pointer and fails",
         context do
      parent = claim_parent_run(context)
      captured_worktree = :ets.new(:captured_wt, [:set, :public])

      Process.put(:agent_loop_tool_result, fn name, _args, worktree_root ->
        :ets.insert(captured_worktree, {:path, worktree_root})

        if name == "read_file" do
          # Simulate broken worktree metadata so `git worktree remove` needs fallback cleanup
          File.rm_rf!(Path.join(worktree_root, ".git"))
          {:ok, "corrupted worktree gitfile"}
        else
          {:ok, "ok"}
        end
      end)

      Process.put(:agent_loop_responses, [
        {:ok,
         %{
           text: "Corrupting worktree then exhausting turns.",
           tool_calls: [%{id: "call-1", name: "read_file", args: %{"path" => "lib/sample.ex"}}],
           usage: %{}
         }},
        {:error, :synthetic_provider_failure}
      ])

      sub_ctx =
        parent
        |> sub_agent_context(%{isolate_worktree: true, max_turns: 2})
        |> Map.put(:tool_executor, IexCode.AgentLoopToolStub)

      assert {:error, :synthetic_provider_failure} =
               SubAgent.run(parent.id, "Broken worktree child", context.root, sub_ctx)

      _ = collect_llm_calls(2)

      assert [{:path, wt_path}] = :ets.lookup(captured_worktree, :path)
      assert wt_path != context.root
      refute File.exists?(wt_path)

      worktrees = git!(context.root, ["worktree", "list", "--porcelain"])
      assert length(Regex.scan(~r/^worktree /m, worktrees)) == 1
      assert git!(context.root, ["status", "--porcelain"]) == ""

      [failed_child] =
        context.session.id
        |> Runs.list_runs()
        |> Enum.filter(
          &(&1.metadata["sub_agent"] == true and &1.objective == "Broken worktree child")
        )

      assert failed_child.status == "failed"
      assert failed_child.error_message =~ "synthetic_provider_failure"
    end

    test "fails closed and marks child run failed when project_root is not a git repository",
         context do
      non_git_root =
        Path.join(System.tmp_dir!(), "iex-non-git-#{System.unique_integer([:positive])}")

      File.mkdir_p!(non_git_root)
      on_exit(fn -> File.rm_rf(non_git_root) end)

      parent = claim_parent_run(context)

      assert {:error, {:worktree_unavailable, _reason}} =
               SubAgent.run(
                 parent.id,
                 "Try worktree on non-git dir",
                 non_git_root,
                 sub_agent_context(parent, %{isolate_worktree: true})
               )

      [failed_child] =
        context.session.id
        |> Runs.list_runs()
        |> Enum.filter(
          &(&1.metadata["sub_agent"] == true and &1.objective == "Try worktree on non-git dir")
        )

      assert failed_child.status == "failed"
      assert failed_child.error_message =~ "worktree_unavailable"
    end

    test "supports keyword opts with clean empty diff when read_only isolated child makes no edits",
         context do
      parent = claim_parent_run(context)

      Process.put(:agent_loop_responses, [
        {:ok,
         %{
           text: "Inspecting in isolated worktree.",
           tool_calls: [
             %{id: "call-ro-wt", name: "read_file", args: %{"path" => "README.md"}}
           ],
           usage: %{}
         }},
        {:ok, %{text: "Clean worktree audit finished.", tool_calls: [], usage: %{}}}
      ])

      assert {:ok, result} =
               SubAgent.run(
                 parent.id,
                 "Audit in isolated worktree",
                 context.root,
                 sub_agent_context(parent, %{}),
                 mode: :read_only,
                 isolate_worktree: true,
                 max_turns: 3
               )

      _ = collect_llm_calls(2)

      assert result["mode"] == "read_only"
      assert result["summary"] == "Clean worktree audit finished."
      assert result["changed_files"] == []
      assert result["diff_stat"] == ""
      assert Runs.get_run!(result["child_run_id"]).status == "completed"
    end

    test "pause attempts inside sub-agent fail closed and terminalize child run", context do
      parent = claim_parent_run(context)

      Process.put(:agent_loop_responses, [
        {:ok,
         %{
           text: "Asking user from child.",
           tool_calls: [
             %{id: "call-pause", name: "request_input", args: %{"question" => "Allowed?"}}
           ],
           usage: %{}
         }}
      ])

      assert {:error, :sub_agent_cannot_pause} =
               SubAgent.run(
                 parent.id,
                 "Attempt pause",
                 context.root,
                 sub_agent_context(parent, %{mode: "coder"})
               )

      _ = collect_llm_calls(1)

      [failed_child] =
        context.session.id
        |> Runs.list_runs()
        |> Enum.filter(&(&1.metadata["sub_agent"] == true and &1.objective == "Attempt pause"))

      assert failed_child.status == "failed"
      assert failed_child.error_message =~ "sub_agent_cannot_pause"
    end
  end

  defp init_git_repo!(root) do
    File.mkdir_p!(Path.join(root, "lib"))

    File.write!(
      Path.join(root, "lib/sample.ex"),
      "defmodule Sample do\n  def greet, do: :hello\nend\n"
    )

    File.write!(Path.join(root, "README.md"), "# Sample\n")

    git!(root, ["init", "-q"])
    git!(root, ["config", "user.email", "test@example.com"])
    git!(root, ["config", "user.name", "Test User"])
    git!(root, ["add", "."])
    git!(root, ["commit", "-q", "-m", "initial commit"])
  end

  defp git!(dir, args) do
    {output, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
    String.trim(output)
  end

  defp claim_parent_run(context, opts \\ []) do
    policy = Keyword.get(opts, :execution_policy, %{"agent_max_turns" => 5})

    {:ok, _queued} =
      Runs.create_run(%{
        project_id: context.project.id,
        session_id: context.session.id,
        objective: "Parent run",
        kind: "coding_agent",
        mode: "single",
        metadata: %{"execution_policy" => policy}
      })

    owner = "subagent-iso-test:#{System.unique_integer([:positive])}"
    {:ok, run} = Runs.claim_next_run(owner, lease_ms: 300_000)
    run
  end

  defp sub_agent_context(parent, extra) do
    Map.merge(
      %{
        llm: IexCode.AgentLoopLLMStub,
        tool_executor: Tools,
        lease_owner: parent.lease_owner,
        run_attempt: parent.attempt,
        run_lease_generation: parent.lease_generation,
        max_turns: 4
      },
      extra
    )
  end

  defp collect_llm_calls(count) do
    for _ <- 1..count do
      assert_receive {:agent_loop_llm_call, messages, _system, policy}, 5_000
      {messages, policy}
    end
  end
end
