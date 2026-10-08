defmodule IexCode.Swarm.PeerStream do
  @moduledoc """
  Live Peer Message Stream and Dynamic Swarm Telemetry Hub.
  Facilitates real-time inter-agent messaging over Phoenix.PubSub,
  chronological message history accumulation, and filtering by role/agent.
  """

  use GenServer
  require Logger

  @pubsub IexCode.PubSub
  @table :iex_code_swarm_peer_stream_history
  @telemetry_topic "swarm:telemetry"
  @history_select_chunk 64
  @history_default_window 50
  @history_maximum_window 200
  @history_preview_bytes 2048

  # ============================================================================
  # CLIENT API
  # ============================================================================

  @doc """
  Starts the PeerStream history server.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Subscribes the caller process to the swarm's peer message topic.
  """
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(swarm_id) when is_binary(swarm_id) do
    Phoenix.PubSub.subscribe(@pubsub, topic(swarm_id))
  end

  def subscribe(swarm_id), do: subscribe(to_string(swarm_id))

  @doc """
  Subscribes the caller process to the global swarm telemetry topic.
  """
  @spec subscribe_telemetry() :: :ok | {:error, term()}
  def subscribe_telemetry do
    Phoenix.PubSub.subscribe(@pubsub, @telemetry_topic)
  end

  @doc """
  Unsubscribes the caller process from the swarm's peer message topic.
  """
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(swarm_id) when is_binary(swarm_id) do
    Phoenix.PubSub.unsubscribe(@pubsub, topic(swarm_id))
  end

  def unsubscribe(swarm_id), do: unsubscribe(to_string(swarm_id))

  @doc """
  Unsubscribes the caller process from the global swarm telemetry topic.
  """
  @spec unsubscribe_telemetry() :: :ok
  def unsubscribe_telemetry do
    Phoenix.PubSub.unsubscribe(@pubsub, @telemetry_topic)
  end

  @doc """
  Topic name helper.
  """
  @spec topic(String.t()) :: String.t()
  def topic(swarm_id), do: "swarm:#{swarm_id}"

  @doc """
  Broadcasts a structured peer message across Phoenix.PubSub and records it to history.
  """
  @spec broadcast_peer_message(
          String.t(),
          String.t(),
          String.t(),
          atom() | String.t(),
          atom() | String.t(),
          map()
        ) :: {:ok, map()}
  def broadcast_peer_message(swarm_id, from_agent, to_agent, role, type, payload) do
    msg = %{
      id: generate_uuid(),
      swarm_id: to_string(swarm_id),
      from_agent: to_string(from_agent),
      to_agent: to_string(to_agent),
      role: normalize_atom(role),
      type: normalize_atom(type),
      payload: payload || %{},
      timestamp: DateTime.utc_now()
    }

    # Record message to history table
    record_message(msg)

    # Broadcast to swarm-specific channel
    Phoenix.PubSub.broadcast(@pubsub, topic(swarm_id), {:swarm_peer_message, msg})

    # Broadcast to global telemetry channel
    Phoenix.PubSub.broadcast(@pubsub, @telemetry_topic, {:swarm_peer_message, msg})

    {:ok, msg}
  end

  @doc """
  Broadcasts real-time swarm telemetry data.
  """
  @spec broadcast_telemetry(String.t(), map()) :: {:ok, map()}
  def broadcast_telemetry(swarm_id, telemetry_data) when is_map(telemetry_data) do
    s_id = to_string(swarm_id)

    payload = %{
      swarm_id: s_id,
      active_roles:
        Map.get(telemetry_data, :active_roles) || Map.get(telemetry_data, "active_roles") || [],
      consensus_score:
        Map.get(telemetry_data, :consensus_score) || Map.get(telemetry_data, "consensus_score") ||
          0.0,
      concordance:
        Map.get(telemetry_data, :concordance) || Map.get(telemetry_data, "concordance") || 1.0,
      message_count:
        Map.get(telemetry_data, :message_count) || Map.get(telemetry_data, "message_count") || 0,
      active_turn:
        Map.get(telemetry_data, :active_turn) || Map.get(telemetry_data, "active_turn") || 1,
      token_usage:
        Map.get(telemetry_data, :token_usage) ||
          Map.get(telemetry_data, "token_usage") ||
          %{input_tokens: 0, output_tokens: 0, total_tokens: 0},
      stage:
        normalize_atom(
          Map.get(telemetry_data, :stage) || Map.get(telemetry_data, "stage") || :coding
        ),
      timestamp: DateTime.utc_now()
    }

    Phoenix.PubSub.broadcast(@pubsub, topic(s_id), {:swarm_telemetry, payload})
    Phoenix.PubSub.broadcast(@pubsub, @telemetry_topic, {:swarm_telemetry, payload})

    {:ok, payload}
  end

  @doc """
  Records a peer message in the history storage.
  """
  @spec record_message(map()) :: :ok
  def record_message(message) when is_map(message) do
    ensure_table_exists()
    s_id = to_string(message[:swarm_id] || message["swarm_id"] || "default")
    order_key = System.monotonic_time(:microsecond)
    :ets.insert(@table, {s_id, order_key, message})
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Retrieves chronological peer message history for a swarm (earliest first).
  """
  @spec get_history(String.t()) :: [map()]
  def get_history(swarm_id) do
    ensure_table_exists()
    s_id = to_string(swarm_id)

    case :ets.lookup(@table, s_id) do
      records when is_list(records) ->
        records
        |> Enum.sort_by(fn {_swarm_id, order_key, _msg} -> order_key end)
        |> Enum.map(fn {_swarm_id, _order_key, msg} -> msg end)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  @doc """
  Returns a chronological bounded peer window from the existing ETS lifetime.

  Options are `:limit` (default 50, maximum 200), and either `:before` or `:after`
  (an exclusive message ID in this swarm). Without a cursor returns latest.
  Result: `{:ok, %{messages: rows, first_cursor: id, last_cursor: id,
  has_older?: boolean, has_newer?: boolean, total: integer}}`.

  Payloads are encoded UTF-8 preview strings of at most 2048 bytes. Detail is
  available through `get_message/2`. Duplicate IDs use their earliest retained
  `{order, id}` position; `total` counts retained records, including duplicates,
  just like `length(get_history(swarm_id))`. No records are changed or persisted.
  Foreign/missing/malformed cursors return `{:error, :invalid_cursor}`; invalid
  options return `{:error, :invalid_arguments}`.
  """
  def fetch_history_page(swarm_id, opts \\ [])

  def fetch_history_page(swarm_id, opts) when is_binary(swarm_id) and is_list(opts) do
    with true <- swarm_id != "" and Keyword.keyword?(opts),
         true <- Enum.all?(Keyword.keys(opts), &(&1 in [:limit, :before, :after])),
         true <- length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))),
         limit = Keyword.get(opts, :limit, @history_default_window),
         true <- is_integer(limit) and limit in 1..@history_maximum_window,
         before = Keyword.get(opts, :before),
         after_cursor = Keyword.get(opts, :after),
         false <- not is_nil(before) and not is_nil(after_cursor) do
      ensure_table_exists()
      cursor_id = if is_nil(before), do: after_cursor, else: before

      with {:ok, cursor} <- history_cursor(swarm_id, cursor_id) do
        direction = if is_nil(after_cursor), do: :older, else: :newer
        candidates = history_candidates(swarm_id, cursor, direction, limit)

        # Only the selected rows cross ETS with a payload, one at a time, and
        # each is immediately reduced to a preview. Scans retain metadata only.
        rows =
          Enum.flat_map(candidates, fn key ->
            case history_message(swarm_id, key) do
              nil -> []
              message -> [{key, history_preview(message)}]
            end
          end)

        first = List.first(rows)
        last = List.last(rows)
        first_key = if first, do: elem(first, 0), else: cursor
        last_key = if last, do: elem(last, 0), else: cursor

        {:ok,
         %{
           messages: Enum.map(rows, &elem(&1, 1)),
           first_cursor: first && elem(first_key, 1),
           last_cursor: last && elem(last_key, 1),
           has_older?: history_boundary?(swarm_id, first_key, :older),
           has_newer?: history_boundary?(swarm_id, last_key, :newer),
           total: :ets.select_count(@table, [{{swarm_id, :_, :_}, [], [true]}])
         }}
      end
    else
      _ -> {:error, :invalid_arguments}
    end
  end

  def fetch_history_page(_swarm_id, _opts), do: {:error, :invalid_arguments}

  @doc "Returns one full peer message in this swarm's existing lifetime, or nil."
  def get_message(swarm_id, message_id) when is_binary(swarm_id) and is_binary(message_id) do
    ensure_table_exists()

    case history_cursor(swarm_id, message_id) do
      {:ok, cursor} -> history_message(swarm_id, cursor)
      _ -> nil
    end
  end

  def get_message(_swarm_id, _message_id), do: nil

  defp history_cursor(_swarm_id, nil), do: {:ok, nil}

  defp history_cursor(swarm_id, message_id) when is_binary(message_id) and message_id != "" do
    match_spec = history_metadata_spec(swarm_id, [{:==, :"$2", {:const, message_id}}])

    case history_reduce(match_spec, nil, fn key, earliest ->
           if is_nil(earliest) or key < earliest, do: key, else: earliest
         end) do
      nil -> {:error, :invalid_cursor}
      key -> {:ok, key}
    end
  end

  defp history_cursor(_swarm_id, _message_id), do: {:error, :invalid_cursor}

  defp history_candidates(swarm_id, cursor, direction, limit) do
    swarm_id
    |> history_metadata_spec([])
    |> history_reduce([], fn key, retained ->
      eligible? =
        (is_nil(cursor) or history_relative?(key, cursor, direction)) and
          key not in retained and
          (length(retained) < limit or
             history_relative?(key, List.last(retained), opposite(direction)))

      if eligible? and history_canonical?(swarm_id, key) do
        [key | retained]
        |> Enum.sort(if(direction == :older, do: :desc, else: :asc))
        |> Enum.take(limit)
      else
        retained
      end
    end)
    |> Enum.sort()
  end

  # An unordered duplicate_bag has no secondary ID index. Check only competitive
  # candidates for earlier duplicates, using a one-result metadata-only select,
  # rather than retaining an ever-growing "seen IDs" set or changing the table.
  defp history_canonical?(swarm_id, {order, id}) do
    spec =
      history_metadata_spec(swarm_id, [
        {:==, :"$2", {:const, id}},
        {:<, :"$1", {:const, order}}
      ])

    :ets.select(@table, spec, 1) == :"$end_of_table"
  end

  defp history_boundary?(_swarm_id, nil, _direction), do: false

  defp history_boundary?(swarm_id, key, direction),
    do: history_candidates(swarm_id, key, direction, 1) != []

  defp history_relative?(key, cursor, :older), do: key < cursor
  defp history_relative?(key, cursor, :newer), do: key > cursor
  defp opposite(:older), do: :newer
  defp opposite(:newer), do: :older

  defp history_metadata_spec(swarm_id, guards) do
    [
      {{swarm_id, :"$1", %{id: :"$2"}}, [{:is_binary, :"$2"} | guards], [{{:"$1", :"$2"}}]},
      {{swarm_id, :"$1", %{"id" => :"$2"}}, [{:is_binary, :"$2"} | guards], [{{:"$1", :"$2"}}]}
    ]
  end

  defp history_reduce(spec, acc, fun) do
    history_continue(:ets.select(@table, spec, @history_select_chunk), acc, fun)
  end

  defp history_continue(:"$end_of_table", acc, _fun), do: acc

  defp history_continue({rows, continuation}, acc, fun) do
    acc = Enum.reduce(rows, acc, fun)
    history_continue(:ets.select(continuation), acc, fun)
  end

  defp history_message(swarm_id, {order, id}) do
    spec = [
      {{swarm_id, order, :"$1"},
       [
         {:==, {:map_get, :id, :"$1"}, {:const, id}}
       ], [:"$1"]},
      {{swarm_id, order, :"$1"},
       [
         {:==, {:map_get, "id", :"$1"}, {:const, id}}
       ], [:"$1"]}
    ]

    case :ets.select(@table, spec, 1) do
      {[message], _continuation} -> message
      :"$end_of_table" -> nil
    end
  end

  defp history_preview(message) do
    Map.new(
      [:id, :swarm_id, :from_agent, :to_agent, :role, :type, :payload, :timestamp],
      fn key ->
        value = Map.get(message, key) || Map.get(message, Atom.to_string(key))

        preview =
          cond do
            key == :payload -> value |> Jason.encode!() |> history_text_preview()
            is_binary(value) -> history_text_preview(value)
            true -> value
          end

        {key, preview}
      end
    )
  end

  defp history_text_preview(binary) do
    prefix = binary_part(binary, 0, min(byte_size(binary), @history_preview_bytes))

    case :unicode.characters_to_binary(prefix, :utf8, :utf8) do
      valid when is_binary(valid) -> :binary.copy(valid)
      {_kind, valid, _rest} -> :binary.copy(valid)
    end
  end

  @doc """
  Clears message history for a given swarm.
  """
  @spec clear_history(String.t()) :: :ok
  def clear_history(swarm_id) do
    ensure_table_exists()
    s_id = to_string(swarm_id)
    :ets.delete(@table, s_id)
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Filters a list of peer messages by role.
  """
  @spec filter_by_role([map()], atom() | String.t()) :: [map()]
  def filter_by_role(messages, role) when is_list(messages) do
    target_role = normalize_atom(role)

    Enum.filter(messages, fn msg ->
      r = normalize_atom(msg[:role] || msg["role"])
      r == target_role
    end)
  end

  @doc """
  Filters a list of peer messages by agent identifier (matches from_agent or to_agent).
  """
  @spec filter_by_agent([map()], String.t()) :: [map()]
  def filter_by_agent(messages, agent_id) when is_list(messages) do
    target_agent = to_string(agent_id)

    Enum.filter(messages, fn msg ->
      from_a = to_string(msg[:from_agent] || msg["from_agent"])
      to_a = to_string(msg[:to_agent] || msg["to_agent"])
      from_a == target_agent or to_a == target_agent
    end)
  end

  # ============================================================================
  # GENSERVER CALLBACKS
  # ============================================================================

  @impl true
  def init(_opts) do
    ensure_table_exists()
    {:ok, %{}}
  end

  defp ensure_table_exists do
    if :ets.info(@table) == :undefined do
      try do
        :ets.new(@table, [
          :duplicate_bag,
          :public,
          :named_table,
          read_concurrency: true,
          write_concurrency: true
        ])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  defp generate_uuid do
    "peer-" <> (:crypto.strong_rand_bytes(10) |> Base.encode16(case: :lower))
  end

  defp normalize_atom(val) when is_atom(val), do: val

  defp normalize_atom(val) when is_binary(val) do
    try do
      String.to_existing_atom(val)
    rescue
      ArgumentError -> :general
    end
  end

  defp normalize_atom(_), do: :general
end
