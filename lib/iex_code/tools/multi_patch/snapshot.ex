defmodule IexCode.Tools.MultiPatch.Snapshot do
  @moduledoc """
  Snapshot store for tracking multi-file patch transactions and supporting rollback.
  Uses an ETS table for concurrency-safe transactional storage.
  """

  @table_name :iex_code_multipatch_snapshots

  @doc """
  Ensures ETS table is created.
  """
  def ensure_table do
    case :ets.info(@table_name) do
      :undefined ->
        :ets.new(@table_name, [:set, :public, :named_table, read_concurrency: true])

      _ ->
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

    entry = %{
      transaction_id: tx_id,
      timestamp: timestamp,
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
  Lists all recorded snapshot transactions.
  """
  @spec list_snapshots() :: [map()]
  def list_snapshots do
    ensure_table()

    :ets.tab2list(@table_name)
    |> Enum.map(fn {_id, entry} -> entry end)
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
