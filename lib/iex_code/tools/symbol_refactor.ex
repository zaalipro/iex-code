defmodule IexCode.Tools.SymbolRefactor do
  @moduledoc """
  LSP-grade Elixir symbol navigation and safe multi-file refactoring engine.

  Provides AST-accurate `find_references/3` and `rename_symbol/4` across a
  workspace while respecting `IexCode.WorkspacePath` containment, skipping
  symlinks escaping root and oversized files, resolving lexical `alias` /
  multi-alias / `:as` scopes and `import` directives, ignoring occurrences
  inside comments, string literals, and heredocs, and validating transformed
  syntax with `Code.string_to_quoted/2` before atomic disk writes.
  """

  alias IexCode.Tools.MultiPatch.Diff
  alias IexCode.WorkspacePath

  require Logger

  @default_max_file_bytes 1_048_576
  @excluded_dir_names MapSet.new(["_build", "deps", "node_modules", ".git", ".agents"])
  @elixir_extensions [".ex", ".exs"]

  @non_call_special_forms MapSet.new([
                            :__MODULE__,
                            :__ENV__,
                            :__DIR__,
                            :__CALLER__,
                            :__STACKTRACE__,
                            :__aliases__,
                            :__block__,
                            :%{},
                            :{},
                            :<<>>,
                            :fn,
                            :->,
                            :&,
                            :|>,
                            :=,
                            :^,
                            :"::",
                            :when
                          ])

  @type reference_kind ::
          :definition
          | :alias
          | :import
          | :require
          | :use
          | :struct
          | :call
          | :capture
          | :spec_or_type
          | :module_ref

  @type reference_entry :: %{
          file: String.t(),
          line: pos_integer(),
          column: pos_integer(),
          kind: reference_kind(),
          snippet: String.t()
        }

  @type symbol_spec ::
          String.t()
          | module()
          | {String.t() | module(), String.t() | atom()}
          | {String.t() | module(), String.t() | atom(), non_neg_integer() | :any}
          | map()

  @doc """
  Finds all AST-verified references to `symbol_spec` across `.ex` and `.exs` files
  within `root_path`.

  Never matches occurrences inside `#` comments, string literals, sigils, or heredocs.
  Resolves lexical `alias Foo.Bar`, `alias Foo.{Bar, Baz}`, and `alias Foo.Bar, as: Custom`.
  """
  @spec find_references(Path.t(), symbol_spec(), keyword()) ::
          {:ok, [reference_entry()]} | {:error, term()}
  def find_references(root_path, symbol_spec, opts \\ []) when is_list(opts) do
    max_file_bytes = normalize_max_file_bytes(Keyword.get(opts, :max_file_bytes))
    sub_path = Keyword.get(opts, :path) || Keyword.get(opts, :sub_path) || "."
    limit = Keyword.get(opts, :limit)

    with {:ok, target} <- parse_symbol_spec(symbol_spec),
         {:ok, canonical_root, files} <-
           collect_workspace_files(root_path, sub_path, max_file_bytes) do
      refs =
        files
        |> Enum.flat_map(fn {full_path, rel_path} ->
          case read_bounded_file(full_path, max_file_bytes) do
            {:ok, source} ->
              analyze_file_references(source, rel_path, target)

            :skip ->
              []
          end
        end)
        |> Enum.uniq_by(fn r -> {r.file, r.line, r.column, r.kind} end)
        |> Enum.sort_by(fn r -> {r.file, r.line, r.column} end)

      refs =
        if is_integer(limit) and limit > 0 do
          Enum.take(refs, limit)
        else
          refs
        end

      _ = canonical_root
      {:ok, refs}
    end
  end

  @doc """
  Safely renames a module or function/macro symbol across all `.ex` and `.exs` files
  within `root_path`.

  Options:
    * `:dry_run` - when `true`, computes diffs and change counts without writing files (default `false`).
    * `:path` / `:sub_path` - optional relative directory/file inside `root_path` (default `"."`).
    * `:max_file_bytes` - skips files larger than this limit (default `#{@default_max_file_bytes}`).
  """
  @spec rename_symbol(Path.t(), symbol_spec(), String.t() | atom(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def rename_symbol(root_path, from_spec, to_name, opts \\ []) when is_list(opts) do
    dry_run? = Keyword.get(opts, :dry_run, false) == true
    max_file_bytes = normalize_max_file_bytes(Keyword.get(opts, :max_file_bytes))
    sub_path = Keyword.get(opts, :path) || Keyword.get(opts, :sub_path) || "."

    with {:ok, target} <- parse_symbol_spec(from_spec),
         {:ok, rename_target} <- parse_rename_target(target, to_name),
         {:ok, canonical_root, files} <-
           collect_workspace_files(root_path, sub_path, max_file_bytes),
         {:ok, planned_files} <-
           plan_workspace_renames(files, target, rename_target, max_file_bytes),
         :ok <- validate_all_transformed_syntax(planned_files, target, rename_target) do
      combined_diff =
        planned_files
        |> Enum.map(& &1.diff)
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")

      changes =
        Enum.map(planned_files, fn plan ->
          %{
            file: plan.rel_path,
            occurrences: plan.occurrences,
            diff: plan.diff
          }
        end)

      total_occurrences = Enum.reduce(planned_files, 0, fn p, sum -> sum + p.occurrences end)

      if dry_run? do
        {:ok,
         %{
           dry_run: true,
           files_changed: length(planned_files),
           occurrences: total_occurrences,
           diff: combined_diff,
           changes: changes
         }}
      else
        case commit_planned_files_atomically(canonical_root, planned_files) do
          :ok ->
            {:ok,
             %{
               dry_run: false,
               files_changed: length(planned_files),
               occurrences: total_occurrences,
               diff: combined_diff,
               changes: changes,
               files: Enum.map(planned_files, & &1.rel_path)
             }}

          {:error, _reason} = err ->
            err
        end
      end
    end
  end

  @doc """
  Formats reference entries as structured `file:line:column [kind] snippet` lines.
  """
  @spec format_references([reference_entry()], keyword()) :: String.t()
  def format_references(entries, opts \\ [])
  def format_references([], _opts), do: "No symbol references found."

  def format_references(entries, opts) when is_list(entries) do
    limit = Keyword.get(opts, :limit, 200)
    {shown, hidden} = Enum.split(entries, limit)

    body =
      Enum.map_join(shown, "\n", fn ref ->
        "#{ref.file}:#{ref.line}:#{ref.column} [#{ref.kind}] #{ref.snippet}"
      end)

    case hidden do
      [] -> body
      _ -> body <> "\n... (#{length(hidden)} more references omitted)"
    end
  end

  # ===========================================================================
  # Symbol & Target Parsing (zero String.to_atom/1 on user input)
  # ===========================================================================

  defp parse_symbol_spec(mod_atom)
       when is_atom(mod_atom) and mod_atom not in [nil, true, false] do
    raw = Atom.to_string(mod_atom)

    if String.starts_with?(raw, "Elixir.") do
      mod_name = String.replace_prefix(raw, "Elixir.", "")

      if valid_module_name?(mod_name) do
        {:ok, {:module, mod_name}}
      else
        {:error, {:invalid_symbol_spec, mod_atom}}
      end
    else
      {:error, {:invalid_symbol_spec, mod_atom}}
    end
  end

  defp parse_symbol_spec({:module, mod}) do
    with {:ok, mod_str} <- normalize_module_spec(mod) do
      {:ok, {:module, mod_str}}
    else
      _ -> {:error, {:invalid_symbol_spec, {:module, mod}}}
    end
  end

  defp parse_symbol_spec({mod, fun}) do
    parse_symbol_spec({mod, fun, :any})
  end

  defp parse_symbol_spec({mod, fun, arity}) do
    with {:ok, mod_str} <- normalize_module_spec(mod),
         {:ok, fun_str} <- normalize_function_spec(fun),
         {:ok, norm_arity} <- normalize_arity_spec(arity) do
      {:ok, {:function, mod_str, fun_str, norm_arity}}
    else
      _ -> {:error, {:invalid_symbol_spec, {mod, fun, arity}}}
    end
  end

  defp parse_symbol_spec(%{} = map) do
    cond do
      is_binary(Map.get(map, :symbol) || Map.get(map, "symbol")) ->
        parse_symbol_spec(Map.get(map, :symbol) || Map.get(map, "symbol"))

      (Map.get(map, :function) || Map.get(map, "function")) != nil ->
        mod = Map.get(map, :module) || Map.get(map, "module")
        fun = Map.get(map, :function) || Map.get(map, "function")
        arity = Map.get(map, :arity, Map.get(map, "arity", :any))
        parse_symbol_spec({mod, fun, arity})

      (Map.get(map, :module) || Map.get(map, "module")) != nil ->
        parse_symbol_spec({:module, Map.get(map, :module) || Map.get(map, "module")})

      true ->
        {:error, {:invalid_symbol_spec, map}}
    end
  end

  defp parse_symbol_spec(spec_str) when is_binary(spec_str) do
    trimmed = spec_str |> String.trim() |> String.replace_prefix("Elixir.", "")

    cond do
      trimmed == "" ->
        {:error, {:invalid_symbol_spec, spec_str}}

      String.contains?(trimmed, "/") ->
        case String.split(trimmed, "/") do
          [qualified, arity_str] ->
            parts = String.split(qualified, ".")

            if length(parts) >= 2 do
              mod_parts = Enum.slice(parts, 0..-2//1)
              fun_part = List.last(parts)

              with true <- Enum.all?(mod_parts, &valid_module_segment?/1),
                   true <- valid_function_name?(fun_part),
                   {:ok, arity} <- normalize_arity_spec(arity_str) do
                {:ok, {:function, Enum.join(mod_parts, "."), fun_part, arity}}
              else
                _ -> {:error, {:invalid_symbol_spec, spec_str}}
              end
            else
              {:error, {:invalid_symbol_spec, spec_str}}
            end

          _ ->
            {:error, {:invalid_symbol_spec, spec_str}}
        end

      true ->
        parts = String.split(trimmed, ".")

        cond do
          Enum.all?(parts, &valid_module_segment?/1) ->
            {:ok, {:module, Enum.join(parts, ".")}}

          length(parts) >= 2 ->
            mod_parts = Enum.slice(parts, 0..-2//1)
            fun_part = List.last(parts)

            if Enum.all?(mod_parts, &valid_module_segment?/1) and valid_function_name?(fun_part) do
              {:ok, {:function, Enum.join(mod_parts, "."), fun_part, :any}}
            else
              {:error, {:invalid_symbol_spec, spec_str}}
            end

          true ->
            {:error, {:invalid_symbol_spec, spec_str}}
        end
    end
  end

  defp parse_symbol_spec(other), do: {:error, {:invalid_symbol_spec, other}}

  defp normalize_module_spec(mod) when is_atom(mod) and mod not in [nil, true, false] do
    raw = Atom.to_string(mod)

    if String.starts_with?(raw, "Elixir.") do
      name = String.replace_prefix(raw, "Elixir.", "")
      if valid_module_name?(name), do: {:ok, name}, else: :error
    else
      :error
    end
  end

  defp normalize_module_spec(mod) when is_binary(mod) do
    name = mod |> String.trim() |> String.replace_prefix("Elixir.", "")
    if valid_module_name?(name), do: {:ok, name}, else: :error
  end

  defp normalize_module_spec(_), do: :error

  defp normalize_function_spec(fun) when is_atom(fun) and fun not in [nil, true, false] do
    name = Atom.to_string(fun)
    if valid_function_name?(name), do: {:ok, name}, else: :error
  end

  defp normalize_function_spec(fun) when is_binary(fun) do
    name = String.trim(fun)
    if valid_function_name?(name), do: {:ok, name}, else: :error
  end

  defp normalize_function_spec(_), do: :error

  defp normalize_arity_spec(:any), do: {:ok, :any}
  defp normalize_arity_spec(nil), do: {:ok, :any}
  defp normalize_arity_spec("*"), do: {:ok, :any}
  defp normalize_arity_spec("any"), do: {:ok, :any}
  defp normalize_arity_spec(n) when is_integer(n) and n >= 0, do: {:ok, n}

  defp normalize_arity_spec(bin) when is_binary(bin) do
    case Integer.parse(String.trim(bin)) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp normalize_arity_spec(_), do: :error

  defp valid_module_name?(name) when is_binary(name) and name != "" do
    parts = String.split(name, ".")
    parts != [] and Enum.all?(parts, &valid_module_segment?/1)
  end

  defp valid_module_name?(_), do: false

  defp valid_module_segment?(seg) when is_binary(seg) do
    Regex.match?(~r/\A[A-Z][a-zA-Z0-9_]*\z/, seg)
  end

  defp valid_function_name?(name) when is_binary(name) do
    Regex.match?(~r/\A[a-z_][a-zA-Z0-9_]*[?!]?\z/, name)
  end

  defp parse_rename_target({:module, _from_mod}, to_name) do
    raw =
      cond do
        is_atom(to_name) and to_name not in [nil, true, false] ->
          Atom.to_string(to_name)

        is_binary(to_name) ->
          String.trim(to_name)

        true ->
          nil
      end

    cond do
      is_nil(raw) or raw == "" or String.contains?(raw, [<<0>>, "\n", "\r"]) ->
        {:error, {:invalid_target_name, to_name}}

      is_atom(to_name) and not String.starts_with?(raw, "Elixir.") ->
        {:error, {:invalid_target_name, to_name}}

      true ->
        cleaned = String.replace_prefix(raw, "Elixir.", "")
        segments = String.split(cleaned, ".")

        cond do
          cleaned == "" or Enum.any?(segments, &(&1 == "")) ->
            {:error, {:invalid_target_name, to_name}}

          # Reject lowercase variable-like names up front because `defmodule foo`
          # parses as a variable macro call in Elixir AST.
          Enum.any?(segments, &Regex.match?(~r/\A[a-z_]/, &1)) ->
            {:error, {:invalid_target_name, to_name}}

          true ->
            {:ok, {:module_target, cleaned}}
        end
    end
  end

  defp parse_rename_target({:function, from_mod, _from_fun, from_arity}, to_name) do
    raw =
      cond do
        is_atom(to_name) and to_name not in [nil, true, false] ->
          str = Atom.to_string(to_name)
          if String.starts_with?(str, "Elixir."), do: nil, else: str

        is_binary(to_name) ->
          String.trim(to_name)

        true ->
          nil
      end

    cond do
      is_nil(raw) or raw == "" or String.contains?(raw, [<<0>>, "\n", "\r"]) ->
        {:error, {:invalid_target_name, to_name}}

      true ->
        stripped =
          raw
          |> String.replace_prefix("Elixir.", "")
          |> maybe_strip_same_module_prefix(from_mod, from_arity)

        case stripped do
          {:ok, candidate} ->
            if Regex.match?(~r/\A[A-Z]/, candidate) do
              {:error, {:invalid_target_name, to_name}}
            else
              {:ok, {:function_target, candidate}}
            end

          :error ->
            {:error, {:invalid_target_name, to_name}}
        end
    end
  end

  defp maybe_strip_same_module_prefix(str, from_mod, from_arity) do
    prefix = from_mod <> "."

    cond do
      String.starts_with?(str, prefix) ->
        rest = String.replace_prefix(str, prefix, "")

        case String.split(rest, "/") do
          [fun_part] ->
            if String.contains?(fun_part, "."), do: :error, else: {:ok, fun_part}

          [fun_part, arity_str] ->
            case normalize_arity_spec(arity_str) do
              {:ok, ^from_arity} -> {:ok, fun_part}
              {:ok, _} when from_arity == :any -> {:ok, fun_part}
              _ -> :error
            end

          _ ->
            :error
        end

      String.contains?(str, ".") ->
        :error

      true ->
        {:ok, str}
    end
  end

  # ===========================================================================
  # Safe Workspace File Walking
  # ===========================================================================

  defp collect_workspace_files(root_path, sub_path, max_file_bytes) do
    target_rel = if sub_path in [nil, ""], do: ".", else: sub_path

    with {:ok, canonical_root} <- WorkspacePath.resolve(root_path, "."),
         {:ok, canonical_target} <- WorkspacePath.resolve(canonical_root, target_rel) do
      if File.exists?(canonical_target) do
        files =
          canonical_target
          |> walk_target(canonical_root, max_file_bytes)
          |> Enum.sort_by(fn {_full, rel} -> rel end)

        {:ok, canonical_root, files}
      else
        {:error, :path_not_found}
      end
    end
  end

  defp walk_target(canonical_target, canonical_root, max_file_bytes) do
    case File.lstat(canonical_target) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        if size <= max_file_bytes and elixir_file?(canonical_target) do
          [{canonical_target, relative_to_root(canonical_target, canonical_root)}]
        else
          []
        end

      {:ok, %File.Stat{type: :directory}} ->
        initial_dirs =
          case canonical_dir_key(canonical_target) do
            {:ok, key} -> MapSet.new([key])
            :error -> MapSet.new()
          end

        {acc, _seen_files} =
          walk_dir(
            canonical_target,
            canonical_root,
            max_file_bytes,
            initial_dirs,
            MapSet.new(),
            []
          )

        acc

      _ ->
        []
    end
  end

  defp walk_dir(dir, canonical_root, max_file_bytes, visited_dirs, seen_files, acc) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.reduce({acc, seen_files}, fn name, {acc_in, seen_in} ->
          entry_path = Path.join(dir, name)

          walk_entry(
            name,
            entry_path,
            canonical_root,
            max_file_bytes,
            visited_dirs,
            seen_in,
            acc_in
          )
        end)

      {:error, _} ->
        {acc, seen_files}
    end
  end

  defp walk_entry(
         name,
         entry_path,
         canonical_root,
         max_file_bytes,
         visited_dirs,
         seen_files,
         acc
       ) do
    case File.lstat(entry_path) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        if size <= max_file_bytes and elixir_file?(name) and
             not MapSet.member?(seen_files, entry_path) do
          rel = relative_to_root(entry_path, canonical_root)
          {[{entry_path, rel} | acc], MapSet.put(seen_files, entry_path)}
        else
          {acc, seen_files}
        end

      {:ok, %File.Stat{type: :directory}} ->
        if MapSet.member?(@excluded_dir_names, name) do
          {acc, seen_files}
        else
          case canonical_dir_key(entry_path) do
            {:ok, key} ->
              if MapSet.member?(visited_dirs, key) do
                {acc, seen_files}
              else
                walk_dir(
                  entry_path,
                  canonical_root,
                  max_file_bytes,
                  MapSet.put(visited_dirs, key),
                  seen_files,
                  acc
                )
              end

            :error ->
              {acc, seen_files}
          end
        end

      {:ok, %File.Stat{type: :symlink}} ->
        case WorkspacePath.resolve(canonical_root, entry_path) do
          {:ok, resolved} ->
            if inside_excluded_dir?(resolved, canonical_root) do
              {acc, seen_files}
            else
              case File.stat(resolved) do
                {:ok, %File.Stat{type: :regular, size: size}} ->
                  if size <= max_file_bytes and elixir_file?(resolved) and
                       not MapSet.member?(seen_files, resolved) do
                    rel = relative_to_root(resolved, canonical_root)
                    {[{resolved, rel} | acc], MapSet.put(seen_files, resolved)}
                  else
                    {acc, seen_files}
                  end

                {:ok, %File.Stat{type: :directory}} ->
                  if MapSet.member?(@excluded_dir_names, name) do
                    {acc, seen_files}
                  else
                    case canonical_dir_key(resolved) do
                      {:ok, key} ->
                        if MapSet.member?(visited_dirs, key) do
                          {acc, seen_files}
                        else
                          walk_dir(
                            resolved,
                            canonical_root,
                            max_file_bytes,
                            MapSet.put(visited_dirs, key),
                            seen_files,
                            acc
                          )
                        end

                      :error ->
                        {acc, seen_files}
                    end
                  end

                _ ->
                  {acc, seen_files}
              end
            end

          {:error, _reason} ->
            {acc, seen_files}
        end

      _ ->
        {acc, seen_files}
    end
  end

  defp inside_excluded_dir?(path, canonical_root) do
    rel = Path.relative_to(path, canonical_root)

    rel
    |> Path.split()
    |> Enum.any?(&MapSet.member?(@excluded_dir_names, &1))
  end

  defp relative_to_root(path, canonical_root) do
    root = String.trim_trailing(canonical_root, "/")

    cond do
      path == root -> Path.basename(path)
      String.starts_with?(path, root <> "/") -> Path.relative_to(path, root)
      true -> path
    end
  end

  defp canonical_dir_key(dir_path) do
    case File.stat(dir_path) do
      {:ok, %File.Stat{major_device: dev, inode: ino}} when ino != 0 -> {:ok, {dev, ino}}
      {:ok, _} -> {:ok, Path.expand(dir_path)}
      {:error, _} -> :error
    end
  end

  defp elixir_file?(path), do: Path.extname(path) in @elixir_extensions

  defp normalize_max_file_bytes(bytes) when is_integer(bytes) and bytes > 0, do: bytes
  defp normalize_max_file_bytes(_), do: @default_max_file_bytes

  defp read_bounded_file(full_path, max_file_bytes) do
    case File.stat(full_path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= max_file_bytes ->
        case File.read(full_path) do
          {:ok, content} when byte_size(content) <= max_file_bytes ->
            if String.valid?(content), do: {:ok, content}, else: :skip

          _ ->
            :skip
        end

      _ ->
        :skip
    end
  end

  # ===========================================================================
  # AST + Tokenizer Analysis Engine
  # ===========================================================================

  defp analyze_file_references(source, rel_path, target) do
    case parse_source(source, rel_path) do
      {:ok, ast, tokens, line_index} ->
        ctx = %{
          file: rel_path,
          target: target,
          rename_target: nil,
          tokens: tokens,
          line_index: line_index
        }

        {_env, occurrences} = walk_ast(ast, initial_env(), ctx, [])

        occurrences
        |> Enum.reverse()
        |> Enum.map(fn occ ->
          %{
            file: rel_path,
            line: occ.line,
            column: occ.column,
            kind: occ.kind,
            snippet: occ.snippet
          }
        end)

      :skip ->
        []
    end
  end

  defp plan_workspace_renames(files, target, rename_target, max_file_bytes) do
    plans =
      Enum.flat_map(files, fn {full_path, rel_path} ->
        case File.stat(full_path) do
          {:ok, %File.Stat{type: :regular, size: size} = stat} when size <= max_file_bytes ->
            case File.read(full_path) do
              {:ok, source} when byte_size(source) <= max_file_bytes ->
                if String.valid?(source) do
                  case transform_file_source(source, rel_path, target, rename_target) do
                    {:changed, new_source, edit_count} when new_source != source ->
                      diff = Diff.unified_diff(source, new_source, rel_path)

                      [
                        %{
                          full_path: full_path,
                          rel_path: rel_path,
                          original_content: source,
                          new_content: new_source,
                          occurrences: edit_count,
                          diff: diff,
                          stat: %{size: stat.size, mtime: stat.mtime, mode: stat.mode}
                        }
                      ]

                    _unchanged ->
                      []
                  end
                else
                  []
                end

              _ ->
                []
            end

          _ ->
            []
        end
      end)

    {:ok, plans}
  end

  defp transform_file_source(source, rel_path, target, rename_target) do
    case parse_source(source, rel_path) do
      {:ok, ast, tokens, line_index} ->
        ctx = %{
          file: rel_path,
          target: target,
          rename_target: rename_target,
          tokens: tokens,
          line_index: line_index
        }

        {_env, occurrences} = walk_ast(ast, initial_env(), ctx, [])

        edits =
          occurrences
          |> Enum.reverse()
          |> Enum.flat_map(fn occ -> List.wrap(occ.edit) end)
          |> resolve_byte_edits(source, line_index)

        case edits do
          [] ->
            :unchanged

          valid_edits ->
            new_source = apply_byte_edits(source, valid_edits)
            {:changed, new_source, length(valid_edits)}
        end

      :skip ->
        :unchanged
    end
  end

  defp parse_source(source, rel_path) do
    case Code.string_to_quoted_with_comments(source,
           columns: true,
           token_metadata: true,
           emit_warnings: false,
           file: rel_path
         ) do
      {:ok, ast, _comments} ->
        tokens = tokenize_safely(source)
        line_index = build_line_index(source)
        {:ok, ast, tokens, line_index}

      {:error, _reason} ->
        :skip
    end
  rescue
    _ -> :skip
  end

  defp tokenize_safely(source) do
    case :elixir_tokenizer.tokenize(String.to_charlist(source), 1, 1, emit_warnings: false) do
      {:ok, _line, _col, _warnings, rev_tokens, _terminators} ->
        Enum.reverse(rev_tokens)

      {:ok, _line, _col, _warnings, rev_tokens} ->
        Enum.reverse(rev_tokens)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp initial_env do
    %{
      module_stack: [],
      aliases: %{},
      imports: [],
      bound_vars: MapSet.new(),
      local_zero_arity: MapSet.new(),
      in_typespec?: false,
      in_capture?: false,
      pipe_arity: 0
    }
  end

  defp current_module(%{module_stack: [cur | _]}), do: cur
  defp current_module(_), do: nil

  defp reset_expr_flags(env) do
    %{env | in_capture?: false, pipe_arity: 0}
  end

  # ===========================================================================
  # Recursive Scope-Aware AST Walker
  # ===========================================================================

  # Sequential block: threads lexical aliases, imports, and bound variables forward.
  defp walk_ast({:__block__, _meta, exprs}, env, ctx, acc) when is_list(exprs) do
    base_env = reset_expr_flags(env)

    Enum.reduce(exprs, {base_env, acc}, fn expr, {cur_env, cur_acc} ->
      walk_ast(expr, cur_env, ctx, cur_acc)
    end)
  end

  # Module / Protocol definition
  defp walk_ast({def_kind, _meta, [mod_ast | rest]}, env, ctx, acc)
       when def_kind in [:defmodule, :defprotocol] do
    parent_mod = current_module(env)
    {full_mod, short_child, acc} = handle_module_definition(mod_ast, parent_mod, env, ctx, acc)

    zero_arity_defs = scan_module_zero_arity_defs(rest)

    inner_env = %{
      env
      | module_stack: [full_mod | env.module_stack],
        bound_vars: MapSet.new(),
        local_zero_arity: zero_arity_defs,
        in_typespec?: false,
        in_capture?: false,
        pipe_arity: 0
    }

    {_inner_after, acc} = walk_list(rest, inner_env, ctx, acc)

    # Defining nested `defmodule Child` inside `Parent` implicitly aliases `Child` in `Parent`.
    outer_after =
      if is_binary(parent_mod) and is_binary(short_child) and short_child != "" do
        put_in(env.aliases[short_child], %{full: full_mod, explicit_as?: false})
      else
        env
      end

    {outer_after, acc}
  end

  # Protocol implementation (`defimpl Proto, for: TargetMod do ... end`)
  defp walk_ast({:defimpl, _meta, [proto_ast | rest]}, env, ctx, acc) do
    clean_env = reset_expr_flags(env)
    {_e1, acc} = walk_ast(proto_ast, clean_env, ctx, acc)

    {opts_kw, body_parts} =
      case rest do
        [opts, body] when is_list(opts) -> {opts, [body]}
        [body] when is_list(body) -> {Keyword.drop(body, [:do]), [Keyword.take(body, [:do])]}
        other -> {[], other}
      end

    {_e2, acc} = walk_list(opts_kw, clean_env, ctx, acc)

    impl_mod =
      case resolve_module_ast(proto_ast, clean_env) do
        {:ok, p_mod} -> "#{p_mod}.Impl"
        :error -> current_module(clean_env) || "Impl"
      end

    inner_env = %{
      clean_env
      | module_stack: [impl_mod | clean_env.module_stack],
        bound_vars: MapSet.new(),
        local_zero_arity: scan_module_zero_arity_defs(body_parts)
    }

    {_inner_after, acc} = walk_list(body_parts, inner_env, ctx, acc)
    {env, acc}
  end

  # Lexical module directives: alias / import / require / use
  defp walk_ast({directive, dir_meta, args}, env, ctx, acc)
       when directive in [:alias, :import, :require, :use] and is_list(args) do
    handle_module_directive(directive, dir_meta, args, reset_expr_flags(env), ctx, acc)
  end

  # Module attributes: @spec, @type, @doc, @behaviour, @attr, etc.
  defp walk_ast({:@, attr_meta, [{attr_name, _name_meta, attr_args}]}, env, ctx, acc)
       when is_atom(attr_name) do
    handle_module_attribute(attr_name, attr_meta, attr_args, reset_expr_flags(env), ctx, acc)
  end

  # Function / Macro / Guard definitions: def, defp, defmacro, defmacrop, defguard, defguardp
  defp walk_ast({def_kind, _def_meta, [head_ast | rest]}, env, ctx, acc)
       when def_kind in [:def, :defp, :defmacro, :defmacrop, :defguard, :defguardp] do
    handle_function_definition(head_ast, rest, reset_expr_flags(env), ctx, acc)
  end

  # defdelegate
  defp walk_ast({:defdelegate, del_meta, [head_ast | rest]}, env, ctx, acc) do
    handle_defdelegate(del_meta, head_ast, rest, reset_expr_flags(env), ctx, acc)
  end

  # Struct literal / pattern `%Mod{...}`
  defp walk_ast({:%, _pct_meta, [struct_mod_ast, map_ast]}, env, ctx, acc) do
    clean_env = reset_expr_flags(env)
    acc = check_struct_module(struct_mod_ast, clean_env, ctx, acc)
    {_e, acc} = walk_ast(map_ast, clean_env, ctx, acc)
    {env, acc}
  end

  # Capture `&...`
  defp walk_ast({:&, _amp_meta, [capture_arg]}, env, ctx, acc) do
    handle_capture(capture_arg, reset_expr_flags(env), ctx, acc)
  end

  # Pipeline `lhs |> rhs`
  defp walk_ast({:|>, _pipe_meta, [lhs, rhs]}, env, ctx, acc) do
    clean_env = reset_expr_flags(env)
    {env_after_lhs, acc} = walk_ast(lhs, clean_env, ctx, acc)
    {env_after_rhs, acc} = walk_ast(rhs, %{env_after_lhs | pipe_arity: 1}, ctx, acc)
    {%{env_after_rhs | pipe_arity: 0}, acc}
  end

  # Pattern match `lhs = rhs`
  defp walk_ast({:=, _meta, [lhs, rhs]}, env, ctx, acc) do
    clean_env = reset_expr_flags(env)
    {env_rhs, acc} = walk_ast(rhs, clean_env, ctx, acc)
    {bound_env, acc} = walk_pattern(lhs, env_rhs, ctx, acc)
    {bound_env, acc}
  end

  # `cond do ... end` (LHS of `->` in `cond` is an expression, NOT a pattern!)
  defp walk_ast({:cond, _meta, [[do: clauses]]}, env, ctx, acc) when is_list(clauses) do
    clean_env = reset_expr_flags(env)

    acc =
      Enum.reduce(clauses, acc, fn
        {:->, _, [cond_exprs, body]}, cl_acc ->
          {cond_env, cl_acc} = walk_list(cond_exprs, clean_env, ctx, cl_acc)
          {_body_env, cl_acc} = walk_ast(body, cond_env, ctx, cl_acc)
          cl_acc

        other, cl_acc ->
          {_e, cl_acc} = walk_ast(other, clean_env, ctx, cl_acc)
          cl_acc
      end)

    {env, acc}
  end

  # Anonymous function `fn ... -> ... end`
  defp walk_ast({:fn, _meta, clauses}, env, ctx, acc) when is_list(clauses) do
    clean_env = reset_expr_flags(env)
    acc = walk_arrow_clauses(clauses, clean_env, ctx, acc)
    {env, acc}
  end

  # `case subject do ... end`
  defp walk_ast({:case, _meta, [subject, blocks]}, env, ctx, acc) when is_list(blocks) do
    clean_env = reset_expr_flags(env)
    {subj_env, acc} = walk_ast(subject, clean_env, ctx, acc)
    {_b_env, acc} = walk_keyword_clause_blocks(blocks, subj_env, ctx, acc)
    {subj_env, acc}
  end

  # `receive do ... end` / `try do ... end`
  defp walk_ast({block_form, _meta, [blocks]}, env, ctx, acc)
       when block_form in [:receive, :try] and is_list(blocks) do
    clean_env = reset_expr_flags(env)
    {_b_env, acc} = walk_keyword_clause_blocks(blocks, clean_env, ctx, acc)
    {env, acc}
  end

  # `with` and `for` comprehensions/pipelines
  defp walk_ast({comp_form, _meta, comp_args}, env, ctx, acc)
       when comp_form in [:with, :for] and is_list(comp_args) do
    clean_env = reset_expr_flags(env)
    acc = walk_comprehension_or_with(comp_args, clean_env, ctx, acc)
    {env, acc}
  end

  # Access.get (`container[key]`)
  defp walk_ast({{:., _, [Access, :get]}, _meta, [container, key]}, env, ctx, acc) do
    clean_env = reset_expr_flags(env)
    {_e1, acc} = walk_ast(container, clean_env, ctx, acc)
    {_e2, acc} = walk_ast(key, clean_env, ctx, acc)
    {env, acc}
  end

  # Remote call or remote typespec `Mod.fun(args)`
  defp walk_ast({{:., _dot_meta, [recv_ast, fun_atom]}, call_meta, args}, env, ctx, acc)
       when is_atom(fun_atom) and is_list(args) do
    handle_remote_call(recv_ast, fun_atom, call_meta, args, env, ctx, acc)
  end

  # Dynamic / anonymous dot call `fun.(args)`
  defp walk_ast({{:., _dot_meta, [callee_expr]}, _call_meta, args}, env, ctx, acc)
       when is_list(args) do
    clean_env = reset_expr_flags(env)
    {_e1, acc} = walk_ast(callee_expr, clean_env, ctx, acc)
    {_e2, acc} = walk_list(args, clean_env, ctx, acc)
    {env, acc}
  end

  # Bare module reference `{:__aliases__, meta, segments}`
  defp walk_ast({:__aliases__, alias_meta, segments}, env, ctx, acc) when is_list(segments) do
    clean_env = reset_expr_flags(env)

    if Enum.all?(segments, &is_atom/1) do
      resolved_mod = resolve_aliases(segments, clean_env)
      kind = if clean_env.in_typespec?, do: :spec_or_type, else: :module_ref
      acc = maybe_record_module_ref(resolved_mod, alias_meta, segments, kind, clean_env, ctx, acc)
      {env, acc}
    else
      {_e, acc} = walk_list(segments, clean_env, ctx, acc)
      {env, acc}
    end
  end

  # Unqualified call or parenless identifier `{name, meta, args}`
  defp walk_ast({fun_atom, call_meta, args}, env, ctx, acc)
       when is_atom(fun_atom) and is_list(call_meta) do
    if MapSet.member?(@non_call_special_forms, fun_atom) do
      clean_env = reset_expr_flags(env)

      {_e, acc} =
        if is_list(args), do: walk_list(args, clean_env, ctx, acc), else: {clean_env, acc}

      {env, acc}
    else
      handle_unqualified_node(fun_atom, call_meta, args, env, ctx, acc)
    end
  end

  # Generic 3-tuple (e.g. `{{...}, meta, args}`)
  defp walk_ast({form, _meta, args}, env, ctx, acc) do
    clean_env = reset_expr_flags(env)
    {_e1, acc} = walk_ast(form, clean_env, ctx, acc)

    {_e2, acc} =
      if is_list(args), do: walk_list(args, clean_env, ctx, acc), else: {clean_env, acc}

    {env, acc}
  end

  # 2-tuple (keyword pair `{:do, body}` or 2-element tuple literal `{a, b}`)
  defp walk_ast({left, right}, env, ctx, acc) do
    clean_env = reset_expr_flags(env)
    {env1, acc} = walk_ast(left, clean_env, ctx, acc)
    {env2, acc} = walk_ast(right, env1, ctx, acc)
    {env2, acc}
  end

  # Lists
  defp walk_ast(list, env, ctx, acc) when is_list(list) do
    walk_list(list, reset_expr_flags(env), ctx, acc)
  end

  # Literals (binaries, numbers, atoms, etc.) — never match string literals!
  defp walk_ast(atom, env, ctx, acc)
       when is_atom(atom) and atom not in [nil, true, false] do
    # Check rare explicit `:"Elixir.MyApp.OldMod"` atom literal if used as module ref
    raw = Atom.to_string(atom)

    acc =
      if String.starts_with?(raw, "Elixir.") do
        mod_name = String.replace_prefix(raw, "Elixir.", "")

        case ctx.target do
          {:module, ^mod_name} ->
            acc

          _ ->
            acc
        end
      else
        acc
      end

    {env, acc}
  end

  defp walk_ast(_literal, env, _ctx, acc), do: {env, acc}

  defp walk_list(items, env, ctx, acc) when is_list(items) do
    Enum.reduce(items, {env, acc}, fn item, {cur_env, cur_acc} ->
      walk_ast(item, cur_env, ctx, cur_acc)
    end)
  end

  # ===========================================================================
  # Specialized AST Handlers
  # ===========================================================================

  defp handle_module_definition(
         {:__aliases__, alias_meta, segments},
         parent_mod,
         env,
         ctx,
         acc
       )
       when is_list(segments) do
    if Enum.all?(segments, &is_atom/1) do
      {full_mod, short_child} =
        case segments do
          [Elixir | rest] ->
            joined = join_atom_segments(rest)
            {joined, nil}

          [first | _] ->
            first_str = Atom.to_string(first)

            cond do
              Map.has_key?(env.aliases, first_str) ->
                {resolve_aliases(segments, env), Atom.to_string(List.last(segments))}

              is_binary(parent_mod) ->
                rel = join_atom_segments(segments)
                {"#{parent_mod}.#{rel}", Atom.to_string(List.last(segments))}

              true ->
                {join_atom_segments(segments), Atom.to_string(List.last(segments))}
            end
        end

      acc =
        case ctx.target do
          {:module, ^full_mod} ->
            edit =
              case ctx.rename_target do
                {:module_target, to_mod} ->
                  repl = defmodule_replacement(to_mod, parent_mod, segments, env)
                  build_alias_span_edit(alias_meta, segments, repl)

                _ ->
                  nil
              end

            record_occurrence(acc, alias_meta, :definition, edit, ctx)

          _ ->
            acc
        end

      {full_mod, short_child, acc}
    else
      {_e, acc} = walk_list(segments, env, ctx, acc)
      {"DynamicModule", nil, acc}
    end
  end

  defp handle_module_definition(other_ast, parent_mod, env, ctx, acc) do
    {_e, acc} = walk_ast(other_ast, env, ctx, acc)
    {parent_mod || "DynamicModule", nil, acc}
  end

  defp defmodule_replacement(to_mod, parent_mod, segments, env) do
    case segments do
      [Elixir | _] ->
        "Elixir." <> to_mod

      [first | _] ->
        first_str = Atom.to_string(first)

        cond do
          is_binary(parent_mod) and not Map.has_key?(env.aliases, first_str) ->
            if String.starts_with?(to_mod, parent_mod <> ".") do
              String.replace_prefix(to_mod, parent_mod <> ".", "")
            else
              "Elixir." <> to_mod
            end

          true ->
            to_mod
        end
    end
  end

  # Handles `alias`, `import`, `require`, `use` including `alias Foo.{Bar, Baz}` and `, as: Custom`
  defp handle_module_directive(
         directive,
         dir_meta,
         [{{:., _, [prefix_ast, :{}]}, tuple_meta, children} | rest_opts],
         env,
         ctx,
         acc
       )
       when is_list(children) do
    case resolve_module_ast(prefix_ast, env) do
      {:ok, prefix_mod} ->
        {env_out, acc_out, matched_children} =
          Enum.reduce(children, {env, acc, []}, fn
            {:__aliases__, child_meta, child_segs} = child_node, {e_acc, o_acc, m_acc} ->
              if Enum.all?(child_segs, &is_atom/1) do
                child_rel = join_atom_segments(child_segs)
                child_full = "#{prefix_mod}.#{child_rel}"
                short_name = Atom.to_string(List.last(child_segs))

                e_next =
                  case directive do
                    :alias ->
                      put_in(e_acc.aliases[short_name], %{full: child_full, explicit_as?: false})

                    :import ->
                      add_import_entry(e_acc, child_full, [])

                    _ ->
                      e_acc
                  end

                if ctx.target == {:module, child_full} do
                  {e_next, o_acc, [{child_node, child_meta, child_segs, child_full} | m_acc]}
                else
                  {e_next, o_acc, m_acc}
                end
              else
                {e_acc, o_acc, m_acc}
              end

            _other, state ->
              state
          end)

        acc_final =
          case Enum.reverse(matched_children) do
            [] ->
              acc_out

            matches ->
              build_multi_directive_occurrences(
                directive,
                dir_meta,
                tuple_meta,
                prefix_mod,
                children,
                rest_opts,
                matches,
                ctx,
                acc_out
              )
          end

        {env_out, acc_final}

      :error ->
        walk_list(children, env, ctx, acc)
    end
  end

  defp handle_module_directive(directive, dir_meta, [target_ast | rest], env, ctx, acc) do
    opts_kw =
      case rest do
        [kw] when is_list(kw) -> kw
        _ -> []
      end

    explicit_as =
      case Keyword.get(opts_kw, :as) do
        {:__aliases__, _, [as_atom]} when is_atom(as_atom) -> Atom.to_string(as_atom)
        _ -> nil
      end

    {resolved_mod, acc} =
      case target_ast do
        {:__aliases__, t_meta, t_segs} when is_list(t_segs) ->
          if Enum.all?(t_segs, &is_atom/1) do
            resolved = resolve_aliases(t_segs, env)

            acc =
              if ctx.target == {:module, resolved} do
                edit =
                  case ctx.rename_target do
                    {:module_target, to_mod} ->
                      repl =
                        if directive == :alias do
                          if List.first(t_segs) == Elixir, do: "Elixir." <> to_mod, else: to_mod
                        else
                          module_usage_replacement_text(t_segs, env, to_mod)
                        end

                      if is_binary(repl) do
                        build_alias_span_edit(t_meta, t_segs, repl)
                      else
                        nil
                      end

                    _ ->
                      nil
                  end

                record_occurrence(acc, t_meta, directive, edit, ctx)
              else
                acc
              end

            {resolved, acc}
          else
            {_e, acc} = walk_list(t_segs, env, ctx, acc)
            {nil, acc}
          end

        {:__MODULE__, _m_meta, _} ->
          {current_module(env), acc}

        other ->
          {_e, acc} = walk_ast(other, env, ctx, acc)
          {nil, acc}
      end

    # Check `import TargetMod, only: [old_fun: 2]` / `except: [old_fun: 2]` for function target
    acc =
      if directive == :import and is_binary(resolved_mod) do
        check_import_function_list(dir_meta, resolved_mod, opts_kw, ctx, acc)
      else
        acc
      end

    # Walk non-`:as` options (e.g. `use SomeMacro, worker: MyApp.OldMod`)
    other_opts = if Keyword.keyword?(opts_kw), do: Keyword.delete(opts_kw, :as), else: opts_kw
    {_e_opts, acc} = walk_list(other_opts, env, ctx, acc)

    env_next =
      cond do
        directive == :alias and is_binary(resolved_mod) ->
          bound_name = explicit_as || last_module_segment(resolved_mod)

          put_in(env.aliases[bound_name], %{
            full: resolved_mod,
            explicit_as?: not is_nil(explicit_as)
          })

        directive == :require and is_binary(resolved_mod) and not is_nil(explicit_as) ->
          put_in(env.aliases[explicit_as], %{full: resolved_mod, explicit_as?: true})

        directive == :import and is_binary(resolved_mod) ->
          add_import_entry(env, resolved_mod, opts_kw)

        true ->
          env
      end

    {env_next, acc}
  end

  defp handle_module_directive(_directive, _dir_meta, args, env, ctx, acc) do
    walk_list(args, env, ctx, acc)
  end

  defp build_multi_directive_occurrences(
         directive,
         dir_meta,
         tuple_meta,
         prefix_mod,
         all_children,
         rest_opts,
         matches,
         ctx,
         acc
       ) do
    case ctx.rename_target do
      {:module_target, to_mod} ->
        if String.starts_with?(to_mod, prefix_mod <> ".") do
          rel_new = String.replace_prefix(to_mod, prefix_mod <> ".", "")

          Enum.reduce(matches, acc, fn {_node, child_meta, child_segs, _full}, acc_in ->
            edit = build_alias_span_edit(child_meta, child_segs, rel_new)
            record_occurrence(acc_in, child_meta, directive, edit, ctx)
          end)
        else
          # Different namespace prefix: expand multi-directive into clean separate directives!
          [{_first_node, first_meta, _first_segs, _first_full} | rest_matches] = matches

          remaining_children =
            Enum.reject(all_children, fn
              {:__aliases__, _, segs} when is_list(segs) ->
                Enum.all?(segs, &is_atom/1) and
                  {:module, "#{prefix_mod}.#{join_atom_segments(segs)}"} == ctx.target

              _ ->
                false
            end)

          edit =
            build_multi_directive_expansion_edit(
              directive,
              dir_meta,
              tuple_meta,
              prefix_mod,
              remaining_children,
              rest_opts,
              to_mod,
              ctx
            )

          acc = record_occurrence(acc, first_meta, directive, edit, ctx)

          Enum.reduce(rest_matches, acc, fn {_n, m_meta, _s, _f}, acc_in ->
            record_occurrence(acc_in, m_meta, directive, nil, ctx)
          end)
        end

      _ ->
        Enum.reduce(matches, acc, fn {_node, child_meta, _child_segs, _full}, acc_in ->
          record_occurrence(acc_in, child_meta, directive, nil, ctx)
        end)
    end
  end

  defp build_multi_directive_expansion_edit(
         directive,
         dir_meta,
         tuple_meta,
         prefix_mod,
         remaining_children,
         rest_opts,
         to_mod,
         ctx
       ) do
    start_line = dir_meta[:line]
    start_col = dir_meta[:column]
    closing = tuple_meta[:closing]

    end_pos =
      cond do
        rest_opts != [] and dir_meta[:end_of_expression] != nil ->
          eoe = dir_meta[:end_of_expression]
          {eoe[:line], eoe[:column]}

        closing != nil ->
          {closing[:line], closing[:column] + 1}

        dir_meta[:end_of_expression] != nil ->
          eoe = dir_meta[:end_of_expression]
          {eoe[:line], eoe[:column]}

        true ->
          nil
      end

    if is_integer(start_line) and is_integer(start_col) and not is_nil(end_pos) do
      indent = line_leading_whitespace(ctx.line_index, start_line)

      opts_suffix =
        if rest_opts == [] do
          ""
        else
          ", " <> Enum.map_join(rest_opts, ", ", &Macro.to_string/1)
        end

      replacement =
        case remaining_children do
          [] ->
            "#{directive} #{to_mod}#{opts_suffix}"

          [{:__aliases__, _, single_segs}] ->
            other_rel = join_atom_segments(single_segs)

            "#{directive} #{prefix_mod}.#{other_rel}#{opts_suffix}\n" <>
              "#{indent}#{directive} #{to_mod}#{opts_suffix}"

          many ->
            others_joined =
              Enum.map_join(many, ", ", fn
                {:__aliases__, _, segs} -> join_atom_segments(segs)
                other -> Macro.to_string(other)
              end)

            "#{directive} #{prefix_mod}.{#{others_joined}}#{opts_suffix}\n" <>
              "#{indent}#{directive} #{to_mod}#{opts_suffix}"
        end

      %{
        start_pos: {start_line, start_col},
        end_pos: end_pos,
        expected: nil,
        replacement: replacement
      }
    else
      nil
    end
  end

  defp check_import_function_list(
         dir_meta,
         resolved_mod,
         opts_kw,
         %{target: {:function, target_mod, target_fun, target_arity}} = ctx,
         acc
       )
       when resolved_mod == target_mod and is_list(opts_kw) do
    start_line = dir_meta[:line] || 1
    end_line = get_in(dir_meta, [:end_of_expression, :line]) || start_line + 5

    Enum.reduce([:only, :except], acc, fn key, acc_in ->
      case Keyword.get(opts_kw, key) do
        kw when is_list(kw) ->
          Enum.reduce(kw, acc_in, fn
            {fun_atom, arity_int}, inner_acc
            when is_atom(fun_atom) and is_integer(arity_int) ->
              if Atom.to_string(fun_atom) == target_fun and
                   matches_arity?(arity_int, target_arity) do
                case find_kw_token_in_lines(ctx.tokens, fun_atom, start_line, end_line) do
                  {:ok, tok_line, tok_col} ->
                    edit =
                      case ctx.rename_target do
                        {:function_target, to_fun} ->
                          build_identifier_edit(tok_line, tok_col, target_fun, to_fun)

                        _ ->
                          nil
                      end

                    record_occurrence(
                      inner_acc,
                      [line: tok_line, column: tok_col],
                      :import,
                      edit,
                      ctx
                    )

                  :error ->
                    inner_acc
                end
              else
                inner_acc
              end

            _other, inner_acc ->
              inner_acc
          end)

        _ ->
          acc_in
      end
    end)
  end

  defp check_import_function_list(_dir_meta, _resolved_mod, _opts_kw, _ctx, acc), do: acc

  # Module Attributes (`@spec`, `@type`, `@doc`, `@behaviour`, `@attr`, ...)
  defp handle_module_attribute(attr_name, _attr_meta, [spec_ast], env, ctx, acc)
       when attr_name in [:spec, :callback, :macrocallback] do
    spec_env = %{env | in_typespec?: true}
    {head_node, return_ast, guard_ast} = unwrap_spec_ast(spec_ast)

    acc =
      case {head_node, ctx.target} do
        {{fun_atom, head_meta, head_args}, {:function, target_mod, target_fun, target_arity}}
        when is_atom(fun_atom) ->
          arity = if is_list(head_args), do: length(head_args), else: 0

          if current_module(env) == target_mod and Atom.to_string(fun_atom) == target_fun and
               matches_arity?(arity, target_arity) do
            edit =
              case ctx.rename_target do
                {:function_target, to_fun} ->
                  build_identifier_edit(head_meta[:line], head_meta[:column], target_fun, to_fun)

                _ ->
                  nil
              end

            record_occurrence(acc, head_meta, :spec_or_type, edit, ctx)
          else
            acc
          end

        _ ->
          acc
      end

    head_args =
      case head_node do
        {_name, _meta, args} when is_list(args) -> args
        _ -> []
      end

    {_e1, acc} = walk_list(head_args, spec_env, ctx, acc)

    {_e2, acc} =
      if return_ast != nil, do: walk_ast(return_ast, spec_env, ctx, acc), else: {spec_env, acc}

    {_e3, acc} =
      if guard_ast != nil, do: walk_ast(guard_ast, spec_env, ctx, acc), else: {spec_env, acc}

    {env, acc}
  end

  defp handle_module_attribute(attr_name, _attr_meta, [type_ast], env, ctx, acc)
       when attr_name in [:type, :typep, :opaque] do
    spec_env = %{env | in_typespec?: true}
    {head_node, rhs_ast, guard_ast} = unwrap_spec_ast(type_ast)

    type_params =
      case head_node do
        {_name, _meta, params} when is_list(params) -> params
        _ -> []
      end

    {_e1, acc} = walk_list(type_params, spec_env, ctx, acc)

    {_e2, acc} =
      if rhs_ast != nil, do: walk_ast(rhs_ast, spec_env, ctx, acc), else: {spec_env, acc}

    {_e3, acc} =
      if guard_ast != nil, do: walk_ast(guard_ast, spec_env, ctx, acc), else: {spec_env, acc}

    {env, acc}
  end

  defp handle_module_attribute(doc_attr, _attr_meta, _attr_args, env, _ctx, acc)
       when doc_attr in [:doc, :moduledoc, :typedoc] do
    # Never match occurrences inside @doc / @moduledoc / @typedoc documentation text.
    {env, acc}
  end

  defp handle_module_attribute(_attr_name, _attr_meta, attr_args, env, ctx, acc) do
    # Note: when `attr_args` is `nil` (reading `@some_attr`), do NOT walk `attr_name` as a call!
    if is_list(attr_args) do
      {_e, acc} = walk_list(attr_args, env, ctx, acc)
      {env, acc}
    else
      {env, acc}
    end
  end

  defp unwrap_spec_ast({:when, _, [inner, guard_ast]}) do
    {head, rhs, _} = unwrap_spec_ast(inner)
    {head, rhs, guard_ast}
  end

  defp unwrap_spec_ast({:"::", _, [head, rhs]}), do: {head, rhs, nil}
  defp unwrap_spec_ast(head), do: {head, nil, nil}

  # Function / Macro / Guard definition
  defp handle_function_definition(head_ast, rest, env, ctx, acc) do
    {call_head, guard_ast} = unwrap_when_head(head_ast)

    {fn_env, acc} =
      case call_head do
        {fun_atom, head_meta, raw_args} when is_atom(fun_atom) ->
          {min_arity, max_arity} = arity_bounds(raw_args)

          acc =
            case ctx.target do
              {:function, target_mod, target_fun, target_arity} ->
                if current_module(env) == target_mod and Atom.to_string(fun_atom) == target_fun and
                     matches_def_arity?(min_arity, max_arity, target_arity) do
                  edit =
                    case ctx.rename_target do
                      {:function_target, to_fun} ->
                        build_identifier_edit(
                          head_meta[:line],
                          head_meta[:column],
                          target_fun,
                          to_fun
                        )

                      _ ->
                        nil
                    end

                  record_occurrence(acc, head_meta, :definition, edit, ctx)
                else
                  acc
                end

              _ ->
                acc
            end

          args_list = if is_list(raw_args), do: raw_args, else: []
          walk_def_params(args_list, env, ctx, acc)

        other_head ->
          walk_ast(other_head, env, ctx, acc)
      end

    {fn_env, acc} =
      if guard_ast != nil do
        walk_ast(guard_ast, fn_env, ctx, acc)
      else
        {fn_env, acc}
      end

    {_body_env, acc} = walk_keyword_clause_blocks(rest, fn_env, ctx, acc)
    {env, acc}
  end

  # `defdelegate`
  defp handle_defdelegate(del_meta, head_ast, rest, env, ctx, acc) do
    {call_head, _guard} = unwrap_when_head(head_ast)

    opts_kw =
      case rest do
        [kw] when is_list(kw) -> kw
        _ -> []
      end

    {fn_env, acc} =
      case call_head do
        {fun_atom, head_meta, raw_args} when is_atom(fun_atom) ->
          {min_arity, max_arity} = arity_bounds(raw_args)

          # 1. Definition on `current_module(env)`
          acc =
            case ctx.target do
              {:function, target_mod, target_fun, target_arity} ->
                if current_module(env) == target_mod and Atom.to_string(fun_atom) == target_fun and
                     matches_def_arity?(min_arity, max_arity, target_arity) do
                  edit =
                    case ctx.rename_target do
                      {:function_target, to_fun} ->
                        build_identifier_edit(
                          head_meta[:line],
                          head_meta[:column],
                          target_fun,
                          to_fun
                        )

                      _ ->
                        nil
                    end

                  record_occurrence(acc, head_meta, :definition, edit, ctx)
                else
                  acc
                end

              _ ->
                acc
            end

          # 2. Delegation call to another module (`to: TargetMod`, optional `as: :old_fun`)
          acc =
            check_defdelegate_target(
              del_meta,
              fun_atom,
              head_meta,
              min_arity,
              max_arity,
              opts_kw,
              env,
              ctx,
              acc
            )

          args_list = if is_list(raw_args), do: raw_args, else: []
          walk_def_params(args_list, env, ctx, acc)

        _ ->
          {env, acc}
      end

    {_e_opts, acc} = walk_list(opts_kw, fn_env, ctx, acc)
    {env, acc}
  end

  defp check_defdelegate_target(
         del_meta,
         fun_atom,
         head_meta,
         min_arity,
         max_arity,
         opts_kw,
         env,
         %{target: {:function, target_mod, target_fun, target_arity}} = ctx,
         acc
       ) do
    to_ast = Keyword.get(opts_kw, :to)

    case resolve_module_ast(to_ast, env) do
      {:ok, ^target_mod} ->
        if current_module(env) != target_mod do
          explicit_as = Keyword.get(opts_kw, :as)

          delegated_atom =
            if is_atom(explicit_as) and explicit_as != nil, do: explicit_as, else: fun_atom

          if Atom.to_string(delegated_atom) == target_fun and
               matches_def_arity?(min_arity, max_arity, target_arity) do
            start_line = del_meta[:line] || head_meta[:line] || 1
            end_line = get_in(del_meta, [:end_of_expression, :line]) || start_line + 5

            if is_atom(explicit_as) and explicit_as != nil do
              case find_atom_token_in_lines(ctx.tokens, explicit_as, start_line, end_line) do
                {:ok, tok_line, tok_col} ->
                  edit =
                    case ctx.rename_target do
                      {:function_target, to_fun} ->
                        %{
                          start_pos: {tok_line, tok_col},
                          end_pos: {tok_line, tok_col + 1 + codepoint_length(target_fun)},
                          expected: ":" <> target_fun,
                          replacement: ":" <> to_fun
                        }

                      _ ->
                        nil
                    end

                  record_occurrence(acc, [line: tok_line, column: tok_col], :call, edit, ctx)

                :error ->
                  record_occurrence(acc, head_meta, :call, nil, ctx)
              end
            else
              edit =
                case {ctx.rename_target, to_ast} do
                  {{:function_target, to_fun}, {:__aliases__, to_meta, to_segs}} ->
                    {_s_pos, end_pos} = alias_positions(to_meta, to_segs)

                    %{
                      start_pos: end_pos,
                      end_pos: end_pos,
                      expected: "",
                      replacement: ", as: :#{to_fun}"
                    }

                  _ ->
                    nil
                end

              record_occurrence(acc, head_meta, :call, edit, ctx)
            end
          else
            acc
          end
        else
          acc
        end

      _ ->
        acc
    end
  end

  defp check_defdelegate_target(_del_meta, _f, _hm, _min, _max, _opts, _env, _ctx, acc), do: acc

  # Struct `%Mod{}`
  defp check_struct_module({:__aliases__, alias_meta, segments}, env, ctx, acc)
       when is_list(segments) do
    if Enum.all?(segments, &is_atom/1) do
      resolved_mod = resolve_aliases(segments, env)
      maybe_record_module_ref(resolved_mod, alias_meta, segments, :struct, env, ctx, acc)
    else
      {_e, acc} = walk_list(segments, env, ctx, acc)
      acc
    end
  end

  defp check_struct_module(other_ast, env, ctx, acc) do
    {_e, acc} = walk_ast(other_ast, env, ctx, acc)
    acc
  end

  # Captures `&Mod.fun/n`, `&fun/n`, `&Mod.fun(&1)`
  defp handle_capture({:/, _slash_meta, [target_expr, arity_int]}, env, ctx, acc)
       when is_integer(arity_int) do
    case target_expr do
      {{:., _dot_meta, [recv_ast, fun_atom]}, call_meta, _args} when is_atom(fun_atom) ->
        acc =
          case recv_ast do
            {:__aliases__, alias_meta, segments} when is_list(segments) ->
              if Enum.all?(segments, &is_atom/1) do
                resolved_mod = resolve_aliases(segments, env)

                maybe_record_module_ref(
                  resolved_mod,
                  alias_meta,
                  segments,
                  :capture,
                  env,
                  ctx,
                  acc
                )
              else
                {_e, acc} = walk_list(segments, env, ctx, acc)
                acc
              end

            other_recv ->
              {_e, acc} = walk_ast(other_recv, env, ctx, acc)
              acc
          end

        acc =
          case {ctx.target, resolve_module_ast(recv_ast, env)} do
            {{:function, target_mod, target_fun, target_arity}, {:ok, resolved_mod}}
            when resolved_mod == target_mod ->
              if Atom.to_string(fun_atom) == target_fun and
                   matches_arity?(arity_int, target_arity) do
                edit =
                  case ctx.rename_target do
                    {:function_target, to_fun} ->
                      build_identifier_edit(
                        call_meta[:line],
                        call_meta[:column],
                        target_fun,
                        to_fun
                      )

                    _ ->
                      nil
                  end

                record_occurrence(acc, call_meta, :capture, edit, ctx)
              else
                acc
              end

            _ ->
              acc
          end

        {env, acc}

      {fun_atom, call_meta, call_ctx} when is_atom(fun_atom) and is_atom(call_ctx) ->
        acc =
          case ctx.target do
            {:function, target_mod, target_fun, target_arity} ->
              if Atom.to_string(fun_atom) == target_fun and
                   matches_arity?(arity_int, target_arity) and
                   unqualified_callable?(env, target_mod, target_fun, arity_int) do
                edit =
                  case ctx.rename_target do
                    {:function_target, to_fun} ->
                      build_identifier_edit(
                        call_meta[:line],
                        call_meta[:column],
                        target_fun,
                        to_fun
                      )

                    _ ->
                      nil
                  end

                record_occurrence(acc, call_meta, :capture, edit, ctx)
              else
                acc
              end

            _ ->
              acc
          end

        {env, acc}

      other ->
        walk_ast(other, %{env | in_capture?: true}, ctx, acc)
    end
  end

  defp handle_capture(placeholder, env, _ctx, acc) when is_integer(placeholder) do
    {env, acc}
  end

  defp handle_capture(body_expr, env, ctx, acc) do
    {_e, acc} = walk_ast(body_expr, %{env | in_capture?: true}, ctx, acc)
    {env, acc}
  end

  # Remote call `Mod.fun(args)` or remote typespec `Mod.t()`
  defp handle_remote_call(recv_ast, fun_atom, call_meta, args, env, ctx, acc) do
    effective_kind =
      cond do
        env.in_typespec? -> :spec_or_type
        env.in_capture? -> :capture
        true -> :call
      end

    effective_arity = length(args) + env.pipe_arity
    clean_env = reset_expr_flags(env)

    acc =
      case recv_ast do
        {:__aliases__, alias_meta, segments} when is_list(segments) ->
          if Enum.all?(segments, &is_atom/1) do
            resolved_mod = resolve_aliases(segments, clean_env)

            maybe_record_module_ref(
              resolved_mod,
              alias_meta,
              segments,
              effective_kind,
              clean_env,
              ctx,
              acc
            )
          else
            {_e, acc} = walk_list(segments, clean_env, ctx, acc)
            acc
          end

        other_recv ->
          {_e, acc} = walk_ast(other_recv, clean_env, ctx, acc)
          acc
      end

    acc =
      if not env.in_typespec? do
        case {ctx.target, resolve_module_ast(recv_ast, clean_env)} do
          {{:function, target_mod, target_fun, target_arity}, {:ok, resolved_mod}}
          when resolved_mod == target_mod ->
            if Atom.to_string(fun_atom) == target_fun and
                 matches_arity?(effective_arity, target_arity) do
              edit =
                case ctx.rename_target do
                  {:function_target, to_fun} ->
                    build_identifier_edit(
                      call_meta[:line],
                      call_meta[:column],
                      target_fun,
                      to_fun
                    )

                  _ ->
                    nil
                end

              record_occurrence(acc, call_meta, effective_kind, edit, ctx)
            else
              acc
            end

          _ ->
            acc
        end
      else
        acc
      end

    {_e_args, acc} = walk_list(args, clean_env, ctx, acc)
    {clean_env, acc}
  end

  # Unqualified calls & parenless identifiers
  defp handle_unqualified_node(fun_atom, call_meta, args, env, ctx, acc) when is_list(args) do
    effective_kind = if env.in_capture?, do: :capture, else: :call
    effective_arity = length(args) + env.pipe_arity
    clean_env = reset_expr_flags(env)

    acc =
      if not env.in_typespec? do
        case ctx.target do
          {:function, target_mod, target_fun, target_arity} ->
            if Atom.to_string(fun_atom) == target_fun and
                 matches_arity?(effective_arity, target_arity) and
                 unqualified_callable?(clean_env, target_mod, target_fun, effective_arity) do
              edit =
                case ctx.rename_target do
                  {:function_target, to_fun} ->
                    build_identifier_edit(
                      call_meta[:line],
                      call_meta[:column],
                      target_fun,
                      to_fun
                    )

                  _ ->
                    nil
                end

              record_occurrence(acc, call_meta, effective_kind, edit, ctx)
            else
              acc
            end

          _ ->
            acc
        end
      else
        acc
      end

    {after_args_env, acc} = walk_list(args, clean_env, ctx, acc)
    {after_args_env, acc}
  end

  defp handle_unqualified_node(fun_atom, call_meta, call_ctx, env, ctx, acc)
       when is_atom(call_ctx) do
    effective_kind = if env.in_capture?, do: :capture, else: :call
    name_str = Atom.to_string(fun_atom)
    clean_env = reset_expr_flags(env)

    acc =
      if not env.in_typespec? do
        case ctx.target do
          {:function, target_mod, target_fun, target_arity} when name_str == target_fun ->
            cond do
              # RHS of `|>` without parens (`x |> old_fun`) is always a 1-arity call!
              env.pipe_arity > 0 and matches_arity?(env.pipe_arity, target_arity) and
                  unqualified_callable?(clean_env, target_mod, target_fun, env.pipe_arity) ->
                edit =
                  case ctx.rename_target do
                    {:function_target, to_fun} ->
                      build_identifier_edit(
                        call_meta[:line],
                        call_meta[:column],
                        target_fun,
                        to_fun
                      )

                    _ ->
                      nil
                  end

                record_occurrence(acc, call_meta, effective_kind, edit, ctx)

              # Bare 0-arity call (`old_fun`) inside defining/importing module when not shadowed by a local variable
              env.pipe_arity == 0 and matches_arity?(0, target_arity) and
                not MapSet.member?(clean_env.bound_vars, name_str) and
                  zero_arity_callable?(clean_env, target_mod, target_fun) ->
                edit =
                  case ctx.rename_target do
                    {:function_target, to_fun} ->
                      build_identifier_edit(
                        call_meta[:line],
                        call_meta[:column],
                        target_fun,
                        to_fun
                      )

                    _ ->
                      nil
                  end

                record_occurrence(acc, call_meta, effective_kind, edit, ctx)

              true ->
                acc
            end

          _ ->
            acc
        end
      else
        acc
      end

    {clean_env, acc}
  end

  # ===========================================================================
  # Pattern & Clause Walkers (prevent shadowing variables from matching 0-arity fns)
  # ===========================================================================

  defp walk_def_params(params, env, ctx, acc) do
    Enum.reduce(params, {env, acc}, fn
      {:\\, _, [pat, default_expr]}, {cur_env, cur_acc} ->
        {cur_env, cur_acc} = walk_ast(default_expr, cur_env, ctx, cur_acc)
        walk_pattern(pat, cur_env, ctx, cur_acc)

      pat, {cur_env, cur_acc} ->
        walk_pattern(pat, cur_env, ctx, cur_acc)
    end)
  end

  defp walk_pattern({:^, _, [pinned_expr]}, env, ctx, acc) do
    walk_ast(pinned_expr, env, ctx, acc)
  end

  defp walk_pattern({:%, _, [struct_mod_ast, map_pat]}, env, ctx, acc) do
    acc = check_struct_module(struct_mod_ast, env, ctx, acc)
    walk_pattern(map_pat, env, ctx, acc)
  end

  defp walk_pattern({:when, _, [pat, guard_expr]}, env, ctx, acc) do
    {pat_env, acc} = walk_pattern(pat, env, ctx, acc)
    walk_ast(guard_expr, pat_env, ctx, acc)
  end

  # Exception rescue pattern `e in MyApp.OldError` or `e in [MyApp.OldError]`
  defp walk_pattern({:in, _, [var_pat, exc_mods]}, env, ctx, acc) do
    {pat_env, acc} = walk_pattern(var_pat, env, ctx, acc)
    {_e, acc} = walk_ast(exc_mods, pat_env, ctx, acc)
    {pat_env, acc}
  end

  defp walk_pattern({:__aliases__, alias_meta, segments}, env, ctx, acc)
       when is_list(segments) do
    walk_ast({:__aliases__, alias_meta, segments}, env, ctx, acc)
  end

  defp walk_pattern({var_atom, _meta, var_ctx}, env, _ctx, acc)
       when is_atom(var_atom) and is_atom(var_ctx) do
    name = Atom.to_string(var_atom)

    if String.starts_with?(name, "_") and name == "_" do
      {env, acc}
    else
      {%{env | bound_vars: MapSet.put(env.bound_vars, name)}, acc}
    end
  end

  defp walk_pattern({_form, _meta, args}, env, ctx, acc) when is_list(args) do
    Enum.reduce(args, {env, acc}, fn arg, {cur_env, cur_acc} ->
      walk_pattern(arg, cur_env, ctx, cur_acc)
    end)
  end

  defp walk_pattern({left, right}, env, ctx, acc) do
    {env1, acc} = walk_pattern(left, env, ctx, acc)
    walk_pattern(right, env1, ctx, acc)
  end

  defp walk_pattern(list, env, ctx, acc) when is_list(list) do
    Enum.reduce(list, {env, acc}, fn item, {cur_env, cur_acc} ->
      walk_pattern(item, cur_env, ctx, cur_acc)
    end)
  end

  defp walk_pattern(_literal, env, _ctx, acc), do: {env, acc}

  defp walk_arrow_clauses(clauses, env, ctx, acc) when is_list(clauses) do
    Enum.reduce(clauses, acc, fn
      {:->, _, [pats, body]}, cl_acc ->
        {clause_env, cl_acc} = walk_pattern(pats, env, ctx, cl_acc)
        {_body_env, cl_acc} = walk_ast(body, clause_env, ctx, cl_acc)
        cl_acc

      other, cl_acc ->
        {_e, cl_acc} = walk_ast(other, env, ctx, cl_acc)
        cl_acc
    end)
  end

  defp walk_keyword_clause_blocks(blocks, env, ctx, acc) when is_list(blocks) do
    Enum.reduce(blocks, {env, acc}, fn
      [{_k, _v} | _] = kw_list, {cur_env, cur_acc} ->
        walk_keyword_clause_blocks(kw_list, cur_env, ctx, cur_acc)

      {block_key, block_val}, {cur_env, cur_acc}
      when block_key in [:rescue, :catch, :else, :after, :do] ->
        if is_list(block_val) and Enum.any?(block_val, &match?({:->, _, _}, &1)) do
          {cur_env, walk_arrow_clauses(block_val, cur_env, ctx, cur_acc)}
        else
          {_b_env, next_acc} = walk_ast(block_val, cur_env, ctx, cur_acc)
          {cur_env, next_acc}
        end

      other, {cur_env, cur_acc} ->
        walk_ast(other, cur_env, ctx, cur_acc)
    end)
  end

  defp walk_comprehension_or_with(args, env, ctx, acc) do
    {_final_env, final_acc} =
      Enum.reduce(args, {env, acc}, fn
        {:<-, _, [pat, expr]}, {cur_env, cur_acc} ->
          {cur_env, cur_acc} = walk_ast(expr, cur_env, ctx, cur_acc)
          walk_pattern(pat, cur_env, ctx, cur_acc)

        [{_k, _v} | _] = kw_blocks, {cur_env, cur_acc} ->
          {_e, next_acc} = walk_keyword_clause_blocks(kw_blocks, cur_env, ctx, cur_acc)
          {cur_env, next_acc}

        filter_expr, {cur_env, cur_acc} ->
          walk_ast(filter_expr, cur_env, ctx, cur_acc)
      end)

    final_acc
  end

  # ===========================================================================
  # Lexical Resolution & Occurrence Recording Helpers
  # ===========================================================================

  defp resolve_module_ast({:__aliases__, _meta, segments}, env) when is_list(segments) do
    if Enum.all?(segments, &is_atom/1) do
      {:ok, resolve_aliases(segments, env)}
    else
      :error
    end
  end

  defp resolve_module_ast({:__MODULE__, _meta, _ctx}, env) do
    case current_module(env) do
      mod when is_binary(mod) -> {:ok, mod}
      _ -> :error
    end
  end

  defp resolve_module_ast(atom, _env)
       when is_atom(atom) and atom not in [nil, true, false] do
    raw = Atom.to_string(atom)

    if String.starts_with?(raw, "Elixir.") do
      {:ok, String.replace_prefix(raw, "Elixir.", "")}
    else
      :error
    end
  end

  defp resolve_module_ast(_other, _env), do: :error

  defp resolve_aliases([Elixir | rest], _env) do
    join_atom_segments(rest)
  end

  defp resolve_aliases([first | rest], env) do
    first_str = Atom.to_string(first)

    case Map.get(env.aliases, first_str) do
      %{full: mapped_prefix} ->
        if rest == [] do
          mapped_prefix
        else
          mapped_prefix <> "." <> join_atom_segments(rest)
        end

      nil ->
        join_atom_segments([first | rest])
    end
  end

  defp resolve_aliases([], _env), do: ""

  defp join_atom_segments(segments) do
    Enum.map_join(segments, ".", &Atom.to_string/1)
  end

  defp last_module_segment(full_mod) do
    full_mod |> String.split(".") |> List.last()
  end

  defp maybe_record_module_ref(resolved_mod, alias_meta, segments, kind, env, ctx, acc) do
    if ctx.target == {:module, resolved_mod} do
      edit =
        case ctx.rename_target do
          {:module_target, to_mod} ->
            case module_usage_replacement_text(segments, env, to_mod) do
              repl when is_binary(repl) ->
                build_alias_span_edit(alias_meta, segments, repl)

              :keep_custom_alias ->
                nil
            end

          _ ->
            nil
        end

      record_occurrence(acc, alias_meta, kind, edit, ctx)
    else
      acc
    end
  end

  defp module_usage_replacement_text([Elixir | _rest], _env, to_mod) do
    "Elixir." <> to_mod
  end

  defp module_usage_replacement_text([single], env, to_mod) do
    single_str = Atom.to_string(single)

    case Map.get(env.aliases, single_str) do
      %{explicit_as?: true} ->
        :keep_custom_alias

      %{explicit_as?: false} ->
        last_module_segment(to_mod)

      nil ->
        to_mod
    end
  end

  defp module_usage_replacement_text([first | _rest], env, to_mod) do
    first_str = Atom.to_string(first)

    case Map.get(env.aliases, first_str) do
      %{full: prefix_full, explicit_as?: true} ->
        if String.starts_with?(to_mod, prefix_full <> ".") do
          first_str <> "." <> String.replace_prefix(to_mod, prefix_full <> ".", "")
        else
          to_mod
        end

      _ ->
        to_mod
    end
  end

  defp add_import_entry(env, mod_name, opts_kw) do
    only_spec =
      case Keyword.get(opts_kw, :only) do
        kw when is_list(kw) ->
          kw
          |> Enum.flat_map(fn
            {f, a} when is_atom(f) and is_integer(a) -> [{Atom.to_string(f), a}]
            _ -> []
          end)
          |> MapSet.new()

        _ ->
          :all
      end

    except_spec =
      case Keyword.get(opts_kw, :except) do
        kw when is_list(kw) ->
          kw
          |> Enum.flat_map(fn
            {f, a} when is_atom(f) and is_integer(a) -> [{Atom.to_string(f), a}]
            _ -> []
          end)
          |> MapSet.new()

        _ ->
          MapSet.new()
      end

    entry = %{module: mod_name, only: only_spec, except: except_spec}
    %{env | imports: [entry | env.imports]}
  end

  defp unqualified_callable?(env, target_mod, fun_str, arity) do
    current_module(env) == target_mod or imported_callable?(env, target_mod, fun_str, arity)
  end

  defp zero_arity_callable?(env, target_mod, fun_str) do
    (current_module(env) == target_mod and MapSet.member?(env.local_zero_arity, fun_str)) or
      imported_callable?(env, target_mod, fun_str, 0)
  end

  defp imported_callable?(env, target_mod, fun_str, arity) do
    Enum.any?(env.imports, fn
      %{module: ^target_mod, only: :all, except: except} ->
        not MapSet.member?(except, {fun_str, arity})

      %{module: ^target_mod, only: only_set, except: except} ->
        MapSet.member?(only_set, {fun_str, arity}) and
          not MapSet.member?(except, {fun_str, arity})

      _ ->
        false
    end)
  end

  defp scan_module_zero_arity_defs(body_parts) do
    {_ast, set} =
      Macro.prewalk(body_parts, MapSet.new(), fn
        {inner_mod, _, _}, acc when inner_mod in [:defmodule, :defprotocol, :defimpl] ->
          # Do not descend into nested child modules when scanning outer module 0-arity defs
          {:ok, acc}

        {def_kind, _, [head_ast | _]} = node, acc
        when def_kind in [:def, :defp, :defmacro, :defmacrop, :defguard, :defguardp, :defdelegate] ->
          {call_head, _} = unwrap_when_head(head_ast)

          acc =
            case call_head do
              {fun_atom, _, raw_args} when is_atom(fun_atom) ->
                {min_arity, _max_arity} = arity_bounds(raw_args)
                if min_arity == 0, do: MapSet.put(acc, Atom.to_string(fun_atom)), else: acc

              _ ->
                acc
            end

          {node, acc}

        node, acc ->
          {node, acc}
      end)

    set
  end

  defp unwrap_when_head({:when, _, [head, guard]}), do: {head, guard}
  defp unwrap_when_head(head), do: {head, nil}

  defp arity_bounds(args) when is_list(args) do
    max_arity = length(args)
    defaults = Enum.count(args, &match?({:\\, _, _}, &1))
    {max(max_arity - defaults, 0), max_arity}
  end

  defp arity_bounds(_nil_or_atom), do: {0, 0}

  defp matches_arity?(_arity, :any), do: true
  defp matches_arity?(arity, expected) when is_integer(expected), do: arity == expected

  defp matches_def_arity?(_min, _max, :any), do: true

  defp matches_def_arity?(min_arity, max_arity, expected) when is_integer(expected) do
    expected >= min_arity and expected <= max_arity
  end

  defp record_occurrence(acc, meta, kind, edit, ctx) do
    line = meta[:line]
    col = meta[:column]

    if is_integer(line) and line >= 1 and is_integer(col) and col >= 1 do
      snippet = line_snippet(ctx.line_index, line)

      occ = %{
        line: line,
        column: col,
        kind: kind,
        snippet: snippet,
        edit: edit
      }

      [occ | acc]
    else
      acc
    end
  end

  # ===========================================================================
  # Exact Span & Byte-Offset Editing Helpers
  # ===========================================================================

  defp build_alias_span_edit(alias_meta, segments, replacement) do
    case alias_positions(alias_meta, segments) do
      {{s_line, s_col} = start_pos, {e_line, e_col} = end_pos}
      when is_integer(s_line) and is_integer(s_col) and is_integer(e_line) and is_integer(e_col) ->
        %{
          start_pos: start_pos,
          end_pos: end_pos,
          expected: nil,
          replacement: replacement
        }

      _ ->
        nil
    end
  end

  defp alias_positions(alias_meta, segments) do
    start_line = alias_meta[:line]
    start_col = alias_meta[:column]
    last_meta = alias_meta[:last] || [line: start_line, column: start_col]
    end_line = last_meta[:line]
    last_seg_len = segments |> List.last() |> Atom.to_string() |> codepoint_length()
    end_col = if is_integer(last_meta[:column]), do: last_meta[:column] + last_seg_len, else: nil
    {{start_line, start_col}, {end_line, end_col}}
  end

  defp build_identifier_edit(line, col, expected_ident, replacement)
       when is_integer(line) and is_integer(col) do
    len = codepoint_length(expected_ident)

    %{
      start_pos: {line, col},
      end_pos: {line, col + len},
      expected: expected_ident,
      replacement: replacement
    }
  end

  defp build_identifier_edit(_line, _col, _expected, _replacement), do: nil

  defp find_kw_token_in_lines(tokens, target_atom, min_line, max_line) do
    Enum.find_value(tokens, :error, fn
      {:kw_identifier, {line, col, _}, ^target_atom}
      when line >= min_line and line <= max_line ->
        {:ok, line, col}

      _ ->
        nil
    end)
  end

  defp find_atom_token_in_lines(tokens, target_atom, min_line, max_line) do
    Enum.find_value(tokens, :error, fn
      {:atom, {line, col, _}, ^target_atom}
      when line >= min_line and line <= max_line ->
        {:ok, line, col}

      _ ->
        nil
    end)
  end

  defp build_line_index(source) do
    build_line_index_loop(source, 0, byte_size(source), 1, %{})
  end

  defp build_line_index_loop(source, offset, total, line_num, acc) when offset <= total do
    if offset == total do
      Map.put_new(acc, line_num, {offset, ""})
    else
      case :binary.match(source, "\n", scope: {offset, total - offset}) do
        {nl_pos, 1} ->
          raw_line = binary_part(source, offset, nl_pos - offset)
          clean_line = String.trim_trailing(raw_line, "\r")
          acc = Map.put(acc, line_num, {offset, clean_line})
          build_line_index_loop(source, nl_pos + 1, total, line_num + 1, acc)

        :nomatch ->
          raw_line = binary_part(source, offset, total - offset)
          clean_line = String.trim_trailing(raw_line, "\r")
          Map.put(acc, line_num, {offset, clean_line})
      end
    end
  end

  defp line_snippet(line_index, line_num) do
    case Map.get(line_index, line_num) do
      {_offset, text} -> String.trim(text)
      nil -> ""
    end
  end

  defp line_leading_whitespace(line_index, line_num) do
    case Map.get(line_index, line_num) do
      {_offset, text} ->
        case Regex.run(~r/\A[ \t]*/, text) do
          [ws] -> ws
          _ -> ""
        end

      nil ->
        ""
    end
  end

  defp pos_to_byte(line_index, {line_num, col_1_based})
       when is_integer(line_num) and is_integer(col_1_based) and col_1_based >= 1 do
    case Map.get(line_index, line_num) do
      {line_start_byte, line_text} ->
        prefix_bytes =
          line_text
          |> String.to_charlist()
          |> Enum.take(col_1_based - 1)
          |> List.to_string()
          |> byte_size()

        {:ok, line_start_byte + prefix_bytes}

      nil ->
        :error
    end
  end

  defp pos_to_byte(_line_index, _pos), do: :error

  defp codepoint_length(str) when is_binary(str) do
    length(String.to_charlist(str))
  end

  defp resolve_byte_edits(edits, source, line_index) do
    total_bytes = byte_size(source)

    edits
    |> Enum.flat_map(fn edit ->
      with {:ok, s_byte} <- pos_to_byte(line_index, edit.start_pos),
           {:ok, e_byte} <- pos_to_byte(line_index, edit.end_pos),
           true <- s_byte >= 0 and e_byte >= s_byte and e_byte <= total_bytes do
        actual = binary_part(source, s_byte, e_byte - s_byte)

        if is_nil(edit.expected) or actual == edit.expected do
          [%{start_byte: s_byte, end_byte: e_byte, replacement: edit.replacement}]
        else
          []
        end
      else
        _ -> []
      end
    end)
    |> Enum.uniq_by(fn e -> {e.start_byte, e.end_byte} end)
    |> Enum.sort_by(fn e -> {e.start_byte, e.end_byte} end)
    |> drop_overlapping_edits(-1, [])
  end

  defp drop_overlapping_edits([], _last_end, acc), do: Enum.reverse(acc)

  defp drop_overlapping_edits([edit | rest], last_end, acc) do
    if edit.start_byte >= last_end do
      drop_overlapping_edits(rest, edit.end_byte, [edit | acc])
    else
      drop_overlapping_edits(rest, last_end, acc)
    end
  end

  defp apply_byte_edits(source, sorted_edits) do
    {iodata, cursor} =
      Enum.reduce(sorted_edits, {[], 0}, fn edit, {chunks, pos} ->
        prefix = binary_part(source, pos, edit.start_byte - pos)
        {[edit.replacement, prefix | chunks], edit.end_byte}
      end)

    tail = binary_part(source, cursor, byte_size(source) - cursor)
    IO.iodata_to_binary(Enum.reverse([tail | iodata]))
  end

  # ===========================================================================
  # Pre-Write Syntax Validation & Atomic Rollback Commit
  # ===========================================================================

  defp validate_all_transformed_syntax([], target, rename_target) do
    # Even if zero occurrences matched in workspace files, verify the target name
    # itself is syntactically valid Elixir code!
    probe =
      case {target, rename_target} do
        {{:module, _}, {:module_target, to_mod}} ->
          "defmodule #{to_mod} do\n  def __probe__, do: %#{to_mod}{}\nend"

        {{:function, _, _, _}, {:function_target, to_fun}} ->
          "defmodule Probe do\n  def #{to_fun}(x), do: #{to_fun}(x)\nend"
      end

    case Code.string_to_quoted(probe, columns: true, emit_warnings: false) do
      {:ok, _ast} ->
        :ok

      {:error, {meta, message, token}} ->
        {:error,
         {:invalid_transformed_syntax,
          %{
            file: nil,
            line: meta[:line] || 1,
            column: meta[:column] || 1,
            reason: format_parse_error(message, token)
          }}}
    end
  end

  defp validate_all_transformed_syntax(planned_files, _target, _rename_target) do
    Enum.find_value(planned_files, :ok, fn plan ->
      case Code.string_to_quoted(plan.new_content,
             columns: true,
             emit_warnings: false,
             file: plan.rel_path
           ) do
        {:ok, _ast} ->
          nil

        {:error, {meta, message, token}} ->
          {:error,
           {:invalid_transformed_syntax,
            %{
              file: plan.rel_path,
              line: meta[:line] || 1,
              column: meta[:column] || 1,
              reason: format_parse_error(message, token)
            }}}
      end
    end)
  end

  defp format_parse_error(message, token) do
    msg_str =
      cond do
        is_binary(message) -> message
        is_tuple(message) -> inspect(message)
        is_list(message) -> IO.iodata_to_binary(message)
        true -> inspect(message)
      end

    tok_str = if is_binary(token), do: token, else: inspect(token)
    String.trim("#{msg_str}#{tok_str}")
  end

  defp commit_planned_files_atomically(_canonical_root, []), do: :ok

  defp commit_planned_files_atomically(canonical_root, planned_files) do
    with :ok <- preflight_verify_targets(canonical_root, planned_files) do
      Enum.reduce_while(planned_files, {:ok, []}, fn plan, {:ok, written} ->
        case atomic_write_plan(canonical_root, plan) do
          :ok ->
            {:cont, {:ok, [plan | written]}}

          {:error, reason} ->
            rollback_written_plans(written)
            {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, _written} -> :ok
        {:error, _reason} = err -> err
      end
    end
  end

  defp preflight_verify_targets(canonical_root, planned_files) do
    Enum.find_value(planned_files, :ok, fn plan ->
      with {:ok, authorized} <- WorkspacePath.resolve(canonical_root, plan.rel_path),
           true <- authorized == plan.full_path || {:error, :outside_workspace},
           {:ok, %File.Stat{type: :regular} = stat} <- File.lstat(plan.full_path) do
        if stat.size != plan.stat.size or stat.mtime != plan.stat.mtime do
          {:error, {:stale_target, plan.rel_path}}
        else
          nil
        end
      else
        {:ok, %File.Stat{type: :symlink}} ->
          {:error, :outside_workspace}

        {:error, :outside_workspace} ->
          {:error, :outside_workspace}

        {:error, reason} ->
          {:error, {:write_failed, plan.rel_path, reason}}
      end
    end)
  end

  defp atomic_write_plan(canonical_root, plan) do
    with {:ok, authorized} <- WorkspacePath.resolve(canonical_root, plan.rel_path),
         true <- authorized == plan.full_path || {:error, :outside_workspace},
         {:ok, %File.Stat{type: :regular} = cur_stat} <- File.lstat(plan.full_path) do
      if cur_stat.size != plan.stat.size or cur_stat.mtime != plan.stat.mtime do
        {:error, {:stale_target, plan.rel_path}}
      else
        tmp_path = temp_sibling_path(plan.full_path)

        try do
          case File.write(tmp_path, plan.new_content) do
            :ok ->
              _ = File.chmod(tmp_path, plan.stat.mode)

              case File.rename(tmp_path, plan.full_path) do
                :ok -> :ok
                {:error, reason} -> {:error, {:write_failed, plan.rel_path, reason}}
              end

            {:error, reason} ->
              {:error, {:write_failed, plan.rel_path, reason}}
          end
        after
          _ = File.rm(tmp_path)
        end
      end
    else
      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :outside_workspace}

      {:error, :outside_workspace} ->
        {:error, :outside_workspace}

      {:error, reason} ->
        {:error, {:write_failed, plan.rel_path, reason}}
    end
  end

  defp rollback_written_plans(written_plans) do
    Enum.each(written_plans, fn plan ->
      tmp_path = temp_sibling_path(plan.full_path)

      try do
        if File.write(tmp_path, plan.original_content) == :ok do
          _ = File.chmod(tmp_path, plan.stat.mode)
          _ = File.rename(tmp_path, plan.full_path)
        else
          _ = File.write(plan.full_path, plan.original_content)
        end
      after
        _ = File.rm(tmp_path)
      end
    end)
  end

  defp temp_sibling_path(full_path) do
    dir = Path.dirname(full_path)
    base = Path.basename(full_path)
    uniq = System.unique_integer([:positive])
    Path.join(dir, ".#{base}.symref-#{uniq}.tmp")
  end
end
