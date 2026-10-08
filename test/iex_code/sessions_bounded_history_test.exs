defmodule IexCode.SessionsBoundedHistoryTest do
  use IexCode.DataCase, async: false

  alias IexCode.{Projects, Repo, Runs, Sessions}
  alias IexCode.Sessions.Message
  alias IexCode.Test.LeanHarnessCollector

  setup do
    {:ok, project} =
      Projects.create_project(%{
        name: "Bounded history",
        root_path: "/tmp/bounded-history-#{Ecto.UUID.generate()}"
      })

    {:ok, session} = Sessions.create_session(%{project_id: project.id, title: "History"})
    {:ok, other} = Sessions.create_session(%{project_id: project.id, title: "Other"})
    %{project: project, session: session, other: other}
  end

  test "recent retrieval limits rows in SQL and orders timestamp ties by ID", context do
    seed(context.session.id, 1..40)
    seed(context.other.id, 3_001..3_060)

    {messages, metrics} =
      LeanHarnessCollector.measure(fn ->
        Sessions.list_recent_messages(context.session.id, 20)
      end)

    assert Enum.map(messages, & &1.content) == Enum.map(21..40, &"message #{&1}")
    assert metrics.loaded_message_rows == 20
    assert metrics.query_count == 1

    seed(context.session.id, 41..2_000, ~U[2025-01-01 00:00:00Z])

    {larger, larger_metrics} =
      LeanHarnessCollector.measure(fn ->
        Sessions.list_recent_messages(context.session.id, 20)
      end)

    assert Enum.map(larger, & &1.id) == Enum.map(messages, & &1.id)
    assert larger_metrics.loaded_message_rows == 20
    assert larger_metrics.query_count == 1

    assert_raise ArgumentError, fn -> Sessions.list_recent_messages(context.session.id, 0) end
    assert_raise ArgumentError, fn -> Sessions.list_recent_messages(context.session.id, 201) end
  end

  test "display previews bound SQL content and reasoning at increasing history sizes",
       context do
    body = String.duplicate("🙂λ", 20_000)
    seed(context.session.id, 1..60)

    Repo.update_all(from(m in Message, where: m.session_id == ^context.session.id),
      set: [content: body, metadata: %{"reasoning" => body}, tool_calls: [%{"body" => body}]]
    )

    for size <- [60, 2_000] do
      if size > 60, do: seed(context.session.id, 61..size, ~U[2025-01-01 00:00:00Z])

      {result, metrics} =
        LeanHarnessCollector.measure(fn ->
          Sessions.fetch_message_preview_page(context.session.id)
        end)

      assert {:ok, page} = result
      assert length(page.messages) == 50
      assert metrics.loaded_message_rows <= 52
      assert metrics.query_count == 3
      assert Enum.all?(page.messages, &(&1.truncated? and &1.metadata["reasoning_truncated"]))
      assert Enum.all?(page.messages, &(byte_size(&1.metadata["reasoning"]) <= 2048))

      assert Enum.all?(
               page.messages,
               &(String.valid?(&1.content) and byte_size(&1.content) <= 4096)
             )

      assert Enum.all?(page.messages, &(:binary.referenced_byte_size(&1.content) <= 4096))
      refute Enum.any?(page.messages, &Map.has_key?(&1, :tool_calls))
    end

    assert Sessions.get_message(context.session.id, id(60)).content == body
  end

  test "exclusive cursor pages traverse tied timestamps without gaps in both directions",
       context do
    seed(context.session.id, 1..17)
    seed(context.other.id, 3_001..3_030)

    assert {:ok, latest} = Sessions.fetch_message_page(context.session.id, limit: 5)
    assert contents(latest) == Enum.map(13..17, &"message #{&1}")
    assert latest.has_older?
    refute latest.has_newer?

    assert {:ok, older} =
             Sessions.fetch_message_page(context.session.id,
               limit: 5,
               before: latest.first_cursor
             )

    assert contents(older) == Enum.map(8..12, &"message #{&1}")
    assert older.has_older? and older.has_newer?

    assert {:ok, oldest_ids} = traverse_older(context.session.id, latest, [])
    assert oldest_ids == Enum.map(1..17, &id/1)
    assert {:ok, newest_ids} = traverse_newer(context.session.id, id(1), [id(1)])
    assert newest_ids == Enum.map(1..17, &id/1)

    assert {:ok, newer} =
             Sessions.fetch_message_page(context.session.id, limit: 5, after: older.last_cursor)

    assert contents(newer) == contents(latest)
  end

  test "foreign, missing and malformed cursors are rejected without selecting another session",
       context do
    seed(context.session.id, 1..5)

    {:ok, foreign} =
      Sessions.create_message(%{session_id: context.other.id, role: "user", content: "foreign"})

    for cursor <- [foreign.id, Ecto.UUID.generate(), "invalid", false] do
      assert {:error, :invalid_cursor} =
               Sessions.fetch_message_page(context.session.id, before: cursor)
    end

    assert {:error, :invalid_arguments} =
             Sessions.fetch_message_page(context.session.id, before: id(1), after: id(2))

    for limit <- [0, -1, 201, :infinity] do
      assert {:error, :invalid_arguments} =
               Sessions.fetch_message_page(context.session.id, limit: limit)
    end
  end

  test "empty, one-message and exact-window pages expose correct boundaries", context do
    assert {:ok, %{messages: [], first_cursor: nil, last_cursor: nil} = empty} =
             Sessions.fetch_message_page(context.session.id, limit: 5)

    refute empty.has_older? or empty.has_newer?
    seed(context.session.id, 1..1)
    assert {:ok, one} = Sessions.fetch_message_page(context.session.id, limit: 5)
    assert contents(one) == ["message 1"]
    refute one.has_older? or one.has_newer?

    seed(context.session.id, 2..5)
    assert {:ok, exact} = Sessions.fetch_message_page(context.session.id, limit: 5)
    assert length(exact.messages) == 5
    refute exact.has_older? or exact.has_newer?
  end

  test "timestamp ordering takes precedence over the ID tie breaker", context do
    seed(context.session.id, 1..3, ~U[2026-01-03 00:00:00Z])
    seed(context.session.id, 4..6, ~U[2026-01-02 00:00:00Z])
    seed(context.session.id, 7..9, ~U[2026-01-01 00:00:00Z])

    assert {:ok, page} = Sessions.fetch_message_page(context.session.id, limit: 4)
    assert contents(page) == ["message 6", "message 1", "message 2", "message 3"]
    assert {:ok, ids} = traverse_older(context.session.id, page, [])
    assert ids == Enum.map([7, 8, 9, 4, 5, 6, 1, 2, 3], &id/1)
  end

  test "paging stays row-bounded and new insertions remain reachable without altering records",
       context do
    seed(context.session.id, 1..200)

    {result, metrics} =
      LeanHarnessCollector.measure(fn ->
        Sessions.fetch_message_page(context.session.id, limit: 5)
      end)

    assert {:ok, latest} = result
    assert metrics.loaded_message_rows <= 7
    seed(context.session.id, 201..201)

    assert {:ok, next} =
             Sessions.fetch_message_page(context.session.id, after: latest.last_cursor, limit: 5)

    assert contents(next) == ["message 201"]

    assert Repo.aggregate(from(m in Message, where: m.session_id == ^context.session.id), :count) ==
             201
  end

  test "scoped detail returns the complete stored body and rejects foreign identities", context do
    content = String.duplicate("complete λ body\n", 20_000)

    {:ok, message} =
      Sessions.create_message(%{
        session_id: context.session.id,
        role: "assistant",
        content: content,
        metadata: %{"reasoning" => "retained"},
        tool_calls: [%{"id" => "retained-tool"}]
      })

    assert Sessions.get_message(context.session.id, message.id) == message
    assert Sessions.get_message(context.other.id, message.id) == nil
    assert Sessions.get_message(context.session.id, "invalid") == nil
    assert Sessions.get_message(context.session.id, Ecto.UUID.generate()) == nil
  end

  test "final lookup uses the existing idempotency identity and preserves its full receipt",
       context do
    run = run(context)

    {:ok, message, :created} =
      Sessions.create_message_once(final_attrs(context.session.id, run.id), "run-final:#{run.id}")

    seed(context.session.id, 1..100)

    {found, metrics} =
      LeanHarnessCollector.measure(fn -> Sessions.get_run_final_message(run) end)

    assert found == message
    assert metrics.loaded_message_rows == 1
    assert metrics.query_count == 1
  end

  for mismatch <- [:session, :run_id, :role, :kind] do
    test "final lookup rejects mismatched #{mismatch}", context do
      run = run(context)
      attrs = final_attrs(context.session.id, run.id)

      attrs =
        case unquote(mismatch) do
          :session -> %{attrs | session_id: context.other.id}
          :run_id -> put_in(attrs.metadata["run_id"], Ecto.UUID.generate())
          :role -> %{attrs | role: "user"}
          :kind -> put_in(attrs.metadata["kind"], "research")
        end

      {:ok, _, :created} = Sessions.create_message_once(attrs, "run-final:#{run.id}")
      assert Sessions.get_run_final_message(run) == nil
    end
  end

  test "matching metadata without the canonical final identity is not replayed", context do
    run = run(context)
    {:ok, _} = Sessions.create_message(final_attrs(context.session.id, run.id))
    assert Sessions.get_run_final_message(run) == nil
  end

  defp seed(session_id, range, timestamp \\ ~U[2026-01-01 00:00:00Z]) do
    Repo.insert_all(
      Message,
      Enum.map(range, fn n ->
        %{
          id: id(n),
          session_id: session_id,
          role: "user",
          content: "message #{n}",
          inserted_at: timestamp,
          updated_at: timestamp
        }
      end)
    )
  end

  defp id(n), do: "00000000-0000-0000-0000-#{String.pad_leading(Integer.to_string(n), 12, "0")}"
  defp contents(page), do: Enum.map(page.messages, & &1.content)

  defp traverse_older(session_id, page, acc) do
    acc = Enum.map(page.messages, & &1.id) ++ acc

    if page.has_older? do
      {:ok, next} = Sessions.fetch_message_page(session_id, before: page.first_cursor, limit: 5)
      traverse_older(session_id, next, acc)
    else
      {:ok, acc}
    end
  end

  defp traverse_newer(session_id, cursor, acc) do
    {:ok, next} = Sessions.fetch_message_page(session_id, after: cursor, limit: 5)
    acc = acc ++ Enum.map(next.messages, & &1.id)
    if next.has_newer?, do: traverse_newer(session_id, next.last_cursor, acc), else: {:ok, acc}
  end

  defp run(context) do
    {:ok, run} =
      Runs.create_run(%{
        project_id: context.project.id,
        session_id: context.session.id,
        objective: "Bounded final",
        kind: "coding_agent",
        mode: "single"
      })

    run
  end

  defp final_attrs(session_id, run_id) do
    %{
      session_id: session_id,
      role: "assistant",
      content: "Historical answer",
      metadata: %{"run_id" => run_id, "kind" => "coding_agent", "turns" => 2, "tool_calls" => 1},
      input_tokens: 7,
      output_tokens: 11,
      cost_cents: 2
    }
  end
end
