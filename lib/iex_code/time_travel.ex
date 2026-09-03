defmodule IexCode.TimeTravel do
  @moduledoc """
  Atomic Workspace Time-Travel Engine & 1-Click Rollback.
  Provides durable pre-mutation checkpointing, monotonic transaction tracking,
  reverse-chronological sequential rollback, zero-orphan cleanup, and real-time PubSub notifications.
  """

  import Ecto.Query
  require Logger

  alias IexCode.Repo
  alias IexCode.Tools.MultiPatch.MutationSnapshot

  @doc """
  Lists all checkpoints for a session ordered by monotonic sequence descending (latest first).
  """
  @spec list_checkpoints(String.t()) :: [MutationSnapshot.t()]
  def list_checkpoints(session_id) when is_binary(session_id) do
    query =
      from(s in MutationSnapshot,
        where: s.session_id == ^session_id,
        order_by: [desc: s.seq, desc: s.created_at]
      )

    Repo.all(query)
    |> Enum.map(&populate_virtual_fields/1)
  end

  @doc """
  Fetches a single checkpoint by transaction_id.
  """
  @spec get_checkpoint(String.t()) :: MutationSnapshot.t() | nil
  def get_checkpoint(transaction_id) when is_binary(transaction_id) do
    case Repo.get(MutationSnapshot, transaction_id) do
      nil -> nil
      snapshot -> populate_virtual_fields(snapshot)
    end
  end

  @doc """
  Creates and persists a durable pre-mutation checkpoint.
  Broadcasts `{:checkpoint_created, checkpoint}` on `"session:\#{session_id}"`.
  """
  @spec create_checkpoint(map()) :: {:ok, MutationSnapshot.t()} | {:error, term()}
  def create_checkpoint(attrs) when is_map(attrs) do
    session_id = attrs[:session_id] || attrs["session_id"]
    tx_id = attrs[:transaction_id] || attrs["transaction_id"] || "tx_#{Ecto.UUID.generate()}"
    project_root = attrs[:project_root] || attrs["project_root"]
    patches = attrs[:patches] || attrs["patches"] || []
    label = attrs[:label] || attrs["label"] || generate_default_label(patches)
    diff_summary = attrs[:diff_summary] || attrs["diff_summary"] || summarize_patches(patches)

    next_seq =
      if session_id do
        max_seq =
          Repo.one(
            from(s in MutationSnapshot,
              where: s.session_id == ^session_id,
              select: max(s.seq)
            )
          ) || 0

        max_seq + 1
      else
        1
      end

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    changeset_attrs = %{
      transaction_id: tx_id,
      session_id: session_id,
      run_id: attrs[:run_id] || attrs["run_id"],
      project_root: project_root,
      patches: patches,
      created_at: attrs[:created_at] || attrs["created_at"] || now,
      seq: next_seq,
      status: "active",
      label: label,
      diff_summary: diff_summary
    }

    changeset = MutationSnapshot.changeset(%MutationSnapshot{}, changeset_attrs)

    case Repo.insert(changeset) do
      {:ok, snapshot} ->
        checkpoint = populate_virtual_fields(snapshot)

        if session_id do
          Phoenix.PubSub.broadcast(
            IexCode.PubSub,
            "session:#{session_id}",
            {:checkpoint_created, checkpoint}
          )
        end

        {:ok, checkpoint}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Reverts the most recent active checkpoint for the session.
  Restores original contents and deletes newly created files (zero orphans).
  Broadcasts `{:checkpoint_rolled_back, tx_id, details}` on `"session:\#{session_id}"`.
  """
  @spec rollback_latest(String.t()) :: {:ok, map()} | {:error, term()}
  def rollback_latest(session_id) when is_binary(session_id) do
    latest =
      Repo.one(
        from(s in MutationSnapshot,
          where: s.session_id == ^session_id and s.status == "active",
          order_by: [desc: s.seq, desc: s.created_at],
          limit: 1
        )
      )

    case latest do
      nil ->
        {:error, :no_active_checkpoints}

      snapshot ->
        case revert_snapshot(snapshot) do
          :ok ->
            # Mark snapshot as rolled_back
            snapshot
            |> MutationSnapshot.changeset(%{status: "rolled_back"})
            |> Repo.update!()

            details = %{
              transaction_id: snapshot.transaction_id,
              seq: snapshot.seq,
              label: snapshot.label,
              reverted_files: length(snapshot.patches)
            }

            Phoenix.PubSub.broadcast(
              IexCode.PubSub,
              "session:#{session_id}",
              {:checkpoint_rolled_back, snapshot.transaction_id, details}
            )

            {:ok, %{reverted_checkpoints: 1, reverted_tx_ids: [snapshot.transaction_id]}}

          {:error, err} ->
            {:error, err}
        end
    end
  end

  @doc """
  Reverts all intervening mutations back to a target checkpoint in reverse-chronological order.
  """
  @spec rollback_to(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def rollback_to(target_tx_id, opts \\ []) when is_binary(target_tx_id) do
    target = get_checkpoint(target_tx_id)

    if is_nil(target) do
      {:error, :checkpoint_not_found}
    else
      session_id = Keyword.get(opts, :session_id) || target.session_id

      # Find all active checkpoints strictly after target.seq
      subsequent_checkpoints =
        Repo.all(
          from(s in MutationSnapshot,
            where: s.session_id == ^session_id and s.status == "active" and s.seq > ^target.seq,
            order_by: [desc: s.seq]
          )
        )

      if subsequent_checkpoints == [] do
        {:ok, %{reverted_checkpoints: 0, target_tx_id: target_tx_id}}
      else
        # Revert in strict reverse-chronological order
        results =
          Enum.reduce_while(subsequent_checkpoints, :ok, fn cp, :ok ->
            case revert_snapshot(cp) do
              :ok ->
                cp
                |> MutationSnapshot.changeset(%{status: "rolled_back"})
                |> Repo.update!()

                {:cont, :ok}

              {:error, reason} ->
                {:halt, {:error, reason}}
            end
          end)

        case results do
          :ok ->
            reverted_ids = Enum.map(subsequent_checkpoints, & &1.transaction_id)

            details = %{
              target_tx_id: target_tx_id,
              reverted_count: length(subsequent_checkpoints),
              reverted_ids: reverted_ids
            }

            Phoenix.PubSub.broadcast(
              IexCode.PubSub,
              "session:#{session_id}",
              {:checkpoint_rolled_back, target_tx_id, details}
            )

            {:ok,
             %{
               reverted_checkpoints: length(subsequent_checkpoints),
               reverted_tx_ids: reverted_ids,
               target_tx_id: target_tx_id
             }}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  # ============================================================================
  # Snapshot Reversal Core Logic
  # ============================================================================

  defp revert_snapshot(%MutationSnapshot{project_root: root, patches: patches}) do
    # Reverse patches list to undo in reverse order
    reversed_patches = Enum.reverse(patches)

    Enum.each(reversed_patches, fn patch ->
      rel_path = patch["path"] || patch[:path]
      full_path = Path.join(root, rel_path)
      file_existed = Map.get(patch, "file_existed", Map.get(patch, :file_existed, true))

      if file_existed == false do
        # File was newly created by this mutation — delete to avoid orphans
        if File.exists?(full_path) do
          File.rm(full_path)
        end
      else
        # File existed before — restore original content
        original_content =
          Map.get(patch, "original_content", Map.get(patch, :original_content, ""))

        File.mkdir_p!(Path.dirname(full_path))
        File.write!(full_path, original_content || "")
      end
    end)

    :ok
  rescue
    e ->
      Logger.error("Failed to revert snapshot: #{inspect(e)}")
      {:error, e}
  end

  defp populate_virtual_fields(%MutationSnapshot{} = s) do
    %{s | id: s.transaction_id}
  end

  defp generate_default_label(patches) when is_list(patches) do
    case length(patches) do
      0 ->
        "Empty checkpoint"

      1 ->
        p = hd(patches)
        path = p["path"] || p[:path] || "file"
        "Modified #{path}"

      count ->
        "Modified #{count} files"
    end
  end

  defp generate_default_label(_), do: "Checkpoint"

  defp summarize_patches(patches) when is_list(patches) do
    count = length(patches)
    "#{count} file(s) affected"
  end

  defp summarize_patches(_), do: ""
end
