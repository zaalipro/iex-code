defmodule IexCode.Tools.TestSelector do
  @moduledoc """
  Smart incremental test selector for Elixir and polyglot codebases.

  Resolves a bounded, deterministically ranked list of test targets
  (`test/**/*_test.exs`, JS/TS `*.test.*` / `*.spec.*` / `__tests__/*`,
  Python `test_*.py` / `*_test.py`, Go `*_test.go`, and Rust `tests/*.rs`)
  from explicit `:changed_files` or workspace Git status/diff + untracked
  files across three tiers:

    1. Direct modified test files (`:direct`)
    2. Path-convention mirrors (`:mirror`):
       - Elixir: `lib/.../<name>.ex` -> `test/.../<name>_test.exs`
       - TS/JS: `foo.ts` -> `foo.test.ts` / `foo.spec.ts` / `__tests__/foo.test.ts`
       - Python: `foo.py` -> `test_foo.py` / `foo_test.py`
       - Go: `foo.go` -> `foo_test.go`
       - Rust: `foo.rs` -> `tests/foo.rs`
    3. Reverse module/import reference graph (`:reference`)
  """

  alias IexCode.WorkspacePath

  @default_max_targets 25
  @max_file_bytes 512_000
  @excluded_dirs MapSet.new(~w(_build deps .git node_modules target __pycache__ .venv))
  @js_ts_extensions ~w(.ts .tsx .js .jsx .mjs .cjs)

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

      references =
        select_references(canonical_root, all_test_files, mirror_set, modules, changed_files)

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
    canonical_root
    |> walk_test_files(canonical_root, [])
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp walk_test_files(dir, canonical_root, acc) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.reduce(names, acc, fn name, inner_acc ->
          full_path = Path.join(dir, name)
          collect_test_entry(name, full_path, canonical_root, inner_acc)
        end)

      {:error, _} ->
        acc
    end
  end

  defp collect_test_entry(name, full_path, canonical_root, acc) do
    case File.lstat(full_path) do
      {:ok, %File.Stat{type: :symlink}} ->
        acc

      {:ok, %File.Stat{type: :directory}} ->
        if MapSet.member?(@excluded_dirs, name) do
          acc
        else
          walk_test_files(full_path, canonical_root, acc)
        end

      {:ok, %File.Stat{type: :regular}} ->
        rel = Path.relative_to(full_path, canonical_root)

        if not excluded_rel_path?(rel) and test_file?(rel) do
          [rel | acc]
        else
          acc
        end

      _ ->
        acc
    end
  end

  @doc false
  @spec test_file?(String.t()) :: boolean()
  def test_file?(rel) when is_binary(rel) do
    ext = rel |> Path.extname() |> String.downcase()
    base = Path.basename(rel)
    parts = Path.split(Path.dirname(rel))

    cond do
      String.starts_with?(rel, "test/") and String.ends_with?(rel, "_test.exs") ->
        true

      ext in @js_ts_extensions ->
        stem = Path.basename(rel, ext)

        String.ends_with?(stem, ".test") or String.ends_with?(stem, ".spec") or
          "__tests__" in parts

      ext == ".py" ->
        stem = Path.basename(rel, ".py")
        String.starts_with?(base, "test_") or String.ends_with?(stem, "_test")

      ext == ".go" ->
        String.ends_with?(base, "_test.go")

      ext == ".rs" ->
        "tests" in parts

      true ->
        false
    end
  end

  @doc false
  @spec paired_tests_for(String.t(), [String.t()]) :: [String.t()]
  def paired_tests_for(source_path, all_test_files)
      when is_binary(source_path) and is_list(all_test_files) do
    if test_file?(source_path) do
      []
    else
      select_mirrors([source_path], all_test_files, MapSet.new())
    end
  end

  # Tier 1: Direct modified test files.
  defp select_direct(changed_files, test_file_set) do
    changed_files
    |> Enum.filter(&MapSet.member?(test_file_set, &1))
    |> Enum.sort()
  end

  # Tier 2: Path-convention mirrors for Elixir and polyglot source files.
  defp select_mirrors(changed_files, all_test_files, already_selected) do
    candidates =
      Enum.flat_map(changed_files, fn path ->
        elixir_matches =
          case lib_mirror_specs(path) do
            nil -> []
            spec -> match_mirror_specs(spec, all_test_files)
          end

        polyglot_matches =
          if test_file?(path) do
            []
          else
            match_polyglot_mirrors(path, all_test_files)
          end

        elixir_matches ++ polyglot_matches
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

  defp match_polyglot_mirrors(path, all_test_files) do
    ext = path |> Path.extname() |> String.downcase()
    dir = Path.dirname(path)
    stem = Path.basename(path, ext)

    cond do
      ext in @js_ts_extensions ->
        match_js_ts_mirrors(dir, stem, ext, all_test_files)

      ext == ".py" ->
        match_python_mirrors(dir, stem, all_test_files)

      ext == ".go" ->
        match_go_mirrors(dir, stem, all_test_files)

      ext == ".rs" ->
        match_rust_mirrors(dir, stem, all_test_files)

      true ->
        []
    end
  end

  defp match_js_ts_mirrors(dir, stem, ext, all_test_files) do
    same_dir_exact =
      MapSet.new(
        for suffix <- [".test", ".spec"], e <- [ext | @js_ts_extensions] do
          join_rel(dir, "#{stem}#{suffix}#{e}")
        end ++
          for test_dir <- [join_rel(dir, "__tests__")],
              name <- ["#{stem}.test", "#{stem}.spec", stem],
              e <- [ext | @js_ts_extensions] do
            join_rel(test_dir, "#{name}#{e}")
          end
      )

    sub_dir = strip_source_prefix(dir)

    mirrored_sibling =
      MapSet.new(
        for root_dir <- ["__tests__", "tests", "test"],
            rel_dir <- Enum.uniq([dir, sub_dir]),
            target_dir = join_rel(root_dir, rel_dir),
            name <- ["#{stem}.test", "#{stem}.spec", stem],
            e <- [ext | @js_ts_extensions] do
          join_rel(target_dir, "#{name}#{e}")
        end ++
          for root_dir <- ["__tests__", "tests", "test"],
              name <- ["#{stem}.test", "#{stem}.spec", stem],
              e <- [ext | @js_ts_extensions] do
            join_rel(root_dir, "#{name}#{e}")
          end
      )

    Enum.flat_map(all_test_files, fn test_path ->
      cond do
        MapSet.member?(same_dir_exact, test_path) -> [{:exact, test_path}]
        MapSet.member?(mirrored_sibling, test_path) -> [{:sibling, test_path}]
        true -> []
      end
    end)
  end

  defp match_python_mirrors(dir, stem, all_test_files) do
    exact_names = ["test_#{stem}.py", "#{stem}_test.py"]

    same_dir_exact =
      MapSet.new(
        for(name <- exact_names, do: join_rel(dir, name)) ++
          for(
            sub <- ["tests", "test"],
            name <- exact_names,
            do: join_rel(join_rel(dir, sub), name)
          )
      )

    sub_dir = strip_source_prefix(dir)

    mirrored_sibling =
      MapSet.new(
        for root_dir <- ["tests", "test"],
            rel_dir <- Enum.uniq([dir, sub_dir]),
            target_dir = join_rel(root_dir, rel_dir),
            name <- exact_names do
          join_rel(target_dir, name)
        end ++
          for root_dir <- ["tests", "test"], name <- exact_names do
            join_rel(root_dir, name)
          end
      )

    Enum.flat_map(all_test_files, fn test_path ->
      cond do
        MapSet.member?(same_dir_exact, test_path) -> [{:exact, test_path}]
        MapSet.member?(mirrored_sibling, test_path) -> [{:sibling, test_path}]
        true -> []
      end
    end)
  end

  defp match_go_mirrors(dir, stem, all_test_files) do
    exact_path = join_rel(dir, "#{stem}_test.go")

    Enum.flat_map(all_test_files, fn test_path ->
      if test_path == exact_path, do: [{:exact, test_path}], else: []
    end)
  end

  defp match_rust_mirrors(dir, stem, all_test_files) do
    {crate_root, sub_inside_src} = split_rust_src_root(dir)

    exact_paths =
      MapSet.new(
        [
          join_rel(crate_root, "tests/#{stem}.rs"),
          join_rel(crate_root, "tests/#{stem}_test.rs"),
          "tests/#{stem}.rs",
          "tests/#{stem}_test.rs"
        ] ++
          if sub_inside_src != "." do
            [
              join_rel(crate_root, "tests/#{sub_inside_src}/#{stem}.rs"),
              "tests/#{sub_inside_src}/#{stem}.rs"
            ]
          else
            []
          end
      )

    subdir_prefixes =
      [
        join_rel(crate_root, "tests/#{stem}") <> "/",
        "tests/#{stem}/"
      ]
      |> Enum.uniq()

    Enum.flat_map(all_test_files, fn test_path ->
      cond do
        MapSet.member?(exact_paths, test_path) ->
          [{:exact, test_path}]

        Enum.any?(subdir_prefixes, &String.starts_with?(test_path, &1)) ->
          [{:subdir, test_path}]

        true ->
          []
      end
    end)
  end

  defp split_rust_src_root("."), do: {".", "."}

  defp split_rust_src_root(dir) do
    parts = Path.split(dir)

    case Enum.find_index(parts, &(&1 == "src")) do
      nil ->
        {dir, "."}

      idx ->
        crate_parts = Enum.take(parts, idx)
        sub_parts = Enum.drop(parts, idx + 1)
        crate_root = if crate_parts == [], do: ".", else: Path.join(crate_parts)
        sub_dir = if sub_parts == [], do: ".", else: Path.join(sub_parts)
        {crate_root, sub_dir}
    end
  end

  defp strip_source_prefix("."), do: "."

  defp strip_source_prefix(dir) do
    case Path.split(dir) do
      [head | rest] when head in ["src", "lib", "app"] ->
        if rest == [], do: ".", else: Path.join(rest)

      _ ->
        dir
    end
  end

  defp join_rel(".", child), do: child
  defp join_rel("", child), do: child
  defp join_rel(dir, "."), do: dir
  defp join_rel(dir, child), do: Path.join(dir, child)

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

  defp select_references(canonical_root, all_test_files, already_selected, modules, changed_files) do
    elixir_targets = build_module_match_targets(modules)
    polyglot_targets = build_polyglot_targets(changed_files)

    if elixir_targets == [] and polyglot_targets == [] do
      []
    else
      all_test_files
      |> Enum.reject(&MapSet.member?(already_selected, &1))
      |> Enum.flat_map(fn test_rel ->
        score =
          if String.ends_with?(test_rel, ".exs") do
            if elixir_targets == [],
              do: 0,
              else: score_test_file_references(canonical_root, test_rel, elixir_targets)
          else
            if polyglot_targets == [],
              do: 0,
              else: score_polyglot_references(canonical_root, test_rel, polyglot_targets)
          end

        if score > 0, do: [{score, test_rel}], else: []
      end)
      |> Enum.sort_by(fn {score, path} -> {-score, path} end)
      |> Enum.map(&elem(&1, 1))
    end
  end

  defp build_polyglot_targets(changed_files) do
    generic_stems = MapSet.new(~w(index mod lib main __init__))

    changed_files
    |> Enum.reject(
      &(String.ends_with?(&1, ".ex") or String.ends_with?(&1, ".exs") or test_file?(&1))
    )
    |> Enum.flat_map(fn path ->
      ext = path |> Path.extname() |> String.downcase()
      stem = Path.basename(path, ext)

      if ext in ([".py", ".go", ".rs"] ++ @js_ts_extensions) and String.length(stem) >= 3 and
           not MapSet.member?(generic_stems, stem) do
        [%{stem: stem, no_ext: Path.rootname(path)}]
      else
        []
      end
    end)
  end

  defp score_polyglot_references(canonical_root, test_rel, targets) do
    with {:ok, full_path} <- WorkspacePath.resolve(canonical_root, test_rel),
         {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_file_bytes <-
           File.stat(full_path),
         {:ok, content} <- File.read(full_path) do
      import_lines =
        content
        |> String.split(~r/\r?\n/)
        |> Enum.filter(&Regex.match?(~r/\b(import|from|require|use|mod)\b/, &1))
        |> Enum.join("\n")

      if import_lines == "" do
        0
      else
        Enum.reduce(targets, 0, fn target, acc ->
          cond do
            Regex.match?(
              ~r/(?<![\w])#{Regex.escape(target.no_ext)}(?![\w])/,
              import_lines
            ) ->
              acc + 10

            Regex.match?(~r/(?<![\w])#{Regex.escape(target.stem)}(?![\w])/, import_lines) ->
              acc + 5

            true ->
              acc
          end
        end)
      end
    else
      _ -> 0
    end
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
