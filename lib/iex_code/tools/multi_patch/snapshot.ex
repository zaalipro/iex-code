defmodule IexCode.Tools.MultiPatch.Snapshot do
  @moduledoc """
  Snapshot store for tracking multi-file patch transactions and supporting rollback.
  Uses an ETS table for concurrency-safe transactional storage.

  The table is normally owned by `IexCode.Tools.MultiPatch.Snapshot.Owner` in the
  supervision tree; `ensure_table/0` creates it lazily (idempotently) when the
  owner is not running (e.g. in tests or standalone scripts).
  """

  @table_name :iex_code_multipatch_snapshots

  @doc """
  Returns the name of the underlying ETS table.
  """
  def table_name, do: @table_name

  @doc """
  Ensures ETS table is created. Idempotent and race-safe: concurrent callers
  that lose the creation race simply reuse the existing table.
  """
  def ensure_table do
    case :ets.whereis(@table_name) do
      :undefined ->
        try do
          :ets.new(@table_name, [:set, :public, :named_table, read_concurrency: true])
        rescue
          # Another process created the named table concurrently.
          ArgumentError -> @table_name
        end

      _table ->
        @table_name
    end
  end

  @doc """
  Saves a snapshot transaction record.
  """
  @spec save_snapshot(String.t(), [map()], keyword()) :: :ok
  def save_snapshot(tx_id, patches, opts \\ []) do
    ensure_table()
    timestamp = Keyword.get(opts, :timestamp, DateTime.utc_now())
    session_id = Keyword.get(opts, :session_id)

    entry = %{
      transaction_id: tx_id,
      timestamp: timestamp,
      session_id: session_id,
      patches: patches
    }

    :ets.insert(@table_name, {tx_id, entry})
    :ok
  end

  @doc """
  Retrieves a snapshot transaction record by ID.
  """
  @spec get_snapshot(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_snapshot(tx_id) do
    ensure_table()

    case :ets.lookup(@table_name, tx_id) do
      [{^tx_id, entry}] -> {:ok, entry}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Lists recorded snapshot transactions, optionally filtered by `session_id`.
  Pass `nil` (or omit the argument) to list all snapshots.
  """
  @spec list_snapshots(String.t() | nil) :: [map()]
  def list_snapshots(session_id \\ nil) do
    ensure_table()

    :ets.tab2list(@table_name)
    |> Enum.map(fn {_id, entry} -> entry end)
    |> Enum.filter(fn entry ->
      session_id == nil or Map.get(entry, :session_id) == session_id
    end)
  end

  @doc """
  Deletes a snapshot record.
  """
  def delete_snapshot(tx_id) do
    ensure_table()
    :ets.delete(@table_name, tx_id)
    :ok
  end
end
