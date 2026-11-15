defmodule IexCode.Consensus.FeedbackSynthesisAndBoundsTest do
  use IexCode.DataCase, async: false

  alias IexCode.Consensus.{Arbitrator, Assessment, Matrix}
  alias IexCode.Projects
  alias IexCode.Runs
  alias IexCode.Sessions

  defp make_assessment(attrs) do
    struct(Assessment, attrs)
  end

  describe "Assessment & Matrix Clamping and Bounds" do
    test "Assessment.parse/1 clamps out-of-range confidence and all rubric scores to [0.0, 1.0]" do
      payload = %{
        "vote" => "approve",
        "confidence" => 5.0,
        "scores" => %{
          "correctness" => 99.0,
          "security" => -2.5,
          "architectural_fit" => 1.7,
          "maintainability" => -0.1,
          "testability" => 3.14
        }
      }

      assert {:ok, assessment} = Assessment.parse(payload)
      assert assessment.confidence == 1.0
      assert assessment.scores.correctness == 1.0
      assert assessment.scores.security == 0.0
      assert assessment.scores.architectural_fit == 1.0
      assert assessment.scores.maintainability == 0.0
      assert assessment.scores.testability == 1.0
    end

    test "Assessment.parse/1 supports test_coverage alias and negative confidence clamping" do
      payload = %{
        "vote" => "reject",
        "confidence" => -3.0,
        "scores" => %{
          "correctness" => 0.4,
          "security" => 0.5,
          "maintainability" => 0.6,
          "test_coverage" => 1.8
        }
      }

      assert {:ok, assessment} = Assessment.parse(payload)
      assert assessment.confidence == 0.0
      assert assessment.scores.testability == 1.0
    end

    test "Matrix.compute/2 clamps rogue hand-built struct scores/confidence so outputs stay bounded" do
      rogue_high =
        make_assessment(%{
          reviewer_id: "rogue_1",
          vote: :approve,
          confidence: 5.0,
          scores: %{
            correctness: 4.0,
            security: 2.5,
            architectural_fit: 1.5,
            maintainability: 9.0,
            testability: 2.0
          }
        })

      rogue_low =
        make_assessment(%{
          reviewer_id: "rogue_2",
          vote: :reject,
          confidence: 10.0,
          scores: %{
            correctness: -2.0,
            security: -5.0,
            architectural_fit: -1.0,
            maintainability: -3.0,
            testability: -0.5
          }
        })

      res = Matrix.compute([rogue_high, rogue_low])
      assert res.weighted_score == 0.0
      assert res.swarm_concordance == 0.0
      assert Enum.all?(Map.values(res.dimensional_averages), &(&1 >= 0.0 and &1 <= 1.0))

      # Single rogue approver cannot exceed weighted_score 1.0
      solo = Matrix.compute([rogue_high])
      assert solo.weighted_score == 1.0
      assert solo.swarm_concordance == 1.0
      assert solo.dimensional_averages.correctness == 1.0
    end
  end

  describe "Matrix Weight Guarding & Reviewer Deduplication" do
    test "clamps negative reviewer weights to 0.0 and falls back to uniform when total positive weight is 0.0" do
      r1 = make_assessment(%{reviewer_id: "r1", vote: :approve, confidence: 1.0})
      r2 = make_assessment(%{reviewer_id: "r2", vote: :reject, confidence: 1.0})

      # r1 clamped to 0.0, only r2 has positive weight
      res_partial = Matrix.compute([r1, r2], weights: %{"r1" => -5.0, "r2" => 2.0})
      assert_in_delta res_partial.weighted_score, -1.0, 1.0e-5
      assert res_partial.decision == :rejected

      # All negative / zero weights fall back to uniform (0.5 / 0.5 -> 0.0)
      res_all_neg = Matrix.compute([r1, r2], weights: %{"r1" => -1.0, "r2" => -3.0})
      assert_in_delta res_all_neg.weighted_score, 0.0, 1.0e-5
      assert res_all_neg.decision == :requires_arbitration
    end

    test "clamps negative dimension weights and falls back to @default_weights when total positive weight is 0.0" do
      r1 =
        make_assessment(%{
          reviewer_id: "r1",
          vote: :approve,
          confidence: 1.0,
          scores: %{
            correctness: 1.0,
            security: 1.0,
            architectural_fit: 1.0,
            maintainability: 1.0,
            testability: 1.0
          }
        })

      r2 =
        make_assessment(%{
          reviewer_id: "r2",
          vote: :approve,
          confidence: 1.0,
          scores: %{
            correctness: 0.0,
            security: 0.0,
            architectural_fit: 0.0,
            maintainability: 0.0,
            testability: 0.0
          }
        })

      res_neg_dims =
        Matrix.compute([r1, r2],
          dimension_weights: %{
            correctness: -2.0,
            security: -1.0,
            architectural_fit: 0.0,
            maintainability: 0.0,
            testability: 0.0
          }
        )

      res_default = Matrix.compute([r1, r2], dimension_weights: Matrix.default_weights())
      assert_in_delta res_neg_dims.swarm_concordance, res_default.swarm_concordance, 1.0e-6
    end

    test "deduplicates assessments with duplicate non-empty reviewer_id by default, preserves anonymous, and allows opt-out" do
      r1_a = make_assessment(%{reviewer_id: "r1", vote: :approve, confidence: 0.9})
      r1_b = make_assessment(%{reviewer_id: "r1", vote: :approve, confidence: 0.9})
      r1_c = make_assessment(%{reviewer_id: "r1", vote: :approve, confidence: 0.9})
      r2 = make_assessment(%{reviewer_id: "r2", vote: :reject, confidence: 0.9})

      # Without dedup, 3x r1 approves would outvote 1x r2 reject; with dedup it's 1 vs 1
      deduped = Matrix.compute([r1_a, r1_b, r1_c, r2])
      assert length(deduped.assessments) == 2
      assert deduped.decision == :requires_arbitration
      assert_in_delta deduped.weighted_score, 0.0, 1.0e-5

      # Opt-out preserves all 4
      raw = Matrix.compute([r1_a, r1_b, r1_c, r2], deduplicate_reviewers: false)
      assert length(raw.assessments) == 4

      # Empty or nil reviewer_id assessments are NOT collapsed together
      anon1 = make_assessment(%{reviewer_id: nil, vote: :approve, confidence: 0.9})
      anon2 = make_assessment(%{reviewer_id: "", vote: :reject, confidence: 0.9})
      anon3 = make_assessment(%{reviewer_id: "   ", vote: :approve, confidence: 0.9})
      anon_res = Matrix.compute([anon1, anon2, anon3])
      assert length(anon_res.assessments) == 3
    end
  end

  describe "Arbitrator Resolution Hardening & Actionable Feedback Synthesis" do
    setup do
      unique_id = System.unique_integer([:positive])
      temp_dir = Path.join(System.tmp_dir!(), "iex_synth_test_#{unique_id}")
      File.mkdir_p!(temp_dir)

      {:ok, project} =
        Projects.create_project(%{
          name: "Synthesis Test Project #{unique_id}",
          root_path: temp_dir
        })

      {:ok, session} =
        Sessions.create_session(%{
          project_id: project.id,
          title: "Synthesis Session #{unique_id}"
        })

      {:ok, run} =
        Runs.create_run(%{
          session_id: session.id,
          project_id: project.id,
          objective: "Consensus Feedback Synthesis Test",
          status: "running"
        })

      on_exit(fn -> File.rm_rf(temp_dir) end)
      {:ok, run: run}
    end

    test "resolve_arbitration enforces strict resolution values, idempotency, and conflict rejection",
         %{run: run} do
      contested = [
        make_assessment(%{reviewer_id: "r1", vote: :approve, confidence: 0.8}),
        make_assessment(%{reviewer_id: "r2", vote: :reject, confidence: 0.8})
      ]

      %{approval_record: approval} = Arbitrator.arbitrate(contested, run_id: run.id)

      assert {:error, :invalid_resolution} = Arbitrator.resolve_arbitration(approval.id, :denied)
      assert {:error, :invalid_resolution} = Arbitrator.resolve_arbitration(approval.id, nil)
      assert {:error, :invalid_resolution} = Arbitrator.resolve_arbitration(approval.id, "maybe")

      assert {:ok, resolved} = Arbitrator.resolve_arbitration(approval.id, "rejected")
      assert resolved.status == :rejected

      # Same resolution is idempotent
      assert {:ok, same} = Arbitrator.resolve_arbitration(approval.id, :rejected)
      assert same.status == :rejected

      # Conflicting re-resolution returns {:error, :already_resolved}
      assert {:error, :already_resolved} = Arbitrator.resolve_arbitration(approval.id, :approved)
    end

    test "synthesize_actionable_feedback deduplicates, ranks, finds weak dimensions, and builds crisp repair_prompt" do
      r1 =
        make_assessment(%{
          reviewer_id: "claude",
          vote: :reject,
          confidence: 0.95,
          scores: %{
            correctness: 0.4,
            security: 0.2,
            architectural_fit: 0.85,
            maintainability: 0.85,
            testability: 0.5
          },
          critique_points: [
            %{
              severity: :minor,
              category: "style",
              file_path: "lib/auth.ex",
              line_number: 12,
              description: "Unused alias"
            },
            %{
              severity: :major,
              category: "security",
              file_path: "lib/auth.ex",
              line_number: 42,
              description: "Unchecked shell interpolation"
            }
          ],
          suggested_modifications: ["Use System.cmd/3 with argument list", "Add unit tests"]
        })

      r2 =
        make_assessment(%{
          reviewer_id: "gpt5",
          vote: :request_changes,
          confidence: 0.90,
          scores: %{
            correctness: 0.5,
            security: 0.3,
            architectural_fit: 0.90,
            maintainability: 0.80,
            testability: 0.6
          },
          critique_points: [
            %{
              severity: "blocker",
              category: "security",
              file_path: "./lib/auth.ex",
              line_number: 42,
              description: "Command injection via user input"
            },
            %{
              severity: :major,
              category: "correctness",
              file_path: "lib/session.ex",
              line_number: 18,
              description: "Missing expiry validation"
            }
          ],
          suggested_modifications: ["Add unit tests", "Validate token expiration timestamp"]
        })

      r3 =
        make_assessment(%{
          reviewer_id: "gemini",
          vote: :request_changes,
          confidence: 0.85,
          scores: %{
            correctness: 0.45,
            security: 0.25,
            architectural_fit: 0.85,
            maintainability: 0.85,
            testability: 0.55
          },
          critique_points: [
            %{
              severity: :major,
              category: "correctness",
              file_path: "lib/session.ex",
              line_number: 18,
              description: "Missing expiry validation"
            }
          ],
          suggested_modifications: []
        })

      arbitration = Arbitrator.arbitrate([r1, r2, r3])
      feedback_from_arb = Arbitrator.synthesize_actionable_feedback(arbitration)
      feedback_from_list = Arbitrator.synthesize_actionable_feedback([r1, r2, r3])

      assert feedback_from_arb == feedback_from_list
      assert feedback_from_arb.reviewer_count == 3

      # lib/auth.ex:42 security finding deduplicated across r1+r2 and elevated to :blocker
      assert length(feedback_from_arb.blocking_issues) == 1
      [blocker] = feedback_from_arb.blocking_issues
      assert blocker.file == "lib/auth.ex"
      assert blocker.line == 42
      assert blocker.category == "security"
      assert blocker.frequency == 2
      assert blocker.severity == :blocker
      assert_in_delta blocker.confidence, 0.95, 1.0e-5

      # 3 unique critique items ranked: blocker (auth:42) > major freq=2 (session:18) > minor (auth:12)
      assert length(feedback_from_arb.critique_items) == 3

      assert Enum.map(feedback_from_arb.critique_items, &{&1.severity, &1.file, &1.line}) == [
               {:blocker, "lib/auth.ex", 42},
               {:major, "lib/session.ex", 18},
               {:minor, "lib/auth.ex", 12}
             ]

      # Weakest dimensions: security (~0.25), correctness (~0.45), testability (~0.55)
      weak_dims = Enum.map(feedback_from_arb.weakest_dimensions, & &1.dimension)
      assert weak_dims == [:security, :correctness, :testability]

      # Deduplicated suggested modifications
      assert feedback_from_arb.suggested_modifications == [
               "Use System.cmd/3 with argument list",
               "Add unit tests",
               "Validate token expiration timestamp"
             ]

      # Crisp repair_prompt ready for coder retry turn
      prompt = feedback_from_arb.repair_prompt
      assert is_binary(prompt) and prompt != ""
      assert prompt =~ "Blocking issues"
      assert prompt =~ "[BLOCKER] lib/auth.ex:42 (security)"
      assert prompt =~ "lib/session.ex:18"
      assert prompt =~ "Weakest rubric dimensions"
      assert prompt =~ "security:"
      assert prompt =~ "Suggested modifications"
    end

    test "synthesize_actionable_feedback handles empty panel cleanly" do
      feedback = Arbitrator.synthesize_actionable_feedback([])
      assert feedback.reviewer_count == 0
      assert feedback.blocking_issues == []
      assert feedback.critique_items == []
      assert feedback.weakest_dimensions == []
      assert feedback.repair_prompt == ""
    end
  end
end
