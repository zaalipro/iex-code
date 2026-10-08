defmodule IexCode.Swarm.PeerStreamHistoryTest do
  use ExUnit.Case, async: false

  alias IexCode.Swarm.PeerStream

  @table :iex_code_swarm_peer_stream_history

  setup do
    swarm_id = "paged-peers-#{Ecto.UUID.generate()}"
    other = "paged-peers-#{Ecto.UUID.generate()}"
    PeerStream.clear_history(swarm_id)

    on_exit(fn ->
      PeerStream.clear_history(swarm_id)
      PeerStream.clear_history(other)
    end)

    %{swarm_id: swarm_id, other: other}
  end

  test "latest and exclusive older/newer pages retain all existing-lifetime history", context do
    seed(context.swarm_id, 1..173)
    seed(context.other, 1_001..1_100)
    assert {:ok, latest} = PeerStream.fetch_history_page(context.swarm_id)
    assert ids(latest) == Enum.map(124..173, &id/1)
    assert latest.total == 173
    assert latest.has_older?
    refute latest.has_newer?
    assert walk_older(context.swarm_id, latest, []) == Enum.map(1..173, &id/1)
    assert walk_newer(context.swarm_id, id(1), [id(1)]) == Enum.map(1..173, &id/1)
    assert length(PeerStream.get_history(context.swarm_id)) == 173
    assert :ets.info(@table, :type) == :duplicate_bag
  end

  test "ordering uses the stored order before the message ID tie breaker", context do
    seed(context.swarm_id, 1..3, 30)
    seed(context.swarm_id, 4..6, 20)
    seed(context.swarm_id, 7..9, 10)
    assert {:ok, page} = PeerStream.fetch_history_page(context.swarm_id, limit: 4)
    assert ids(page) == Enum.map([6, 1, 2, 3], &id/1)
    assert walk_older(context.swarm_id, page, []) == Enum.map([7, 8, 9, 4, 5, 6, 1, 2, 3], &id/1)
  end

  test "duplicate storage events never duplicate page identities or hide neighbors", context do
    seed(context.swarm_id, 1..12)
    :ets.insert(@table, {context.swarm_id, 1, message(context.swarm_id, 3)})
    :ets.insert(@table, {context.swarm_id, 2, message(context.swarm_id, 3)})
    assert {:ok, latest} = PeerStream.fetch_history_page(context.swarm_id, limit: 4)
    assert ids(latest) == Enum.map(9..12, &id/1)
    assert walk_older(context.swarm_id, latest, []) == Enum.map(1..12, &id/1)
    assert latest.total == length(PeerStream.get_history(context.swarm_id))
    assert latest.total == 14
  end

  test "previews are UTF8 byte-bounded strings while scoped detail preserves full payload",
       context do
    body = String.duplicate("🙂λ\n", 20_000)
    message = %{message(context.swarm_id, 1) | payload: %{"body" => body}}
    :ets.insert(@table, {context.swarm_id, 1, message})
    assert {:ok, page} = PeerStream.fetch_history_page(context.swarm_id)
    assert [%{payload: preview}] = page.messages
    assert is_binary(preview)
    assert String.valid?(preview)
    assert byte_size(preview) <= 2048
    assert :binary.referenced_byte_size(preview) <= 2048
    assert String.starts_with?(Jason.encode!(message.payload), preview)
    assert PeerStream.get_message(context.swarm_id, message.id) == message
    assert PeerStream.get_message(context.other, message.id) == nil
    assert PeerStream.get_message(context.swarm_id, "missing") == nil
  end

  test "large lifetimes scan metadata in bounded chunks rather than loading the bag", context do
    seed(context.swarm_id, 1..2_001)
    supervisor = start_supervised!(Task.Supervisor)
    owner = self()

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        receive do
          :run ->
            result = PeerStream.fetch_history_page(context.swarm_id)
            send(owner, {:page_result, result})
            receive do: (:finish -> :ok)
        end
      end)

    traced = [{:ets, :lookup, 2}, {:ets, :select, 2}, {:ets, :select, 3}, {:ets, :select, 1}]
    for mfa <- traced, do: :erlang.trace_pattern(mfa, [{:_, [], [{:return_trace}]}], [:local])
    :erlang.trace(task.pid, true, [:call, {:tracer, self()}])

    on_exit(fn ->
      for mfa <- traced, do: :erlang.trace_pattern(mfa, false, [:local])
    end)

    send(task.pid, :run)
    assert_receive {:page_result, {:ok, page}}, 10_000
    ref = :erlang.trace_delivered(task.pid)
    assert_receive {:trace_delivered, _, ^ref}
    :erlang.trace(task.pid, false, [:call])
    send(task.pid, :finish)
    assert :ok = Task.await(task)

    calls = collect_traces(task.pid, [])
    assert length(page.messages) == 50 and page.total == 2_001
    assert Enum.any?(calls, &match?({:call, {:ets, :select, [_continuation]}}, &1))
    refute Enum.any?(calls, &match?({:call, {:ets, :lookup, [@table, _]}}, &1))
    refute Enum.any?(calls, &match?({:call, {:ets, :select, [@table, _]}}, &1))

    for {:return_from, {:ets, :select, _arity}, {rows, _continuation}} <- calls do
      assert length(rows) <= 64
      assert length(rows) == 1 or Enum.all?(rows, &match?({_, id} when is_binary(id), &1))
    end

    full_rows =
      for {:return_from, {:ets, :select, _arity}, {rows, _continuation}} <- calls,
          row <- rows,
          is_map(row),
          do: row

    assert length(full_rows) == 50
  end

  test "string-keyed records are paged without changing full detail", context do
    message =
      Map.new(message(context.swarm_id, 1), fn {key, value} -> {Atom.to_string(key), value} end)

    :ok = PeerStream.record_message(message)
    assert {:ok, page} = PeerStream.fetch_history_page(context.swarm_id)
    assert [%{id: "peer-000001", payload: "{\"n\":1}"}] = page.messages
    assert PeerStream.get_message(context.swarm_id, id(1)) == message
  end

  test "foreign and malformed cursors do not change stored peers or escape scope", context do
    seed(context.swarm_id, 1..3)
    seed(context.other, 1_001..1_001)
    before = PeerStream.get_history(context.swarm_id)

    for cursor <- [id(1_001), "missing", false] do
      assert {:error, :invalid_cursor} =
               PeerStream.fetch_history_page(context.swarm_id, before: cursor)
    end

    for opts <- [[limit: 0], [limit: 201], [before: id(1), after: id(2)], [unknown: 1], %{}] do
      assert {:error, :invalid_arguments} = PeerStream.fetch_history_page(context.swarm_id, opts)
    end

    assert PeerStream.get_history(context.swarm_id) == before
    assert {:ok, page} = PeerStream.fetch_history_page(context.other)
    assert ids(page) == [id(1_001)]
  end

  test "empty, exact and cleared lifetimes expose correct totals and boundaries", context do
    assert {:ok, empty} = PeerStream.fetch_history_page(context.swarm_id)
    assert empty.messages == [] and empty.total == 0
    assert empty.first_cursor == nil and empty.last_cursor == nil
    refute empty.has_older? or empty.has_newer?
    seed(context.swarm_id, 1..50)
    assert {:ok, exact} = PeerStream.fetch_history_page(context.swarm_id)
    assert length(exact.messages) == 50
    refute exact.has_older? or exact.has_newer?
    seed(context.swarm_id, 51..51, 2)

    assert {:ok, newer} =
             PeerStream.fetch_history_page(context.swarm_id, after: exact.last_cursor)

    assert ids(newer) == [id(51)]
    assert newer.total == 51
    :ok = PeerStream.clear_history(context.swarm_id)

    assert {:error, :invalid_cursor} =
             PeerStream.fetch_history_page(context.swarm_id, before: exact.first_cursor)

    assert PeerStream.get_message(context.swarm_id, id(1)) == nil
  end

  defp seed(swarm_id, range, order \\ 1) do
    for n <- range, do: :ets.insert(@table, {swarm_id, order, message(swarm_id, n)})
  end

  defp message(swarm_id, n) do
    %{
      id: id(n),
      swarm_id: swarm_id,
      from_agent: "worker",
      to_agent: "lead",
      role: :coder,
      type: :context_handoff,
      payload: %{"n" => n},
      timestamp: ~U[2026-01-01 00:00:00Z]
    }
  end

  defp id(n), do: "peer-#{String.pad_leading(Integer.to_string(n), 6, "0")}"
  defp ids(page), do: Enum.map(page.messages, & &1.id)

  defp collect_traces(pid, acc) do
    receive do
      {:trace, ^pid, :call, call} ->
        collect_traces(pid, [{:call, call} | acc])

      {:trace, ^pid, :return_from, mfa, result} ->
        collect_traces(pid, [{:return_from, mfa, result} | acc])
    after
      0 -> acc
    end
  end

  defp walk_older(swarm_id, page, acc) do
    acc = ids(page) ++ acc

    if page.has_older? do
      {:ok, next} = PeerStream.fetch_history_page(swarm_id, before: page.first_cursor, limit: 4)
      walk_older(swarm_id, next, acc)
    else
      acc
    end
  end

  defp walk_newer(swarm_id, cursor, acc) do
    {:ok, page} = PeerStream.fetch_history_page(swarm_id, after: cursor)
    acc = acc ++ ids(page)
    if page.has_newer?, do: walk_newer(swarm_id, page.last_cursor, acc), else: acc
  end
end
