defmodule IexCode.Eval.ScoringTest do
  use ExUnit.Case, async: true

  alias IexCode.Eval.Scoring

  test "pass rate counts outcomes" do
    assert Scoring.pass_rate([]) == 0.0
    assert Scoring.pass_rate([true, true]) == 1.0
    assert Scoring.pass_rate([true, false, false, false]) == 0.25
  end

  test "pass@k matches the unbiased estimator" do
    assert Scoring.pass_at_k([], 1) == 0.0
    assert Scoring.pass_at_k([false, false], 1) == 0.0
    assert Scoring.pass_at_k([true, true], 2) == 1.0
    # n=4, c=1, k=2 -> 1 - C(3,2)/C(4,2) = 1 - 3/6 = 0.5
    assert Scoring.pass_at_k([true, false, false, false], 2) == 0.5
    # n-c < k with a pass -> 1.0
    assert Scoring.pass_at_k([true, false], 2) == 1.0
    # n=5, c=2, k=1 -> 0.4
    assert Scoring.pass_at_k([true, true, false, false, false], 1) == 0.4
  end

  test "summarize bundles rate and curve" do
    summary = Scoring.summarize([true, false], [1, 2])
    assert summary.samples == 2
    assert summary.passed == 1
    assert summary.pass_rate == 0.5
    assert summary.pass_at_k == %{1 => 0.5, 2 => 1.0}
  end

  test "summarize_by_category groups tasks and computes pass@k per category" do
    tasks = [
      %{category: "bugfix", samples: [%{passed: true}, %{passed: false}]},
      %{category: "bugfix", samples: [%{passed: true}, %{passed: true}]},
      %{category: "refactor", samples: [%{passed: false}, %{passed: false}]},
      %{samples: [%{passed: true}]}
    ]

    by_cat = Scoring.summarize_by_category(tasks, [1, 2])

    assert by_cat["bugfix"] == Scoring.summarize([true, false, true, true], [1, 2])
    assert by_cat["refactor"] == Scoring.summarize([false, false], [1, 2])
    assert by_cat["general"] == Scoring.summarize([true], [1, 2])
    assert Scoring.summarize_by_category([], [1]) == %{}
  end
end
