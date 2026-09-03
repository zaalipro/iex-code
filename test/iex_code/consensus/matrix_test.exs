defmodule IexCode.Consensus.MatrixTest do
  @moduledoc """
  Requirement R4: Multi-Model Adversarial Consensus & Swarm Voting.
  Tests for IexCode.Consensus.Assessment and IexCode.Consensus.Matrix:
  - Structured assessment JSON parsing and markdown extraction
  - Pairwise agreement matrix math A_{j,k} and mathematical axioms (reflexivity, symmetry, bounds)
  - Swarm concordance \bar{A} and weighted score C calculation
  - Strict decision rule thresholds (:approved, :rejected, :requires_arbitration)
  """
  use ExUnit.Case, async: true

  alias IexCode.Consensus.Assessment
  alias IexCode.Consensus.Matrix

  @epsilon 1.0e-4

  defp assert_close(actual, expected, eps \\ @epsilon) do
    diff = abs(actual - expected)
    assert diff <= eps, "Expected #{actual} to be within #{eps} of #{expected} (diff: #{diff})"
  end

  defp make_assessment(attrs) do
    if Code.ensure_loaded?(Assessment) and function_exported?(Assessment, :__struct__, 1) do
      struct(Assessment, attrs)
    else
      Map.merge(%{__struct__: Assessment}, Map.new(attrs))
    end
  end

  defp sample_assessment(reviewer_id, vote, conf, scores, critiques \\ []) do
    make_assessment(%{
      reviewer_id: reviewer_id,
      provider: "anthropic",
      model: "claude-3-7-sonnet",
      vote: vote,
      confidence: conf,
      scores: %{
        correctness: Map.get(scores, :correctness, 0.8),
        security: Map.get(scores, :security, 0.8),
        architectural_fit: Map.get(scores, :architectural_fit, 0.8),
        maintainability: Map.get(scores, :maintainability, 0.8),
        testability: Map.get(scores, :testability, 0.8)
      },
      verdict_reason: "Automated assessment",
      critique_points: critiques,
      suggested_modifications: []
    })
  end

  describe "Tier 1: Structured Assessment Parsing" do
    test "T1_R4_MAT_01: parses valid assessment JSON map into Assessment struct" do
      json_str = """
      {
        "vote": "approve",
        "confidence": 0.95,
        "scores": {
          "correctness": 0.9,
          "security": 0.95,
          "architectural_fit": 0.85,
          "maintainability": 0.8,
          "testability": 0.9
        },
        "verdict_reason": "Clean implementation with solid test coverage",
        "critique_points": [
          {
            "severity": "minor",
            "category": "style",
            "file_path": "lib/foo.ex",
            "line_number": 12,
            "description": "Consider extracting helper function"
          }
        ],
        "suggested_modifications": ["Extract helper"]
      }
      """

      {:ok, assessment} = Assessment.parse(json_str)

      assert assessment.vote == :approve
      assert assessment.confidence == 0.95
      assert assessment.scores.security == 0.95
      assert length(assessment.critique_points) == 1
      assert hd(assessment.critique_points).severity in ["minor", :minor]
    end

    test "T1_R4_MAT_02: extracts JSON from markdown-fenced code blocks" do
      wrapped = """
      Here is my peer review analysis:
      ```json
      {
        "vote": "reject",
        "confidence": 0.85,
        "scores": {
          "correctness": 0.3,
          "security": 0.2,
          "architectural_fit": 0.5,
          "maintainability": 0.4,
          "testability": 0.3
        },
        "verdict_reason": "Critical SQL injection vulnerability detected",
        "critique_points": [
          {
            "severity": "blocker",
            "category": "security",
            "file_path": "lib/query.ex",
            "description": "Direct string interpolation in SQL query"
          }
        ],
        "suggested_modifications": ["Use parameterized queries"]
      }
      ```
      """

      {:ok, assessment} = Assessment.parse(wrapped)

      assert assessment.vote == :reject
      assert assessment.scores.security == 0.2

      assert Enum.any?(assessment.critique_points, fn c -> c.severity in ["blocker", :blocker] end)
    end
  end

  describe "Tier 1: Pairwise Agreement Matrix & Mathematical Axioms" do
    test "T1_R4_MAT_03: reflexivity — agreement of an assessment with itself is strictly 1.0" do
      a = sample_assessment("r1", :approve, 0.9, %{correctness: 0.85, security: 0.9})

      assert_close(Matrix.pairwise_agreement(a, a), 1.0)
    end

    test "T1_R4_MAT_04: symmetry — pairwise_agreement(A, B) == pairwise_agreement(B, A)" do
      a = sample_assessment("r1", :approve, 0.9, %{correctness: 0.9, security: 0.85})
      b = sample_assessment("r2", :request_changes, 0.7, %{correctness: 0.6, security: 0.7})

      agr_ab = Matrix.pairwise_agreement(a, b)
      agr_ba = Matrix.pairwise_agreement(b, a)

      assert_close(agr_ab, agr_ba)
    end

    test "T1_R4_MAT_05: boundedness — 0.0 <= A_{j,k} <= 1.0 under all inputs" do
      a =
        sample_assessment("r1", :approve, 1.0, %{
          correctness: 1.0,
          security: 1.0,
          architectural_fit: 1.0,
          maintainability: 1.0,
          testability: 1.0
        })

      b =
        sample_assessment("r2", :reject, 1.0, %{
          correctness: 0.0,
          security: 0.0,
          architectural_fit: 0.0,
          maintainability: 0.0,
          testability: 0.0
        })

      agr = Matrix.pairwise_agreement(a, b)

      assert agr >= 0.0 and agr <= 1.0
      assert agr < 0.15
    end

    test "T1_R4_MAT_06: vote concordance values match formal specification" do
      a_app = sample_assessment("r1", :approve, 1.0, %{})
      a_rej = sample_assessment("r2", :reject, 1.0, %{})
      a_req = sample_assessment("r3", :request_changes, 1.0, %{})

      assert_close(Matrix.vote_concordance(a_app, a_app), 1.0)
      assert_close(Matrix.vote_concordance(a_app, a_rej), 0.0)
      assert_close(Matrix.vote_concordance(a_app, a_req), 0.25)
      assert_close(Matrix.vote_concordance(a_rej, a_req), 0.75)
    end
  end

  describe "Tier 1 & 2: Swarm Concordance, Weighted Score, and Arbitration Decisions" do
    test "T1_R4_MAT_07: unanimous approval yields decision :approved with high C and A" do
      r1 = sample_assessment("r1", :approve, 0.9, %{correctness: 0.9, security: 0.95})
      r2 = sample_assessment("r2", :approve, 0.85, %{correctness: 0.85, security: 0.9})
      r3 = sample_assessment("r3", :approve, 0.8, %{correctness: 0.8, security: 0.85})

      result = Matrix.compute([r1, r2, r3])

      assert result.decision == :approved
      assert result.weighted_score >= 0.65
      assert result.swarm_concordance >= 0.60
      assert result.dimensional_averages.security >= 0.70
    end

    test "T1_R4_MAT_08: unanimous rejection yields decision :rejected" do
      r1 = sample_assessment("r1", :reject, 0.9, %{correctness: 0.2, security: 0.3})
      r2 = sample_assessment("r2", :reject, 0.85, %{correctness: 0.1, security: 0.2})

      result = Matrix.compute([r1, r2])

      assert result.decision == :rejected
      assert result.weighted_score <= -0.40
    end

    test "T2_R4_MAT_01: security blocker critique triggers immediate :rejected or arbitration regardless of score" do
      blocker_critique = %{
        severity: "blocker",
        category: "security",
        file_path: "lib/auth.ex",
        description: "Hardcoded secret exposed in cleartext"
      }

      r1 =
        sample_assessment("r1", :approve, 0.95, %{correctness: 0.9, security: 0.95}, [
          blocker_critique
        ])

      r2 = sample_assessment("r2", :approve, 0.9, %{correctness: 0.85, security: 0.9})

      result = Matrix.compute([r1, r2])

      assert result.decision in [:rejected, :requires_arbitration]
    end

    test "T2_R4_MAT_02: 50/50 split panel triggers :requires_arbitration" do
      r1 = sample_assessment("r1", :approve, 0.9, %{correctness: 0.9, security: 0.9})
      r2 = sample_assessment("r2", :reject, 0.9, %{correctness: 0.2, security: 0.3})

      result = Matrix.compute([r1, r2])

      assert result.decision == :requires_arbitration
      assert result.swarm_concordance < 0.60
    end

    test "T2_R4_MAT_03: custom reviewer weights are respected" do
      r1 = sample_assessment("r1", :approve, 1.0, %{correctness: 0.9, security: 0.9})
      r2 = sample_assessment("r2", :reject, 1.0, %{correctness: 0.1, security: 0.1})

      weights = %{"r1" => 0.8, "r2" => 0.2}
      result = Matrix.compute([r1, r2], weights: weights)

      assert_close(result.weighted_score, 0.60)
    end
  end
end
