Code.require_file("lib/feedback_repair.ex", __DIR__)

ExUnit.start(autorun: false)

defmodule FeedbackRepairGradeTest do
  use ExUnit.Case

  test "rejects :approved when findings are present and invalid verdicts" do
    state = FeedbackRepair.new(max_rounds: 3)

    assert {:error, :approved_with_findings} =
             FeedbackRepair.record_verdict(state, %{
               status: :approved,
               findings: [%{file: "lib/a.ex", line: 10, reason: "missing guard"}]
             })

    assert {:error, :invalid_verdict} = FeedbackRepair.record_verdict(state, %{status: :unknown})
  end

  test "deduplicates, sorts open findings, tracks resolved findings, and approves cleanly" do
    state = FeedbackRepair.new(max_rounds: 3)
    assert {:repair, 1, []} = FeedbackRepair.next_action(state)

    f_b = %{file: "lib/b.ex", line: 20, reason: "unused var"}
    f_a2 = %{file: "lib/a.ex", line: 12, reason: "nil deref"}
    f_a1 = %{file: "lib/a.ex", line: 5, reason: "bad spec"}

    {:ok, s1} =
      FeedbackRepair.record_verdict(state, %{
        status: :changes_requested,
        findings: [f_b, f_a2, f_b, f_a1]
      })

    assert s1.round == 1
    assert s1.status == :repairing
    assert s1.open_findings == [f_a1, f_a2, f_b]
    assert s1.resolved_findings == []
    assert {:repair, 2, [^f_a1, ^f_a2, ^f_b]} = FeedbackRepair.next_action(s1)

    # Round 2 fixes f_a1 and f_a2, leaves f_b open
    {:ok, s2} =
      FeedbackRepair.record_verdict(s1, %{
        status: :changes_requested,
        findings: [f_b]
      })

    assert s2.round == 2
    assert s2.status == :repairing
    assert s2.open_findings == [f_b]
    assert s2.resolved_findings == [f_a1, f_a2]

    # Round 3 approves cleanly with no findings
    {:ok, s3} = FeedbackRepair.record_verdict(s2, %{status: :approved, findings: []})
    assert s3.round == 3
    assert s3.status == :approved
    assert s3.open_findings == []
    assert s3.resolved_findings == [f_a1, f_a2, f_b]
    assert {:halt, :approved} = FeedbackRepair.next_action(s3)
  end

  test "transitions to :exhausted and halts with :max_rounds_exceeded when max_rounds reached" do
    s0 = FeedbackRepair.new(max_rounds: 2)
    f1 = %{file: "lib/x.ex", line: 4, reason: "timeout"}

    {:ok, s1} = FeedbackRepair.record_verdict(s0, %{status: :changes_requested, findings: [f1]})
    assert s1.status == :repairing
    assert {:repair, 2, [^f1]} = FeedbackRepair.next_action(s1)

    {:ok, s2} = FeedbackRepair.record_verdict(s1, %{status: :changes_requested, findings: [f1]})
    assert s2.round == 2
    assert s2.status == :exhausted
    assert {:halt, :max_rounds_exceeded} = FeedbackRepair.next_action(s2)
    assert length(s2.history) == 2
  end
end

case ExUnit.run() do
  %{failures: 0} -> System.halt(0)
  _ -> System.halt(1)
end
