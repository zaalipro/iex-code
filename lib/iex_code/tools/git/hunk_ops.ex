defmodule IexCode.Tools.Git.HunkOps do
  @moduledoc """
  Granular diff hunk management and file reversion engine.

  Provides capabilities to:
  - Accept individual hunks (stage to Git index or apply to working tree)
  - Reject individual hunks (reverse/discard hunk changes from working tree)
  - Revert entire files (discard all unstaged and staged changes)
  - Accept or reject all hunks in a file
  - Seamlessly integrate with `IexCode.Tools.Git` and `IexCode.Tools.MultiPatch`
  """

  alias IexCode.Tools.Git
  alias IexCode.Tools.Git.DiffParser
  alias IexCode.Tools.MultiPatch

  @doc """
  Accepts a specific hunk.
  In a Git repository with unstaged changes, staging the hunk moves it into the Git index.
  In `:apply_to_file` mode or patch workflow, applies the hunk to the working copy.

  ## Options
  - `:diff` - Raw diff string if already computed
  - `:mode` - `:stage` (default) or `:apply_to_file`
  - `:staged` - Boolean, whether to look in staged diff
  """
  @spec accept_hunk(Path.t(), Path.t(), String.t() | integer(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def accept_hunk(project_root, file_path, hunk_id, opts \\ []) do
    with {:ok, {file_diff, hunk}} <- find_target_hunk(project_root, file_path, hunk_id, opts) do
      mode = Keyword.get(opts, :mode, :stage)

      case mode do
        :stage ->
          stage_hunk(project_root, file_path, file_diff, hunk)

        :apply_to_file ->
          apply_hunk_to_file(project_root, file_path, file_diff, hunk)
      end
    end
  end

  @doc """
  Rejects / discards changes in a specific hunk from the working tree.
  """
  @spec reject_hunk(Path.t(), Path.t(), String.t() | integer(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def reject_hunk(project_root, file_path, hunk_id, opts \\ []) do
    with {:ok, {file_diff, hunk}} <- find_target_hunk(project_root, file_path, hunk_id, opts) do
      patch_str = DiffParser.format_hunk_patch(file_diff, hunk)

      # Attempt Git reverse apply
      case Git.apply_patch(project_root, patch_str, reverse: true) do
        {:ok, _output} ->
          fetch_updated_diff(project_root, file_path)

        {:error, reason} ->
          # Fallback to in-memory replacement on the file
          case fallback_revert_hunk_in_file(project_root, file_path, hunk) do
            :ok -> fetch_updated_diff(project_root, file_path)
            {:error, _} -> {:error, reason}
          end
      end
    end
  end

  @doc """
  Reverts a specific hunk. Alias for `reject_hunk/4`.
  """
  defdelegate revert_hunk(project_root, file_path, hunk_id, opts \\ []),
    to: __MODULE__,
    as: :reject_hunk

  @doc """
  Reverts all changes to a specific file (staged and unstaged), restoring the HEAD revision.
  If the file is untracked (newly created), it is safely removed from disk.
  """
  @spec revert_file(Path.t(), Path.t()) :: {:ok, :reverted} | {:error, term()}
  def revert_file(project_root, file_path) do
    full_path = resolve_file_path(project_root, file_path)

    # Check git status first
    case Git.status(project_root) do
      {:ok, status} ->
        is_untracked = file_path in status.untracked

        if is_untracked do
          if File.exists?(full_path) do
            File.rm(full_path)
          end

          {:ok, :reverted}
        else
          case Git.restore_file(project_root, file_path, staged: true, worktree: true) do
            {:ok, _} ->
              {:ok, :reverted}

            {:error, _} ->
              # Fallback: run git checkout HEAD -- <file>
              case Git.run_git(project_root, ["checkout", "HEAD", "--", file_path]) do
                {:ok, _} -> {:ok, :reverted}
                err -> err
              end
          end
        end

      {:error, :not_a_git_repo} ->
        # Non-git workspace fallback
        if File.exists?(full_path) do
          File.rm(full_path)
        end

        {:ok, :reverted}

      err ->
        err
    end
  end

  @doc """
  Accepts all hunks for a given file by staging the file.
  """
  @spec accept_all_hunks(Path.t(), Path.t()) :: {:ok, :accepted} | {:error, term()}
  def accept_all_hunks(project_root, file_path) do
    case Git.stage(file_path, project_root) do
      :ok -> {:ok, :accepted}
      err -> err
    end
  end

  @doc """
  Rejects all hunks for a given file. Alias for `revert_file/2`.
  """
  defdelegate reject_all_hunks(project_root, file_path), to: __MODULE__, as: :revert_file

  # --- Internal Helpers ---

  defp find_target_hunk(project_root, file_path, hunk_id, opts) do
    diff_text =
      case Keyword.get(opts, :diff) do
        d when is_binary(d) and d != "" ->
          d

        _ ->
          staged = Keyword.get(opts, :staged, false)

          case Git.diff(project_root, paths: [file_path], staged: staged) do
            {:ok, output} -> output
            _ -> ""
          end
      end

    if String.trim(diff_text) == "" do
      {:error, :no_diff_found}
    else
      with {:ok, file_diffs} <- DiffParser.parse(diff_text) do
        normalized_path = normalize_rel_path(file_path)

        # Filter file diff matching file_path
        target_file_diff =
          Enum.find(file_diffs, fn fd ->
            normalize_rel_path(fd.path) == normalized_path or
              normalize_rel_path(fd.new_path) == normalized_path or
              normalize_rel_path(fd.old_path) == normalized_path
          end) || List.first(file_diffs)

        if is_nil(target_file_diff) do
          {:error, {:file_diff_not_found, file_path}}
        else
          case DiffParser.find_hunk(target_file_diff, hunk_id) do
            {:ok, {fd, hunk}} -> {:ok, {fd, hunk}}
            {:error, _} -> {:error, {:hunk_not_found, hunk_id}}
          end
        end
      end
    end
  end

  defp stage_hunk(project_root, file_path, file_diff, hunk) do
    patch_str = DiffParser.format_hunk_patch(file_diff, hunk)

    case Git.apply_patch(project_root, patch_str, cached: true) do
      {:ok, _output} ->
        fetch_updated_diff(project_root, file_path)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_hunk_to_file(project_root, file_path, file_diff, hunk) do
    patch_str = DiffParser.format_hunk_patch(file_diff, hunk)

    case Git.apply_patch(project_root, patch_str) do
      {:ok, _output} ->
        fetch_updated_diff(project_root, file_path)

      {:error, _reason} ->
        case fallback_apply_hunk_in_file(project_root, file_path, hunk) do
          :ok -> fetch_updated_diff(project_root, file_path)
          {:error, err} -> {:error, err}
        end
    end
  end

  defp fetch_updated_diff(project_root, file_path) do
    case Git.diff(project_root, paths: [file_path]) do
      {:ok, remaining_diff} -> {:ok, remaining_diff}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fallback_revert_hunk_in_file(project_root, file_path, hunk) do
    full_path = resolve_file_path(project_root, file_path)

    if not File.exists?(full_path) do
      {:error, :file_not_found}
    else
      content = File.read!(full_path)

      target =
        hunk.lines
        |> Enum.filter(&(&1.type in [:context, :addition]))
        |> Enum.map(& &1.content)
        |> Enum.join("\n")

      replacement =
        hunk.lines
        |> Enum.filter(&(&1.type in [:context, :deletion]))
        |> Enum.map(& &1.content)
        |> Enum.join("\n")

      if target == "" or target == content do
        File.write!(full_path, replacement)
        :ok
      else
        case MultiPatch.patch_string(content, target, replacement, allow_multiple: false) do
          {:ok, %{content: new_content}} ->
            File.write!(full_path, new_content)
            :ok

          {:error, _} ->
            {:error, :fallback_revert_failed}
        end
      end
    end
  end

  defp fallback_apply_hunk_in_file(project_root, file_path, hunk) do
    full_path = resolve_file_path(project_root, file_path)

    if not File.exists?(full_path) do
      {:error, :file_not_found}
    else
      content = File.read!(full_path)

      target =
        hunk.lines
        |> Enum.filter(&(&1.type in [:context, :deletion]))
        |> Enum.map(& &1.content)
        |> Enum.join("\n")

      replacement =
        hunk.lines
        |> Enum.filter(&(&1.type in [:context, :addition]))
        |> Enum.map(& &1.content)
        |> Enum.join("\n")

      case MultiPatch.patch_string(content, target, replacement, allow_multiple: false) do
        {:ok, %{content: new_content}} ->
          File.write!(full_path, new_content)
          :ok

        {:error, _} ->
          {:error, :fallback_apply_failed}
      end
    end
  end

  defp normalize_rel_path(nil), do: ""

  defp normalize_rel_path(path) do
    path
    |> String.trim_leading("./")
    |> String.trim_leading("/")
  end

  defp resolve_file_path(project_root, path) do
    if Path.type(path) == :absolute do
      path
    else
      Path.expand(Path.join(project_root, path))
    end
  end
end
