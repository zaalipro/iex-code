defmodule IexCode.SessionsOperationHistoryTest do
  use IexCode.DataCase, async: false

  alias IexCode.{Projects, Repo, Sessions}
  alias IexCode.Sessions.Operation
  alias IexCode.Test.LeanHarnessCollector

  setup do
    {:ok, project} =
      Projects.create_project(%{
        name: "Operation pages",
        root_path: "/tmp/operation-pages-#{Ecto.UUID.generate()}"
      })

    {:ok, session} = Sessions.create_session(%{project_id: project.id, title: "Operations"})
    {:ok, other} = Sessions.create_session(%{project_id: project.id, title: "Other"})
    %{session: session, other: other}
  end

  test "terminal pages traverse more than three windows in both directions", context do
    seed(context.session.id, 1..173)
    seed(context.other.id, 1_001..1_080)

    assert {:ok, latest} = Sessions.fetch_operation_page(context.session.id)
    assert ids(latest) == Enum.map(124..173, &id/1)
    assert latest.first_cursor == id(124)
    assert latest.last_cursor == id(173)
    assert latest.has_older?
    refute latest.has_newer?

    oldest = walk_older(context.session.id, latest, [])
    assert oldest == Enum.map(1..173, &id/1)
    assert walk_newer(context.session.id, id(1), [id(1)]) == oldest

    assert latest.stats == %{
             total: 173,
             roots: 173,
             pending: 0,
             running: 0,
             completed: 173,
             failed: 0,
             total_duration_ms: 1730
           }

    assert Repo.aggregate(
             from(o in Operation, where: o.session_id == ^context.session.id),
             :count
           ) ==
             173
  end

  test "timestamp precedes ID and inserts remain reachable from an older page", context do
    seed(context.session.id, 1..3, inserted_at: ~U[2026-01-03 00:00:00Z])
    seed(context.session.id, 4..6, inserted_at: ~U[2026-01-02 00:00:00Z])
    seed(context.session.id, 7..9, inserted_at: ~U[2026-01-01 00:00:00Z])
    assert {:ok, latest} = Sessions.fetch_operation_page(context.session.id, limit: 4)
    assert ids(latest) == Enum.map([6, 1, 2, 3], &id/1)

    assert {:ok, older} =
             Sessions.fetch_operation_page(context.session.id,
               before: latest.first_cursor,
               limit: 4
             )

    assert ids(older) == Enum.map([8, 9, 4, 5], &id/1)
    seed(context.session.id, 10..10, inserted_at: ~U[2026-01-04 00:00:00Z])

    assert {:ok, newer} =
             Sessions.fetch_operation_page(context.session.id, after: latest.last_cursor)

    assert ids(newer) == [id(10)]
    assert newer.stats.total == 10
  end

  test "only active ancestors escape the terminal limit and cursors track terminal seeds",
       context do
    seed(context.session.id, 1..120)
    seed(context.session.id, 121..121, status: "failed", parent_op_id: id(1))
    seed(context.session.id, 122..122, status: "running", parent_op_id: id(121))
    seed(context.session.id, 123..123, status: "pending", parent_op_id: id(1))
    seed(context.other.id, 1_001..1_001)
    seed(context.session.id, 124..124, status: "running", parent_op_id: id(1_001))
    seed(context.session.id, 125..125, parent_op_id: id(2))

    assert {:ok, page} = Sessions.fetch_operation_page(context.session.id, limit: 5)
    assert ids(page) == Enum.map([1, 118, 119, 120, 121, 122, 123, 124, 125], &id/1)
    refute id(2) in ids(page)
    refute id(1_001) in ids(page)
    assert page.first_cursor == id(118)
    assert page.last_cursor == id(125)
    assert page.has_older?
    refute page.has_newer?

    assert page.stats == %{
             total: 125,
             roots: 121,
             running: 2,
             pending: 1,
             completed: 121,
             failed: 1,
             total_duration_ms: 1250
           }

    assert {:ok, older} =
             Sessions.fetch_operation_page(context.session.id,
               before: page.first_cursor,
               limit: 5
             )

    assert ids(older) == Enum.map([1, 113, 114, 115, 116, 117, 121, 122, 123, 124], &id/1)
  end

  test "active ancestry terminates on cycles and missing parents", context do
    seed(context.session.id, 1..1, parent_op_id: id(2), status: "running")
    seed(context.session.id, 2..2, parent_op_id: id(1))
    seed(context.session.id, 3..3, parent_op_id: id(99), status: "pending")
    assert {:ok, page} = Sessions.fetch_operation_page(context.session.id, limit: 1)
    assert ids(page) == Enum.map(1..3, &id/1)
    assert page.stats.roots == 1
  end

  test "SQL returns bounded previews, no params, and only a terminal window", context do
    oversized = String.duplicate("🙂λ", 20_000)

    seed(context.session.id, 1..400,
      title: oversized,
      agent_name: oversized,
      op_type: oversized,
      pid_str: oversized,
      result: oversized,
      error_message: oversized,
      params: %{"body" => oversized}
    )

    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(handler, [:iex_code, :repo, :query], &__MODULE__.capture_query/4, self())

    on_exit(fn -> :telemetry.detach(handler) end)

    {result, metrics} =
      LeanHarnessCollector.measure(fn -> Sessions.fetch_operation_page(context.session.id) end)

    :telemetry.detach(handler)
    assert {:ok, page} = result
    assert length(page.operations) == 50
    assert metrics.selected_rows <= 54

    for operation <- page.operations do
      assert %Operation{params: %{}} = operation

      for field <- [:title, :agent_name, :op_type, :pid_str, :result, :error_message] do
        preview = Map.fetch!(operation, field)
        assert String.valid?(preview)
        assert byte_size(preview) <= 2048
        assert String.starts_with?(oversized, preview)
      end
    end

    rows = captured_rows([])
    assert length(rows) >= 50
    assert Enum.all?(List.flatten(rows), &(not is_binary(&1) or byte_size(&1) <= 2048))
    assert Sessions.get_operation(context.session.id, id(400)).result == oversized
    assert Sessions.get_operation(context.session.id, id(400)).params == %{"body" => oversized}
  end

  test "scoped detail and invalid cursors never leak or mutate records", context do
    seed(context.session.id, 1..3)
    seed(context.other.id, 1_001..1_001, result: "foreign")
    before = Sessions.list_operations(context.session.id)

    for cursor <- [id(1_001), Ecto.UUID.generate(), "invalid", false] do
      assert {:error, :invalid_cursor} =
               Sessions.fetch_operation_page(context.session.id, before: cursor)
    end

    for opts <- [[limit: 0], [limit: 201], [before: id(1), after: id(2)], [unknown: 1], %{}] do
      assert {:error, :invalid_arguments} =
               Sessions.fetch_operation_page(context.session.id, opts)
    end

    assert Sessions.get_operation(context.session.id, id(1)) == hd(before)
    assert Sessions.get_operation(context.session.id, id(1_001)) == nil
    assert Sessions.get_operation(context.session.id, "invalid") == nil
    assert Sessions.get_operation("invalid", id(1)) == nil
    assert Sessions.get_operation(id(1)) == hd(before)
    assert Sessions.list_operations(context.session.id) == before
  end

  test "empty, active-only and exact terminal windows keep honest boundaries", context do
    assert {:ok, empty} = Sessions.fetch_operation_page(context.session.id)
    assert empty.operations == []
    assert empty.first_cursor == nil and empty.last_cursor == nil
    refute empty.has_older? or empty.has_newer?
    assert empty.stats.total == 0 and empty.stats.total_duration_ms == 0

    seed(context.session.id, 1..1, status: "pending")
    assert {:ok, active} = Sessions.fetch_operation_page(context.session.id)
    assert ids(active) == [id(1)]
    assert active.first_cursor == nil and active.last_cursor == nil
    refute active.has_older? or active.has_newer?

    seed(context.session.id, 2..51)
    assert {:ok, exact} = Sessions.fetch_operation_page(context.session.id)
    assert length(exact.operations) == 51
    refute exact.has_older? or exact.has_newer?
  end

  def capture_query(_event, _measurements, %{result: {:ok, %{rows: rows}}}, owner),
    do: send(owner, {:operation_rows, rows || []})

  def capture_query(_event, _measurements, _metadata, _owner), do: :ok

  defp captured_rows(acc) do
    receive do
      {:operation_rows, rows} -> captured_rows(rows ++ acc)
    after
      0 -> acc
    end
  end

  defp seed(session_id, range, opts \\ []) do
    Repo.insert_all(
      Operation,
      Enum.map(range, fn n ->
        Map.merge(
          %{
            id: id(n),
            session_id: session_id,
            agent_name: "worker",
            op_type: "read_file",
            title: "operation #{n}",
            status: "completed",
            progress: 100,
            duration_ms: 10,
            inserted_at: ~U[2026-01-01 00:00:00Z],
            updated_at: ~U[2026-01-01 00:00:00Z]
          },
          Map.new(opts)
        )
      end)
    )
  end

  defp id(n), do: "00000000-0000-0000-0000-#{String.pad_leading(Integer.to_string(n), 12, "0")}"
  defp ids(page), do: Enum.map(page.operations, & &1.id)

  defp walk_older(session_id, page, acc) do
    acc = ids(page) ++ acc

    if page.has_older? do
      {:ok, next} = Sessions.fetch_operation_page(session_id, before: page.first_cursor)
      walk_older(session_id, next, acc)
    else
      acc
    end
  end

  defp walk_newer(session_id, cursor, acc) do
    {:ok, page} = Sessions.fetch_operation_page(session_id, after: cursor)
    acc = acc ++ ids(page)
    if page.has_newer?, do: walk_newer(session_id, page.last_cursor, acc), else: acc
  end
end
