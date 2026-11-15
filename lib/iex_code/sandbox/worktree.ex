defmodule IexCode.Sandbox.Worktree do
  @moduledoc """
  Ephemeral Git worktree sandboxing for isolated parallel coding runs.

  Creates isolated `git worktree` directories in temporary space, inspects
  working-tree + committed changes relative to the base commit, atomically
  applies validated changes back to a target workspace under `WorkspacePath`
  containment and `WorkspaceLocks`, and prunes orphaned worktree artifacts.
  """

  alias IexCode.Tools.Git
  alias IexCode.Tools.MultiPatch.Diff
  alias IexCode.{WorkspaceLocks, WorkspacePath}

  @enforce_keys [:id, :repo_root, :path, :base_ref, :base_commit]
  defstruct [
    :id,
    :repo_root,
    :path,
    :branch,
    :base_ref,
    :base_commit,
    :created_at,
    detached?: true
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          repo_root: String.t(),
          path: String.t(),
          branch: String.t() | nil,
          base_ref: String.t(),
          base_commit: String.t(),
          created_at: DateTime.t() | nil,
          detached?: boolean()
        }

  @type change_entry :: %{
          path: String.t(),
          old_path: String.t() | nil,
          status: :added | :modified | :deleted | :renamed | :copied | :untracked
        }

  @doc """
  Creates an isolated git worktree for `repo_root`.

  Options:
    * `:base_ref` - git ref or commit to base the worktree on (default `"HEAD"`)
    * `:branch` - optional branch name to create (`-b <branch>`); defaults to detached HEAD
    * `:path` - optional explicit destination path (must not already exist)
    * `:base_dir` - optional parent directory for auto-generated worktree directories
    * `:id` - optional identifier used for the worktree directory name
  """
  @spec create(Path.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def create(repo_root, opts \\ []) when is_binary(repo_root) and is_list(opts) do
    base_ref = Keyword.get(opts, :base_ref, "HEAD")
    branch = normalize_optional_binary(Keyword.get(opts, :branch))

    with {:ok, canonical_repo} <- resolve_existing_dir(repo_root),
         {:ok, toplevel} <- git_toplevel(canonical_repo),
         {:ok, base_commit} <- resolve_commit(toplevel, base_ref),
         id <- normalize_id(Keyword.get(opts, :id)),
         {:ok, wt_path} <- allocate_worktree_path(toplevel, id, opts),
         :ok <- add_worktree(toplevel, wt_path, base_commit, branch),
         {:ok, canonical_wt} <- WorkspacePath.resolve(wt_path, "") do
      {:ok,
       %__MODULE__{
         id: id,
         repo_root: toplevel,
         path: canonical_wt,
         branch: branch,
         base_ref: base_ref,
         base_commit: base_commit,
         created_at: DateTime.utc_now(),
         detached?: is_nil(branch)
       }}
    end
  end

  @doc """
  Returns structured `IexCode.Tools.Git.StatusResult` for `worktree`.
  """
  @spec status(t() | Path.t()) :: {:ok, IexCode.Tools.Git.StatusResult.t()} | {:error, term()}
  def status(worktree) do
    with {:ok, wt_path, _repo_root, _base_commit} <- extract_worktree(worktree),
         :ok <- ensure_worktree_dir(wt_path) do
      Git.status(wt_path)
    end
  end

  @doc """
  Returns unified diff text covering tracked (committed, staged, unstaged) and
  untracked changes inside `worktree`.

  Options:
    * `:stat` - when `true`, returns `git diff --stat` summary against `base_commit`
    * `:unified` - integer unified context lines
    * `:paths` - list of relative paths to filter
    * `:include_untracked` - include synthetic unified diffs for untracked files (default `true`)
  """
  @spec diff(t() | Path.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def diff(worktree, opts \\ []) when is_list(opts) do
    with {:ok, wt_path, _repo_root, base_commit} <- extract_worktree(worktree),
         :ok <- ensure_worktree_dir(wt_path) do
      base = base_commit || "HEAD"
      paths = opts |> Keyword.get(:paths, []) |> List.wrap()

      if Keyword.get(opts, :stat, false) do
        args = ["diff", "--stat", base] ++ if(paths != [], do: ["--"] ++ paths, else: [])
        Git.run_git(wt_path, args)
      else
        args = ["diff"]

        args =
          case Keyword.get(opts, :unified) do
            n when is_integer(n) and n >= 0 -> args ++ ["-U#{n}"]
            _ -> args
          end

        args = args ++ [base] ++ if(paths != [], do: ["--"] ++ paths, else: [])

        with {:ok, tracked_diff} <- Git.run_git(wt_path, args),
             {:ok, untracked_diff} <- maybe_untracked_diff(wt_path, paths, opts) do
          {:ok, combine_diffs(tracked_diff, untracked_diff)}
        end
      end
    end
  end

  @doc """
  Returns sorted unique relative file paths changed (modified, added, deleted,
  renamed, or untracked) in `worktree`.
  """
  @spec changed_files(t() | Path.t()) :: {:ok, [String.t()]} | {:error, term()}
  def changed_files(worktree) do
    with {:ok, wt_path, _repo_root, base_commit} <- extract_worktree(worktree),
         :ok <- ensure_worktree_dir(wt_path),
         {:ok, changes} <- collect_changes(wt_path, base_commit || "HEAD", true) do
      files =
        changes
        |> Enum.map(& &1.path)
        |> Enum.uniq()
        |> Enum.sort()

      {:ok, files}
    end
  end

  @doc """
  Atomically copies/applies validated relative changes from `worktree` back into
  `target_root` (defaulting to `worktree.repo_root`) under `WorkspacePath`
  containment and `WorkspaceLocks`.

  Fails closed before mutating any file in `target_root` if any path escapes
  containment via traversal or symlinks.

  Options:
    * `:paths` / `:files` - optional subset of relative paths to apply
    * `:include_untracked` - apply untracked files from `worktree` (default `true`)
    * `:cleanup` - clean up `worktree` after a successful apply (default `false`)
  """
  @spec apply_back(t() | Path.t(), Path.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def apply_back(worktree, target_root \\ nil, opts \\ []) when is_list(opts) do
    with {:ok, wt_path, repo_root, base_commit} <- extract_worktree(worktree),
         :ok <- ensure_worktree_dir(wt_path),
         {:ok, raw_target} <- resolve_target_root(target_root, repo_root),
         {:ok, canonical_wt} <- WorkspacePath.resolve(wt_path, ""),
         {:ok, canonical_target} <- resolve_existing_dir(raw_target),
         include_untracked? = Keyword.get(opts, :include_untracked, true),
         {:ok, changes} <-
           collect_changes(canonical_wt, base_commit || "HEAD", include_untracked?),
         {:ok, selected} <- filter_changes(changes, opts),
         {:ok, plan} <-
           build_apply_plan(selected, canonical_wt, canonical_target),
         {:ok, applied_summary} <-
           execute_apply_plan(plan, raw_target, canonical_target, canonical_wt) do
      if Keyword.get(opts, :cleanup, false) do
        _ = cleanup(worktree)
      end

      {:ok, applied_summary}
    end
  end

  @doc """
  Removes `worktree` and prunes its git worktree metadata. Idempotent.

  Options:
    * `:delete_branch` - delete `worktree.branch` if non-detached (default `false`)
  """
  @spec cleanup(t() | Path.t(), keyword()) :: :ok | {:error, term()}
  def cleanup(worktree, opts \\ []) when is_list(opts) do
    case extract_worktree(worktree) do
      {:ok, wt_path, repo_root, _base_commit} ->
        resolved_repo = repo_root || discover_main_repo(wt_path)

        if is_binary(resolved_repo) and File.dir?(resolved_repo) do
          _ = Git.run_git(resolved_repo, ["worktree", "remove", "--force", wt_path])
          if File.exists?(wt_path), do: File.rm_rf(wt_path)
          _ = Git.run_git(resolved_repo, ["worktree", "prune", "--expire=now"])

          if Keyword.get(opts, :delete_branch, false) and
               match?(%__MODULE__{detached?: false}, worktree) and
               is_binary(worktree.branch) do
            _ = Git.run_git(resolved_repo, ["branch", "-D", worktree.branch])
          end
        else
          if File.exists?(wt_path), do: File.rm_rf(wt_path)
        end

        :ok

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Prunes stale git worktree administrative metadata and orphaned ephemeral
  worktree directories associated with `repo_root`.

  Options:
    * `:base_dir` - override the ephemeral worktrees directory to scan
    * `:older_than_ms` - optional age threshold in milliseconds to also clean up
      registered ephemeral worktrees under the repo's worktree directory
  """
  @spec prune_orphans(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prune_orphans(repo_root, opts \\ []) when is_binary(repo_root) and is_list(opts) do
    with {:ok, canonical_repo} <- resolve_existing_dir(repo_root),
         {:ok, toplevel} <- git_toplevel(canonical_repo),
         {:ok, before_entries} <- list_porcelain_worktrees(toplevel),
         prunable_count = Enum.count(before_entries, & &1.prunable?),
         {:ok, _} <- Git.run_git(toplevel, ["worktree", "prune", "--expire=now"]),
         {:ok, after_entries} <- list_porcelain_worktrees(toplevel) do
      active_paths = MapSet.new(Enum.map(after_entries, & &1.path))
      base_dir = Keyword.get(opts, :base_dir) || default_base_dir(toplevel)
      older_than_ms = Keyword.get(opts, :older_than_ms)

      removed_dirs = prune_worktree_base_dir(base_dir, active_paths, toplevel, older_than_ms)

      {:ok,
       %{
         pruned_worktrees: prunable_count,
         removed_dirs: removed_dirs
       }}
    end
  end

  # --- Internal Helpers ---

  defp resolve_existing_dir(dir) do
    if File.dir?(dir) do
      case WorkspacePath.resolve(dir, "") do
        {:ok, canonical} -> {:ok, canonical}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_workspace}
    end
  end

  defp git_toplevel(dir) do
    case Git.run_git(dir, ["rev-parse", "--show-toplevel"]) do
      {:ok, out} ->
        toplevel = String.trim(out)
        WorkspacePath.resolve(toplevel, "")

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_commit(repo_root, ref) when is_binary(ref) and ref != "" do
    case Git.run_git(repo_root, ["rev-parse", "--verify", "#{ref}^{commit}"]) do
      {:ok, sha} -> {:ok, String.trim(sha)}
      {:error, {:git_error, _, _}} -> {:error, {:invalid_base_ref, ref}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_commit(_repo_root, ref), do: {:error, {:invalid_base_ref, ref}}

  defp allocate_worktree_path(toplevel, id, opts) do
    case Keyword.get(opts, :path) do
      explicit when is_binary(explicit) and explicit != "" ->
        expanded = Path.expand(explicit)

        if File.exists?(expanded) do
          {:error, {:worktree_path_exists, expanded}}
        else
          File.mkdir_p!(Path.dirname(expanded))
          {:ok, expanded}
        end

      nil ->
        base_dir = Keyword.get(opts, :base_dir) || default_base_dir(toplevel)
        File.mkdir_p!(base_dir)

        with {:ok, canonical_base} <- WorkspacePath.resolve(base_dir, "") do
          {:ok, Path.join(canonical_base, id)}
        end

      invalid ->
        {:error, {:invalid_worktree_path, invalid}}
    end
  end

  defp default_base_dir(toplevel) do
    repo_hash =
      :crypto.hash(:sha256, toplevel)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    Path.join([System.tmp_dir!(), "iex_code_worktrees", repo_hash])
  end

  defp add_worktree(toplevel, wt_path, base_commit, nil) do
    case Git.run_git(toplevel, ["worktree", "add", "--detach", wt_path, base_commit]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp add_worktree(toplevel, wt_path, base_commit, branch) do
    case Git.run_git(toplevel, ["worktree", "add", "-b", branch, wt_path, base_commit]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract_worktree(%__MODULE__{path: path, repo_root: repo_root, base_commit: base_commit})
       when is_binary(path) do
    {:ok, path, repo_root, base_commit}
  end

  defp extract_worktree(path) when is_binary(path) and path != "" do
    {:ok, Path.expand(path), nil, nil}
  end

  defp extract_worktree(_), do: {:error, :invalid_worktree}

  defp ensure_worktree_dir(wt_path) do
    if File.dir?(wt_path), do: :ok, else: {:error, :worktree_not_found}
  end

  defp normalize_id(id) when is_binary(id) and id != "" do
    if String.contains?(id, ["/", "\\", "..", <<0>>]) do
      "wt_#{System.unique_integer([:positive, :monotonic])}"
    else
      id
    end
  end

  defp normalize_id(_), do: "wt_#{System.unique_integer([:positive, :monotonic])}"

  defp normalize_optional_binary(val) when is_binary(val) do
    trimmed = String.trim(val)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_optional_binary(_), do: nil

  defp collect_changes(wt_path, base_commit, include_untracked?) do
    with {:ok, tracked_raw} <-
           Git.run_git(wt_path, ["diff", "--name-status", "-z", base_commit]),
         {:ok, untracked_raw} <-
           if(include_untracked?,
             do: Git.run_git(wt_path, ["ls-files", "--others", "--exclude-standard", "-z"]),
             else: {:ok, ""}
           ) do
      tracked = parse_name_status_z(tracked_raw)
      tracked_paths = MapSet.new(Enum.map(tracked, & &1.path))

      untracked =
        untracked_raw
        |> split_nul()
        |> Enum.reject(&MapSet.member?(tracked_paths, &1))
        |> Enum.map(&%{path: &1, old_path: nil, status: :untracked})

      {:ok, tracked ++ untracked}
    end
  end

  defp parse_name_status_z(raw) when is_binary(raw) do
    raw
    |> split_nul()
    |> parse_name_status_tokens([])
    |> Enum.reverse()
  end

  defp parse_name_status_tokens([], acc), do: acc

  defp parse_name_status_tokens([status_tok | rest], acc) do
    cond do
      String.starts_with?(status_tok, "R") ->
        case rest do
          [old_path, new_path | tail] ->
            entry = %{path: new_path, old_path: old_path, status: :renamed}
            parse_name_status_tokens(tail, [entry | acc])

          _ ->
            acc
        end

      String.starts_with?(status_tok, "C") ->
        case rest do
          [old_path, new_path | tail] ->
            entry = %{path: new_path, old_path: old_path, status: :copied}
            parse_name_status_tokens(tail, [entry | acc])

          _ ->
            acc
        end

      true ->
        case rest do
          [path | tail] ->
            status =
              case String.first(status_tok) do
                "A" -> :added
                "D" -> :deleted
                "M" -> :modified
                "T" -> :modified
                _ -> :modified
              end

            parse_name_status_tokens(tail, [%{path: path, old_path: nil, status: status} | acc])

          [] ->
            acc
        end
    end
  end

  defp split_nul(""), do: []

  defp split_nul(raw) do
    raw
    |> String.split(<<0>>)
    |> Enum.reject(&(&1 == ""))
  end

  defp maybe_untracked_diff(wt_path, filter_paths, opts) do
    if Keyword.get(opts, :include_untracked, true) do
      with {:ok, raw} <-
             Git.run_git(wt_path, ["ls-files", "--others", "--exclude-standard", "-z"]) do
        paths =
          raw
          |> split_nul()
          |> filter_by_paths(filter_paths)

        diffs =
          Enum.map(paths, fn rel_path ->
            build_untracked_diff(wt_path, rel_path)
          end)
          |> Enum.reject(&(&1 == ""))

        {:ok, Enum.join(diffs, "\n")}
      end
    else
      {:ok, ""}
    end
  end

  defp filter_by_paths(paths, []), do: paths

  defp filter_by_paths(paths, filter_paths) do
    filter_set = MapSet.new(filter_paths)

    Enum.filter(paths, fn p ->
      MapSet.member?(filter_set, p) or
        Enum.any?(filter_paths, &String.starts_with?(p, String.trim_trailing(&1, "/") <> "/"))
    end)
  end

  defp build_untracked_diff(wt_path, rel_path) do
    with {:ok, full_path} <- WorkspacePath.resolve(wt_path, rel_path),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(full_path),
         {:ok, content} <- File.read(full_path) do
      if String.contains?(content, <<0>>) or not String.valid?(content) do
        "diff --git a/#{rel_path} b/#{rel_path}\nnew file mode 100644\nBinary files /dev/null and b/#{rel_path} differ\n"
      else
        "diff --git a/#{rel_path} b/#{rel_path}\nnew file mode 100644\n" <>
          Diff.unified_diff("", content, rel_path)
      end
    else
      _ -> ""
    end
  end

  defp combine_diffs("", ""), do: ""
  defp combine_diffs(a, ""), do: a
  defp combine_diffs("", b), do: b

  defp combine_diffs(a, b) do
    String.trim_trailing(a, "\n") <> "\n" <> b
  end

  defp resolve_target_root(nil, repo_root) when is_binary(repo_root), do: {:ok, repo_root}
  defp resolve_target_root(nil, _repo_root), do: {:error, :target_root_required}

  defp resolve_target_root(target_root, _repo_root) when is_binary(target_root),
    do: {:ok, target_root}

  defp resolve_target_root(_target_root, _repo_root), do: {:error, :invalid_workspace}

  defp filter_changes(changes, opts) do
    requested = Keyword.get(opts, :paths) || Keyword.get(opts, :files)

    case requested do
      nil ->
        {:ok, changes}

      list when is_list(list) ->
        if Enum.all?(list, &(is_binary(&1) and &1 != "")) do
          requested_set = MapSet.new(list)

          invalid =
            Enum.find(list, fn p ->
              ".." in Path.split(p) or Path.type(p) == :absolute or String.contains?(p, <<0>>)
            end)

          if invalid do
            {:error, :outside_workspace}
          else
            {:ok, Enum.filter(changes, &MapSet.member?(requested_set, &1.path))}
          end
        else
          {:error, :invalid_path}
        end

      _ ->
        {:error, :invalid_path}
    end
  end

  defp build_apply_plan(changes, canonical_wt, canonical_target) do
    Enum.reduce_while(changes, {:ok, []}, fn change, {:ok, ops} ->
      case plan_single_change(change, canonical_wt, canonical_target) do
        {:ok, new_ops} -> {:cont, {:ok, Enum.reverse(new_ops) ++ ops}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, reversed_ops} -> {:ok, Enum.reverse(reversed_ops)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp plan_single_change(%{status: :deleted, path: rel_path}, canonical_wt, canonical_target) do
    with {:ok, _src} <- validate_contained_rel_path(canonical_wt, rel_path),
         {:ok, dst_full} <- validate_contained_rel_path(canonical_target, rel_path) do
      {:ok, [{:delete, rel_path, dst_full}]}
    end
  end

  defp plan_single_change(
         %{status: :renamed, path: new_path, old_path: old_path},
         canonical_wt,
         canonical_target
       ) do
    with {:ok, src_full} <- validate_contained_rel_path(canonical_wt, new_path),
         {:ok, dst_full} <- validate_contained_rel_path(canonical_target, new_path),
         {:ok, old_dst_full} <- validate_contained_rel_path(canonical_target, old_path),
         {:ok, content, mode} <- read_safe_regular_file(canonical_wt, src_full, new_path) do
      delete_op =
        if old_path != new_path, do: [{:delete, old_path, old_dst_full}], else: []

      {:ok, [{:write, new_path, dst_full, content, mode} | delete_op]}
    end
  end

  defp plan_single_change(%{path: rel_path}, canonical_wt, canonical_target) do
    with {:ok, src_full} <- validate_contained_rel_path(canonical_wt, rel_path),
         {:ok, dst_full} <- validate_contained_rel_path(canonical_target, rel_path),
         {:ok, content, mode} <- read_safe_regular_file(canonical_wt, src_full, rel_path) do
      {:ok, [{:write, rel_path, dst_full, content, mode}]}
    end
  end

  defp validate_contained_rel_path(canonical_root, rel_path) do
    cond do
      not is_binary(rel_path) or rel_path == "" ->
        {:error, :invalid_path}

      Path.type(rel_path) == :absolute ->
        {:error, :outside_workspace}

      true ->
        case WorkspacePath.resolve(canonical_root, rel_path) do
          {:ok, ^canonical_root} -> {:error, :invalid_path}
          {:ok, resolved} -> {:ok, resolved}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp read_safe_regular_file(canonical_wt, src_full, rel_path) do
    raw_src = Path.expand(rel_path, canonical_wt)

    case File.lstat(raw_src) do
      {:ok, %File.Stat{type: :symlink}} ->
        {:error, {:unsafe_symlink, rel_path}}

      _ ->
        case File.lstat(src_full) do
          {:ok, %File.Stat{type: :regular, mode: mode}} ->
            case File.read(src_full) do
              {:ok, content} -> {:ok, content, mode}
              {:error, reason} -> {:error, {:read_failed, rel_path, reason}}
            end

          {:ok, %File.Stat{type: :symlink}} ->
            {:error, {:unsafe_symlink, rel_path}}

          {:ok, %File.Stat{type: other}} ->
            {:error, {:unsupported_file_type, rel_path, other}}

          {:error, reason} ->
            {:error, {:stat_failed, rel_path, reason}}
        end
    end
  end

  defp execute_apply_plan([], _raw_target, canonical_target, canonical_wt) do
    {:ok,
     %{
       applied_files: [],
       deleted_files: [],
       target_root: canonical_target,
       worktree: canonical_wt
     }}
  end

  defp execute_apply_plan(plan, raw_target, canonical_target, canonical_wt) do
    resources =
      plan
      |> Enum.map(fn
        {:write, rel_path, _dst, _content, _mode} -> rel_path
        {:delete, rel_path, _dst} -> rel_path
      end)
      |> Enum.uniq()
      |> Enum.map(&{{:file, &1}, :write})

    identity_opts = lock_identity_opts(canonical_wt)

    with_workspace_locks(raw_target, resources, identity_opts, fn ->
      apply_plan_transactional(plan, canonical_target, canonical_wt)
    end)
  end

  defp lock_identity_opts(canonical_wt) do
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
        [
          owner_id:
            "worktree:#{:erlang.phash2(canonical_wt)}:#{System.unique_integer([:positive, :monotonic])}",
          allow_unmanaged: true
        ]
    end
  end

  defp with_workspace_locks(raw_target, resources, identity_opts, fun) do
    case Process.whereis(WorkspaceLocks) do
      nil -> fun.()
      _pid -> WorkspaceLocks.with_locks(raw_target, resources, identity_opts, fun)
    end
  end

  defp apply_plan_transactional(plan, canonical_target, canonical_wt) do
    # Re-verify containment under lock to close TOCTOU symlink races.
    with :ok <- reverify_plan_under_lock(plan, canonical_target),
         {:ok, backups} <- capture_target_backups(plan) do
      do_apply_ops(plan, backups, canonical_target, canonical_wt)
    end
  end

  defp reverify_plan_under_lock(plan, canonical_target) do
    Enum.reduce_while(plan, :ok, fn op, :ok ->
      rel_path = elem(op, 1)

      case validate_contained_rel_path(canonical_target, rel_path) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp capture_target_backups(plan) do
    Enum.reduce_while(plan, {:ok, %{}}, fn op, {:ok, acc} ->
      dst_full = elem(op, 2)

      if Map.has_key?(acc, dst_full) do
        {:cont, {:ok, acc}}
      else
        case File.lstat(dst_full) do
          {:ok, %File.Stat{type: :regular, mode: mode}} ->
            case File.read(dst_full) do
              {:ok, content} -> {:cont, {:ok, Map.put(acc, dst_full, {:regular, content, mode})}}
              {:error, reason} -> {:halt, {:error, {:backup_read_failed, dst_full, reason}}}
            end

          {:ok, %File.Stat{type: :symlink}} ->
            {:halt, {:error, :outside_workspace}}

          {:ok, %File.Stat{type: other}} ->
            {:halt, {:error, {:unsupported_target_type, dst_full, other}}}

          {:error, :enoent} ->
            {:cont, {:ok, Map.put(acc, dst_full, :missing)}}

          {:error, reason} ->
            {:halt, {:error, {:backup_stat_failed, dst_full, reason}}}
        end
      end
    end)
  end

  defp do_apply_ops(plan, backups, canonical_target, canonical_wt) do
    result =
      Enum.reduce_while(plan, {:ok, [], [], []}, fn
        {:write, rel_path, dst_full, content, mode}, {:ok, written, deleted, touched} ->
          case atomic_write_file(dst_full, content, mode) do
            :ok -> {:cont, {:ok, [rel_path | written], deleted, [dst_full | touched]}}
            {:error, reason} -> {:halt, {:error, reason, touched}}
          end

        {:delete, rel_path, dst_full}, {:ok, written, deleted, touched} ->
          case safe_remove_file(dst_full) do
            {:ok, true} -> {:cont, {:ok, written, [rel_path | deleted], [dst_full | touched]}}
            {:ok, false} -> {:cont, {:ok, written, deleted, touched}}
            {:error, reason} -> {:halt, {:error, reason, touched}}
          end
      end)

    case result do
      {:ok, written, deleted, _touched} ->
        {:ok,
         %{
           applied_files: Enum.reverse(written),
           deleted_files: Enum.reverse(deleted),
           target_root: canonical_target,
           worktree: canonical_wt
         }}

      {:error, reason, touched} ->
        restore_backups(touched, backups)
        {:error, reason}
    end
  end

  defp atomic_write_file(dst_full, content, mode) do
    dir = Path.dirname(dst_full)
    File.mkdir_p!(dir)

    tmp_path =
      Path.join(
        dir,
        ".#{Path.basename(dst_full)}.wt-#{System.unique_integer([:positive, :monotonic])}"
      )

    try do
      with :ok <- File.write(tmp_path, content),
           :ok <- maybe_chmod(tmp_path, mode),
           :ok <- File.rename(tmp_path, dst_full) do
        :ok
      else
        {:error, reason} -> {:error, reason}
      end
    rescue
      exception -> {:error, exception}
    after
      File.rm(tmp_path)
    end
  end

  defp maybe_chmod(path, mode) when is_integer(mode) do
    File.chmod(path, Bitwise.band(mode, 0o777))
  end

  defp maybe_chmod(_path, _mode), do: :ok

  defp safe_remove_file(dst_full) do
    case File.lstat(dst_full) do
      {:ok, %File.Stat{type: :regular}} ->
        case File.rm(dst_full) do
          :ok -> {:ok, true}
          {:error, reason} -> {:error, reason}
        end

      {:error, :enoent} ->
        {:ok, false}

      {:ok, %File.Stat{type: other}} ->
        {:error, {:unsupported_target_type, dst_full, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp restore_backups(touched, backups) do
    touched
    |> Enum.uniq()
    |> Enum.each(fn dst_full ->
      case Map.get(backups, dst_full) do
        {:regular, content, mode} ->
          _ = atomic_write_file(dst_full, content, mode)

        :missing ->
          _ = File.rm(dst_full)

        _ ->
          :ok
      end
    end)
  end

  defp discover_main_repo(wt_path) do
    if File.dir?(wt_path) do
      case Git.run_git(wt_path, ["worktree", "list", "--porcelain"]) do
        {:ok, out} ->
          out
          |> parse_porcelain_worktrees()
          |> List.first()
          |> case do
            %{path: main_path} -> main_path
            _ -> nil
          end

        _ ->
          nil
      end
    end
  end

  defp list_porcelain_worktrees(repo_root) do
    with {:ok, out} <- Git.run_git(repo_root, ["worktree", "list", "--porcelain"]) do
      {:ok, parse_porcelain_worktrees(out)}
    end
  end

  defp parse_porcelain_worktrees(output) do
    output
    |> String.split(~r/\r?\n\r?\n/, trim: true)
    |> Enum.map(fn block ->
      lines = String.split(block, ~r/\r?\n/, trim: true)

      path =
        Enum.find_value(lines, fn
          "worktree " <> p -> canonical_or_expand(p)
          _ -> nil
        end)

      prunable? = Enum.any?(lines, &String.starts_with?(&1, "prunable"))
      %{path: path, prunable?: prunable?}
    end)
    |> Enum.reject(&is_nil(&1.path))
  end

  defp canonical_or_expand(path) do
    case WorkspacePath.resolve(path, "") do
      {:ok, canonical} -> canonical
      {:error, _} -> Path.expand(path)
    end
  end

  defp prune_worktree_base_dir(base_dir, active_paths, toplevel, older_than_ms) do
    if File.dir?(base_dir) do
      now_sec = System.os_time(:second)

      removed =
        base_dir
        |> File.ls!()
        |> Enum.reduce([], fn entry, acc ->
          full_entry = Path.join(base_dir, entry)
          canonical_entry = canonical_or_expand(full_entry)

          cond do
            not MapSet.member?(active_paths, canonical_entry) ->
              _ = File.rm_rf(full_entry)
              [canonical_entry | acc]

            is_integer(older_than_ms) and older_than_ms >= 0 and
                entry_expired?(full_entry, now_sec, older_than_ms) ->
              _ =
                cleanup(%__MODULE__{
                  id: entry,
                  repo_root: toplevel,
                  path: canonical_entry,
                  base_ref: "HEAD",
                  base_commit: "HEAD"
                })

              [canonical_entry | acc]

            true ->
              acc
          end
        end)
        |> Enum.reverse()

      case File.ls(base_dir) do
        {:ok, []} -> _ = File.rmdir(base_dir)
        _ -> :ok
      end

      removed
    else
      []
    end
  end

  defp entry_expired?(path, now_sec, older_than_ms) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} ->
        age_ms = max(now_sec - mtime, 0) * 1_000
        age_ms >= older_than_ms

      _ ->
        false
    end
  end
end
