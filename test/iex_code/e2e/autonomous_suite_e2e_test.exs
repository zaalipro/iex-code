defmodule IexCode.E2E.AutonomousSuiteE2ETest do
  @moduledoc """
  Tier 4 Workload E2E Test: Advanced Autonomous Engineering Suite.
  Simulates comprehensive real-world multi-step workflows uniting:
  - R1: Multi-Window Native Desktop Detachment & PubSub Sync
  - R2: Offline Local Semantic Indexing & Sub-Second Vector Search
  - R3: Universal Pre-Mutation Checkpointing & 1-Click Rollback
  - R4: Multi-Model Adversarial Consensus Arbitration & RunApproval Gating
  """
  use IexCode.E2E.Case, async: false

  alias IexCode.Desktop.WindowManager
  alias IexCode.SemanticIndex.Indexer
  alias IexCode.TimeTravel
  alias IexCode.Consensus.{Assessment, Arbitrator}
  alias IexCode.Tools
  alias IexCode.Runs
  alias Phoenix.PubSub

  setup %{workspace_path: workspace_path} do
    core_module = """
    defmodule AutonomousApp.Core do
      @moduledoc "Core autonomous business logic."

      def execute_workload(items) when is_list(items) do
        Enum.map(items, &process_item/1)
      end

      defp process_item(item), do: {:processed, item}
    end
    """

    auth_module = """
    defmodule AutonomousApp.Auth do
      @moduledoc "Cryptographic token and session authorization."

      def authorize(token) do
        String.length(token) > 10
      end
    end
    """

    workspace_write_file(workspace_path, "lib/core.ex", core_module)
    workspace_write_file(workspace_path, "lib/auth.ex", auth_module)

    {:ok, project} =
      Projects.create_project(%{
        name: "Autonomous Suite E2E Project",
        root_path: workspace_path
      })

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Autonomous Suite E2E Session"
      })

    {:ok, run} =
      Runs.create_run(%{
        session_id: session.id,
        project_id: project.id,
        objective: "Execute complete autonomous engineering lifecycle",
        status: "running"
      })

    if Process.whereis(IexCode.PubSub) do
      PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")
      PubSub.subscribe(IexCode.PubSub, "project:#{project.id}:git")
      PubSub.subscribe(IexCode.PubSub, "desktop:events")
    end

    {:ok, project: project, session: session, run: run, workspace_path: workspace_path}
  end

  defp make_assessment(attrs) do
    if Code.ensure_loaded?(Assessment) and function_exported?(Assessment, :__struct__, 1) do
      struct(Assessment, attrs)
    else
      Map.merge(%{__struct__: Assessment}, Map.new(attrs))
    end
  end

  describe "Tier 4: Comprehensive Real-World Workload Scenarios" do
    test "Scenario 1: Semantic Code Search during Agent Planning", %{
      project: project,
      workspace_path: workspace_path
    } do
      {:ok, index_summary} = Indexer.index_project(project.id, workspace_path)
      indexed_count = index_summary[:indexed] || index_summary[:files_indexed] || 0
      assert indexed_count >= 2

      {:ok, results} =
        Indexer.search(project.id, "cryptographic token authorization and validation")

      assert length(results) >= 1
      top_result = hd(results)
      assert top_result.file_path =~ "auth.ex"
      assert top_result.score > 0.3
    end

    test "Scenario 2: Multi-Model Adversarial Consensus with Contested Security Patch", %{
      run: run,
      workspace_path: workspace_path
    } do
      cloud_review =
        make_assessment(%{
          reviewer_id: "cloud_reviewer",
          provider: "anthropic",
          model: "claude-3-7-sonnet",
          vote: :approve,
          confidence: 0.9,
          scores: %{
            correctness: 0.8,
            security: 0.75,
            architectural_fit: 0.8,
            maintainability: 0.8,
            testability: 0.8
          },
          verdict_reason: "Faster execution",
          critique_points: [],
          suggested_modifications: []
        })

      local_review =
        make_assessment(%{
          reviewer_id: "local_apple_silicon",
          provider: "ollama",
          model: "llama3.2:latest",
          vote: :reject,
          confidence: 0.95,
          scores: %{
            correctness: 0.2,
            security: 0.1,
            architectural_fit: 0.5,
            maintainability: 0.5,
            testability: 0.2
          },
          verdict_reason: "Security bypass renders authentication useless",
          critique_points: [
            %{
              severity: "blocker",
              category: "security",
              file_path: "lib/auth.ex",
              description: "Bypasses all token checks"
            }
          ],
          suggested_modifications: ["Preserve signature checks"]
        })

      arbitration_result = Arbitrator.arbitrate([cloud_review, local_review], run_id: run.id)

      assert arbitration_result.decision in [:rejected, :requires_arbitration]
      assert arbitration_result.auto_approved == false

      auth_content = File.read!(Path.join(workspace_path, "lib/auth.ex"))
      refute auth_content =~ "bypass validation"
    end

    test "Scenario 3: Swarm Multi-File Refactoring with Atomic Pre-Mutation Checkpointing", %{
      session: session,
      workspace_path: workspace_path
    } do
      {:ok, _} =
        Tools.execute(
          "patch_file",
          %{
            "path" => "lib/core.ex",
            "target_content" => "{:processed, item}",
            "replacement_content" => "{:ok, item}",
            "session_id" => session.id
          },
          workspace_path
        )

      {:ok, _} =
        Tools.execute(
          "write_file",
          %{
            "path" => "lib/util.ex",
            "content" => "defmodule AutonomousApp.Util, do: :util\n",
            "session_id" => session.id
          },
          workspace_path
        )

      {:ok, _} =
        Tools.execute(
          "multi_patch",
          %{
            "session_id" => session.id,
            "patches" => [
              %{
                "path" => "lib/core.ex",
                "target_content" => "@moduledoc",
                "replacement_content" => "# Refactored core\n@moduledoc"
              },
              %{
                "path" => "lib/util.ex",
                "target_content" => ":util",
                "replacement_content" => ":v2_util"
              }
            ]
          },
          workspace_path
        )

      checkpoints = TimeTravel.list_checkpoints(session.id)
      assert length(checkpoints) == 3

      assert File.exists?(Path.join(workspace_path, "lib/util.ex"))
      assert File.read!(Path.join(workspace_path, "lib/core.ex")) =~ "Refactored core"

      oldest_checkpoint = List.last(checkpoints)
      tx_id = oldest_checkpoint.transaction_id || oldest_checkpoint.id

      {:ok, _} = TimeTravel.rollback_to(tx_id, session_id: session.id)

      assert File.read!(Path.join(workspace_path, "lib/core.ex")) =~ "{:ok, item}"

      refute File.exists?(Path.join(workspace_path, "lib/util.ex")),
             "Created file must be cleanly deleted"
    end

    test "Scenario 4: Multi-Window Native Desktop Detachment and PubSub Sync", %{
      session: session,
      project: project
    } do
      diff_res = WindowManager.open_window(:diff, session.id)
      assert match?({:ok, _}, diff_res) or match?({:ok, _, _}, diff_res)
      term_res = WindowManager.open_window(:terminal, session.id)
      assert match?({:ok, _}, term_res) or match?({:ok, _, _}, term_res)

      config = WindowManager.window_configs()[:diff] || WindowManager.get_config(:diff)
      assert config.id == IexCodeDiffWindow

      PubSub.broadcast(
        IexCode.PubSub,
        "project:#{project.id}:git",
        {:git_state_changed, project.id}
      )

      assert_receive {:git_state_changed, _pid}, 1000

      if function_exported?(WindowManager, :close_window, 1) do
        assert :ok = WindowManager.close_window(:diff)
        assert :ok = WindowManager.close_window(:terminal)
      else
        assert :ok = WindowManager.hide_window(:diff)
        assert :ok = WindowManager.hide_window(:terminal)
      end
    end

    test "Scenario 5: Full Autonomous Suite Lifecycle (Search -> Plan -> Vote -> Checkpoint -> Patch -> Rollback -> Window Sync)",
         %{
           session: session,
           project: project,
           run: run,
           workspace_path: workspace_path
         } do
      {:ok, _} = Indexer.index_project(project.id, workspace_path)
      {:ok, search_results} = Indexer.search(project.id, "execute_workload", threshold: 0.0)
      assert length(search_results) >= 1

      r1 =
        make_assessment(%{
          reviewer_id: "claude",
          provider: "anthropic",
          model: "claude-3-7-sonnet",
          vote: :approve,
          confidence: 0.95,
          scores: %{
            correctness: 0.95,
            security: 0.9,
            architectural_fit: 0.9,
            maintainability: 0.9,
            testability: 0.9
          },
          verdict_reason: "Optimizes workload cleanly",
          critique_points: [],
          suggested_modifications: []
        })

      r2 =
        make_assessment(%{
          reviewer_id: "local_llama",
          provider: "ollama",
          model: "llama3.2:latest",
          vote: :approve,
          confidence: 0.9,
          scores: %{
            correctness: 0.9,
            security: 0.9,
            architectural_fit: 0.85,
            maintainability: 0.85,
            testability: 0.85
          },
          verdict_reason: "Local inference approves patch",
          critique_points: [],
          suggested_modifications: []
        })

      arbitration = Arbitrator.arbitrate([r1, r2], run_id: run.id)
      assert arbitration.decision == :approved

      patch_spec = %{
        "path" => "lib/core.ex",
        "target_content" => "Enum.map(items, &process_item/1)",
        "replacement_content" => "Task.async_stream(items, &process_item/1, timeout: :infinity)",
        "session_id" => session.id
      }

      {:ok, _} = Tools.execute("patch_file", patch_spec, workspace_path)

      PubSub.broadcast(
        IexCode.PubSub,
        "project:#{project.id}:git",
        {:git_state_changed, project.id}
      )

      assert_receive {:git_state_changed, _}, 1000

      assert File.read!(Path.join(workspace_path, "lib/core.ex")) =~ "Task.async_stream"

      {:ok, _} = TimeTravel.rollback_latest(session.id)

      assert File.read!(Path.join(workspace_path, "lib/core.ex")) =~
               "Enum.map(items, &process_item/1)"
    end
  end
end
