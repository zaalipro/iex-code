defmodule IexCode.Tools.TestSelector do
  @moduledoc """
  Smart incremental ExUnit test selector.

  Resolves a bounded, deterministically ranked list of `test/**/*_test.exs`
  targets from explicit `:changed_files` or workspace Git status/diff +
  untracked files across three tiers:

    1. Direct modified `*_test.exs` files (`:direct`)
    2. Path-convention mirrors from `lib/.../<name>.ex` (`:mirror`)
    3. Reverse module reference graph from `defmodule` names in changed `.ex`
       files to `test/**/*_test.exs` references (`:reference`)
  """

  alias IexCode.WorkspacePath

  @default_max_targets 25
  @max_file_bytes 512_000
  @excluded_dirs MapSet.new(~w(_build deps .git node_modules))

  @type reason_tier :: :direct | :mirror | :reference

  @type selection :: %{
          paths: [String.t()],
          changed_files: [String.t()],
          reasons: %{String.t() => reason_tier()},
          modules: [String.t()],
          truncated?: boolean()
        }

  @doc """
  Selects ranked `test/**/*_test.exs` targets for `project_root`.

  Options:
    * `:changed_files` - explicit list (or single string) of changed paths
      relative to `project_root` (or inside it); when provided (non-`nil`),
      Git inspection is skipped.
    * `:max_targets` - maximum number of selected test files to return
      (default `#{@default_max_targets}`).
  """
  @spec select(Path.t(), keyword()) :: {:ok, selection()} | {:error, term()}
  def select(project_root, opts \\ []) when is_binary(project_root) and is_list(opts) do
    max_targets =
      opts
      |> Keyword.get(:max_targets, Keyword.get(opts, :limit, @default_max_targets))
      |> normalize_max_targets()

    with {:ok, canonical_root} <- WorkspacePath.resolve(project_root, "."),
         {:ok, changed_files} <- resolve_changed_files(canonical_root, opts) do
      all_test_files = list_test_files(canonical_root)
      test_file_set = MapSet.new(all_test_files)

      direct = select_direct(changed_files, test_file_set)
      direct_set = MapSet.new(direct)

      mirrors = select_mirrors(changed_files, all_test_files, direct_set)
      mirror_set = MapSet.union(direct_set, MapSet.new(mirrors))

      modules = extract_changed_modules(canonical_root, changed_files)
      references = select_references(canonical_root, all_test_files, mirror_set, modules)

      ranked =
        Enum.map(direct, &{&1, :direct}) ++
          Enum.map(mirrors, &{&1, :mirror}) ++
          Enum.map(references, &{&1, :reference})

      bounded = Enum.take(ranked, max_targets)
      paths = Enum.map(bounded, &elem(&1, 0))
      reasons = Map.new(bounded)

      {:ok,
       %{
         paths: paths,
         changed_files: changed_files,
         reasons: reasons,
         modules: modules,
         truncated?: length(ranked) > max_targets
       }}
    end
  end

  defp normalize_max_targets(n) when is_integer(n) and n > 0, do: n
  defp normalize_max_targets(_), do: @default_max_targets

  defp resolve_changed_files(canonical_root, opts) do
    if Keyword.has_key?(opts, :changed_files) and Keyword.get(opts, :changed_files) != nil do
      raw = opts |> Keyword.get(:changed_files) |> List.wrap()
      {:ok, normalize_workspace_paths(canonical_root, raw)}
    else
      git_changed_files(canonical_root)
    end
  end

  defp git_changed_files(canonical_root) do
    case System.cmd("git", ["rev-parse", "--is-inside-work-tree"],
           cd: canonical_root,
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        if String.trim(out) == "true" do
          case System.cmd("git", ["status", "--porcelain=v1", "-z", "-uall"],
                 cd: canonical_root,
                 stderr_to_stdout: true
               ) do
            {status_out, 0} ->
              raw_paths = parse_porcelain_z(status_out)
              {:ok, normalize_workspace_paths(canonical_root, raw_paths)}

            {_err, _code} ->
              {:error, :git_status_failed}
          end
        else
          {:error, :not_a_git_repository}
        end

      {_err, _code} ->
        {:error, :not_a_git_repository}
    end
  rescue
    _ -> {:error, :git_unavailable}
  end

  # In `git status --porcelain=v1 -z`, entries are NUL-terminated `XY path`.
  # Renames/copies (`R`/`C`) carry a second NUL-terminated original path right after.
  defp parse_porcelain_z(output) when is_binary(output) do
    output
    |> :binary.split(<<0>>, [:global])
    |> consume_porcelain_tokens([])
    |> Enum.reverse()
  end

  defp consume_porcelain_tokens([], acc), do: acc
  defp consume_porcelain_tokens(["" | rest], acc), do: consume_porcelain_tokens(rest, acc)

  defp consume_porcelain_tokens([<<x, y, ?\s, path::binary>> | rest], acc) do
    rest_after =
      if x in [?R, ?C] or y in [?R, ?C] do
        case rest do
          [_orig | tail] -> tail
          [] -> []
        end
      else
        rest
      end

    consume_porcelain_tokens(rest_after, [path | acc])
  end

  defp consume_porcelain_tokens([_other | rest], acc), do: consume_porcelain_tokens(rest, acc)

  defp normalize_workspace_paths(canonical_root, paths) do
    paths
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(fn raw ->
      trimmed = String.trim(raw)

      if trimmed == "" do
        []
      else
        case WorkspacePath.resolve(canonical_root, trimmed) do
          {:ok, resolved} ->
            rel = Path.relative_to(resolved, canonical_root)

            if rel == "." or excluded_rel_path?(rel) do
              []
            else
              [rel]
            end

          {:error, _} ->
            []
        end
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp excluded_rel_path?(rel) do
    rel
    |> Path.split()
    |> Enum.any?(&MapSet.member?(@excluded_dirs, &1))
  end

  defp list_test_files(canonical_root) do
    test_root = Path.join(canonical_root, "test")

    if File.dir?(test_root) do
      Path.wildcard(Path.join(test_root, "**/*_test.exs"))
      |> Enum.flat_map(fn candidate ->
        with {:ok, resolved} <- WorkspacePath.resolve(canonical_root, candidate),
             true <- File.regular?(resolved),
             rel <- Path.relative_to(resolved, canonical_root),
             false <- excluded_rel_path?(rel) do
          [rel]
        else
          _ -> []
        end
      end)
      |> Enum.uniq()
      |> Enum.sort()
    else
      []
    end
  end

  # Tier 1: Direct modified `*_test.exs` files inside `test/`.
  defp select_direct(changed_files, test_file_set) do
    changed_files
    |> Enum.filter(&MapSet.member?(test_file_set, &1))
    |> Enum.sort()
  end

  # Tier 2: Path-convention mirrors from `lib/.../<stem>.ex`.
  defp select_mirrors(changed_files, all_test_files, already_selected) do
    candidates =
      Enum.flat_map(changed_files, fn path ->
        case lib_mirror_specs(path) do
          nil -> []
          spec -> match_mirror_specs(spec, all_test_files)
        end
      end)

    exact =
      candidates
      |> Enum.filter(fn {tier, _path} -> tier == :exact end)
      |> Enum.map(&elem(&1, 1))
      |> Enum.uniq()
      |> Enum.sort()

    sibling =
      candidates
      |> Enum.filter(fn {tier, _path} -> tier == :sibling end)
      |> Enum.map(&elem(&1, 1))
      |> Enum.uniq()
      |> Enum.sort()

    subdir =
      candidates
      |> Enum.filter(fn {tier, _path} -> tier == :subdir end)
      |> Enum.map(&elem(&1, 1))
      |> Enum.uniq()
      |> Enum.sort()

    (exact ++ sibling ++ subdir)
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(already_selected, &1))
  end

  defp lib_mirror_specs(path) do
    if String.starts_with?(path, "lib/") and String.ends_with?(path, ".ex") do
      rel_inside_lib = String.replace_prefix(path, "lib/", "")
      dir = Path.dirname(rel_inside_lib)
      stem = Path.basename(rel_inside_lib, ".ex")

      test_dir =
        case dir do
          "." -> "test"
          sub -> Path.join("test", sub)
        end

      %{
        exact_path: Path.join(test_dir, "#{stem}_test.exs"),
        test_dir: test_dir,
        stem: stem,
        subdir_prefix: Path.join(test_dir, stem) <> "/"
      }
    else
      nil
    end
  end

  defp match_mirror_specs(spec, all_test_files) do
    sibling_prefix = "#{spec.stem}_"

    Enum.flat_map(all_test_files, fn test_path ->
      cond do
        test_path == spec.exact_path ->
          [{:exact, test_path}]

        Path.dirname(test_path) == spec.test_dir and
          String.starts_with?(Path.basename(test_path), sibling_prefix) and
            String.ends_with?(test_path, "_test.exs") ->
          [{:sibling, test_path}]

        String.starts_with?(test_path, spec.subdir_prefix) ->
          [{:subdir, test_path}]

        true ->
          []
      end
    end)
  end

  # Tier 3: Reverse module reference graph.
  defp extract_changed_modules(canonical_root, changed_files) do
    changed_files
    |> Enum.filter(&String.ends_with?(&1, ".ex"))
    |> Enum.flat_map(fn rel_path ->
      with {:ok, full_path} <- WorkspacePath.resolve(canonical_root, rel_path),
           {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_file_bytes <-
             File.stat(full_path),
           {:ok, content} <- File.read(full_path) do
        extract_defmodules(content)
      else
        _ -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc false
  @spec extract_defmodules(String.t()) :: [String.t()]
  def extract_defmodules(content) when is_binary(content) do
    case Code.string_to_quoted(content) do
      {:ok, ast} ->
        {_, modules} = collect_ast_defmodules(ast, [], [])
        modules |> Enum.uniq() |> Enum.sort()

      {:error, _} ->
        Regex.scan(~r/^\s*defmodule\s+([A-Z][A-Za-z0-9_.]*)\b/m, content)
        |> Enum.map(fn [_, mod] -> mod end)
        |> Enum.uniq()
        |> Enum.sort()
    end
  end

  defp collect_ast_defmodules({:defmodule, _meta, [alias_ast | rest]}, prefix, acc) do
    case extract_alias_segments(alias_ast) do
      {:ok, segments} ->
        full_segments = prefix ++ segments
        full_name = Enum.join(full_segments, ".")
        {_, nested_acc} = collect_ast_defmodules(rest, full_segments, [full_name | acc])
        {nil, nested_acc}

      :error ->
        collect_ast_defmodules(rest, prefix, acc)
    end
  end

  defp collect_ast_defmodules({left, _meta, right}, prefix, acc) do
    {_, acc1} = collect_ast_defmodules(left, prefix, acc)
    collect_ast_defmodules(right, prefix, acc1)
  end

  defp collect_ast_defmodules({left, right}, prefix, acc) do
    {_, acc1} = collect_ast_defmodules(left, prefix, acc)
    collect_ast_defmodules(right, prefix, acc1)
  end

  defp collect_ast_defmodules(list, prefix, acc) when is_list(list) do
    Enum.reduce(list, {nil, acc}, fn item, {_, cur_acc} ->
      collect_ast_defmodules(item, prefix, cur_acc)
    end)
  end

  defp collect_ast_defmodules(_other, _prefix, acc), do: {nil, acc}

  defp extract_alias_segments({:__aliases__, _meta, parts}) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1) do
      {:ok, Enum.map(parts, &Atom.to_string/1)}
    else
      :error
    end
  end

  defp extract_alias_segments(_), do: :error

  defp select_references(_canonical_root, _all_test_files, _already_selected, []), do: []

  defp select_references(canonical_root, all_test_files, already_selected, modules) do
    match_targets = build_module_match_targets(modules)

    all_test_files
    |> Enum.reject(&MapSet.member?(already_selected, &1))
    |> Enum.flat_map(fn test_rel ->
      case score_test_file_references(canonical_root, test_rel, match_targets) do
        0 -> []
        score -> [{score, test_rel}]
      end
    end)
    |> Enum.sort_by(fn {score, path} -> {-score, path} end)
    |> Enum.map(&elem(&1, 1))
  end

  defp build_module_match_targets(modules) do
    Enum.map(modules, fn full_name ->
      segments = String.split(full_name, ".")
      short = List.last(segments)

      suffixes =
        if length(segments) >= 2 do
          1..(length(segments) - 1)
          |> Enum.map(fn drop_n ->
            segments |> Enum.drop(drop_n) |> Enum.join(".")
          end)
          |> Enum.filter(&String.contains?(&1, "."))
        else
          []
        end

      %{
        full: full_name,
        suffixes: suffixes,
        short: short
      }
    end)
  end

  defp score_test_file_references(canonical_root, test_rel, match_targets) do
    with {:ok, full_path} <- WorkspacePath.resolve(canonical_root, test_rel),
         {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_file_bytes <-
           File.stat(full_path),
         {:ok, content} <- File.read(full_path) do
      case extract_test_aliases(content) do
        {:ast, alias_set} ->
          score_against_alias_set(alias_set, match_targets)

        {:regex, text} ->
          score_against_text(text, match_targets)
      end
    else
      _ -> 0
    end
  end

  defp extract_test_aliases(content) do
    case Code.string_to_quoted(content) do
      {:ok, ast} ->
        {_, aliases} = collect_test_aliases(ast, MapSet.new())
        {:ast, aliases}

      {:error, _} ->
        {:regex, content}
    end
  end

  defp collect_test_aliases({:defmodule, _meta, [_mod_name | body]}, acc) do
    collect_test_aliases(body, acc)
  end

  defp collect_test_aliases({:__aliases__, _meta, parts}, acc) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1) do
      name = Enum.map_join(parts, ".", &Atom.to_string/1)
      {nil, MapSet.put(acc, name)}
    else
      {nil, acc}
    end
  end

  defp collect_test_aliases({left, _meta, right}, acc) do
    {_, acc1} = collect_test_aliases(left, acc)
    collect_test_aliases(right, acc1)
  end

  defp collect_test_aliases({left, right}, acc) do
    {_, acc1} = collect_test_aliases(left, acc)
    collect_test_aliases(right, acc1)
  end

  defp collect_test_aliases(list, acc) when is_list(list) do
    Enum.reduce(list, {nil, acc}, fn item, {_, cur_acc} ->
      collect_test_aliases(item, cur_acc)
    end)
  end

  defp collect_test_aliases(_other, acc), do: {nil, acc}

  defp score_against_alias_set(alias_set, match_targets) do
    Enum.reduce(match_targets, 0, fn target, score ->
      cond do
        MapSet.member?(alias_set, target.full) ->
          score + 10

        Enum.any?(target.suffixes, &MapSet.member?(alias_set, &1)) ->
          score + 5

        MapSet.member?(alias_set, target.short) ->
          score + 1

        true ->
          score
      end
    end)
  end

  defp score_against_text(text, match_targets) do
    Enum.reduce(match_targets, 0, fn target, score ->
      cond do
        Regex.match?(~r/(?<![.\w])#{Regex.escape(target.full)}(?![.\w])/, text) ->
          score + 10

        Enum.any?(target.suffixes, fn suf ->
          Regex.match?(~r/(?<![.\w])#{Regex.escape(suf)}(?![.\w])/, text)
        end) ->
          score + 5

        Regex.match?(~r/(?<![.\w])#{Regex.escape(target.short)}(?![\w])/, text) ->
          score + 1

        true ->
          score
      end
    end)
  end
end
