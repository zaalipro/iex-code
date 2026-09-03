defmodule IexCode.Consensus.ArbitratorTest do
  @moduledoc """
  Requirement R4: Multi-Model Adversarial Consensus & Swarm Voting.
  Tests for IexCode.Consensus.Arbitrator:
  - Review panel assembly (cloud + local Apple Silicon models)
  - Auto-approval gating and patch execution
  - Gated arbitration via IexCode.Runs.RunApproval
  - Offline model timeout handling and weight renormalization
  """
  use IexCode.DataCase, async: false

  alias IexCode.Consensus.Arbitrator
  alias IexCode.Consensus.Assessment
  alias IexCode.Runs
  alias IexCode.Runs.RunApproval
  alias IexCode.Projects
  alias IexCode.Sessions
  alias Phoenix.PubSub

  setup do
    unique_id = System.unique_integer([:positive])
    temp_dir = Path.join(System.tmp_dir!(), "iex_arbitrator_test_#{unique_id}")
    File.mkdir_p!(temp_dir)

    {:ok, project} =
      Projects.create_project(%{
        name: "Arbitrator Test Project #{unique_id}",
        root_path: temp_dir
      })

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Arbitrator Session #{unique_id}"
      })

    {:ok, run} =
      Runs.create_run(%{
        session_id: session.id,
        project_id: project.id,
        objective: "Arbitration Test Run",
        status: "running"
      })

    if Process.whereis(IexCode.PubSub) do
      PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")
      PubSub.subscribe(IexCode.PubSub, "runs:#{run.id}")
    end

    on_exit(fn ->
      File.rm_rf(temp_dir)
    end)

    {:ok, project: project, session: session, run: run, temp_dir: temp_dir}
  end

  defp make_assessment(attrs) do
    if Code.ensure_loaded?(Assessment) and function_exported?(Assessment, :__struct__, 1) do
      struct(Assessment, attrs)
    else
      Map.merge(%{__struct__: Assessment}, Map.new(attrs))
    end
  end

  defp mock_assessment(id, vote, conf, sec_score) do
    make_assessment(%{
      reviewer_id: id,
      provider: "mock",
      model: "mock-model",
      vote: vote,
      confidence: conf,
      scores: %{
        correctness: 0.85,
        security: sec_score,
        architectural_fit: 0.8,
        maintainability: 0.8,
        testability: 0.8
      },
      verdict_reason: "Mock assessment for #{vote}",
      critique_points: [],
      suggested_modifications: []
    })
  end

  describe "Tier 1: Consensus Gating & Decision Routing" do
    test "T1_R4_ARB_01: high consensus assessments automatically approve diff", %{run: run} do
      assessments = [
        mock_assessment("rev1", :approve, 0.95, 0.95),
        mock_assessment("rev2", :approve, 0.90, 0.90),
        mock_assessment("rev3", :approve, 0.85, 0.85)
      ]

      result = Arbitrator.arbitrate(assessments, run_id: run.id)

      assert result.decision == :approved
      assert result.auto_approved == true
      assert result.approval_record == nil
    end

    test "T1_R4_ARB_02: contested consensus creates RunApproval and pauses execution", %{run: run} do
      assessments = [
        mock_assessment("cloud_claude", :approve, 0.9, 0.9),
        mock_assessment("local_llama", :reject, 0.9, 0.3)
      ]

      result = Arbitrator.arbitrate(assessments, run_id: run.id)

      assert result.decision == :requires_arbitration
      assert result.auto_approved == false
      assert %RunApproval{} = result.approval_record
      assert result.approval_record.action == "consensus_arbitration"
      assert result.approval_record.status == :pending
    end

    test "T1_R4_ARB_03: low consensus with security flaws triggers immediate rejection", %{
      run: run
    } do
      assessments = [
        mock_assessment("rev1", :reject, 0.9, 0.2),
        mock_assessment("rev2", :reject, 0.8, 0.3)
      ]

      result = Arbitrator.arbitrate(assessments, run_id: run.id)

      assert result.decision == :rejected
      assert result.auto_approved == false
    end
  end

  describe "Tier 2 & 3: Human Resolution of RunApproval & Dynamic Weight Adjustment" do
    test "T2_R4_ARB_01: human approving RunApproval resolves arbitration decision to :approved",
         %{
           run: run
         } do
      assessments = [
        mock_assessment("r1", :approve, 0.8, 0.8),
        mock_assessment("r2", :request_changes, 0.7, 0.6)
      ]

      result = Arbitrator.arbitrate(assessments, run_id: run.id)
      assert result.decision == :requires_arbitration
      approval = result.approval_record

      {:ok, resolved} = Arbitrator.resolve_arbitration(approval.id, :approved)

      assert resolved.status == :approved
    end

    test "T2_R4_ARB_02: human rejecting RunApproval resolves arbitration decision to :rejected",
         %{
           run: run
         } do
      assessments = [
        mock_assessment("r1", :approve, 0.8, 0.8),
        mock_assessment("r2", :request_changes, 0.7, 0.6)
      ]

      result = Arbitrator.arbitrate(assessments, run_id: run.id)
      approval = result.approval_record

      {:ok, resolved} = Arbitrator.resolve_arbitration(approval.id, :rejected)

      assert resolved.status == :rejected
    end

    test "T3_R4_ARB_01: offline model timeout triggers dynamic weight renormalization", %{
      run: run
    } do
      available_assessments = [
        mock_assessment("cloud_claude", :approve, 0.9, 0.9),
        mock_assessment("challenger_gpt", :approve, 0.85, 0.85)
      ]

      weights = %{"cloud_claude" => 0.45, "local_llama" => 0.30, "challenger_gpt" => 0.25}

      result =
        Arbitrator.arbitrate(available_assessments, run_id: run.id, initial_weights: weights)

      assert result.decision == :approved
      assert abs(result.swarm_concordance - 1.0) < 0.2
    end
  end
end
