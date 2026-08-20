defmodule IexCode.Sessions do
  @moduledoc """
  Context for managing sessions, conversation messages, and real-time swarm operations.
  """
  import Ecto.Query, warn: false
  alias IexCode.Repo
  alias IexCode.Sessions.{Session, Message, Operation}

  def list_sessions_for_project(project_id) do
    Session
    |> where([s], s.project_id == ^project_id)
    |> order_by([s], desc: s.updated_at)
    |> Repo.all()
  end

  def get_session!(id) do
    Session
    |> Repo.get!(id)
    |> Repo.preload([:project])
  end

  def get_session(id) do
    case Repo.get(Session, id) do
      nil -> nil
      session -> Repo.preload(session, [:project])
    end
  end

  def create_session(attrs \\ %{}, retries \\ 20) do
    %Session{}
    |> Session.changeset(attrs)
    |> Repo.insert()
  rescue
    e in [Exqlite.Error, DBConnection.ConnectionError] ->
      if retries > 0 do
        :timer.sleep(35)
        create_session(attrs, retries - 1)
      else
        reraise e, __STACKTRACE__
      end
  end

  def update_session(%Session{} = session, attrs) do
    session
    |> Session.changeset(attrs)
    |> Repo.update()
  end

  def delete_session(%Session{} = session) do
    Repo.delete(session)
  end

  def list_messages(session_id) do
    Message
    |> where([m], m.session_id == ^session_id)
    |> order_by([m], asc: m.inserted_at)
    |> Repo.all()
  end

  def create_message(attrs \\ %{}, retries \\ 20) do
    %Message{}
    |> Message.changeset(sanitize_attrs(attrs))
    |> Repo.insert()
  rescue
    e in [Exqlite.Error, DBConnection.ConnectionError] ->
      if retries > 0 do
        :timer.sleep(35)
        create_message(attrs, retries - 1)
      else
        reraise e, __STACKTRACE__
      end
  end

  def list_operations(session_id) do
    Operation
    |> where([o], o.session_id == ^session_id)
    |> order_by([o], asc: o.inserted_at)
    |> Repo.all()
  end

  def get_operation!(id), do: Repo.get!(Operation, id)

  def get_operation(id), do: Repo.get(Operation, id)

  def create_operation(attrs \\ %{}, retries \\ 5) do
    try do
      %Operation{}
      |> Operation.changeset(sanitize_attrs(attrs))
      |> Repo.insert()
    rescue
      _ in [Exqlite.Error, DBConnection.ConnectionError] ->
        if retries > 0 do
          :timer.sleep(20)
          create_operation(attrs, retries - 1)
        else
          {:error, :db_unavailable}
        end

      _ ->
        {:error, :db_unavailable}
    catch
      _, _ ->
        {:error, :db_unavailable}
    end
  end

  def update_operation(op_or_id, attrs, retries \\ 5) do
    op_id =
      case op_or_id do
        %Operation{id: id} -> id
        id when is_binary(id) -> id
        _ -> nil
      end

    try do
      case op_id && Repo.get(Operation, op_id) do
        nil ->
          {:error, :not_found}

        %Operation{} = op ->
          op
          |> Operation.changeset(sanitize_attrs(attrs))
          |> Repo.update()
      end
    rescue
      _ in [Exqlite.Error, DBConnection.ConnectionError] ->
        if retries > 0 do
          :timer.sleep(20)
          update_operation(op_or_id, attrs, retries - 1)
        else
          {:error, :db_unavailable}
        end

      _ ->
        {:error, :db_unavailable}
    catch
      :exit, _ ->
        if retries > 0 do
          :timer.sleep(20)
          update_operation(op_or_id, attrs, retries - 1)
        else
          {:error, :db_exited}
        end

      _, _ ->
        {:error, :db_unavailable}
    end
  end

  def sanitize_utf8(nil), do: nil

  def sanitize_utf8(term) when is_binary(term) do
    if String.valid?(term) do
      term
    else
      case :unicode.characters_to_binary(term, :utf8, :utf8) do
        {:error, valid, _rest} -> valid <> " [binary truncated]"
        {:incomplete, valid, _rest} -> valid
        binary when is_binary(binary) -> binary
      end
    end
  end

  def sanitize_utf8(%DateTime{} = dt), do: dt
  def sanitize_utf8(%Date{} = d), do: d
  def sanitize_utf8(%Time{} = t), do: t
  def sanitize_utf8(%NaiveDateTime{} = ndt), do: ndt
  def sanitize_utf8(%{__struct__: _} = struct), do: struct

  def sanitize_utf8(term) when is_map(term) do
    Map.new(term, fn {k, v} -> {sanitize_utf8(k), sanitize_utf8(v)} end)
  end

  def sanitize_utf8(term) when is_list(term) do
    Enum.map(term, &sanitize_utf8/1)
  end

  def sanitize_utf8(term), do: term

  defp sanitize_attrs(attrs) when is_map(attrs) do
    Map.new(attrs, fn {k, v} -> {k, sanitize_utf8(v)} end)
  end

  defp sanitize_attrs(attrs), do: attrs

  def clear_session_operations(session_id) do
    Operation
    |> where([o], o.session_id == ^session_id)
    |> Repo.delete_all()
  end
end
