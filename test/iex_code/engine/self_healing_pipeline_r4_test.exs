defmodule IexCode.Engine.SelfHealingPipelineR4Test do
  use IexCode.DataCase, async: false
  @moduletag timeout: 180_000

  alias IexCode.{CoderAgentLoopLLMStub, Projects, Sessions}
  alias IexCode.Engine.{AgentCancellation, AgentSupervisor, SwarmCoordinator}
  alias IexCode.Engine.Agents.{CoderAgent, ExplorerAgent, VerifierAgent}
  alias IexCode.SemanticIndex.Indexer

  setup context do
    root_path = Map.get(context, :tmp_dir, File.cwd!())

    {:ok, project} =
      Projects.create_project(%{
        name: "SelfHealing R4 Project #{System.unique_integer([:positive])}",
        root_path: root_path
      })

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "SelfHealing R4 Session",
        swarm_mode: true
      })

    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")

    on_exit(fn ->
      AgentSupervisor.stop_all_agents(session.id)
      cleanup_ets_project(project.id)
      cleanup_ets_project(root_path)
      cleanup_ets_project(Path.expand(root_path))
    end)

    %{project: project, session: session}
  end

  describe "ExplorerAgent enriched context synthesis (RepoMap + SymbolRefactor + Lexical SemanticIndex + AST + Grep)" do
    @tag :tmp_dir
    test "combines grep, AST, SymbolRefactor references, lexical SemanticIndex hits, and RepoMap within <= 4_500 bytes",
         %{project: project, session: session, tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "lib/billing"))

      File.write!(Path.join(tmp_dir, "lib/billing/invoice.ex"), """
      defmodule Billing.Invoice do
        @moduledoc "Computes invoice subtotal and tax adjustments."

        def compute_subtotal(items) when is_list(items) do
          Enum.sum(items)
        end
      end
      """)

      File.write!(Path.join(tmp_dir, "lib/billing/checkout.ex"), """
      defmodule Billing.Checkout do
        alias Billing.Invoice

        def finalize(items) do
          Invoice.compute_subtotal(items)
        end
      end
      """)

      seed_ets_chunk!(
        project.id,
        "lib/billing/invoice.ex",
        1,
        7,
        "Billing.Invoice.compute_subtotal/1",
        "def",
        "def compute_subtotal(items), do: Enum.sum(items) # invoice subtotal calculation"
      )

      {:ok, pid} = AgentSupervisor.start_agent(session.id, :explorer, project_root: tmp_dir)
      Ecto.Adapters.SQL.Sandbox.allow(IexCode.Repo, self(), pid)

      assert {:ok, summary} =
               ExplorerAgent.explore(
                 session.id,
                 "Inspect Billing.Invoice.compute_subtotal/1 and checkout subtotal flow",
                 project_root: tmp_dir
               )

      assert is_binary(summary)
      assert byte_size(summary) <= 4_500

      # Backward-compatible headings + all enriched sections present
      assert summary =~ "Found key modules in workspace:"
      assert summary =~ "Discovered AST modules:"
      assert summary =~ "Billing.Invoice"
      assert summary =~ "Symbol references:"
      assert summary =~ "lib/billing/checkout.ex"
      assert summary =~ "Lexical semantic matches:"
      assert summary =~ "compute_subtotal"
      assert summary =~ "Structural repository map:"
      assert summary =~ "# Repo Map"
    end

    @tag :tmp_dir
    test "strictly enforces <= 4_500 UTF-8 byte ceiling on dense multi-module workspaces",
         %{project: project, session: session, tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "lib/dense"))

      for idx <- 1..28 do
        mod_file = Path.join(tmp_dir, "lib/dense/service_#{idx}.ex")

        File.write!(mod_file, """
        defmodule Dense.Service#{idx} do
          @moduledoc "Dense telemetry & orchestration pipeline — λ#{idx} — #{String.duplicate("orchestrate ", 12)}"

          def orchestrate_step_#{idx}(payload) do
            {:ok, payload}
          end

          def fallback_step_#{idx}(reason), do: {:error, reason}
        end
        """)

        seed_ets_chunk!(
          project.id,
          "lib/dense/service_#{idx}.ex",
          1,
          10,
          "Dense.Service#{idx}.orchestrate_step_#{idx}/1",
          "def",
          "def orchestrate_step_#{idx}(payload), do: {:ok, payload} # λ#{idx}"
        )
      end

      {:ok, pid} = AgentSupervisor.start_agent(session.id, :explorer, project_root: tmp_dir)
      Ecto.Adapters.SQL.Sandbox.allow(IexCode.Repo, self(), pid)

      assert {:ok, summary} =
               ExplorerAgent.explore(
                 session.id,
                 "Inspect Dense.Service1 and orchestrate pipeline modules",
                 project_root: tmp_dir
               )

      assert String.valid?(summary)
      assert byte_size(summary) <= 4_500
      assert summary =~ "Found key modules in workspace:"
      assert summary =~ "Discovered AST modules:"
    end

    @tag :tmp_dir
    test "honors per-tool allowed_tools guards and cancellation cleanly",
         %{session: session, tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "lib"))

      File.write!(Path.join(tmp_dir, "lib/price_calc.ex"), """
      defmodule PriceCalc do
        def apply_tax(amount), do: amount * 1.2
      end
      """)

      File.write!(Path.join(tmp_dir, "lib/order_flow.ex"), """
      defmodule OrderFlow do
        def total(amount), do: PriceCalc.apply_tax(amount)
      end
      """)

      seed_ets_chunk!(
        tmp_dir,
        "lib/price_calc.ex",
        1,
        3,
        "PriceCalc.apply_tax/1",
        "def",
        "def apply_tax(amount), do: amount * 1.2"
      )

      {:ok, pid} = AgentSupervisor.start_agent(session.id, :explorer, project_root: tmp_dir)
      Ecto.Adapters.SQL.Sandbox.allow(IexCode.Repo, self(), pid)

      # 1. Empty allowed_tools skips all tools and returns ready message
      assert {:ok, empty_summary} =
               ExplorerAgent.explore(pid, "Inspect PriceCalc.apply_tax/1",
                 project_root: tmp_dir,
                 allowed_tools: []
               )

      assert empty_summary == "Workspace exploration complete. Ready for implementation."

      # 2. Only repo_map allowed
      assert {:ok, map_only} =
               ExplorerAgent.explore(pid, "Inspect PriceCalc",
                 project_root: tmp_dir,
                 allowed_tools: ["repo_map"]
               )

      assert map_only =~ "Structural repository map:"
      assert map_only =~ "lib/price_calc.ex"
      refute map_only =~ "Found key modules in workspace:"
      refute map_only =~ "Symbol references:"
      refute map_only =~ "Lexical semantic matches:"

      # 3. Only find_references allowed
      assert {:ok, refs_only} =
               ExplorerAgent.explore(pid, "Find callers of PriceCalc.apply_tax/1",
                 project_root: tmp_dir,
                 allowed_tools: ["find_references"]
               )

      assert refs_only =~ "Symbol references:"
      assert refs_only =~ "lib/order_flow.ex"
      refute refs_only =~ "Structural repository map:"

      # 4. Only semantic_code_search allowed (indexed by project_root, zero network call)
      assert {:ok, sem_only} =
               ExplorerAgent.explore(pid, "Search apply_tax calculation",
                 project_root: tmp_dir,
                 allowed_tools: ["semantic_code_search"]
               )

      assert sem_only =~ "Lexical semantic matches:"
      assert sem_only =~ "lib/price_calc.ex"
      refute sem_only =~ "Structural repository map:"

      # 5. Cancellation check
      AgentCancellation.set(ExplorerAgent, session.id, true)

      assert {:error, :cancelled} =
               ExplorerAgent.explore(pid, "Cancelled exploration", project_root: tmp_dir)

      AgentCancellation.set(ExplorerAgent, session.id, false)
    end
  end

  describe "VerifierAgent smart selective preflight & Arbitrator diagnostics enrichment" do
    @tag :tmp_dir
    test "selective_preflight: true fast-fails on broken target test and runs full suite when preflight passes",
         %{session: session, tmp_dir: tmp_dir} do
      create_mini_mix_project!(tmp_dir, :preflight_fixture)

      marker_path = Path.join(tmp_dir, "full_suite_ran.marker")

      File.write!(Path.join(tmp_dir, "lib/calc.ex"), """
      defmodule PreflightFixture.Calc do
        def double(x), do: x + 1
      end
      """)

      File.write!(Path.join(tmp_dir, "test/calc_test.exs"), """
      defmodule PreflightFixture.CalcTest do
        use ExUnit.Case, async: true

        test "doubles input" do
          assert PreflightFixture.Calc.double(4) == 8
        end
      end
      """)

      File.write!(Path.join(tmp_dir, "test/unrelated_suite_test.exs"), """
      defmodule PreflightFixture.UnrelatedSuiteTest do
        use ExUnit.Case, async: false

        test "writes full suite marker" do
          File.write!(#{inspect(marker_path)}, "executed")
          assert true
        end
      end
      """)

      {:ok, pid} = AgentSupervisor.start_agent(session.id, :verifier, project_root: tmp_dir)
      Ecto.Adapters.SQL.Sandbox.allow(IexCode.Repo, self(), pid)

      # Case A: Targeted test fails -> fast-fails BEFORE full suite runs
      assert {:error, {:verification_failed, diag}} =
               VerifierAgent.verify(pid,
                 project_root: tmp_dir,
                 selective_preflight: true,
                 changed_files: ["lib/calc.ex"]
               )

      assert diag.status == :failed
      assert diag.selective_preflight.enabled == true
      assert diag.selective_preflight.selected_paths == ["test/calc_test.exs"]
      assert diag.selective_preflight.fast_failed == true
      refute File.exists?(marker_path)

      # Legacy & enriched diagnostic keys both intact
      assert is_binary(diag.summary)
      assert is_binary(diag.compile_output)
      assert is_binary(diag.test_output)
      assert is_binary(diag.raw_output)
      assert is_list(diag.failures) and diag.failures != []
      assert is_list(diag.critique_items) and diag.critique_items != []
      assert is_map(diag.actionable_feedback)
      assert diag.actionable_feedback.repair_prompt =~ "[MAJOR]"
      assert diag.actionable_feedback.repair_prompt =~ "test/calc_test.exs"

      # Case B: Fix lib/calc.ex -> preflight passes AND full suite runs afterwards
      File.write!(Path.join(tmp_dir, "lib/calc.ex"), """
      defmodule PreflightFixture.Calc do
        def double(x), do: x * 2
      end
      """)

      assert {:ok, pass_verdict} =
               VerifierAgent.verify(pid,
                 project_root: tmp_dir,
                 selective_preflight: true,
                 changed_files: ["lib/calc.ex"]
               )

      assert pass_verdict.status == :passed
      assert pass_verdict.selective_preflight.selected_paths == ["test/calc_test.exs"]
      assert pass_verdict.selective_preflight.fast_failed == false
      assert pass_verdict.selective_preflight.status == :passed
      assert File.read!(marker_path) == "executed"
    end

    @tag :tmp_dir
    test "parses compiler errors as blocker critique_items and lib/ stacktrace frames as major critique_items",
         %{session: session, tmp_dir: tmp_dir} do
      create_mini_mix_project!(tmp_dir, :diag_fixture)

      # 1. Compiler error in lib/broken_compile.ex
      File.write!(Path.join(tmp_dir, "lib/broken_compile.ex"), """
      defmodule DiagFixture.BrokenCompile do
        def compute(x) do
          non_existent_helper(x)
        end
      end
      """)

      {:ok, pid} = AgentSupervisor.start_agent(session.id, :verifier, project_root: tmp_dir)
      Ecto.Adapters.SQL.Sandbox.allow(IexCode.Repo, self(), pid)

      assert {:error, {:verification_failed, comp_diag}} =
               VerifierAgent.verify(pid, project_root: tmp_dir)

      assert comp_diag.status == :compilation_error
      assert is_binary(comp_diag.compile_output) and comp_diag.compile_output != ""
      assert is_binary(comp_diag.test_output)

      assert Enum.any?(comp_diag.critique_items, fn item ->
               item.severity == "blocker" and
                 item.category == "correctness" and
                 item.file == "lib/broken_compile.ex" and
                 item.line == 3
             end)

      assert comp_diag.actionable_feedback.decision == :rejected
      assert comp_diag.actionable_feedback.blocking_issues != []
      assert comp_diag.actionable_feedback.repair_prompt =~ "[BLOCKER] lib/broken_compile.ex:3"

      # 2. Runtime exception inside lib/broken_compile.ex:3 surfaces lib/ file:line stacktrace
      File.write!(Path.join(tmp_dir, "lib/broken_compile.ex"), """
      defmodule DiagFixture.BrokenCompile do
        def divide_100(divisor) do
          div(100, divisor)
        end
      end
      """)

      File.write!(Path.join(tmp_dir, "test/broken_compile_test.exs"), """
      defmodule DiagFixture.BrokenCompileTest do
        use ExUnit.Case, async: true

        test "handles zero divisor" do
          assert DiagFixture.BrokenCompile.divide_100(0) == :infinity
        end
      end
      """)

      assert {:error, {:verification_failed, fail_diag}} =
               VerifierAgent.verify(pid, project_root: tmp_dir)

      assert fail_diag.status == :failed
      assert is_binary(fail_diag.summary)
      assert is_binary(fail_diag.test_output) and fail_diag.test_output != ""

      assert Enum.any?(fail_diag.critique_items, fn item ->
               item.severity == "major" and
                 item.category == "correctness" and
                 item.file == "lib/broken_compile.ex" and
                 item.line == 3
             end)

      assert fail_diag.actionable_feedback.repair_prompt =~ "[MAJOR] lib/broken_compile.ex:3"
    end

    test "enrich_diagnostics/2 ranks blocker > major > minor and deduplicates identical file:line items" do
      raw_diag = %{
        status: :failed,
        summary: "Mixed severity critique check",
        failures: [],
        compilation_errors: [],
        raw_output: "Mixed severity critique check",
        critique_items: [
          %{
            severity: "minor",
            category: "maintainability",
            file: "lib/a.ex",
            line: 20,
            description: "Unused alias cleanup"
          },
          %{
            severity: "major",
            category: "correctness",
            file: "lib/b.ex",
            line: 14,
            description: "Off-by-one boundary condition"
          },
          %{
            severity: "blocker",
            category: "correctness",
            file: "lib/b.ex",
            line: 14,
            description: "Raises ArithmeticError on empty list"
          },
          %{
            severity: "blocker",
            category: "correctness",
            file: "lib/c.ex",
            line: 5,
            description: "Undefined function call"
          }
        ]
      }

      enriched = VerifierAgent.enrich_diagnostics(raw_diag)
      prompt = enriched.actionable_feedback.repair_prompt

      # lib/b.ex:14 merged & upgraded to BLOCKER; ranked BLOCKER before MINOR
      assert length(enriched.actionable_feedback.critique_items) == 3
      assert length(enriched.actionable_feedback.blocking_issues) == 2

      {blocker_pos, _} = :binary.match(prompt, "[BLOCKER] lib/b.ex:14")
      {minor_pos, _} = :binary.match(prompt, "[MINOR] lib/a.ex:20")
      assert blocker_pos < minor_pos
    end
  end

  describe "End-to-End Self-Healing Swarm Pipeline (Explorer x Verifier x Arbitrator x Coder + Worktree Isolation)" do
    @tag :tmp_dir
    test "CoderAgent.code/3 formats retry diagnostics with ranked Arbitrator file:line repair brief",
         %{session: session, tmp_dir: tmp_dir} do
      start_supervised!(
        {CoderAgentLoopLLMStub, [{:ok, %{text: "Applied targeted repair", tool_calls: []}}]}
      )

      {:ok, coder_pid} =
        AgentSupervisor.start_agent(session.id, :coder,
          project_root: tmp_dir,
          llm: CoderAgentLoopLLMStub
        )

      Ecto.Adapters.SQL.Sandbox.allow(IexCode.Repo, self(), coder_pid)

      diagnostics = %{
        status: :failed,
        summary: "1 test failure and 1 compile blocker",
        critique_items: [
          %{
            severity: "minor",
            category: "correctness",
            file: "lib/style.ex",
            line: 9,
            description: "Prefer pattern match"
          },
          %{
            severity: "major",
            category: "correctness",
            file: "lib/discount.ex",
            line: 12,
            description: "Wrong percentage formula"
          },
          %{
            severity: "blocker",
            category: "correctness",
            file: "lib/parser.ex",
            line: 4,
            description: "Syntax error before end"
          }
        ]
      }

      assert {:ok, "Applied targeted repair"} =
               CoderAgent.code(session.id, "Fix discount and parser issues",
                 project_root: tmp_dir,
                 plan: "1. Fix parser.ex:4\n2. Fix discount.ex:12",
                 diagnostics: diagnostics,
                 allowed_tools: []
               )

      assert [[%{role: "user", content: sent_prompt}]] = CoderAgentLoopLLMStub.requests()
      assert sent_prompt =~ "### ⚠️ Self-Correction Feedback"
      assert sent_prompt =~ "Consensus repair required"
      assert sent_prompt =~ "[BLOCKER] lib/parser.ex:4"
      assert sent_prompt =~ "[MAJOR] lib/discount.ex:12"
      assert sent_prompt =~ "[MINOR] lib/style.ex:9"
      assert sent_prompt =~ "Refined Plan:"

      {b_idx, _} = :binary.match(sent_prompt, "[BLOCKER] lib/parser.ex:4")
      {m_idx, _} = :binary.match(sent_prompt, "[MAJOR] lib/discount.ex:12")
      {min_idx, _} = :binary.match(sent_prompt, "[MINOR] lib/style.ex:9")
      assert b_idx < m_idx and m_idx < min_idx
    end

    @tag :tmp_dir
    test "full self-healing swarm heals ExUnit bug across worktree-isolated retry using Arbitrator repair briefs",
         %{session: session, tmp_dir: tmp_dir} do
      create_mini_mix_project!(tmp_dir, :self_heal_app)
      init_git_repo!(tmp_dir)

      discount_path = Path.join(tmp_dir, "lib/discount.ex")

      initial_placeholder = """
      defmodule SelfHealApp.Discount do
        def apply_percent(price, _pct), do: price
      end
      """

      buggy_turn_0 = """
      defmodule SelfHealApp.Discount do
        def apply_percent(price, pct) do
          if pct == 100, do: div(price, 0), else: price - div(price * pct, 100)
        end
      end
      """

      fixed_turn_1 = """
      defmodule SelfHealApp.Discount do
        def apply_percent(price, pct) do
          price - div(price * pct, 100)
        end
      end
      """

      File.write!(discount_path, initial_placeholder)

      File.write!(Path.join(tmp_dir, "test/discount_test.exs"), """
      defmodule SelfHealApp.DiscountTest do
        use ExUnit.Case, async: true

        test "applies percentage discount including 100%" do
          assert SelfHealApp.Discount.apply_percent(200, 25) == 150
          assert SelfHealApp.Discount.apply_percent(200, 100) == 0
        end
      end
      """)

      git_commit_all!(tmp_dir, "initial mix project")

      responses = [
        # 1. Initial PlannerAgent.plan
        {:ok, %{text: "Plan v1: Implement SelfHealApp.Discount.apply_percent/2", tool_calls: []}},
        # 2. CoderAgent turn 0 -> writes buggy implementation inside isolated worktree
        {:ok,
         %{
           text: "Writing initial apply_percent/2",
           tool_calls: [
             %{
               id: "heal-tc-1",
               name: "write_file",
               args: %{"path" => "lib/discount.ex", "content" => buggy_turn_0}
             }
           ]
         }},
        {:ok, %{text: "Initial implementation written", tool_calls: []}},
        # 3. Replanning PlannerAgent.plan after VerifierAgent + Arbitrator failure
        {:ok,
         %{
           text:
             "Refined Plan v2: Fix ArithmeticError at lib/discount.ex:3 using integer percentage math",
           tool_calls: []
         }},
        # 4. CoderAgent turn 1 -> repairs lib/discount.ex inside isolated worktree
        {:ok,
         %{
           text: "Applying targeted repair at lib/discount.ex:3",
           tool_calls: [
             %{
               id: "heal-tc-2",
               name: "write_file",
               args: %{"path" => "lib/discount.ex", "content" => fixed_turn_1}
             }
           ]
         }},
        {:ok, %{text: "Self-healed SelfHealApp.Discount.apply_percent/2", tool_calls: []}}
      ]

      start_supervised!({CoderAgentLoopLLMStub, responses})

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

      assert {:ok, final_msg} =
               SwarmCoordinator.run(
                 session.id,
                 "Implement SelfHealApp.Discount.apply_percent/2 so tests pass",
                 project_root: tmp_dir,
                 isolate_worktree: true,
                 selective_preflight: true,
                 max_retries: 2
               )

      assert final_msg.metadata.status == :completed
      assert final_msg.metadata.iterations == 1

      # Verified fix synced back to project_root; _build symlinks NOT leaked as broken artifacts; worktree pruned
      assert File.read!(discount_path) == fixed_turn_1
      assert git_worktree_count(tmp_dir) == 1

      # Inspect exact LLM prompts sent to Planner (replanning) and Coder (retry turn 1)
      requests = CoderAgentLoopLLMStub.requests()
      assert length(requests) == 6

      [%{content: replan_user_prompt}] = Enum.at(requests, 3)
      assert replan_user_prompt =~ "### ⚠️ Verification Failure Diagnostics"
      assert replan_user_prompt =~ "Consensus repair required"
      assert replan_user_prompt =~ "[MAJOR] lib/discount.ex:3"

      [%{content: coder_retry_prompt}] = Enum.at(requests, 4)
      assert coder_retry_prompt =~ "### ⚠️ Self-Correction Feedback"
      assert coder_retry_prompt =~ "Consensus repair required"
      assert coder_retry_prompt =~ "[MAJOR] lib/discount.ex:3"
      assert coder_retry_prompt =~ "Refined Plan:"
      assert coder_retry_prompt =~ "Fix ArithmeticError at lib/discount.ex:3"
    end

    @tag :tmp_dir
    test "run_swarm/4 with isolate_worktree: true leaves project_root untouched when Mix verification fails",
         %{session: session, tmp_dir: tmp_dir} do
      create_mini_mix_project!(tmp_dir, :rollback_app)
      init_git_repo!(tmp_dir)

      math_file = Path.join(tmp_dir, "lib/math_ops.ex")
      original_code = "defmodule RollbackApp.MathOps do\n  def add(a, b), do: a + b\nend\n"
      File.write!(math_file, original_code)

      File.write!(Path.join(tmp_dir, "test/math_ops_test.exs"), """
      defmodule RollbackApp.MathOpsTest do
        use ExUnit.Case, async: true

        test "adds numbers" do
          assert RollbackApp.MathOps.add(2, 3) == 5
        end
      end
      """)

      git_commit_all!(tmp_dir, "clean baseline")

      bad_code = "defmodule RollbackApp.MathOps do\n  def add(a, b), do: a - b\nend\n"

      responses = [
        {:ok, %{text: "Plan: edit math_ops", tool_calls: []}},
        {:ok,
         %{
           text: "Mutating math_ops inside worktree",
           tool_calls: [
             %{
               id: "rb-tc-1",
               name: "write_file",
               args: %{"path" => "lib/math_ops.ex", "content" => bad_code}
             }
           ]
         }},
        {:ok, %{text: "Wrote bad_code", tool_calls: []}}
      ]

      start_supervised!({CoderAgentLoopLLMStub, responses})

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

      assert {:ok, task_pid} =
               SwarmCoordinator.run_swarm(
                 session.id,
                 "Break math_ops in isolated async swarm",
                 tmp_dir,
                 isolate_worktree: true,
                 max_retries: 0
               )

      ref = Process.monitor(task_pid)
      assert_receive {:DOWN, ^ref, :process, ^task_pid, :normal}, 60_000
      assert_receive {:goal_lifecycle_changed, %{status: :failed}}, 5_000

      # Main project_root was NEVER mutated and ephemeral worktree was cleaned up
      assert File.read!(math_file) == original_code
      assert git_worktree_count(tmp_dir) == 1
    end
  end

  # --- Test Helpers ---

  defp seed_ets_chunk!(project_key, rel_path, start_line, end_line, sym_name, sym_type, content) do
    table = Indexer.table_name()

    if :ets.whereis(table) == :undefined do
      _ = Indexer.stats(project_key)
    end

    id = Ecto.UUID.generate()
    dummy_vec = <<0.0::float-little-32, 0.0::float-little-32>>

    :ets.insert(
      table,
      {id, project_key, rel_path, start_line, end_line, sym_name, sym_type, content, dummy_vec}
    )
  end

  defp cleanup_ets_project(project_key) when is_binary(project_key) do
    table = Indexer.table_name()

    if :ets.whereis(table) != :undefined do
      :ets.match_delete(table, {:_, project_key, :_, :_, :_, :_, :_, :_, :_})
    end
  end

  defp create_mini_mix_project!(dir, app_atom) when is_atom(app_atom) do
    File.mkdir_p!(Path.join(dir, "lib"))
    File.mkdir_p!(Path.join(dir, "test"))

    mod_camel = app_atom |> Atom.to_string() |> Macro.camelize()

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule #{mod_camel}.MixProject do
      use Mix.Project

      def project do
        [
          app: #{inspect(app_atom)},
          version: "0.1.0",
          elixir: "~> 1.15",
          deps: []
        ]
      end
    end
    """)

    File.write!(Path.join(dir, "test/test_helper.exs"), "ExUnit.start()\n")
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
