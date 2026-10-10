defmodule IexCodeWeb.WorkspaceStreaming do
  @moduledoc false
  import Phoenix.Component, only: [assign: 2]
  import Ecto.Query

  alias IexCode.{Repo, Runs, Sessions}
  alias IexCode.Sessions.Message

  @preview_bytes 16_384
  @preview_count 8
  @ledger_count 64
  # Twenty model turns in each of eleven supported swarm passes (10 repairs),
  # plus a fixed allowance for replanning/helper boundaries.
  @retired_count 256
  @roles ~w(assistant planner coder)
  @closed ~w(settled failed cancelled owner_down paused interrupted)

  def reset(socket), do: assign(socket, execution_previews: [], execution_streams: [])

  def event(socket, %{identity: identity, sequence: sequence, status: status, text: text} = event)
      when is_integer(sequence) and sequence > 0 and is_binary(text) do
    with {:ok, identity} <- identity(identity),
         true <- identity.session_id == socket.assigns.session.id,
         true <- identity.role in @roles do
      apply_event(socket, identity, sequence, to_string(status), text, event[:truncated?] == true)
    else
      _ -> socket
    end
  end

  def event(socket, _), do: socket

  def message(socket, %{session_id: session_id, role: "assistant", metadata: metadata})
      when is_map(metadata) do
    with true <- session_id == socket.assigns.session.id,
         scope when is_map(scope) <- metadata["stream_identity"] || metadata["stream_scope"],
         {:ok, scope} <- scope(scope),
         true <- scope.session_id == session_id,
         true <- saved?(scope) do
      close_scope(socket, scope, "saved", true)
    else
      _ -> socket
    end
  end

  def message(socket, _), do: socket

  def run(socket, %{id: id, session_id: session_id})
      when session_id == socket.assigns.session.id do
    case Runs.get_run(id) do
      %{session_id: ^session_id} = run ->
        streams =
          Enum.map(socket.assigns.execution_streams, fn stream ->
            i = stream.identity

            if i.execution_id == id and
                 (i.attempt != run.attempt or i.generation != run.lease_generation or
                    run.status in ~w(completed failed cancelled interrupted) or
                    not is_nil(run.cancellation_requested_at)) do
              %{stream | closed?: true, status: run.status}
            else
              stream
            end
          end)

        project(socket, streams)

      _ ->
        socket
    end
  end

  def run(socket, _), do: socket

  def agent(socket, %{id: id}) do
    case Runs.get_run_agent(id) do
      nil ->
        socket

      agent ->
        streams =
          Enum.map(socket.assigns.execution_streams, fn stream ->
            if stream.identity.agent_id == id and not current_agent?(stream.identity),
              do: %{stream | closed?: true, status: agent.status},
              else: stream
          end)

        project(socket, streams)
    end
  end

  # The old status notification has no session ID. Read only the selected
  # session's current state rather than trusting a queued foreign notification.
  def session(socket) do
    case Sessions.get_session(socket.assigns.session.id) do
      %{status: status} when status in ~w(idle failed stopped interrupted) ->
        streams =
          Enum.map(socket.assigns.execution_streams, fn stream ->
            i = stream.identity
            op = Sessions.get_operation(i.session_id, i.execution_id)

            if is_nil(Runs.get_run(i.execution_id)) and
                 (is_nil(op) or op.status not in ~w(pending running)),
               do: %{stream | closed?: true, status: status},
               else: stream
          end)

        project(socket, streams)

      _ ->
        socket
    end
  end

  defp apply_event(socket, i, sequence, status, text, truncated?) do
    streams = prune_ledger(socket.assigns.execution_streams, i)
    old = Enum.find(streams, &(lane(&1.identity) == lane(i)))

    cond do
      old && stale?(old, i, sequence, status) ->
        socket

      is_nil(old) && length(streams) >= @ledger_count ->
        # Fail closed rather than evict a fencing identity and revive old work.
        socket

      (is_nil(old) || lineage(old.identity) != lineage(i) ||
         old.identity.invocation_id != i.invocation_id) && not current?(i) ->
        socket

      (is_nil(old) || old.identity.invocation_id != i.invocation_id || status == "settled") &&
          saved?(i) ->
        close_scope(socket, i, "saved", true)

      true ->
        retired =
          if old && old.identity.invocation_id != i.invocation_id,
            do: [old.identity.invocation_id | old.retired],
            else: if(old, do: old.retired, else: [])

        partial? =
          if old && old.identity.invocation_id == i.invocation_id,
            do: old.partial?,
            else: status != "started"

        stream = %{
          identity: i,
          sequence: sequence,
          status: if(status == "settled", do: "complete", else: status),
          text: cap(text),
          truncated?: truncated? or byte_size(text) > @preview_bytes,
          partial?: partial?,
          closed?: status in @closed and status != "settled",
          hidden?: false,
          retired: Enum.take(retired, @retired_count)
        }

        # A newer execution lineage supersedes every role of the older attempt.
        streams =
          Enum.reject(streams, fn s ->
            lane(s.identity) == lane(i) or
              (s.identity.execution_id == i.execution_id and
                 execution_lineage(s.identity) < execution_lineage(i))
          end)

        project(socket, [stream | streams])
    end
  end

  defp stale?(old, i, sequence, status) do
    prior = old.identity

    cond do
      lineage(i) < lineage(prior) ->
        true

      lineage(i) > lineage(prior) ->
        false

      i.invocation_id in old.retired ->
        true

      i.invocation_id != prior.invocation_id ->
        length(old.retired) >= @retired_count or
          not ((old.status == "complete" or
                  (i.role in ~w(planner coder) and old.status in ~w(failed owner_down paused))) and
                 (status == "started" or i.turn > prior.turn))

      old.closed? ->
        true

      i.turn < prior.turn ->
        true

      i.turn > prior.turn ->
        false

      i.retry_epoch < prior.retry_epoch ->
        true

      sequence <= old.sequence ->
        true

      true ->
        false
    end
  end

  defp close_scope(socket, scope, _status, _hidden?) do
    # Committed identity is its own durable tombstone. Retaining final bodies
    # or a session-long set of final IDs is unnecessary.
    project(
      socket,
      Enum.reject(socket.assigns.execution_streams, &(group(&1.identity) == group(scope)))
    )
  end

  defp project(socket, streams) do
    streams =
      streams
      |> Enum.take(@ledger_count)
      |> Enum.with_index()
      |> Enum.map(fn {stream, index} ->
        if index < @preview_count, do: stream, else: %{stream | text: ""}
      end)

    previews =
      streams
      |> Enum.reject(& &1.hidden?)
      |> Enum.take(@preview_count)
      |> Enum.map(&Map.take(&1, [:identity, :status, :text, :truncated?, :partial?, :closed?]))
      |> Enum.reverse()

    assign(socket, execution_streams: streams, execution_previews: previews)
  end

  defp prune_ledger(streams, identity) do
    # Only authorized new lanes may reclaim terminal entries. Ignore reversible
    # session status when deciding whether an interactive identity is obsolete:
    # only a later objective can safely replace its in-memory terminal fence.
    # Live parent role failures and complete/awaiting-final lanes keep fences.
    if not Enum.any?(streams, &(lane(&1.identity) == lane(identity))) and current?(identity) do
      Enum.reject(streams, &(&1.closed? and not current?(&1.identity, false)))
    else
      streams
    end
  end

  defp current?(i, check_session_status? \\ true) do
    case Runs.get_run(i.execution_id) do
      %{} = run ->
        run.session_id == i.session_id and run.attempt == i.attempt and
          run.lease_generation == i.generation and
          run.status in ~w(running paused) and live_lease?(run) and
          is_nil(run.cancellation_requested_at) and current_agent?(i)

      nil ->
        case Sessions.get_operation(i.session_id, i.execution_id) do
          %{} = op ->
            op.status in ~w(pending running)

          nil ->
            session = Sessions.get_session(i.session_id)

            not is_nil(session) and
              (not check_session_status? or session.status not in ~w(failed stopped interrupted)) and
              current_interactive?(i)
        end
    end
  end

  defp current_agent?(%{agent_id: nil}), do: true

  defp current_agent?(i) do
    case Runs.get_run_agent(i.agent_id) do
      %{run_id: run_id, lease_generation: generation, role: role, status: status} = agent ->
        run_id == i.execution_id and generation == i.agent_generation and role == i.role and
          status in ~w(starting idle running paused stopping) and live_lease?(agent)

      _ ->
        false
    end
  end

  defp current_interactive?(i) do
    # Interactive objectives are serialized by SessionServer. SQLite insertion
    # order, unlike second-resolution timestamps/random UUIDs, distinguishes
    # successive objectives even within one second. Steering and independent
    # durable objectives must not supersede an interactive execution.
    Repo.exists?(
      from m in Message,
        where: m.session_id == ^i.session_id and m.id == ^i.execution_id and m.role == "user",
        where:
          fragment(
            "NOT EXISTS (SELECT 1 FROM messages AS newer WHERE newer.session_id = ? AND newer.role = 'user' AND newer.agent_name = 'User' AND json_extract(newer.metadata, '$.run_id') IS NULL AND newer.rowid > ?.rowid)",
            m.session_id,
            m
          )
    )
  end

  # Queued retries retain the previous generation until claimed. Neither they
  # nor an expired/released lease authorize replay of that previous stream.
  defp live_lease?(%{lease_owner: owner, lease_expires_at: %DateTime{} = expires_at}),
    do: is_binary(owner) and DateTime.compare(expires_at, DateTime.utc_now()) == :gt

  defp live_lease?(_), do: false

  # EXISTS loads no final content, transcript, or arbitrary metadata. It also
  # catches final-before-delta and reconnect ordering outside the visible page.
  defp saved?(i) do
    Repo.exists?(
      from m in Message,
        where: m.session_id == ^i.session_id and m.role == "assistant",
        where:
          fragment(
            "(json_extract(?, '$.stream_identity.execution_id') = ? AND json_extract(?, '$.stream_identity.attempt') = ? AND json_extract(?, '$.stream_identity.generation') = ?) OR (json_extract(?, '$.stream_scope.execution_id') = ? AND json_extract(?, '$.stream_scope.attempt') = ? AND json_extract(?, '$.stream_scope.generation') = ?)",
            m.metadata,
            ^i.execution_id,
            m.metadata,
            ^i.attempt,
            m.metadata,
            ^i.generation,
            m.metadata,
            ^i.execution_id,
            m.metadata,
            ^i.attempt,
            m.metadata,
            ^i.generation
          )
    )
  end

  defp identity(map) when is_map(map) do
    with {:ok, scope} <- scope(map),
         role when role in @roles <- value(map, :role),
         invocation when is_binary(invocation) <- value(map, :invocation_id),
         true <- byte_size(invocation) <= 128,
         turn when is_integer(turn) and turn > 0 <- value(map, :turn),
         epoch when is_integer(epoch) and epoch >= 0 <- value(map, :retry_epoch) do
      {:ok,
       Map.merge(scope, %{
         role: role,
         invocation_id: invocation,
         turn: turn,
         retry_epoch: epoch,
         agent_id: value(map, :agent_id),
         agent_generation: value(map, :agent_generation)
       })}
    else
      _ -> :invalid
    end
  end

  defp identity(_), do: :invalid

  defp scope(map) do
    with {:ok, session_id} <- Ecto.UUID.cast(value(map, :session_id)),
         {:ok, execution_id} <- Ecto.UUID.cast(value(map, :execution_id)),
         attempt when is_integer(attempt) and attempt > 0 <- value(map, :attempt),
         generation when is_integer(generation) and generation > 0 <- value(map, :generation) do
      {:ok,
       %{
         session_id: session_id,
         execution_id: execution_id,
         attempt: attempt,
         generation: generation
       }}
    else
      _ -> :invalid
    end
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, to_string(key)))
  defp group(i), do: {i.session_id, i.execution_id, i.attempt, i.generation}
  defp lane(i), do: {i.execution_id, i.role, i.agent_id}
  defp lineage(i), do: {i.attempt, i.generation, i.agent_generation || 0}
  defp execution_lineage(i), do: {i.attempt, i.generation}

  defp cap(text) do
    prefix = binary_part(text, 0, min(byte_size(text), @preview_bytes))

    case :unicode.characters_to_binary(prefix, :utf8, :utf8) do
      valid when is_binary(valid) -> :binary.copy(valid)
      {_kind, valid, _rest} -> :binary.copy(valid)
    end
  end
end
