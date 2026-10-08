defmodule IexCode.Sessions.OperationHistory do
  @moduledoc false
  import Ecto.Query

  alias IexCode.Repo
  alias IexCode.Sessions.Operation

  @default_window 50
  @maximum_window 200
  @preview_fields ~w(agent_name op_type title pid_str result error_message)a

  def statuses(session_id, ids) do
    ids = Enum.filter(ids, &match?({:ok, _}, Ecto.UUID.cast(&1)))

    session_operations(session_id)
    |> where([o], o.id in ^ids)
    |> select([o], {o.id, o.status})
    |> Repo.all()
    |> Map.new()
  end

  def get(session_id, operation_id) do
    with {:ok, session_id} <- Ecto.UUID.cast(session_id),
         {:ok, operation_id} <- Ecto.UUID.cast(operation_id) do
      Repo.get_by(Operation, session_id: session_id, id: operation_id)
    else
      _ -> nil
    end
  end

  def page(session_id, opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         true <- Enum.all?(Keyword.keys(opts), &(&1 in [:limit, :before, :after])),
         true <- length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))),
         {:ok, session_id} <- Ecto.UUID.cast(session_id),
         limit = Keyword.get(opts, :limit, @default_window),
         true <- is_integer(limit) and limit in 1..@maximum_window,
         before = Keyword.get(opts, :before),
         after_cursor = Keyword.get(opts, :after),
         false <- not is_nil(before) and not is_nil(after_cursor),
         cursor_id = if(is_nil(before), do: after_cursor, else: before),
         {:ok, cursor} <- cursor(session_id, cursor_id) do
      direction = if is_nil(after_cursor), do: :older, else: :newer

      query =
        from(o in session_operations(session_id), where: o.status in ["completed", "failed"])

      window = if cursor, do: relative(query, cursor, direction), else: query

      terminal =
        window
        |> ordered(direction)
        |> limit(^limit)
        |> previews()
        |> chronological(direction)

      first = List.first(terminal)
      last = List.last(terminal)

      operations =
        (terminal ++ active_tree(session_id))
        |> Enum.uniq_by(& &1.id)
        |> Enum.sort_by(&{DateTime.to_unix(&1.inserted_at), &1.id})

      {:ok,
       %{
         operations: operations,
         first_cursor: first && first.id,
         last_cursor: last && last.id,
         has_older?: boundary_exists?(query, first || cursor, :older),
         has_newer?: boundary_exists?(query, last || cursor, :newer),
         stats: stats(session_id)
       }}
    else
      {:error, :invalid_cursor} = error -> error
      _ -> {:error, :invalid_arguments}
    end
  end

  def page(_session_id, _opts), do: {:error, :invalid_arguments}

  defp session_operations(session_id),
    do: from(o in Operation, where: o.session_id == ^session_id)

  # Fetch only the active forest, never ancestor chains of ordinary terminal
  # seeds. The visited set also terminates malformed cycles/missing parents.
  defp active_tree(session_id) do
    active =
      session_operations(session_id)
      |> where([o], o.status in ["pending", "running"])
      |> previews()

    ancestors(session_id, active, active, MapSet.new(active, & &1.id))
  end

  defp ancestors(session_id, frontier, rows, visited) do
    parents =
      frontier
      |> Enum.map(& &1.parent_op_id)
      |> Enum.reject(&(is_nil(&1) or MapSet.member?(visited, &1)))
      |> Enum.uniq()

    case parents do
      [] ->
        rows

      _ ->
        ancestors =
          session_operations(session_id)
          |> where([o], o.id in ^parents)
          |> previews()

        ancestors(
          session_id,
          ancestors,
          ancestors ++ rows,
          Enum.reduce(parents, visited, &MapSet.put(&2, &1))
        )
    end
  end

  # SQLite substr(TEXT) counts characters, not bytes. Slice a BLOB so even an
  # enormous multibyte value crosses the adapter boundary as at most 2048 bytes.
  # Repair only the possible final partial UTF-8 character after that SQL bound.
  defp previews(query) do
    query
    |> select([o], %Operation{
      id: o.id,
      session_id: o.session_id,
      parent_op_id: o.parent_op_id,
      agent_name: fragment("substr(CAST(? AS BLOB), 1, 2048)", o.agent_name),
      op_type: fragment("substr(CAST(? AS BLOB), 1, 2048)", o.op_type),
      title: fragment("substr(CAST(? AS BLOB), 1, 2048)", o.title),
      status: o.status,
      progress: o.progress,
      pid_str: fragment("substr(CAST(? AS BLOB), 1, 2048)", o.pid_str),
      params: %{},
      result: fragment("substr(CAST(? AS BLOB), 1, 2048)", o.result),
      error_message: fragment("substr(CAST(? AS BLOB), 1, 2048)", o.error_message),
      started_at: o.started_at,
      completed_at: o.completed_at,
      duration_ms: o.duration_ms,
      inserted_at: o.inserted_at,
      updated_at: o.updated_at
    })
    |> Repo.all()
    |> Enum.map(fn operation ->
      Enum.reduce(@preview_fields, operation, fn field, row ->
        Map.update!(row, field, &valid_utf8/1)
      end)
    end)
  end

  defp valid_utf8(nil), do: nil

  defp valid_utf8(binary) do
    case :unicode.characters_to_binary(binary, :utf8, :utf8) do
      valid when is_binary(valid) -> valid
      {_kind, valid, _rest} -> valid
    end
  end

  defp stats(session_id) do
    totals =
      session_operations(session_id)
      |> join(:left, [o], parent in Operation,
        on: parent.id == o.parent_op_id and parent.session_id == o.session_id
      )
      |> select([o, parent], %{
        total: count(o.id),
        roots: coalesce(sum(fragment("CASE WHEN ? IS NULL THEN 1 ELSE 0 END", parent.id)), 0),
        running:
          coalesce(sum(fragment("CASE WHEN ? = 'running' THEN 1 ELSE 0 END", o.status)), 0),
        pending:
          coalesce(sum(fragment("CASE WHEN ? = 'pending' THEN 1 ELSE 0 END", o.status)), 0),
        completed:
          coalesce(sum(fragment("CASE WHEN ? = 'completed' THEN 1 ELSE 0 END", o.status)), 0),
        failed: coalesce(sum(fragment("CASE WHEN ? = 'failed' THEN 1 ELSE 0 END", o.status)), 0),
        total_duration_ms: coalesce(sum(o.duration_ms), 0)
      })
      |> Repo.one()

    if totals.total > 0 and totals.roots == 0, do: %{totals | roots: 1}, else: totals
  end

  defp cursor(_session_id, nil), do: {:ok, nil}

  defp cursor(session_id, operation_id) do
    with {:ok, operation_id} <- Ecto.UUID.cast(operation_id),
         %{} = cursor <-
           session_operations(session_id)
           |> where([o], o.id == ^operation_id)
           |> select([o], %{id: o.id, inserted_at: o.inserted_at})
           |> Repo.one() do
      {:ok, cursor}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp relative(query, cursor, :older) do
    where(
      query,
      [o],
      fragment(
        "(?, ?) < (?, ?)",
        o.inserted_at,
        o.id,
        type(^cursor.inserted_at, :utc_datetime),
        type(^cursor.id, :binary_id)
      )
    )
  end

  defp relative(query, cursor, :newer) do
    where(
      query,
      [o],
      fragment(
        "(?, ?) > (?, ?)",
        o.inserted_at,
        o.id,
        type(^cursor.inserted_at, :utc_datetime),
        type(^cursor.id, :binary_id)
      )
    )
  end

  defp ordered(query, :older), do: order_by(query, [o], desc: o.inserted_at, desc: o.id)
  defp ordered(query, :newer), do: order_by(query, [o], asc: o.inserted_at, asc: o.id)
  defp chronological(rows, :older), do: Enum.reverse(rows)
  defp chronological(rows, :newer), do: rows
  defp boundary_exists?(_query, nil, _direction), do: false

  defp boundary_exists?(query, cursor, direction),
    do: Repo.exists?(relative(query, cursor, direction))
end
