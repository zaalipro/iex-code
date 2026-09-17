defmodule IexCode.Session.RolloutTest do
  use ExUnit.Case, async: true

  alias IexCode.Session.Rollout

  setup do
    dir = Path.join(System.tmp_dir!(), "rollout-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{path: Rollout.path_for(dir, "sess-1")}
  end

  test "path sanitizes session ids" do
    assert Rollout.path_for("/d", "a/b..c") == "/d/rollouts/a_b__c.jsonl"
  end

  test "records and loads with seq", %{path: path} do
    assert {:ok, []} = Rollout.load(path)

    :ok = Rollout.record(path, "user", %{"content" => "hi"})
    :ok = Rollout.record(path, "assistant", %{"text" => "yo", "tool_calls" => []})

    assert {:ok, [first, second]} = Rollout.load(path)
    assert first["seq"] == 1
    assert first["type"] == "user"
    assert is_binary(first["ts"])
    assert second["seq"] == 2
  end

  test "replays messages in order", %{path: path} do
    :ok = Rollout.record(path, "user", %{"content" => "goal"})

    :ok =
      Rollout.record(path, "assistant", %{"text" => "doing", "tool_calls" => [%{"id" => "c1"}]})

    :ok = Rollout.record(path, "tool", %{"tool_call_id" => "c1", "content" => "out"})
    :ok = Rollout.record(path, "final", %{"text" => "done"})

    {:ok, records} = Rollout.load(path)

    assert Rollout.replay(records) == [
             %{role: "user", content: "goal"},
             %{role: "assistant", content: "doing", tool_calls: [%{"id" => "c1"}]},
             %{role: "tool", tool_call_id: "c1", content: "out"}
           ]
  end

  test "compact checkpoints replace history", %{path: path} do
    :ok = Rollout.record(path, "user", %{"content" => "old"})
    :ok = Rollout.record(path, "assistant", %{"text" => "old2", "tool_calls" => []})

    :ok =
      Rollout.record(path, "compact", %{
        "messages" => [%{"role" => "user", "content" => "summary"}],
        "dropped" => 2
      })

    :ok = Rollout.record(path, "assistant", %{"text" => "new", "tool_calls" => []})

    {:ok, records} = Rollout.load(path)

    assert Rollout.replay(records) == [
             %{role: "user", content: "summary"},
             %{role: "assistant", content: "new", tool_calls: []}
           ]
  end

  test "rollback truncates and marks", %{path: path} do
    :ok = Rollout.record(path, "user", %{"content" => "one"})
    :ok = Rollout.record(path, "user", %{"content" => "two"})
    :ok = Rollout.record(path, "user", %{"content" => "three"})

    assert {:ok, records} = Rollout.rollback(path, 2)
    assert length(records) == 3
    assert List.last(records)["type"] == "rollback"

    {:ok, messages} = Rollout.resume_messages(path)
    assert Enum.map(messages, & &1.content) == ["one", "two"]

    {:ok, wound} = Rollout.resume_messages(path, to_seq: 1)
    assert Enum.map(wound, & &1.content) == ["one"]
  end

  test "corrupt lines error with position", %{path: path} do
    :ok = Rollout.record(path, "user", %{"content" => "ok"})
    File.write!(path, "{broken\n", [:append])

    assert {:error, {:rollout_corrupt_line, 2}} = Rollout.load(path)
  end

  test "maybe_compact checkpoints only over threshold", %{path: path} do
    :ok = Rollout.record(path, "user", %{"content" => "small"})
    assert {:ok, :under_threshold} = Rollout.maybe_compact(path, nil)

    big = String.duplicate("token-heavy tool output ", 200)

    for i <- 1..20 do
      :ok = Rollout.record(path, "assistant", %{"text" => "turn #{i}", "tool_calls" => []})
      :ok = Rollout.record(path, "tool", %{"tool_call_id" => "c#{i}", "content" => big})
    end

    settings = %{
      context_window_tokens: 1_000,
      context_prune_threshold_percent: 10,
      context_compaction_strategy: "sliding_window",
      keep_recent_turns: 2
    }

    assert {:ok, :compacted} = Rollout.maybe_compact(path, settings)

    {:ok, records} = Rollout.load(path)
    assert List.last(records)["type"] == "compact"

    {:ok, messages} = Rollout.resume_messages(path)
    assert length(messages) < 41
  end
end
