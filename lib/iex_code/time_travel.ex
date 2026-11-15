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
  alias IexCode.{WorkspaceLocks, WorkspacePath}

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
  Checks whether any file touched by `checkpoint_or_tx_id` has drifted on disk
  from the expected post-mutation content recorded in the checkpoint.

  Returns `:ok`, `{:error, {:drift_detected, drifts}}`, `{:error, :checkpoint_not_found}`,
  or a path-containment error if any recorded path escapes `project_root`.
  """
  @spec check_drift(MutationSnapshot.t() | String.t()) :: :ok | {:error, term()}
  def check_drift(tx_id) when is_binary(tx_id) do
    case get_checkpoint(tx_id) do
      nil -> {:error, :checkpoint_not_found}
      %MutationSnapshot{} = snapshot -> check_drift(snapshot)
    end
  end

  def check_drift(%MutationSnapshot{} = snapshot) do
    with {:ok, validated_entries} <- validate_snapshots_paths([snapshot]) do
      check_entries_drift(validated_entries)
    end
  end

  @doc """
  Reverts the most recent active checkpoint for the session.
  Restores original contents and deletes newly created files (zero orphans).
  Broadcasts `{:checkpoint_rolled_back, tx_id, details}` on `"session:\#{session_id}"`.

  Options:
    * `:allow_drift` - when `false`, fails closed with `{:error, {:drift_detected, drifts}}`
      if any target file on disk no longer matches the checkpoint's expected post-state
      (default `true`).
  """
  @spec rollback_latest(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def rollback_latest(session_id, opts \\ [])
      when is_binary(session_id) and is_list(opts) do
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
        allow_drift? = Keyword.get(opts, :allow_drift, true)

        with {:ok, validated_entries} <- validate_snapshots_paths([snapshot]),
             :ok <- maybe_check_entries_drift(validated_entries, allow_drift?),
             :ok <- revert_snapshot(snapshot) do
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
        end
    end
  end

  @doc """
  Reverts all intervening mutations back to a target checkpoint in reverse-chronological order.

  Options:
    * `:session_id` - override session lookup scope (defaults to target's `session_id`)
    * `:allow_drift` - when `false`, verifies the reverse checkpoint chain against current
      disk state and aborts with `{:error, {:drift_detected, drifts}}` if external edits exist
      (default `true`).
  """
  @spec rollback_to(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def rollback_to(target_tx_id, opts \\ [])
      when is_binary(target_tx_id) and is_list(opts) do
    target = get_checkpoint(target_tx_id)

    if is_nil(target) do
      {:error, :checkpoint_not_found}
    else
      session_id = Keyword.get(opts, :session_id) || target.session_id
      allow_drift? = Keyword.get(opts, :allow_drift, true)

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
        with {:ok, validated_entries} <- validate_snapshots_paths(subsequent_checkpoints),
             :ok <- maybe_check_entries_drift(validated_entries, allow_drift?),
             :ok <-
               apply_validated_rollback(subsequent_checkpoints, validated_entries, fn ->
                 Enum.each(subsequent_checkpoints, fn cp ->
                   cp
                   |> MutationSnapshot.changeset(%{status: "rolled_back"})
                   |> Repo.update!()
                 end)
               end) do
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
        end
      end
    end
  end

  # ============================================================================
  # Snapshot Reversal Core Logic (Contained, Locked & Atomic)
  # ============================================================================

  defp revert_snapshot(%MutationSnapshot{} = snapshot) do
    with {:ok, validated_entries} <- validate_snapshots_paths([snapshot]) do
      apply_validated_rollback([snapshot], validated_entries, nil)
    end
  rescue
    e ->
      Logger.error("Failed to revert snapshot: #{inspect(e)}")
      {:error, e}
  end

  defp maybe_check_entries_drift(_entries, true), do: :ok
  defp maybe_check_entries_drift(entries, false), do: check_entries_drift(entries)

  defp validate_snapshots_paths(snapshots) do
    snapshots
    |> Enum.reduce_while({:ok, []}, fn %MutationSnapshot{} = cp, {:ok, cp_acc} ->
      case validate_single_snapshot_paths(cp) do
        {:ok, cp_entries} -> {:cont, {:ok, Enum.reverse(cp_entries) ++ cp_acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_single_snapshot_paths(%MutationSnapshot{
         transaction_id: tx_id,
         project_root: root,
         patches: patches
       }) do
    cond do
      not is_list(patches) ->
        {:error, :invalid_patches}

      patches == [] ->
        {:ok, []}

      not is_binary(root) or root == "" ->
        {:error, :invalid_workspace}

      true ->
        # Reversed patch order matches the exact order revert applies them.
        patches
        |> Enum.reverse()
        |> Enum.reduce_while({:ok, []}, fn patch, {:ok, acc} ->
          rel_path = patch_field(patch, "path", :path)

          case resolve_contained_patch_path(root, rel_path) do
            {:ok, canonical_root, full_path, normalized_rel} ->
              entry = %{
                transaction_id: tx_id,
                raw_root: root,
                canonical_root: canonical_root,
                rel_path: rel_path,
                normalized_rel: normalized_rel,
                full_path: full_path,
                patch: patch
              }

              {:cont, {:ok, [entry | acc]}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp resolve_contained_patch_path(root, rel_path) do
    with true <- is_binary(rel_path) and rel_path != "",
         {:ok, canonical_root} <- WorkspacePath.resolve(root, ""),
         {:ok, full_path} <- WorkspacePath.resolve(root, rel_path),
         true <- full_path != canonical_root,
         :ok <- verify_no_escaping_symlinks(canonical_root, rel_path, full_path) do
      {:ok, canonical_root, full_path, Path.relative_to(full_path, canonical_root)}
    else
      false -> {:error, :invalid_path}
      {:error, reason} -> {:error, reason}
    end
  end

  # Catches dangling leaf or parent symlinks whose link target leaves canonical_root.
  defp verify_no_escaping_symlinks(canonical_root, rel_path, full_path) do
    candidate =
      if Path.type(rel_path) == :absolute do
        full_path
      else
        Path.expand(rel_path, canonical_root)
      end

    with :ok <- check_symlink_chain(canonical_root, candidate, 40) do
      check_symlink_chain(canonical_root, full_path, 40)
    end
  end

  defp check_symlink_chain(_canonical_root, _target_path, hops) when hops <= 0 do
    {:error, :too_many_symlinks}
  end

  defp check_symlink_chain(canonical_root, target_path, hops) do
    case Path.relative_to(target_path, canonical_root) do
      ^target_path ->
        {:error, :outside_workspace}

      "" ->
        {:error, :invalid_path}

      rel ->
        rel
        |> Path.split()
        |> Enum.reduce_while({:ok, canonical_root}, fn segment, {:ok, current_dir} ->
          next_path = Path.join(current_dir, segment)

          case File.lstat(next_path) do
            {:ok, %File.Stat{type: :symlink}} ->
              resolve_symlink_hop(canonical_root, current_dir, next_path, hops)

            _ ->
              {:cont, {:ok, next_path}}
          end
        end)
        |> case do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp resolve_symlink_hop(canonical_root, current_dir, next_path, hops) do
    case :file.read_link_all(next_path) do
      {:ok, raw_target} ->
        expanded =
          raw_target
          |> List.to_string()
          |> Path.expand(current_dir)

        if within_root?(expanded, canonical_root) do
          if expanded == canonical_root do
            {:cont, {:ok, canonical_root}}
          else
            case check_symlink_chain(canonical_root, expanded, hops - 1) do
              :ok -> {:cont, {:ok, expanded}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end
        else
          {:halt, {:error, :outside_workspace}}
        end

      {:error, reason} ->
        {:halt, {:error, {:filesystem_error, reason}}}
    end
  end

  defp within_root?(path, canonical_root) do
    path == canonical_root or String.starts_with?(path, canonical_root <> "/")
  end

  defp check_entries_drift([]), do: :ok

  defp check_entries_drift(entries) do
    {drifts, _sim_state} =
      Enum.reduce(entries, {[], %{}}, fn entry, {drifts_acc, sim_state} ->
        %{full_path: full_path, patch: patch, rel_path: rel_path, transaction_id: tx_id} = entry

        {current_state, sim_state} = fetch_simulated_state(full_path, sim_state)
        file_existed = patch_field(patch, "file_existed", :file_existed, true)
        has_new_key? = patch_has_key?(patch, "new_content", :new_content)
        new_content = patch_field(patch, "new_content", :new_content)
        original_content = patch_field(patch, "original_content", :original_content, "")

        drift_reason =
          cond do
            is_binary(new_content) ->
              case current_state do
                {:content, ^new_content} -> nil
                {:content, _other} -> :content_mismatch
                :missing -> :file_missing
                {:error, reason} -> reason
              end

            has_new_key? and is_nil(new_content) ->
              case current_state do
                :missing -> nil
                {:content, _other} -> :unexpected_file_exists
                {:error, reason} -> reason
              end

            true ->
              nil
          end

        next_file_state =
          if file_existed == false do
            :missing
          else
            {:content, original_content || ""}
          end

        next_sim = Map.put(sim_state, full_path, next_file_state)

        drifts_acc =
          if is_nil(drift_reason) do
            drifts_acc
          else
            [%{path: rel_path, reason: drift_reason, transaction_id: tx_id} | drifts_acc]
          end

        {drifts_acc, next_sim}
      end)

    case Enum.reverse(drifts) do
      [] -> :ok
      detected -> {:error, {:drift_detected, detected}}
    end
  end

  defp fetch_simulated_state(full_path, sim_state) do
    case Map.fetch(sim_state, full_path) do
      {:ok, cached} ->
        {cached, sim_state}

      :error ->
        state = read_current_file_state(full_path)
        {state, Map.put(sim_state, full_path, state)}
    end
  end

  defp read_current_file_state(full_path) do
    case File.lstat(full_path) do
      {:ok, %File.Stat{type: :regular}} ->
        case File.read(full_path) do
          {:ok, bytes} -> {:content, bytes}
          {:error, reason} -> {:error, {:read_failed, reason}}
        end

      {:ok, %File.Stat{type: other}} ->
        {:error, {:unsupported_file_type, other}}

      {:error, :enoent} ->
        :missing

      {:error, reason} ->
        {:error, {:stat_failed, reason}}
    end
  end

  defp apply_validated_rollback(_snapshots, [], db_commit_fun) do
    commit_db_changes(db_commit_fun)
  end

  defp apply_validated_rollback(snapshots, entries, db_commit_fun) do
    root_groups =
      entries
      |> Enum.group_by(& &1.raw_root)
      |> Enum.sort_by(fn {raw_root, _} -> raw_root end)
      |> Enum.map(fn {raw_root, group_entries} ->
        resources =
          group_entries
          |> Enum.map(& &1.normalized_rel)
          |> Enum.uniq()
          |> Enum.sort()
          |> Enum.map(&{{:file, &1}, :write})

        {raw_root, resources}
      end)

    identity_opts = lock_identity_opts(entries)

    with_nested_workspace_locks(root_groups, identity_opts, fn ->
      with {:ok, revalidated_entries} <- validate_snapshots_paths(snapshots),
           {:ok, backups} <- capture_backups(revalidated_entries),
           :ok <- apply_entries_with_backups(revalidated_entries, backups) do
        case commit_db_changes(db_commit_fun) do
          :ok ->
            :ok

          {:error, reason} ->
            restore_backups(Map.keys(backups), backups)
            {:error, reason}
        end
      end
    end)
  end

  defp commit_db_changes(nil), do: :ok

  defp commit_db_changes(db_commit_fun) when is_function(db_commit_fun, 0) do
    case Repo.transaction(fn -> db_commit_fun.() end) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp with_nested_workspace_locks([], _identity_opts, fun), do: fun.()

  defp with_nested_workspace_locks([{raw_root, resources} | rest], identity_opts, fun) do
    case Process.whereis(WorkspaceLocks) do
      nil ->
        with_nested_workspace_locks(rest, identity_opts, fun)

      _pid ->
        WorkspaceLocks.with_locks(raw_root, resources, identity_opts, fn ->
          with_nested_workspace_locks(rest, identity_opts, fun)
        end)
    end
  end

  defp lock_identity_opts(entries) do
    case WorkspaceLocks.current_delegation() do
      %WorkspaceLocks{} = delegation ->
        [
          owner_id: delegation.owner_id,
          run_id: delegation.run_id,
          session_id: delegation.session_id,
          delegation: delegation,
          allow_unmanaged: true
        ]
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)

      nil ->
        seed = entries |> List.first() |> Map.get(:canonical_root, "")

        [
          owner_id:
            "timetravel:#{:erlang.phash2(seed)}:#{System.unique_integer([:positive, :monotonic])}",
          allow_unmanaged: true
        ]
    end
  end

  defp capture_backups(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn %{full_path: full_path}, {:ok, acc} ->
      if Map.has_key?(acc, full_path) do
        {:cont, {:ok, acc}}
      else
        case File.lstat(full_path) do
          {:ok, %File.Stat{type: :regular, mode: mode}} ->
            case File.read(full_path) do
              {:ok, content} -> {:cont, {:ok, Map.put(acc, full_path, {:regular, content, mode})}}
              {:error, reason} -> {:halt, {:error, {:backup_read_failed, full_path, reason}}}
            end

          {:ok, %File.Stat{type: :symlink}} ->
            case :file.read_link_all(full_path) do
              {:ok, target} ->
                {:cont, {:ok, Map.put(acc, full_path, {:symlink, List.to_string(target)})}}

              {:error, reason} ->
                {:halt, {:error, {:backup_stat_failed, full_path, reason}}}
            end

          {:ok, %File.Stat{type: other}} ->
            {:halt, {:error, {:unsupported_target_type, full_path, other}}}

          {:error, :enoent} ->
            {:cont, {:ok, Map.put(acc, full_path, :missing)}}

          {:error, reason} ->
            {:halt, {:error, {:backup_stat_failed, full_path, reason}}}
        end
      end
    end)
  end

  defp apply_entries_with_backups(entries, backups) do
    result =
      Enum.reduce_while(entries, {:ok, []}, fn %{full_path: full_path, patch: patch},
                                               {:ok, touched} ->
        file_existed = patch_field(patch, "file_existed", :file_existed, true)

        step_result =
          if file_existed == false do
            safe_remove_file(full_path)
          else
            original_content = patch_field(patch, "original_content", :original_content, "")
            atomic_write_file(full_path, original_content || "")
          end

        case step_result do
          :ok -> {:cont, {:ok, [full_path | touched]}}
          {:error, reason} -> {:halt, {:error, reason, [full_path | touched]}}
        end
      end)

    case result do
      {:ok, _touched} ->
        :ok

      {:error, reason, touched} ->
        restore_backups(touched, backups)
        {:error, reason}
    end
  end

  defp atomic_write_file(full_path, content, mode_override \\ nil) do
    dir = Path.dirname(full_path)

    tmp_path =
      Path.join(
        dir,
        ".#{Path.basename(full_path)}.timetravel-#{System.unique_integer([:positive, :monotonic])}"
      )

    try do
      mode = resolve_write_mode(full_path, mode_override)

      with :ok <- File.mkdir_p(dir),
           :ok <- File.write(tmp_path, content),
           :ok <- maybe_chmod(tmp_path, mode),
           :ok <- File.rename(tmp_path, full_path) do
        :ok
      else
        {:error, reason} -> {:error, reason}
      end
    rescue
      e -> {:error, e}
    after
      File.rm(tmp_path)
    end
  end

  defp resolve_write_mode(_full_path, m) when is_integer(m), do: m

  defp resolve_write_mode(full_path, nil) do
    case File.lstat(full_path) do
      {:ok, %File.Stat{type: :regular, mode: m}} -> m
      _ -> nil
    end
  end

  defp maybe_chmod(path, mode) when is_integer(mode) do
    File.chmod(path, Bitwise.band(mode, 0o777))
  end

  defp maybe_chmod(_path, _mode), do: :ok

  defp safe_remove_file(full_path) do
    case File.lstat(full_path) do
      {:ok, %File.Stat{type: type}} when type in [:regular, :symlink] ->
        File.rm(full_path)

      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: other}} ->
        {:error, {:unsupported_target_type, full_path, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp restore_backups(touched, backups) do
    touched
    |> Enum.uniq()
    |> Enum.each(fn full_path ->
      case Map.get(backups, full_path) do
        {:regular, content, mode} ->
          _ = atomic_write_file(full_path, content, mode)

        {:symlink, target} ->
          _ = File.rm(full_path)
          _ = File.ln_s(target, full_path)

        :missing ->
          _ = File.rm(full_path)

        _ ->
          :ok
      end
    end)
  end

  defp patch_has_key?(patch, str_key, atom_key) do
    Map.has_key?(patch, str_key) or Map.has_key?(patch, atom_key)
  end

  defp patch_field(patch, str_key, atom_key, default \\ nil) do
    cond do
      Map.has_key?(patch, str_key) -> Map.get(patch, str_key)
      Map.has_key?(patch, atom_key) -> Map.get(patch, atom_key)
      true -> default
    end
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

  @doc """
  Converts a single snapshot patch map to a standardized unified diff string.
  Handles additions (--- /dev/null), deletions (+++ /dev/null), and modifications.
  """
  @spec patch_to_unified_diff(map()) :: String.t()
  def patch_to_unified_diff(patch) when is_map(patch) do
    path = patch["path"] || patch[:path] || "file"
    file_existed = Map.get(patch, "file_existed", Map.get(patch, :file_existed, true))
    orig = patch["original_content"] || patch[:original_content]
    new_c = patch["new_content"] || patch[:new_content]

    cond do
      file_existed == false or is_nil(orig) ->
        # Newly created file
        new_lines = if is_binary(new_c), do: String.split(new_c, ~r/\r?\n/), else: []
        new_lines = trim_trailing_empty(new_lines)
        count = length(new_lines)
        hunk_lines = Enum.map(new_lines, &("+" <> &1))

        "--- /dev/null\n+++ b/#{path}\n@@ -0,0 +1,#{count} @@\n" <>
          Enum.join(hunk_lines, "\n") <> "\n"

      is_nil(new_c) ->
        # Deleted file
        orig_lines = if is_binary(orig), do: String.split(orig, ~r/\r?\n/), else: []
        orig_lines = trim_trailing_empty(orig_lines)
        count = length(orig_lines)
        hunk_lines = Enum.map(orig_lines, &("-" <> &1))

        "--- a/#{path}\n+++ /dev/null\n@@ -1,#{count} +0,0 @@\n" <>
          Enum.join(hunk_lines, "\n") <> "\n"

      orig == new_c ->
        ""

      true ->
        IexCode.Tools.MultiPatch.Diff.unified_diff(orig, new_c, path)
    end
  end

  def patch_to_unified_diff(_), do: ""

  @doc """
  Converts all patches in a checkpoint into a list of parsed diff maps for interactive rendering.
  """
  @spec checkpoint_diffs(MutationSnapshot.t() | map() | nil) :: [map()]
  def checkpoint_diffs(%{patches: patches}) when is_list(patches) do
    Enum.map(patches, fn patch ->
      path = patch["path"] || patch[:path] || "file"
      existed = Map.get(patch, "file_existed", Map.get(patch, :file_existed, true))
      diff_text = patch_to_unified_diff(patch)

      hunks =
        case IexCode.Tools.Git.DiffParser.parse(diff_text) do
          {:ok, [fd | _]} -> fd.hunks
          _ -> []
        end

      status =
        cond do
          existed == false or is_nil(patch["original_content"] || patch[:original_content]) ->
            :added

          is_nil(patch["new_content"] || patch[:new_content]) ->
            :deleted

          true ->
            :modified
        end

      %{
        path: path,
        diff_text: diff_text,
        hunks: hunks,
        status: status,
        file_existed: existed
      }
    end)
  end

  def checkpoint_diffs(_), do: []

  defp trim_trailing_empty(lines) do
    case List.last(lines) do
      "" when length(lines) > 1 -> Enum.slice(lines, 0..-2//1)
      _ -> lines
    end
  end
end
