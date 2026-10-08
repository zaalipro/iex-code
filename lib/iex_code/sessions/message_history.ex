defmodule IexCode.Sessions.MessageHistory do
  @moduledoc false
  import Ecto.Query

  alias IexCode.Repo
  alias IexCode.Runs.Run
  alias IexCode.Sessions.Message

  @maximum_window 200
  @default_window 50

  def recent(session_id, limit) when is_integer(limit) and limit in 1..@maximum_window do
    session_messages(session_id)
    |> order_by([m], desc: m.inserted_at, desc: m.id)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
  end

  def recent(_session_id, _limit),
    do: raise(ArgumentError, "message history limit must be an integer in 1..#{@maximum_window}")

  def get(session_id, message_id) do
    with {:ok, session_id} <- Ecto.UUID.cast(session_id),
         {:ok, message_id} <- Ecto.UUID.cast(message_id) do
      Repo.get_by(Message, session_id: session_id, id: message_id)
    else
      _ -> nil
    end
  end

  def run_final(%Run{} = run) do
    message =
      Repo.get_by(Message,
        session_id: run.session_id,
        idempotency_key: "run-final:#{run.id}",
        role: "assistant"
      )

    case message do
      %Message{metadata: metadata} when is_map(metadata) ->
        if metadata["run_id"] == run.id and metadata["kind"] == "coding_agent",
          do: message

      _ ->
        nil
    end
  end

  def page(session_id, opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         {:ok, session_id} <- Ecto.UUID.cast(session_id),
         limit = Keyword.get(opts, :limit, @default_window),
         true <- is_integer(limit) and limit in 1..@maximum_window,
         before = Keyword.get(opts, :before),
         after_cursor = Keyword.get(opts, :after),
         false <- not is_nil(before) and not is_nil(after_cursor),
         cursor_id = if(is_nil(before), do: after_cursor, else: before),
         {:ok, cursor} <- cursor(session_id, cursor_id) do
      direction = if is_nil(after_cursor), do: :older, else: :newer
      query = session_messages(session_id)
      window = if cursor, do: relative(query, cursor, direction), else: query

      messages =
        window
        |> ordered(direction)
        |> limit(^limit)
        |> Repo.all()
        |> chronological(direction)

      first = List.first(messages)
      last = List.last(messages)

      {:ok,
       %{
         messages: messages,
         first_cursor: first && first.id,
         last_cursor: last && last.id,
         has_older?: boundary_exists?(query, first || cursor, :older),
         has_newer?: boundary_exists?(query, last || cursor, :newer)
       }}
    else
      {:error, :invalid_cursor} = error -> error
      _ -> {:error, :invalid_arguments}
    end
  end

  def page(_session_id, _opts), do: {:error, :invalid_arguments}

  defp session_messages(session_id), do: from(m in Message, where: m.session_id == ^session_id)

  defp cursor(_session_id, nil), do: {:ok, nil}

  defp cursor(session_id, message_id) do
    with {:ok, message_id} <- Ecto.UUID.cast(message_id),
         %{} = cursor <-
           session_messages(session_id)
           |> where([m], m.id == ^message_id)
           |> select([m], %{id: m.id, inserted_at: m.inserted_at})
           |> Repo.one() do
      {:ok, cursor}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  # Tuple comparisons let SQLite seek the session/time/id index rather than
  # scanning from the beginning of a session to reach an older cursor.
  defp relative(query, cursor, :older) do
    where(
      query,
      [m],
      fragment(
        "(?, ?) < (?, ?)",
        m.inserted_at,
        m.id,
        type(^cursor.inserted_at, :utc_datetime),
        type(^cursor.id, :binary_id)
      )
    )
  end

  defp relative(query, cursor, :newer) do
    where(
      query,
      [m],
      fragment(
        "(?, ?) > (?, ?)",
        m.inserted_at,
        m.id,
        type(^cursor.inserted_at, :utc_datetime),
        type(^cursor.id, :binary_id)
      )
    )
  end

  defp ordered(query, :older), do: order_by(query, [m], desc: m.inserted_at, desc: m.id)
  defp ordered(query, :newer), do: order_by(query, [m], asc: m.inserted_at, asc: m.id)
  defp chronological(messages, :older), do: Enum.reverse(messages)
  defp chronological(messages, :newer), do: messages
  defp boundary_exists?(_query, nil, _direction), do: false

  defp boundary_exists?(query, cursor, direction),
    do: Repo.exists?(relative(query, cursor, direction))
end
