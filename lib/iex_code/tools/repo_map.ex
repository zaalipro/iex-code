defmodule IexCode.Tools.RepoMap do
  @moduledoc """
  Compact, bounded structural symbol map generator for workspace source files.

  Walks the workspace respecting `WorkspacePath` containment and excluding
  build/vendor directories (`_build`, `deps`, `node_modules`, `.git`, `tmp`).
  Extracts Elixir structural symbols via `Code.string_to_quoted/2` and top-level
  symbol headers for JS/TS, Python, Rust, and Go, optionally ranking files by
  a `focus_query`.
  """

  alias IexCode.Tools.TestSelector
  alias IexCode.WorkspacePath

  @default_max_bytes 16_000
  @min_max_bytes 256
  @max_max_bytes 128_000
  @max_file_bytes 512_000
  @excluded_dirs MapSet.new(~w(_build deps node_modules .git tmp))
  @elixir_extensions MapSet.new(~w(.ex .exs))
  @js_ts_extensions MapSet.new(~w(.js .jsx .ts .tsx .mjs .cjs))
  @python_extensions MapSet.new(~w(.py))
  @rust_extensions MapSet.new(~w(.rs))
  @go_extensions MapSet.new(~w(.go))

  @doc """
  Generates a bounded structural symbol map for `root_path`.

  Options:
    * `:path` - relative subpath inside `root_path` to scope mapping (default `"."`)
    * `:focus_query` - optional query string ranking matching files first
    * `:max_bytes` - maximum output byte budget (default `16_000`)
  """
  @spec generate(Path.t(), keyword() | map()) :: {:ok, String.t()} | {:error, term()}
  def generate(root_path, opts \\ [])

  def generate(root_path, args) when is_binary(root_path) and is_map(args) do
    opts =
      []
      |> maybe_put_opt(:path, Map.get(args, "path") || Map.get(args, :path))
      |> maybe_put_opt(
        :focus_query,
        Map.get(args, "focus_query") || Map.get(args, :focus_query)
      )
      |> maybe_put_opt(:max_bytes, Map.get(args, "max_bytes") || Map.get(args, :max_bytes))

    generate(root_path, opts)
  end

  def generate(root_path, opts) when is_binary(root_path) and is_list(opts) do
    subpath = opts |> Keyword.get(:path) |> normalize_subpath()
    focus_query = opts |> Keyword.get(:focus_query) |> normalize_query()
    max_bytes = opts |> Keyword.get(:max_bytes) |> normalize_max_bytes()

    with {:ok, canonical_root} <- WorkspacePath.resolve(root_path, "."),
         {:ok, target_path} <- WorkspacePath.resolve(canonical_root, subpath) do
      cond do
        File.regular?(target_path) ->
          rel = relative_display_path(canonical_root, target_path)

          entries =
            extract_file_entry(target_path, rel)
            |> List.wrap()
            |> attach_paired_tests([])

          {:ok, format_repo_map(entries, subpath, focus_query, max_bytes)}

        File.dir?(target_path) ->
          raw_entries =
            target_path
            |> collect_source_files()
            |> Enum.flat_map(fn abs_path ->
              rel = relative_display_path(canonical_root, abs_path)
              extract_file_entry(abs_path, rel) |> List.wrap()
            end)

          test_files =
            raw_entries
            |> Enum.map(& &1.path)
            |> Enum.filter(&TestSelector.test_file?/1)

          entries =
            raw_entries
            |> attach_paired_tests(test_files)
            |> rank_entries(focus_query)

          {:ok, format_repo_map(entries, subpath, focus_query, max_bytes)}

        true ->
          {:error, "Path does not exist: #{subpath}"}
      end
    else
      {:error, reason} -> {:error, format_path_error(reason, subpath)}
    end
  end

  @doc """
  Returns paired test file paths in `root_path` for `source_path` using Elixir
  and polyglot test-pairing conventions.
  """
  @spec paired_tests(Path.t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def paired_tests(root_path, source_path)
      when is_binary(root_path) and is_binary(source_path) do
    with {:ok, canonical_root} <- WorkspacePath.resolve(root_path, "."),
         {:ok, resolved_source} <- WorkspacePath.resolve(canonical_root, source_path) do
      rel_source = relative_display_path(canonical_root, resolved_source)

      test_files =
        canonical_root
        |> collect_source_files()
        |> Enum.map(&relative_display_path(canonical_root, &1))
        |> Enum.filter(&TestSelector.test_file?/1)

      {:ok, TestSelector.paired_tests_for(rel_source, test_files)}
    else
      {:error, reason} -> {:error, format_path_error(reason, source_path)}
    end
  end

  defp format_path_error(:outside_workspace, subpath),
    do: "Path escapes the workspace: #{subpath}"

  defp format_path_error(:invalid_workspace, _subpath),
    do: "Invalid workspace directory"

  defp format_path_error(reason, subpath),
    do: "Invalid path #{subpath}: #{inspect(reason)}"

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp normalize_subpath(nil), do: "."
  defp normalize_subpath(""), do: "."
  defp normalize_subpath(path) when is_binary(path), do: path
  defp normalize_subpath(_), do: "."

  defp normalize_query(q) when is_binary(q) do
    case String.trim(q) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_query(_), do: nil

  defp normalize_max_bytes(val) when is_integer(val) do
    val |> max(@min_max_bytes) |> min(@max_max_bytes)
  end

  defp normalize_max_bytes(val) when is_binary(val) do
    case Integer.parse(String.trim(val)) do
      {parsed, ""} -> normalize_max_bytes(parsed)
      _ -> @default_max_bytes
    end
  end

  defp normalize_max_bytes(_), do: @default_max_bytes

  # --- File Traversal ---

  defp collect_source_files(dir) do
    dir
    |> walk_dir([])
    |> Enum.sort()
  end

  defp walk_dir(dir, acc) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.reduce(names, acc, fn name, inner_acc ->
          full_path = Path.join(dir, name)
          classify_and_collect(name, full_path, inner_acc)
        end)

      {:error, _} ->
        acc
    end
  end

  defp classify_and_collect(name, full_path, acc) do
    case File.lstat(full_path) do
      {:ok, %File.Stat{type: :symlink}} ->
        acc

      {:ok, %File.Stat{type: :directory}} ->
        if MapSet.member?(@excluded_dirs, name), do: acc, else: walk_dir(full_path, acc)

      {:ok, %File.Stat{type: :regular, size: size}} ->
        if size <= @max_file_bytes and supported_extension?(full_path),
          do: [full_path | acc],
          else: acc

      _ ->
        acc
    end
  end

  defp supported_extension?(path) do
    ext = path |> Path.extname() |> String.downcase()

    MapSet.member?(@elixir_extensions, ext) or
      MapSet.member?(@js_ts_extensions, ext) or
      MapSet.member?(@python_extensions, ext) or
      MapSet.member?(@rust_extensions, ext) or
      MapSet.member?(@go_extensions, ext)
  end

  defp relative_display_path(canonical_root, abs_path) do
    case Path.relative_to(abs_path, canonical_root) do
      ^abs_path -> Path.basename(abs_path)
      "" -> Path.basename(abs_path)
      rel -> rel
    end
  end

  # --- Symbol Extraction ---

  defp extract_file_entry(abs_path, rel_path) do
    with true <- supported_extension?(abs_path),
         {:ok, content} <- File.read(abs_path) do
      ext = abs_path |> Path.extname() |> String.downcase()
      symbols = extract_symbols(content, ext)
      %{path: rel_path, symbols: symbols}
    else
      _ -> nil
    end
  end

  defp extract_symbols(content, ext) do
    cond do
      MapSet.member?(@elixir_extensions, ext) -> extract_elixir_symbols(content)
      MapSet.member?(@js_ts_extensions, ext) -> extract_js_ts_symbols(content)
      MapSet.member?(@python_extensions, ext) -> extract_python_symbols(content)
      MapSet.member?(@rust_extensions, ext) -> extract_rust_symbols(content)
      MapSet.member?(@go_extensions, ext) -> extract_go_symbols(content)
      true -> []
    end
  end

  # --- Elixir AST Extraction ---

  defp extract_elixir_symbols(content) do
    case Code.string_to_quoted(content, columns: true, token_metadata: true, emit_warnings: false) do
      {:ok, ast} ->
        walk_elixir_ast(ast, [], [])
        |> Enum.reverse()

      {:error, _} ->
        extract_elixir_regex_fallback(content)
    end
  end

  defp walk_elixir_ast({:__block__, _meta, exprs}, ns, acc) when is_list(exprs) do
    Enum.reduce(exprs, acc, &walk_elixir_ast(&1, ns, &2))
  end

  defp walk_elixir_ast({form, meta, [mod_ast, opts_or_body | _]}, ns, acc)
       when form in [:defmodule, :defprotocol] do
    mod_name = format_module_name(mod_ast, ns)
    line = Keyword.get(meta, :line, 1)
    acc = [{line, "#{form} #{mod_name}"} | acc]
    next_ns = String.split(mod_name, ".")
    body = extract_do_body(opts_or_body)
    walk_elixir_ast(body, next_ns, acc)
  end

  defp walk_elixir_ast({:defimpl, meta, [proto_ast | rest]}, ns, acc) do
    line = Keyword.get(meta, :line, 1)
    proto_name = format_alias_or_term(proto_ast)
    {for_target, body} = extract_defimpl_parts(rest)

    label =
      if for_target,
        do: "defimpl #{proto_name}, for: #{for_target}",
        else: "defimpl #{proto_name}"

    acc = [{line, label} | acc]
    walk_elixir_ast(body, ns, acc)
  end

  defp walk_elixir_ast({:@, meta, [{:behaviour, _am, [mod_ast]}]}, _ns, acc) do
    line = Keyword.get(meta, :line, 1)
    [{line, "@behaviour #{format_alias_or_term(mod_ast)}"} | acc]
  end

  defp walk_elixir_ast({:@, meta, [{attr, _am, [spec_ast]}]}, _ns, acc)
       when attr in [:type, :opaque, :callback, :macrocallback] do
    line = Keyword.get(meta, :line, 1)

    case extract_spec_signature(spec_ast) do
      {name, arity} -> [{line, "@#{attr} #{name}/#{arity}"} | acc]
      nil -> acc
    end
  end

  defp walk_elixir_ast({form, meta, [head | _rest]}, _ns, acc)
       when form in [:def, :defmacro, :defguard, :defdelegate] do
    line = Keyword.get(meta, :line, 1)

    case extract_def_signature(head) do
      {name, arity} -> [{line, "#{form} #{name}/#{arity}"} | acc]
      nil -> acc
    end
  end

  defp walk_elixir_ast(_other, _ns, acc), do: acc

  defp extract_do_body([{:do, body} | _]), do: body
  defp extract_do_body(list) when is_list(list), do: Keyword.get(list, :do)
  defp extract_do_body(_), do: nil

  defp extract_defimpl_parts([[{:for, for_ast} | _], opts]) do
    {format_alias_or_term(for_ast), extract_do_body(opts)}
  end

  defp extract_defimpl_parts([opts]) when is_list(opts) do
    for_ast = Keyword.get(opts, :for)
    target = if for_ast, do: format_alias_or_term(for_ast), else: nil
    {target, Keyword.get(opts, :do)}
  end

  defp extract_defimpl_parts(_), do: {nil, nil}

  defp extract_def_signature({:when, _meta, [inner | _]}), do: extract_def_signature(inner)

  defp extract_def_signature({name, _meta, args}) when is_atom(name) and is_list(args) do
    {name, length(args)}
  end

  defp extract_def_signature({name, _meta, ctx}) when is_atom(name) and is_atom(ctx) do
    {name, 0}
  end

  defp extract_def_signature(_), do: nil

  defp extract_spec_signature({:when, _meta, [inner | _]}), do: extract_spec_signature(inner)
  defp extract_spec_signature({:"::", _meta, [head | _]}), do: extract_def_signature(head)
  defp extract_spec_signature(other), do: extract_def_signature(other)

  defp format_module_name({:__aliases__, _meta, parts}, ns) when is_list(parts) do
    part_strs = Enum.map(parts, &to_string/1)

    if ns == [] do
      Enum.join(part_strs, ".")
    else
      Enum.join(ns ++ part_strs, ".")
    end
  end

  defp format_module_name(other, _ns), do: format_alias_or_term(other)

  defp format_alias_or_term({:__aliases__, _meta, parts}) when is_list(parts) do
    Enum.map_join(parts, ".", &to_string/1)
  end

  defp format_alias_or_term(atom) when is_atom(atom), do: inspect(atom)
  defp format_alias_or_term(other), do: Macro.to_string(other)

  defp extract_elixir_regex_fallback(content) do
    regex =
      ~r/^\s*(?:(defmodule|defprotocol|defimpl)\s+([^\s,(]+)|@(behaviour)\s+([^\s]+)|@(type|opaque|callback|macrocallback)\s+([a-z_][a-zA-Z0-9_?!]*)|(def|defmacro|defguard|defdelegate)\s+([a-z_][a-zA-Z0-9_?!]*))/

    scan_lines_regex(content, fn trimmed ->
      case Regex.run(regex, trimmed) do
        [_, form, name] -> "#{form} #{name}"
        [_, "", "", "behaviour", mod] -> "@behaviour #{mod}"
        [_, "", "", "", "", attr, name] -> "@#{attr} #{name}"
        [_, "", "", "", "", "", "", form, name] -> "#{form} #{name}"
        _ -> nil
      end
    end)
  end

  # --- Non-Elixir Top-Level Symbol Extraction ---

  defp extract_js_ts_symbols(content) do
    patterns = [
      ~r/^(?:export\s+(?:default\s+)?)?(?:declare\s+)?(?:abstract\s+)?(?:async\s+)?(function\*?|class|interface|enum)\s+([A-Za-z_$][\w$]*)/,
      ~r/^(?:export\s+)?(type)\s+([A-Za-z_$][\w$]*)\s*(?:<[^>]*>)?\s*=/,
      ~r/^(?:export\s+)?(const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s+)?(?:\([^)]*\)|[A-Za-z_$][\w$]*)\s*=>/
    ]

    scan_top_level_patterns(content, patterns)
  end

  defp extract_python_symbols(content) do
    patterns = [
      ~r/^(?:async\s+)?(def)\s+([A-Za-z_]\w*)\s*\(/,
      ~r/^(class)\s+([A-Za-z_]\w*)/
    ]

    scan_top_level_patterns(content, patterns)
  end

  defp extract_rust_symbols(content) do
    patterns = [
      ~r/^(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?(?:unsafe\s+)?(?:extern\s+(?:"[^"]+"\s+)?)?(fn|struct|enum|trait|mod|type)\s+([A-Za-z_]\w*)/,
      ~r/^(?:unsafe\s+)?(impl)(?:<[^>]*>)?\s+([A-Za-z_][\w:<>]*(?:\s+for\s+[A-Za-z_][\w:<>]*)?)/
    ]

    scan_top_level_patterns(content, patterns)
  end

  defp extract_go_symbols(content) do
    patterns = [
      ~r/^(func)\s+(?:\([^)]+\)\s+)?([A-Za-z_]\w*)/,
      ~r/^(type)\s+([A-Za-z_]\w*)\s+(?:struct|interface|[A-Za-z_\[*])/
    ]

    scan_top_level_patterns(content, patterns)
  end

  defp scan_top_level_patterns(content, patterns) do
    content
    |> String.split(~r/\r?\n/)
    |> Enum.with_index(1)
    |> Enum.reduce([], fn {line, line_no}, acc ->
      trimmed_end = String.trim_trailing(line)

      case match_first_pattern(trimmed_end, patterns) do
        nil -> acc
        label -> [{line_no, label} | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp match_first_pattern(line, patterns) do
    Enum.find_value(patterns, fn regex ->
      case Regex.run(regex, line) do
        [_, kind, name] -> "#{kind} #{String.trim(name)}"
        _ -> nil
      end
    end)
  end

  defp scan_lines_regex(content, extractor) do
    content
    |> String.split(~r/\r?\n/)
    |> Enum.with_index(1)
    |> Enum.reduce([], fn {line, line_no}, acc ->
      case extractor.(line) do
        nil -> acc
        label -> [{line_no, label} | acc]
      end
    end)
    |> Enum.reverse()
  end

  # --- Ranking & Formatting ---

  defp rank_entries(entries, nil), do: Enum.sort_by(entries, & &1.path)

  defp rank_entries(entries, focus_query) do
    down_query = String.downcase(focus_query)
    tokens = String.split(down_query, ~r/[\s,\/.:]+/, trim: true)

    entries
    |> Enum.map(fn entry ->
      score = score_entry(entry, down_query, tokens)
      {score, entry}
    end)
    |> Enum.sort_by(fn {score, entry} -> {-score, entry.path} end)
    |> Enum.map(&elem(&1, 1))
  end

  defp attach_paired_tests(entries, test_files) do
    Enum.map(entries, fn entry ->
      tests = TestSelector.paired_tests_for(entry.path, test_files)
      Map.put(entry, :tests, tests)
    end)
  end

  defp score_entry(entry, down_query, tokens) do
    down_path = String.downcase(entry.path)
    down_symbols = Enum.map_join(entry.symbols, "\n", fn {_line, sym} -> String.downcase(sym) end)
    down_tests = entry |> Map.get(:tests, []) |> Enum.map_join("\n", &String.downcase/1)

    phrase_bonus =
      cond do
        String.contains?(down_path, down_query) -> 20
        String.contains?(down_symbols, down_query) -> 12
        down_tests != "" and String.contains?(down_tests, down_query) -> 4
        true -> 0
      end

    token_score =
      Enum.reduce(tokens, 0, fn tok, acc ->
        path_hit = if String.contains?(down_path, tok), do: 10, else: 0
        sym_hit = if String.contains?(down_symbols, tok), do: 3, else: 0
        test_hit = if down_tests != "" and String.contains?(down_tests, tok), do: 1, else: 0
        acc + path_hit + sym_hit + test_hit
      end)

    phrase_bonus + token_score
  end

  defp format_repo_map([], subpath, _focus_query, _max_bytes) do
    "No supported source files found under #{subpath}."
  end

  defp format_repo_map(entries, subpath, focus_query, max_bytes) do
    focus_suffix = if focus_query, do: ", focus: #{inspect(focus_query)}", else: ""
    header = "# Repo Map (#{length(entries)} file(s), path: #{subpath}#{focus_suffix})\n"

    blocks = Enum.map(entries, &format_entry_block/1)
    assemble_bounded_output(header, blocks, max_bytes)
  end

  defp format_entry_block(%{path: path, symbols: []} = entry) do
    tests_line = format_tests_line(Map.get(entry, :tests, []))
    "## #{path}\n  (no symbols extracted)\n#{tests_line}"
  end

  defp format_entry_block(%{path: path, symbols: symbols} = entry) do
    sym_lines =
      Enum.map_join(symbols, "\n", fn {line_no, label} ->
        "  L#{line_no} #{label}"
      end)

    tests_line = format_tests_line(Map.get(entry, :tests, []))
    "## #{path}\n#{sym_lines}\n#{tests_line}"
  end

  defp format_tests_line([]), do: ""
  defp format_tests_line(tests), do: "  Tests: #{Enum.join(tests, ", ")}\n"

  defp assemble_bounded_output(header, blocks, max_bytes) do
    total_blocks = length(blocks)
    footer_reserve = 72
    effective_limit = max(max_bytes - footer_reserve, 0)

    {acc_parts, _acc_bytes, included_count, truncated?} =
      Enum.reduce_while(blocks, {[header], byte_size(header), 0, false}, fn block,
                                                                            {parts, bytes, count,
                                                                             _trunc} ->
        addition = "\n" <> block
        add_size = byte_size(addition)

        if bytes + add_size <= effective_limit do
          {:cont, {[addition | parts], bytes + add_size, count + 1, false}}
        else
          {:halt, {parts, bytes, count, true}}
        end
      end)

    cond do
      not truncated? ->
        acc_parts |> Enum.reverse() |> IO.iodata_to_binary() |> clamp_utf8_bytes(max_bytes)

      included_count == 0 ->
        first_chunk = header <> "\n" <> hd(blocks)
        footer = "\n... [truncated at #{max_bytes} bytes]"
        take_budget = max(max_bytes - byte_size(footer), 0)
        clamp_utf8_bytes(first_chunk, take_budget) <> footer

      true ->
        omitted = total_blocks - included_count
        footer = "\n... [truncated at #{max_bytes} bytes: omitted #{omitted} file(s)]"
        body = acc_parts |> Enum.reverse() |> IO.iodata_to_binary()
        clamp_utf8_bytes(body, max(max_bytes - byte_size(footer), 0)) <> footer
    end
  end

  defp clamp_utf8_bytes(binary, limit) when byte_size(binary) <= limit, do: binary
  defp clamp_utf8_bytes(_binary, limit) when limit <= 0, do: ""

  defp clamp_utf8_bytes(binary, limit) do
    slice = binary_part(binary, 0, limit)
    do_trim_invalid_tail(slice)
  end

  defp do_trim_invalid_tail(<<>>), do: ""

  defp do_trim_invalid_tail(slice) do
    if String.valid?(slice) do
      slice
    else
      do_trim_invalid_tail(binary_part(slice, 0, byte_size(slice) - 1))
    end
  end
end
