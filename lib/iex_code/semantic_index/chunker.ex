defmodule IexCode.SemanticIndex.Chunker do
  @moduledoc """
  Intelligent code chunking engine for offline semantic indexing.
  - Elixir files (`.ex`, `.exs`): AST symbol decomposition via `ASTSearch.Extractor`
    (modules, functions, macros, types, callbacks) with contextual symbol signatures.
  - Polyglot source files (`.ts`, `.tsx`, `.js`, `.jsx`, `.mjs`, `.cjs`, `.py`, `.go`, `.rs`):
    symbol-aware decomposition (`function`, `class`, `interface`, `type`, `struct`, `impl`, `method`)
    with accurate line ranges and context headers, falling back to windowed line chunking if no
    declarations are found.
  - Non-code / documentation files (`.md`, `.json`, `.txt`, `.heex`, etc.): windowed sliding
    line chunking (50 lines per chunk, 10 lines overlap).
  """

  alias IexCode.Tools.ASTSearch.Extractor

  @js_ts_extensions ~w(.ts .tsx .js .jsx .mjs .cjs)
  @python_extensions ~w(.py)
  @go_extensions ~w(.go)
  @rust_extensions ~w(.rs)

  @js_control_keywords MapSet.new(~w(if for while switch catch with return else try do))

  @doc """
  Decomposes a source file into indexable semantic chunks.
  Returns a list of chunk maps.
  """
  @spec chunk_file(String.t(), String.t()) :: [map()]
  def chunk_file(file_path, content) when is_binary(file_path) and is_binary(content) do
    ext = Path.extname(file_path) |> String.downcase()

    cond do
      ext in [".ex", ".exs"] ->
        chunk_elixir_file(file_path, content)

      ext in @js_ts_extensions ->
        chunk_polyglot_or_fallback(file_path, content, :js_ts)

      ext in @python_extensions ->
        chunk_polyglot_or_fallback(file_path, content, :python)

      ext in @go_extensions ->
        chunk_polyglot_or_fallback(file_path, content, :go)

      ext in @rust_extensions ->
        chunk_polyglot_or_fallback(file_path, content, :rust)

      true ->
        chunk_text_file(file_path, content)
    end
  end

  # ============================================================================
  # Elixir AST Chunking
  # ============================================================================

  defp chunk_elixir_file(file_path, content) do
    case Extractor.extract(content, file_path) do
      {:ok, symbols} when is_list(symbols) and symbols != [] ->
        symbols
        |> Enum.with_index()
        |> Enum.map(fn {sym, idx} ->
          type_str = to_string(sym.type)
          name_str = to_string(sym.name)
          end_line = sym[:end_line] || sym.line + max(1, length(String.split(sym.code, "\n")) - 1)

          context_header =
            "File: #{file_path} | #{type_str} #{name_str}" <>
              if(sym[:arity], do: "/#{sym.arity}", else: "")

          chunk_content = "#{context_header}\n\n#{sym.code}"

          chunk_type =
            cond do
              type_str in ["def", "defp", "function"] -> "function"
              type_str in ["defmodule", "module"] -> "module"
              type_str in ["defmacro", "macro"] -> "macro"
              type_str in ["spec", "@spec"] -> "spec"
              type_str in ["type", "@type"] -> "type"
              type_str in ["doc", "moduledoc", "@doc", "@moduledoc"] -> "doc"
              true -> type_str
            end

          %{
            chunk_index: idx,
            chunk_type: chunk_type,
            symbol_name: name_str,
            symbol_type: type_str,
            start_line: sym.line,
            end_line: end_line,
            content: chunk_content
          }
        end)

      _ ->
        chunk_text_file(file_path, content)
    end
  end

  # ============================================================================
  # Polyglot Symbol-Aware Chunking (TS/JS, Python, Go, Rust)
  # ============================================================================

  defp chunk_polyglot_or_fallback(file_path, content, lang) do
    if String.trim(content) == "" do
      chunk_text_file(file_path, content)
    else
      lines = String.split(content, ~r/\r?\n/)

      symbols =
        case lang do
          :python -> extract_python_symbols(lines)
          brace_lang -> extract_brace_symbols(lines, brace_lang)
        end

      case symbols do
        [] ->
          chunk_text_file(file_path, content)

        found ->
          found
          |> Enum.with_index()
          |> Enum.map(fn {sym, idx} ->
            code =
              lines
              |> Enum.slice(sym.start_line - 1, sym.end_line - sym.start_line + 1)
              |> Enum.join("\n")

            %{
              chunk_index: idx,
              chunk_type: sym.chunk_type,
              symbol_name: sym.symbol_name,
              symbol_type: sym.symbol_type,
              start_line: sym.start_line,
              end_line: sym.end_line,
              content: "File: #{file_path} | #{sym.symbol_type} #{sym.symbol_name}\n\n#{code}"
            }
          end)
      end
    end
  end

  # --- Brace-Delimited Languages (JS/TS, Go, Rust) ---

  defp extract_brace_symbols(lines, lang) do
    total_lines = length(lines)
    meta_by_line = analyze_brace_lines(lines, lang)

    {symbols, _containers} =
      lines
      |> Enum.with_index(1)
      |> Enum.reduce({[], []}, fn {line, line_no}, {acc, containers} ->
        line_meta = Map.fetch!(meta_by_line, line_no)
        active_containers = Enum.filter(containers, fn c -> line_no <= c.end_line end)

        if line_meta.starts_in_comment_or_string? do
          {acc, active_containers}
        else
          trimmed = String.trim_leading(line)

          case match_brace_declaration(trimmed, lang, line_meta.depth_before, active_containers) do
            nil ->
              {acc, active_containers}

            {chunk_type, symbol_type, name, container?} ->
              end_line =
                resolve_brace_end_line(line_no, total_lines, lines, meta_by_line, lang)

              entry = %{
                chunk_type: chunk_type,
                symbol_type: symbol_type,
                symbol_name: name,
                start_line: line_no,
                end_line: end_line
              }

              next_containers =
                if container? do
                  [%{depth: line_meta.depth_before, end_line: end_line} | active_containers]
                else
                  active_containers
                end

              {[entry | acc], next_containers}
          end
        end
      end)

    Enum.reverse(symbols)
  end

  defp match_brace_declaration("", _lang, _depth, _containers), do: nil

  defp match_brace_declaration(trimmed, :js_ts, depth, containers) do
    in_class? = Enum.any?(containers, fn c -> depth == c.depth + 1 end)

    cond do
      match =
          Regex.run(
            ~r/^(?:export\s+(?:default\s+)?)?(?:declare\s+)?(?:abstract\s+)?class\s+([A-Za-z_$][\w$]*)/,
            trimmed
          ) ->
        [_, name] = match
        {"class", "class", name, true}

      match =
          Regex.run(
            ~r/^(?:export\s+(?:default\s+)?)?(?:declare\s+)?interface\s+([A-Za-z_$][\w$]*)/,
            trimmed
          ) ->
        [_, name] = match
        {"interface", "interface", name, false}

      match =
          Regex.run(
            ~r/^(?:export\s+)?(?:declare\s+)?type\s+([A-Za-z_$][\w$]*)\s*(?:<[^>]*>)?\s*=/,
            trimmed
          ) ->
        [_, name] = match
        {"type", "type", name, false}

      match =
          Regex.run(
            ~r/^(?:export\s+(?:default\s+)?)?(?:declare\s+)?(?:const\s+)?enum\s+([A-Za-z_$][\w$]*)/,
            trimmed
          ) ->
        [_, name] = match
        {"type", "enum", name, false}

      match =
          Regex.run(
            ~r/^(?:export\s+(?:default\s+)?)?(?:declare\s+)?(?:async\s+)?function\*?\s+([A-Za-z_$][\w$]*)/,
            trimmed
          ) ->
        [_, name] = match
        {"function", "function", name, false}

      match =
          Regex.run(
            ~r/^(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*(?::[^=]+)?=\s*(?:async\s+)?(?:\([^)]*\)|[A-Za-z_$][\w$]*)\s*(?::[^=]+)?=>/,
            trimmed
          ) ->
        [_, name] = match
        {"function", "function", name, false}

      in_class? ->
        case Regex.run(
               ~r/^(?:(?:public|private|protected|static|async|get|set|readonly|override|abstract)\s+)*([A-Za-z_$][\w$]*)\s*(?:<[^>]*>)?\s*\([^)]*\)\s*(?::[^{;]+)?\{/,
               trimmed
             ) do
          [_, name] ->
            if MapSet.member?(@js_control_keywords, name) do
              nil
            else
              {"method", "method", name, false}
            end

          _ ->
            nil
        end

      true ->
        nil
    end
  end

  defp match_brace_declaration(trimmed, :go, 0, _containers) do
    cond do
      match =
          Regex.run(
            ~r/^func\s+\([^)]+\)\s+([A-Za-z_]\w*)\s*(?:\[[^\]]*\])?\s*\(/,
            trimmed
          ) ->
        [_, name] = match
        {"method", "method", name, false}

      match = Regex.run(~r/^func\s+([A-Za-z_]\w*)\s*(?:\[[^\]]*\])?\s*\(/, trimmed) ->
        [_, name] = match
        {"function", "function", name, false}

      match = Regex.run(~r/^type\s+([A-Za-z_]\w*)(?:\[[^\]]*\])?\s+struct\b/, trimmed) ->
        [_, name] = match
        {"struct", "struct", name, false}

      match = Regex.run(~r/^type\s+([A-Za-z_]\w*)(?:\[[^\]]*\])?\s+interface\b/, trimmed) ->
        [_, name] = match
        {"interface", "interface", name, false}

      match = Regex.run(~r/^type\s+([A-Za-z_]\w*)\b/, trimmed) ->
        [_, name] = match
        {"type", "type", name, false}

      true ->
        nil
    end
  end

  defp match_brace_declaration(_trimmed, :go, _depth, _containers), do: nil

  defp match_brace_declaration(trimmed, :rust, depth, containers) do
    in_impl_or_trait? = Enum.any?(containers, fn c -> depth == c.depth + 1 end)

    cond do
      match =
          Regex.run(
            ~r/^(?:unsafe\s+)?impl(?:<[^>]*>)?\s+([A-Za-z_].*?)(?:\s+where\b|\s*\{|$)/,
            trimmed
          ) ->
        [_, raw_name] = match
        name = String.trim(raw_name)
        {"impl", "impl", name, true}

      match =
          Regex.run(
            ~r/^(?:pub(?:\([^)]*\))?\s+)?(?:unsafe\s+)?trait\s+([A-Za-z_]\w*)/,
            trimmed
          ) ->
        [_, name] = match
        {"interface", "trait", name, true}

      match = Regex.run(~r/^(?:pub(?:\([^)]*\))?\s+)?struct\s+([A-Za-z_]\w*)/, trimmed) ->
        [_, name] = match
        {"struct", "struct", name, false}

      match = Regex.run(~r/^(?:pub(?:\([^)]*\))?\s+)?enum\s+([A-Za-z_]\w*)/, trimmed) ->
        [_, name] = match
        {"type", "enum", name, false}

      match = Regex.run(~r/^(?:pub(?:\([^)]*\))?\s+)?type\s+([A-Za-z_]\w*)/, trimmed) ->
        [_, name] = match
        {"type", "type", name, false}

      match =
          Regex.run(
            ~r/^(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?(?:unsafe\s+)?(?:const\s+)?(?:extern\s+(?:"[^"]+"\s+)?)?fn\s+([A-Za-z_]\w*)/,
            trimmed
          ) ->
        [_, name] = match
        kind = if in_impl_or_trait?, do: "method", else: "function"
        {kind, kind, name, false}

      true ->
        nil
    end
  end

  defp resolve_brace_end_line(start_line, total_lines, lines, meta_by_line, lang) do
    start_meta = Map.fetch!(meta_by_line, start_line)
    base_depth = start_meta.depth_before

    cond do
      start_meta.opened_brace? and start_meta.depth_after <= base_depth ->
        start_line

      start_meta.opened_brace? ->
        find_closing_brace_line(start_line + 1, total_lines, base_depth, meta_by_line)

      start_meta.ends_with_semicolon? ->
        start_line

      true ->
        # Handle Allman-style opening brace on a subsequent line or multi-line statement ending in `;`
        start_idx_line = Enum.at(lines, start_line - 1, "")

        if String.contains?(start_idx_line, "=>") do
          # Single-line arrow function without braces
          find_semicolon_or_line_end(start_line, total_lines, meta_by_line)
        else
          case find_upcoming_brace_or_semicolon(
                 start_line + 1,
                 total_lines,
                 base_depth,
                 lines,
                 meta_by_line,
                 lang
               ) do
            {:brace, open_line} ->
              if Map.fetch!(meta_by_line, open_line).depth_after <= base_depth do
                open_line
              else
                find_closing_brace_line(open_line + 1, total_lines, base_depth, meta_by_line)
              end

            {:semi, end_line} ->
              end_line

            :none ->
              start_line
          end
        end
    end
  end

  defp find_closing_brace_line(line_no, total_lines, _base_depth, _meta_by_line)
       when line_no > total_lines,
       do: total_lines

  defp find_closing_brace_line(line_no, total_lines, base_depth, meta_by_line) do
    meta = Map.fetch!(meta_by_line, line_no)

    if meta.depth_after <= base_depth do
      line_no
    else
      find_closing_brace_line(line_no + 1, total_lines, base_depth, meta_by_line)
    end
  end

  defp find_semicolon_or_line_end(start_line, total_lines, meta_by_line) do
    Enum.find(start_line..min(start_line + 5, total_lines), start_line, fn ln ->
      Map.fetch!(meta_by_line, ln).ends_with_semicolon?
    end)
  end

  defp find_upcoming_brace_or_semicolon(
         line_no,
         total_lines,
         _base_depth,
         _lines,
         _meta_by_line,
         _lang
       )
       when line_no > total_lines,
       do: :none

  defp find_upcoming_brace_or_semicolon(
         line_no,
         total_lines,
         base_depth,
         lines,
         meta_by_line,
         lang
       ) do
    limit = min(line_no + 4, total_lines)

    Enum.reduce_while(line_no..limit, :none, fn ln, _acc ->
      line = Enum.at(lines, ln - 1, "")
      trimmed = String.trim_leading(line)
      meta = Map.fetch!(meta_by_line, ln)

      cond do
        match_brace_declaration(trimmed, lang, meta.depth_before, []) != nil ->
          {:halt, :none}

        meta.opened_brace? and meta.depth_before == base_depth ->
          {:halt, {:brace, ln}}

        meta.ends_with_semicolon? ->
          {:halt, {:semi, ln}}

        true ->
          {:cont, :none}
      end
    end)
  end

  defp analyze_brace_lines(lines, lang) do
    init_lex = %{depth: 0, in_block_comment: false, string_quote: nil}

    {meta_map, _final_lex} =
      lines
      |> Enum.with_index(1)
      |> Enum.reduce({%{}, init_lex}, fn {line, line_no}, {acc, lex} ->
        starts_in_comment_or_string? = lex.in_block_comment or not is_nil(lex.string_quote)
        depth_before = lex.depth
        {next_lex, opened?, ends_semi?} = scan_brace_line(line, lex, lang, false, false)

        meta = %{
          depth_before: depth_before,
          depth_after: next_lex.depth,
          opened_brace?: opened?,
          ends_with_semicolon?: ends_semi?,
          starts_in_comment_or_string?: starts_in_comment_or_string?
        }

        {Map.put(acc, line_no, meta), next_lex}
      end)

    meta_map
  end

  defp scan_brace_line(<<>>, lex, _lang, opened?, ends_semi?), do: {lex, opened?, ends_semi?}

  defp scan_brace_line(
         <<"*/", rest::binary>>,
         %{in_block_comment: true} = lex,
         lang,
         opened?,
         _semi
       ) do
    scan_brace_line(rest, %{lex | in_block_comment: false}, lang, opened?, false)
  end

  defp scan_brace_line(<<_c, rest::binary>>, %{in_block_comment: true} = lex, lang, opened?, semi) do
    scan_brace_line(rest, lex, lang, opened?, semi)
  end

  defp scan_brace_line(
         <<"\\", _escaped, rest::binary>>,
         %{string_quote: q} = lex,
         lang,
         opened?,
         _semi
       )
       when not is_nil(q) and q != ?` do
    scan_brace_line(rest, lex, lang, opened?, false)
  end

  defp scan_brace_line(
         <<"\\", _escaped, rest::binary>>,
         %{string_quote: ?`} = lex,
         :js_ts,
         opened?,
         _semi
       ) do
    scan_brace_line(rest, lex, :js_ts, opened?, false)
  end

  defp scan_brace_line(<<ch, rest::binary>>, %{string_quote: q} = lex, lang, opened?, _semi)
       when not is_nil(q) do
    next_lex = if ch == q, do: %{lex | string_quote: nil}, else: lex
    scan_brace_line(rest, next_lex, lang, opened?, false)
  end

  defp scan_brace_line(<<"//", _rest::binary>>, lex, _lang, opened?, ends_semi?) do
    {lex, opened?, ends_semi?}
  end

  defp scan_brace_line(<<"/*", rest::binary>>, lex, lang, opened?, _semi) do
    scan_brace_line(rest, %{lex | in_block_comment: true}, lang, opened?, false)
  end

  defp scan_brace_line(<<?", rest::binary>>, lex, lang, opened?, _semi) do
    scan_brace_line(rest, %{lex | string_quote: ?"}, lang, opened?, false)
  end

  defp scan_brace_line(<<?`, rest::binary>>, lex, lang, opened?, _semi)
       when lang in [:js_ts, :go] do
    scan_brace_line(rest, %{lex | string_quote: ?`}, lang, opened?, false)
  end

  # In Rust, skip single-char literals like `'{'` without breaking on `'a` lifetimes.
  defp scan_brace_line(<<?', ?\\, _esc, ?', rest::binary>>, lex, :rust, opened?, _semi) do
    scan_brace_line(rest, lex, :rust, opened?, false)
  end

  defp scan_brace_line(<<?', _ch, ?', rest::binary>>, lex, :rust, opened?, _semi) do
    scan_brace_line(rest, lex, :rust, opened?, false)
  end

  defp scan_brace_line(<<?', rest::binary>>, lex, lang, opened?, _semi)
       when lang in [:js_ts, :go] do
    scan_brace_line(rest, %{lex | string_quote: ?'}, lang, opened?, false)
  end

  defp scan_brace_line(<<"{", rest::binary>>, lex, lang, _opened?, _semi) do
    scan_brace_line(rest, %{lex | depth: lex.depth + 1}, lang, true, false)
  end

  defp scan_brace_line(<<"}", rest::binary>>, lex, lang, opened?, _semi) do
    scan_brace_line(rest, %{lex | depth: max(0, lex.depth - 1)}, lang, opened?, false)
  end

  defp scan_brace_line(<<";", rest::binary>>, lex, lang, opened?, _semi) do
    scan_brace_line(rest, lex, lang, opened?, true)
  end

  defp scan_brace_line(<<ws, rest::binary>>, lex, lang, opened?, ends_semi?)
       when ws in [?\s, ?\t, ?\r] do
    scan_brace_line(rest, lex, lang, opened?, ends_semi?)
  end

  defp scan_brace_line(<<_ch, rest::binary>>, lex, lang, opened?, _semi) do
    scan_brace_line(rest, lex, lang, opened?, false)
  end

  # --- Indentation-Delimited Python Symbol Extraction ---

  defp extract_python_symbols(lines) do
    total_lines = length(lines)
    indexed = Enum.with_index(lines, 1)

    {symbols, _classes} =
      Enum.reduce(indexed, {[], []}, fn {line, line_no}, {acc, classes} ->
        case match_python_declaration(line) do
          nil ->
            {acc, classes}

          {:class, indent, name} ->
            active_classes = Enum.filter(classes, fn c -> c.indent < indent end)
            end_line = find_python_block_end(line_no, total_lines, indent, lines)

            entry = %{
              chunk_type: "class",
              symbol_type: "class",
              symbol_name: name,
              start_line: line_no,
              end_line: end_line
            }

            {[entry | acc], [%{indent: indent, end_line: end_line} | active_classes]}

          {:def, indent, name} ->
            active_classes =
              Enum.filter(classes, fn c -> c.indent < indent and line_no <= c.end_line end)

            kind = if active_classes == [], do: "function", else: "method"
            end_line = find_python_block_end(line_no, total_lines, indent, lines)

            entry = %{
              chunk_type: kind,
              symbol_type: kind,
              symbol_name: name,
              start_line: line_no,
              end_line: end_line
            }

            {[entry | acc], active_classes}
        end
      end)

    Enum.reverse(symbols)
  end

  defp match_python_declaration(line) do
    cond do
      match = Regex.run(~r/^([ \t]*)class\s+([A-Za-z_]\w*)/, line) ->
        [_, ws, name] = match
        {:class, String.length(ws), name}

      match = Regex.run(~r/^([ \t]*)(?:async\s+)?def\s+([A-Za-z_]\w*)\s*\(/, line) ->
        [_, ws, name] = match
        {:def, String.length(ws), name}

      true ->
        nil
    end
  end

  defp find_python_block_end(start_line, total_lines, block_indent, lines) do
    # First skip any multi-line header signature lines before the colon body starts
    body_start = find_python_body_start(start_line, total_lines, lines)

    if body_start > total_lines do
      total_lines
    else
      Enum.reduce_while(body_start..total_lines, start_line, fn ln, last_non_blank ->
        line = Enum.at(lines, ln - 1, "")
        trimmed = String.trim(line)

        cond do
          trimmed == "" or String.starts_with?(trimmed, "#") ->
            {:cont, last_non_blank}

          leading_indent_len(line) <= block_indent and ln > start_line ->
            {:halt, last_non_blank}

          true ->
            {:cont, ln}
        end
      end)
    end
  end

  defp find_python_body_start(start_line, total_lines, lines) do
    Enum.reduce_while(start_line..total_lines, {0, start_line}, fn ln, {paren_depth, _} ->
      line = Enum.at(lines, ln - 1, "")

      next_depth =
        paren_depth + count_char(line, ?() + count_char(line, ?[) - count_char(line, ?)) -
          count_char(line, ?])

      if next_depth <= 0 and String.contains?(String.trim_trailing(line), ":") do
        {:halt, ln + 1}
      else
        {:cont, {max(0, next_depth), ln + 1}}
      end
    end)
    |> case do
      {_depth, next_ln} -> next_ln
      next_ln when is_integer(next_ln) -> next_ln
    end
  end

  defp leading_indent_len(line) do
    case Regex.run(~r/^([ \t]*)/, line) do
      [_, ws] -> String.length(ws)
      _ -> 0
    end
  end

  defp count_char(str, char) do
    str |> :binary.bin_to_list() |> Enum.count(&(&1 == char))
  end

  # ============================================================================
  # Windowed Line Chunking
  # ============================================================================

  defp chunk_text_file(file_path, content) do
    lines = String.split(content, "\n")
    total_lines = length(lines)

    if total_lines <= 50 do
      [
        %{
          chunk_index: 0,
          chunk_type: "text",
          symbol_name: Path.basename(file_path),
          symbol_type: "file",
          start_line: 1,
          end_line: max(1, total_lines),
          content: "File: #{file_path} [lines 1-#{max(1, total_lines)}]\n\n#{content}"
        }
      ]
    else
      chunk_size = 50
      step = 40

      lines
      |> Enum.chunk_every(chunk_size, step, :discard)
      |> Enum.with_index()
      |> Enum.map(fn {chunk_lines, idx} ->
        start_line = idx * step + 1
        end_line = min(total_lines, start_line + length(chunk_lines) - 1)
        chunk_text = Enum.join(chunk_lines, "\n")

        %{
          chunk_index: idx,
          chunk_type: "text",
          symbol_name: nil,
          symbol_type: nil,
          start_line: start_line,
          end_line: end_line,
          content: "File: #{file_path} [lines #{start_line}-#{end_line}]\n\n#{chunk_text}"
        }
      end)
    end
  end
end
