defmodule IexCodeWeb.WorkspaceHistory do
  @moduledoc false
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [stream: 4]

  alias IexCode.Sessions
  alias IexCode.Swarm.PeerStream

  @window 50

  def chat(socket, opts \\ []) do
    case Sessions.fetch_message_preview_page(
           socket.assigns.session.id,
           Keyword.put(opts, :limit, @window)
         ) do
      {:ok, page} ->
        rows =
          Enum.with_index(page.messages, fn row, index -> Map.put(row, :index, index + 1) end)

        socket
        |> assign(
          message_previews: rows,
          message_page: Map.delete(page, :messages),
          message_count: length(rows),
          message_detail: nil,
          expanded_message_id: nil,
          chat_latest?: opts == []
        )
        |> stream(:chat_messages, rows, reset: true)

      _ ->
        socket
    end
  end

  def operations(socket, opts \\ []) do
    case Sessions.fetch_operation_page(
           socket.assigns.session.id,
           Keyword.put(opts, :limit, @window)
         ) do
      {:ok, page} ->
        same_session? = socket.assigns[:operation_session_id] == socket.assigns.session.id

        if not same_session? and socket.assigns[:operation_reconcile_ref],
          do: Process.cancel_timer(socket.assigns.operation_reconcile_ref)

        socket
        |> assign(
          operations: page.operations,
          operation_page: Map.drop(page, [:operations, :stats]),
          operation_stats: page.stats,
          operation_detail: nil,
          operation_events: if(same_session?, do: socket.assigns.operation_events, else: []),
          operation_reconcile_ref: if(same_session?, do: socket.assigns.operation_reconcile_ref),
          operation_reconcile_token:
            if(same_session?, do: socket.assigns.operation_reconcile_token),
          operation_session_id: socket.assigns.session.id,
          expanded_ops: active_ancestors(page.operations),
          operation_opts: opts,
          operation_latest?: opts == []
        )
        |> reconcile_events()
        |> schedule_reconciliation(40)

      _ ->
        socket
    end
  end

  def clear_operations(socket) do
    socket |> assign(operation_session_id: nil) |> operations()
  end

  def peers(socket, opts \\ []) do
    case PeerStream.fetch_history_page(
           socket.assigns.session.id,
           Keyword.put(opts, :limit, @window)
         ) do
      {:ok, page} ->
        assign(socket,
          peer_messages: page.messages,
          peer_page: Map.delete(page, :messages),
          peer_detail: nil,
          peer_latest?: opts == []
        )

      _ ->
        socket
    end
  end

  def navigate(socket, kind, params) do
    page = socket.assigns[page_key(kind)]
    direction = params["direction"]
    cursor = params["cursor"]

    opts =
      case direction do
        "older" -> [before: cursor || page.first_cursor]
        "newer" -> [after: cursor || page.last_cursor]
        "latest" -> []
        _ -> :invalid
      end

    cond do
      opts == :invalid -> socket
      direction != "latest" and is_nil(Keyword.values(opts) |> List.first()) -> socket
      kind == :chat -> chat(socket, opts)
      kind == :operations -> operations(socket, opts)
      kind == :peers -> peers(socket, opts)
    end
  end

  def refresh_operations(socket) do
    socket
    |> operations_preserving_detail(socket.assigns.operation_opts)
    |> reconcile_events()
  end

  # At most 50 lightweight notifications bridge detached persistence. Durable
  # rows win terminal status; this overlay is never a history store.
  def operation_event(socket, event) do
    old_events = socket.assigns.operation_events
    old = Enum.find(socket.assigns.operations, &(&1.id == event.id))

    event =
      if old && old.status in ["completed", "failed"] && event.status in ["pending", "running"],
        do: old,
        else: event

    event = project_operation(event)
    events = [event | Enum.reject(old_events, &(&1.id == event.id))] |> Enum.take(@window)

    socket
    |> assign(operation_events: events)
    |> refresh_operations()
    |> schedule_reconciliation(40)
  end

  def reconcile_tick(socket, session_id, token, attempts) do
    if socket.assigns.session.id == session_id and
         socket.assigns.operation_reconcile_token == token do
      if socket.assigns.operation_reconcile_ref,
        do: Process.cancel_timer(socket.assigns.operation_reconcile_ref)

      socket
      |> assign(operation_reconcile_ref: nil)
      |> refresh_operations()
      |> schedule_reconciliation(attempts - 1)
    else
      socket
    end
  end

  defp reconcile_events(socket) do
    statuses =
      Sessions.operation_statuses(
        socket.assigns.session.id,
        Enum.map(socket.assigns.operation_events, & &1.id)
      )

    events =
      Enum.reject(socket.assigns.operation_events, fn event ->
        status = statuses[event.id]
        status in ["completed", "failed"] or (status && event.status in ["pending", "running"])
      end)

    # A detached write may commit between the projection and acknowledgement
    # queries. Reload after any terminal acknowledgement before retiring it.
    socket =
      if Enum.any?(statuses, fn {_id, status} -> status in ["completed", "failed"] end),
        do: operations_preserving_detail(socket, socket.assigns.operation_opts),
        else: socket

    rows =
      Enum.reduce(events, socket.assigns.operations, fn event, rows ->
        case Enum.find(rows, &(&1.id == event.id)) do
          %{status: status} when status in ["completed", "failed"] ->
            rows

          nil
          when not socket.assigns.operation_latest? and event.status in ["completed", "failed"] ->
            rows

          _ ->
            [event | Enum.reject(rows, &(&1.id == event.id))]
        end
      end)

    ancestors = active_ancestors(rows)

    {exceptions, terminal} =
      Enum.split_with(
        rows,
        &(&1.status in ["pending", "running"] or MapSet.member?(ancestors, &1.id))
      )

    terminal = terminal |> Enum.sort_by(&operation_order/1, :desc) |> Enum.take(@window)
    rows = Enum.sort_by(exceptions ++ terminal, &operation_order/1)

    assign(socket,
      operation_events: events,
      operations: rows,
      expanded_ops: MapSet.union(socket.assigns.expanded_ops, ancestors)
    )
  end

  defp schedule_reconciliation(socket, attempts) do
    outstanding? =
      Enum.any?(socket.assigns.operation_events, &(&1.status in ["completed", "failed"]))

    if outstanding? and attempts > 0 and is_nil(socket.assigns.operation_reconcile_ref) do
      token = make_ref()

      ref =
        Process.send_after(
          self(),
          {:reconcile_operation_history, socket.assigns.session.id, token, attempts},
          250
        )

      assign(socket, operation_reconcile_ref: ref, operation_reconcile_token: token)
    else
      socket
    end
  end

  def preview(nil), do: nil

  def preview(text) when is_binary(text) do
    prefix = binary_part(text, 0, min(byte_size(text), 2048))

    case :unicode.characters_to_binary(prefix, :utf8, :utf8) do
      valid when is_binary(valid) -> :binary.copy(valid)
      {_kind, valid, _rest} -> :binary.copy(valid)
    end
  end

  defp project_operation(op) do
    Enum.reduce(~w(agent_name op_type title pid_str result error_message)a, op, fn field, row ->
      Map.update(row, field, nil, &preview/1)
    end)
    |> Map.put(:params, %{})
  end

  defp operation_order(op) do
    timestamp = if op.inserted_at, do: DateTime.to_unix(op.inserted_at, :microsecond), else: 0
    {timestamp, op.id}
  end

  defp active_ancestors(rows) do
    rows
    |> Enum.filter(&(&1.status in ["pending", "running"]))
    |> Enum.reduce(MapSet.new(), fn row, expanded -> expand_ancestors(row, rows, expanded) end)
  end

  defp expand_ancestors(%{parent_op_id: nil}, _rows, expanded), do: expanded

  defp expand_ancestors(row, rows, expanded) do
    if MapSet.member?(expanded, row.parent_op_id) do
      expanded
    else
      case Enum.find(rows, &(&1.id == row.parent_op_id)) do
        nil -> expanded
        parent -> expand_ancestors(parent, rows, MapSet.put(expanded, parent.id))
      end
    end
  end

  defp operations_preserving_detail(socket, opts) do
    detail = socket.assigns.operation_detail
    expanded = socket.assigns.expanded_ops
    events = socket.assigns.operation_events

    {:ok, page} =
      Sessions.fetch_operation_page(socket.assigns.session.id, Keyword.put(opts, :limit, @window))

    socket =
      assign(socket,
        operations: page.operations,
        operation_page: Map.drop(page, [:operations, :stats]),
        operation_stats: page.stats
      )

    visible_ids = MapSet.new(socket.assigns.operations, & &1.id)

    expanded =
      expanded
      |> MapSet.intersection(visible_ids)
      |> MapSet.union(active_ancestors(socket.assigns.operations))

    detail = if detail && MapSet.member?(visible_ids, detail.id), do: detail
    assign(socket, operation_detail: detail, expanded_ops: expanded, operation_events: events)
  end

  defp page_key(:chat), do: :message_page
  defp page_key(:operations), do: :operation_page
  defp page_key(:peers), do: :peer_page
end
