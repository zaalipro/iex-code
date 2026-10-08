defmodule IexCodeWeb.WorkspaceHistoryTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true

  alias IexCode.{Repo, Sessions}
  alias IexCode.Swarm.PeerStream

  test "role cards follow current work rather than the oldest projected operation", ctx do
    {session, _} = history(ctx.workspace_path, 0)
    now = ~U[2026-01-01 00:00:00Z]

    for {id, status, result, progress} <- [
          {"33333333-3333-4333-8333-000000000001", "completed", "older finished work", 100},
          {"33333333-3333-4333-8333-000000000002", "running", "new active work", 25}
        ] do
      Repo.insert!(%IexCode.Sessions.Operation{
        id: id,
        session_id: session.id,
        agent_name: "CoderAgent",
        op_type: "read_file",
        title: result,
        result: result,
        status: status,
        progress: progress,
        inserted_at: now,
        updated_at: now
      })
    end

    {:ok, view, _} = live(ctx.conn, ~p"/sessions/#{session.id}?tab=swarm")
    assert has_element?(view, "#subagent-card-coder", "new active work")
    assert has_element?(view, "#subagent-card-coder", "RUNNING")
    assert has_element?(view, "#subagent-card-coder", "25%")
    op = Sessions.get_operation(session.id, "33333333-3333-4333-8333-000000000002")

    {:ok, done} =
      Sessions.update_operation(op, %{
        status: "completed",
        progress: 100,
        result: "new settled work"
      })

    send(view.pid, {:operation_completed, done})
    assert has_element?(view, "#subagent-card-coder", "new settled work")
    assert has_element?(view, "#subagent-card-coder", "COMPLETED")
  end

  test "visible sidebar navigation rehydrates a consumed chat stream", ctx do
    {session, messages} = history(ctx.workspace_path, 61)
    {:ok, view, _} = live(ctx.conn, ~p"/sessions/#{session.id}")
    view |> element("#sidebar-tab-chat") |> render_click()
    assert ids(view) == Enum.map(Enum.take(messages, -50), & &1.id)
    view |> element("#sidebar-tab-kanban") |> render_click()
    view |> element("#sidebar-tab-chat") |> render_click()
    assert length(ids(view)) == 50
  end

  test "parameter and palette chat navigation rehydrates the bounded stream", ctx do
    {session, _} = history(ctx.workspace_path, 61)
    {:ok, view, _} = live(ctx.conn, ~p"/sessions/#{session.id}")
    render_patch(view, ~p"/sessions/#{session.id}?tab=chat")
    assert length(ids(view)) == 50
    view |> element("#sidebar-tab-kanban") |> render_click()
    render_click(view, "toggle_command_palette")
    render_change(view, "command_palette_search", %{"query" => "Chat Assistant"})
    view |> element("#palette-item-0") |> render_click()
    assert length(ids(view)) == 50
  end

  test "durable progress wins stale starts and detached terminal reconciliation settles totals",
       ctx do
    {session, _} = history(ctx.workspace_path, 0)

    {:ok, op} =
      Sessions.create_operation(%{
        session_id: session.id,
        agent_name: "CoderAgent",
        op_type: "read_file",
        title: "running",
        status: "running",
        progress: 0
      })

    {:ok, view, _} = live(ctx.conn, ~p"/sessions/#{session.id}")
    send(view.pid, {:operation_started, op})
    render(view)
    {:ok, _} = Sessions.update_operation(op, %{progress: 80, result: "latest progress"})
    send(view.pid, {:operation_progress, op.id, 80, "latest progress"})
    send(view.pid, {:operation_created, %{op | id: Ecto.UUID.generate()}})
    render(view)
    state = :sys.get_state(view.pid).socket.assigns
    projected = Enum.find(state.operations, &(&1.id == op.id))
    assert projected.progress == 80
    assert projected.result == "latest progress"
    send(view.pid, {:operation_completed, %{op | status: "completed", result: "terminal"}})
    send(view.pid, {:session_status_changed, "idle"})
    render(view)
    state = :sys.get_state(view.pid).socket.assigns
    assert Enum.find(state.operations, &(&1.id == op.id)).status == "completed"
    render_click(view, "operation_history", %{"direction" => "latest"})
    state = :sys.get_state(view.pid).socket.assigns
    assert Enum.any?(state.operation_events, &(&1.id == op.id))
    assert state.operation_reconcile_ref != nil
    ref = state.operation_reconcile_ref

    render_click(view, "operation_history", %{
      "direction" => "older",
      "cursor" => Ecto.UUID.generate()
    })

    assert :sys.get_state(view.pid).socket.assigns.operation_reconcile_ref == ref
    {:ok, _} = Sessions.update_operation(op, %{status: "completed", result: "terminal"})
    send(view.pid, {:reconcile_operation_history, session.id, state.operation_reconcile_token, 1})
    render(view)
    assert :sys.get_state(view.pid).socket.assigns.operation_stats.completed == 1
    assert :sys.get_state(view.pid).socket.assigns.operation_stats.running == 0
  end

  test "string keyed peer detail renders without losing its existing full payload", ctx do
    {session, _} = history(ctx.workspace_path, 0)

    peer = %{
      "id" => "string-peer",
      "swarm_id" => session.id,
      "payload" => %{"body" => "complete"}
    }

    :ok = PeerStream.record_message(peer)
    {:ok, view, _} = live(ctx.conn, ~p"/sessions/#{session.id}?tab=swarm")
    render_click(view, "peer_detail", %{"id" => peer["id"]})
    assert has_element?(view, "#peer-detail", "complete")
    PeerStream.clear_history(session.id)
  end

  test "code block expansion preserves Markdown controls without duplicate DOM identities", ctx do
    {session, _} = history(ctx.workspace_path, 0)
    body = "λ\n```elixir\nIO.puts(:fixture)\n```\n\n```elixir\nIO.puts(:fixture)\n```"
    message = create_message_fixture(session, %{role: "assistant", content: body})
    {:ok, view, _} = live(ctx.conn, ~p"/sessions/#{session.id}?tab=chat")
    render_click(view, "expand_message", %{"id" => message.id})
    assert has_element?(view, "#expanded-message-modal pre code", "IO.puts(:fixture)")
    assert has_element?(view, "#expanded-message-modal button[title='Copy code']")
  end

  test "chat replaces finite windows and traverses tied history without gaps", ctx do
    {session, messages} = history(ctx.workspace_path, 173)
    {:ok, view, _} = live(ctx.conn, ~p"/sessions/#{session.id}")
    render_click(view, "switch_tab", %{"tab" => "chat"})
    assert length(ids(view)) == 50
    assert ids(view) == Enum.map(Enum.take(messages, -50), & &1.id)

    seen = older_pages(view, ids(view))
    assert Enum.sort(seen) == Enum.sort(Enum.map(messages, & &1.id))
    assert length(Enum.uniq(seen)) == 173
    refute has_element?(view, "#chat-history-older:not([disabled])")
    oldest = ids(view)
    newest_seen = newer_pages(view, oldest)
    assert Enum.sort(newest_seen) == Enum.sort(Enum.map(messages, & &1.id))
    render_click(view, "chat_history", %{"direction" => "latest"})
    assert ids(view) == Enum.map(Enum.take(messages, -50), & &1.id)
    assigns = :sys.get_state(view.pid).socket.assigns
    refute Map.has_key?(assigns, :all_messages)
    refute Map.has_key?(assigns, :messages)
    assert length(assigns.message_previews) == 50
    assert length(Sessions.list_messages(session.id)) == 173
  end

  test "previews omit oversized hidden bodies while scoped copy and one detail stay complete",
       ctx do
    {session, messages} = history(ctx.workspace_path, 61)
    old = hd(messages)
    body = "**Full detail**\n" <> String.duplicate("λ", 30_000) <> "\nunique-tail"

    old
    |> Ecto.Changeset.change(content: body, metadata: %{"reasoning" => body})
    |> Repo.update!()

    {:ok, page} = Sessions.fetch_message_preview_page(session.id, before: List.last(messages).id)
    assert Enum.all?(page.messages, &(byte_size(&1.content) <= 4096))
    assert Enum.all?(page.messages, &(byte_size(&1.metadata["reasoning"] || "") <= 2048))

    {:ok, view, _} = live(ctx.conn, ~p"/sessions/#{session.id}")
    render_click(view, "switch_tab", %{"tab" => "chat"})
    render_click(view, "chat_history", %{"direction" => "older"})
    assert has_element?(view, "#msg-preview-notice-#{old.id}")
    refute has_element?(view, "#copy-msg-btn-#{old.id}[data-code]")
    assert has_element?(view, "#scroll-node-#{old.id}")
    render_hook(view, "copy_message", %{"id" => old.id})
    assert_reply(view, %{content: ^body})
    render_click(view, "expand_message", %{"id" => old.id})
    assert has_element?(view, "#expanded-message-modal")
    assert :sys.get_state(view.pid).socket.assigns.message_detail.content == body
    render_click(view, "close_expand_message")
    assert :sys.get_state(view.pid).socket.assigns.message_detail == nil
    render_click(view, "expand_message", %{"id" => old.id})
    render_click(view, "chat_history", %{"direction" => "latest"})
    refute has_element?(view, "#expanded-message-modal")
  end

  test "duplicate and late events keep older windows and session switches scoped", ctx do
    {session, _} = history(ctx.workspace_path, 120)
    other = create_session_fixture(Sessions.get_session(session.id).project)
    foreign = create_message_fixture(other, %{content: "foreign body"})
    {:ok, view, _} = live(ctx.conn, ~p"/sessions/#{session.id}")
    render_click(view, "switch_tab", %{"tab" => "chat"})
    render_click(view, "chat_history", %{"direction" => "older"})
    old_ids = ids(view)
    new = create_message_fixture(session, %{content: "arrived while paging"})

    new =
      new
      |> Ecto.Changeset.change(inserted_at: DateTime.add(new.inserted_at, 1, :second))
      |> Repo.update!()

    send(view.pid, {:message_created, new})
    send(view.pid, {:message_created, new})
    assert ids(view) == old_ids
    render_click(view, "chat_history", %{"direction" => "latest"})
    assert Enum.count(ids(view), &(&1 == new.id)) == 1
    render_patch(view, ~p"/sessions/#{other.id}")
    send(view.pid, {:message_created, new})
    send(view.pid, {:operation_created, %{id: Ecto.UUID.generate(), session_id: session.id}})
    send(view.pid, {:swarm_peer_message, %{id: "late", swarm_id: session.id}})
    assert ids(view) == [foreign.id]
    render_hook(view, "copy_message", %{"id" => new.id})
    assert_reply(view, %{error: "not_found"})
    render_click(view, "expand_message", %{"id" => new.id})
    refute has_element?(view, "#expanded-message-modal")
    render_click(view, "chat_history", %{"direction" => "older", "cursor" => new.id})
    assert ids(view) == [foreign.id]
    {:ok, reconnected, _} = live(ctx.conn, ~p"/sessions/#{session.id}")
    render_click(reconnected, "switch_tab", %{"tab" => "chat"})
    assert new.id in ids(reconnected)
    assert length(ids(reconnected)) == 50
  end

  test "empty one and exact-window chat have correct navigation", ctx do
    project = create_project_fixture(%{root_path: ctx.workspace_path})

    for size <- [0, 1, 50] do
      session = create_session_fixture(project)

      if size > 0 do
        for n <- 1..size, do: create_message_fixture(session, %{content: "message #{n}"})
      end

      {:ok, view, _} = live(ctx.conn, ~p"/sessions/#{session.id}")
      render_click(view, "switch_tab", %{"tab" => "chat"})
      assert length(ids(view)) == size
      assert has_element?(view, "#chat-history-older[disabled]")
      assert has_element?(view, "#chat-history-newer[disabled]")
      assert has_element?(view, "#chat-empty-state") == (size == 0)
    end
  end

  test "operation totals and peer windows remain bounded with older scoped details", ctx do
    {session, _} = history(ctx.workspace_path, 0)

    ops =
      for n <- 1..65 do
        {:ok, op} =
          Sessions.create_operation(%{
            session_id: session.id,
            agent_name: "CoderAgent",
            op_type: "read_file",
            title: "operation #{n}",
            status: "completed",
            result: String.duplicate("r", 8000)
          })

        op
      end

    parent = hd(ops)

    {:ok, active} =
      Sessions.create_operation(%{
        session_id: session.id,
        agent_name: "CoderAgent",
        op_type: "read_file",
        title: "active child",
        status: "running",
        parent_op_id: parent.id
      })

    peers =
      for n <- 1..70 do
        {:ok, peer} =
          PeerStream.broadcast_peer_message(session.id, "coder", "planner", :coder, :message, %{
            text: "peer #{n}"
          })

        peer
      end

    {:ok, view, _} = live(ctx.conn, ~p"/sessions/#{session.id}")
    render_click(view, "switch_tab", %{"tab" => "swarm"})
    assert has_element?(view, "#operation-node-#{active.id}")
    state = :sys.get_state(view.pid).socket.assigns
    assert length(state.operations) <= 52
    assert Enum.any?(state.operations, &(&1.id == active.id))
    assert Enum.any?(state.operations, &(&1.id == parent.id))
    assert state.operation_stats.total == 66
    assert state.operation_stats.completed == 65
    render_click(view, "operation_history", %{"direction" => "older"})
    # The active child's ancestor is already expanded; inspecting another
    # terminal row replaces the single detail selection.
    render_click(view, "toggle_op_detail", %{"id" => parent.id})
    render_click(view, "toggle_op_detail", %{"id" => parent.id})
    assert :sys.get_state(view.pid).socket.assigns.operation_detail.result == parent.result
    render_click(view, "toggle_op_detail", %{"id" => parent.id})
    assert :sys.get_state(view.pid).socket.assigns.operation_detail == nil
    assert has_element?(view, "#peer-history-older")
    assert length(:sys.get_state(view.pid).socket.assigns.peer_messages) == 50
    render_click(view, "peer_history", %{"direction" => "older"})
    first = hd(peers)
    render_click(view, "peer_detail", %{"id" => first.id})
    assert :sys.get_state(view.pid).socket.assigns.peer_detail.payload == first.payload
    render_click(view, "close_peer_detail")
    assert :sys.get_state(view.pid).socket.assigns.peer_detail == nil
    assert length(Sessions.list_operations(session.id)) == 66
    PeerStream.clear_history(session.id)
  end

  test "terminal event overlays stay capped and late progress cannot resurrect completion", ctx do
    {session, _} = history(ctx.workspace_path, 0)
    {:ok, view, _} = live(ctx.conn, ~p"/sessions/#{session.id}")
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    events =
      for n <- 1..140 do
        %IexCode.Sessions.Operation{
          id: Ecto.UUID.generate(),
          session_id: session.id,
          agent_name: "CoderAgent",
          op_type: "read_file",
          title: "detached #{n}",
          status: "completed",
          inserted_at: DateTime.add(now, n, :second),
          result: String.duplicate("large", 2000)
        }
      end

    for event <- events, do: send(view.pid, {:operation_completed, event})
    render(view)
    state = :sys.get_state(view.pid).socket.assigns
    assert length(state.operations) == 50
    assert length(state.operation_events) <= 50
    assert Enum.all?(state.operations, &(byte_size(&1.result) <= 2048))
    assert Enum.all?(state.operations, &(:binary.referenced_byte_size(&1.result) <= 2048))
    latest = List.last(events)
    send(view.pid, {:operation_started, %{latest | status: "running"}})
    send(view.pid, {:operation_progress, latest.id, 90, "late progress"})
    render(view)

    assert Enum.find(:sys.get_state(view.pid).socket.assigns.operations, &(&1.id == latest.id)).status ==
             "completed"
  end

  test "peer duplicate global deliveries and foreign details never accumulate or cross sessions",
       ctx do
    {session, _} = history(ctx.workspace_path, 0)
    other = create_session_fixture(Sessions.get_session(session.id).project)
    {:ok, view, _} = live(ctx.conn, ~p"/sessions/#{session.id}")

    {:ok, peer} =
      PeerStream.broadcast_peer_message(session.id, "coder", "planner", :coder, :message, %{
        text: "owned"
      })

    {:ok, foreign} =
      PeerStream.broadcast_peer_message(other.id, "coder", "planner", :coder, :message, %{
        text: "foreign"
      })

    send(view.pid, {:swarm_peer_message, peer})
    send(view.pid, {:swarm_peer_message, peer})
    render(view)
    assert Enum.map(:sys.get_state(view.pid).socket.assigns.peer_messages, & &1.id) == [peer.id]
    render_click(view, "peer_detail", %{"id" => foreign.id})
    assert :sys.get_state(view.pid).socket.assigns.peer_detail == nil
    render_patch(view, ~p"/sessions/#{other.id}")
    send(view.pid, {:swarm_peer_message, peer})
    render(view)

    assert Enum.map(:sys.get_state(view.pid).socket.assigns.peer_messages, & &1.id) == [
             foreign.id
           ]

    PeerStream.clear_history(session.id)
    PeerStream.clear_history(other.id)
  end

  defp history(path, count) do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    messages =
      if count == 0,
        do: [],
        else: for(n <- 1..count, do: create_message_fixture(session, %{content: "message #{n}"}))

    {session, Enum.sort_by(messages, &{&1.inserted_at, &1.id})}
  end

  defp ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-chat-msg-id]")
    |> LazyHTML.attribute("data-chat-msg-id")
  end

  defp older_pages(view, seen) do
    if has_element?(view, "#chat-history-older:not([disabled])") do
      view |> element("#chat-history-older") |> render_click()
      assert length(ids(view)) <= 50
      older_pages(view, seen ++ ids(view))
    else
      seen
    end
  end

  defp newer_pages(view, seen) do
    if has_element?(view, "#chat-history-newer:not([disabled])") do
      view |> element("#chat-history-newer") |> render_click()
      assert length(ids(view)) <= 50
      newer_pages(view, seen ++ ids(view))
    else
      seen
    end
  end
end
