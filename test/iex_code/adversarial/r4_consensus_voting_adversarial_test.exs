defmodule IexCode.Adversarial.R4ConsensusVotingAdversarialTest do
  @moduledoc """
  Adversarial stress testing for Requirement R4:
  - Extreme polar disagreements and discordant panels
  - Boundary dimensional scores (0.0, 1.0, missing dimensions)
  - Mathematical axioms: reflexivity, symmetry, boundedness
  - All-reject scenarios and tie-breaks
  - Blocker critique immunity gating (auto-approval prevention)
  - Dynamic weight renormalization across offline/failing models
  - RunApproval lifecycle, DB persistence, and human resolution
  """

  use IexCode.DataCase, async: false

  alias IexCode.Consensus.Assessment
  alias IexCode.Consensus.Matrix
  alias IexCode.Consensus.Arbitrator
  alias IexCode.Projects
  alias IexCode.Sessions
  alias IexCode.Runs
  alias IexCode.Runs.RunApproval

  setup do
    unique_id = System.unique_integer([:positive])
    temp_dir = Path.join(System.tmp_dir!(), "iex_adv_consensus_#{unique_id}")
    File.mkdir_p!(temp_dir)

    {:ok, project} =
      Projects.create_project(%{
        name: "Consensus Project #{unique_id}",
        root_path: temp_dir
      })

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Consensus Session #{unique_id}"
      })

    {:ok, run} =
      Runs.create_run(%{
        session_id: session.id,
        project_id: project.id,
        objective: "Adversarial Consensus Run #{unique_id}",
        status: "running"
      })

    on_exit(fn ->
      File.rm_rf(temp_dir)
    end)

    {:ok, run_id: run.id, session_id: session.id}
  end

  defp make_assessment(reviewer_id, vote, conf, scores, critiques \\ []) do
    %Assessment{
      reviewer_id: reviewer_id,
      provider: "mock_provider",
      model: "mock_model",
      vote: vote,
      confidence: conf,
      scores: scores,
      critique_points: critiques
    }
  end

  describe "ADV_R4_01: Extreme Polar Disagreements" do
    test "proves complete opposition yields 0.0 agreement and forces arbitration" do
      # Model 1: Maximum approval
      a1 =
        make_assessment("model_1", :approve, 1.0, %{
          correctness: 1.0,
          security: 1.0,
          architectural_fit: 1.0,
          maintainability: 1.0,
          testability: 1.0
        })

      # Model 2: Maximum rejection
      a2 =
        make_assessment("model_2", :reject, 1.0, %{
          correctness: 0.0,
          security: 0.0,
          architectural_fit: 0.0,
          maintainability: 0.0,
          testability: 0.0
        })

      agreement = Matrix.pairwise_agreement(a1, a2)
      assert abs(agreement - 0.0) < 1.0e-5, "Polar opposite assessments must have agreement 0.0"

      res = Matrix.compute([a1, a2])
      assert res.swarm_concordance == 0.0
      assert abs(res.weighted_score - 0.0) < 1.0e-5
      assert res.decision == :requires_arbitration
    end
  end

  describe "ADV_R4_02: Boundary Dimensional Scores & Mathematical Axioms" do
    test "verifies reflexivity, symmetry, and strict boundedness (0.0 <= A <= 1.0)" do
      scores_min = %{
        correctness: 0.0,
        security: 0.0,
        architectural_fit: 0.0,
        maintainability: 0.0,
        testability: 0.0
      }

      scores_max = %{
        correctness: 1.0,
        security: 1.0,
        architectural_fit: 1.0,
        maintainability: 1.0,
        testability: 1.0
      }

      scores_partial = %{correctness: 0.5}

      a_min = make_assessment("rev_min", :reject, 0.1, scores_min)
      a_max = make_assessment("rev_max", :approve, 1.0, scores_max)
      a_part = make_assessment("rev_part", :request_changes, 0.7, scores_partial)

      all = [a_min, a_max, a_part]

      for x <- all, y <- all do
        agree = Matrix.pairwise_agreement(x, y)

        # Boundedness: 0.0 <= A <= 1.0
        assert agree >= 0.0 and agree <= 1.0, "Agreement must be bounded in [0.0, 1.0]"

        # Symmetry: A(x, y) == A(y, x)
        agree_rev = Matrix.pairwise_agreement(y, x)
        assert abs(agree - agree_rev) < 1.0e-5, "Agreement must be symmetric"
      end

      # Reflexivity: A(x, x) == 1.0
      for x <- all do
        assert Matrix.pairwise_agreement(x, x) == 1.0
      end
    end
  end

  describe "ADV_R4_03: Unanimous and Supermajority Rejection Scenarios" do
    test "unanimously negative panel produces :rejected decision and blocks auto-approval" do
      assessments = [
        make_assessment("m1", :reject, 0.9, %{correctness: 0.2, security: 0.2}),
        make_assessment("m2", :reject, 0.85, %{correctness: 0.1, security: 0.3}),
        make_assessment("m3", :reject, 0.95, %{correctness: 0.3, security: 0.1})
      ]

      result = Arbitrator.arbitrate(assessments)

      assert result.decision == :rejected
      assert result.auto_approved == false
      assert result.approval_record == nil
      assert result.weighted_score <= -0.40
    end
  end

  describe "ADV_R4_04: Blocker Critique Immunity Gating (Security Gating)" do
    test "atom-keyed blocker critique blocks auto-approval even if scores and votes are 100% positive" do
      # 3 models with perfect 1.0 scores and :approve votes
      perfect_scores = %{
        correctness: 1.0,
        security: 1.0,
        architectural_fit: 1.0,
        maintainability: 1.0,
        testability: 1.0
      }

      assessments = [
        make_assessment("m1", :approve, 1.0, perfect_scores),
        make_assessment("m2", :approve, 1.0, perfect_scores),
        make_assessment("m3", :approve, 1.0, perfect_scores, [
          %{severity: :blocker, message: "Critical vulnerability detected"}
        ])
      ]

      result = Arbitrator.arbitrate(assessments)

      # MUST NOT BE AUTO-APPROVED
      refute result.decision == :approved, "Blocker critique must prevent auto-approval"
      assert result.auto_approved == false
      assert result.decision == :requires_arbitration
      assert result.matrix.has_blocker? == true
    end

    test "string-keyed blocker critique with low security score triggers immediate rejection" do
      low_sec_scores = %{
        correctness: 0.8,
        security: 0.3,
        architectural_fit: 0.8,
        maintainability: 0.8,
        testability: 0.8
      }

      assessments = [
        make_assessment("m1", :approve, 0.8, low_sec_scores),
        make_assessment("m2", :request_changes, 0.8, low_sec_scores, [
          %{"severity" => "blocker", "message" => "SQL injection hazard"}
        ])
      ]

      result = Arbitrator.arbitrate(assessments)

      # Security avg is 0.3 (< 0.5) with blocker -> strict rejection
      assert result.decision == :rejected
      assert result.auto_approved == false
    end
  end

  describe "ADV_R4_05: Tie-Breaks and Even Panels" do
    test "even split between approve and reject forces arbitration without deadlock" do
      scores = %{correctness: 0.7, security: 0.7}

      assessments = [
        make_assessment("m1", :approve, 0.8, scores),
        make_assessment("m2", :approve, 0.8, scores),
        make_assessment("m3", :reject, 0.8, scores),
        make_assessment("m4", :reject, 0.8, scores)
      ]

      result = Arbitrator.arbitrate(assessments)

      assert result.decision == :requires_arbitration
      assert result.auto_approved == false
      assert abs(result.weighted_score - 0.0) < 1.0e-5
    end
  end

  describe "ADV_R4_06: RunApproval Lifecycle & Human Resolution Integration" do
    test "creates persistent RunApproval on arbitration and resolves cleanly with :approved and :rejected",
         %{run_id: run_id} do
      contested = [
        make_assessment("m1", :approve, 0.7, %{correctness: 0.6}),
        make_assessment("m2", :reject, 0.7, %{correctness: 0.5})
      ]

      result = Arbitrator.arbitrate(contested, run_id: run_id)

      assert result.decision == :requires_arbitration
      assert %RunApproval{} = approval = result.approval_record
      assert approval.status == :pending
      assert approval.run_id == run_id

      # Verify persistence in Repo
      db_record = Repo.get(RunApproval, approval.id)
      assert db_record != nil
      assert db_record.status == "pending"

      # Case 1: Resolve as :approved
      {:ok, resolved_app} = Arbitrator.resolve_arbitration(approval.id, :approved)
      assert resolved_app.status == :approved
      assert resolved_app.decided_by == "human_arbitrator"

      # Verify DB record updated
      updated_db = Repo.get(RunApproval, approval.id)
      assert updated_db.status == "approved"

      # Case 2: Resolve as :rejected on new record
      result2 = Arbitrator.arbitrate(contested, run_id: run_id)
      app2 = result2.approval_record

      {:ok, resolved_app2} = Arbitrator.resolve_arbitration(app2.id, :rejected)
      assert resolved_app2.status == :rejected

      # Case 3: Resolve non-existent record
      assert {:error, :not_found} =
               Arbitrator.resolve_arbitration("non_existent_approval_id", :approved)
    end
  end

  describe "ADV_R4_07: Dynamic Weight Renormalization & Fault Tolerance" do
    test "renormalizes weights when offline models drop out, and handles edge panels safely" do
      initial_weights = %{
        "model_online_1" => 0.2,
        "model_online_2" => 0.2,
        "model_offline_3" => 0.2,
        "model_offline_4" => 0.2,
        "model_offline_5" => 0.2
      }

      active_assessments = [
        make_assessment("model_online_1", :approve, 0.9, %{correctness: 0.9, security: 0.9}),
        make_assessment("model_online_2", :approve, 0.9, %{correctness: 0.9, security: 0.9})
      ]

      result = Arbitrator.arbitrate(active_assessments, initial_weights: initial_weights)

      # 2 active models with 0.2 each renormalize to 0.5 and 0.5 -> auto-approved
      assert result.decision == :approved
      assert result.auto_approved == true
      assert result.swarm_concordance == 1.0

      # Single reviewer panel (m=1): must not divide by zero on pair combinations
      single = [make_assessment("solo", :approve, 1.0, %{correctness: 1.0})]
      res_single = Matrix.compute(single)
      assert res_single.swarm_concordance == 1.0

      # Empty assessments panel: must handle gracefully
      empty_res = Matrix.compute([])
      assert empty_res.decision == :requires_arbitration
      assert empty_res.weighted_score == 0.0
      assert empty_res.swarm_concordance == 0.0
    end
  end
end
