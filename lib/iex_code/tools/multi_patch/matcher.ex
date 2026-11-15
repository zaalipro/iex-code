defmodule IexCode.Tools.MultiPatch.Matcher do
  @moduledoc """
  3-Tier Patch Matching Engine:
  1. Tier 1: AST Structural Matching (opt-in only via `tier: :ast`)
  2. Tier 2: Exact String / Substring Matching
  3. Tier 3: Fuzzy Normalization (whitespace & indentation alignment)

  Ambiguous matches are rejected with `{:error, :not_found}` (or
  `{:error, {:ambiguous_match, match_lines}}` when `reject_ambiguous: true`)
  unless `allow_multiple: true` is set or an `:anchor_line` hint disambiguates
  them.
  """

  @type tier :: :ast | :exact | :fuzzy
  @type patch_error :: :not_found | {:ambiguous_match, [pos_integer()]}

  @diag_max_lines 20
  @diag_max_line_chars 200

  @doc """
  Attempts to match and replace `target` with `replacement` in `content`.
  In `:auto` mode applies Tier 2 -> Tier 3; Tier 1 is only used when explicitly
  requested with `tier: :ast`, because an AST round-trip destroys comments —
  the AST tier is restricted to whole-expression replacement that splices only
  the matched expression's source range, preserving all surrounding comments.

  Options:

    * `:allow_multiple` - replace every occurrence instead of requiring a
      unique match (default `false`)
    * `:tier` - `:auto` (default), `:exact`, `:fuzzy`, or `:ast`
    * `:anchor_line` - optional 1-based line hint (e.g. a diff hunk's
      `old_start`) used to disambiguate multiple matches
    * `:reject_ambiguous` - when `true` and `allow_multiple` is `false`, rejects
      multiple non-overlapping matches with `{:error, {:ambiguous_match, lines}}`
      unless `:anchor_line` uniquely disambiguates them (default `false`)
  """
  @spec patch(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{content: String.t(), tier: tier()}} | {:error, patch_error()}
  def patch(content, target, replacement, opts \\ [])
      when is_binary(content) and is_binary(target) and is_binary(replacement) do
    allow_multiple = Keyword.get(opts, :allow_multiple, false)
    preferred_tier = Keyword.get(opts, :tier, :auto)
    anchor_line = normalize_anchor_line(Keyword.get(opts, :anchor_line))
    reject_ambiguous = Keyword.get(opts, :reject_ambiguous, false)

    if target == "" do
      # An empty target would insert `replacement` between every character.
      {:error, :not_found}
    else
      case preferred_tier do
        :ast ->
          tier1_ast_match(
            content,
            target,
            replacement,
            allow_multiple,
            anchor_line,
            reject_ambiguous
          )

        :exact ->
          tier2_exact_match(
            content,
            target,
            replacement,
            allow_multiple,
            anchor_line,
            reject_ambiguous
          )

        :fuzzy ->
          tier3_fuzzy_match(
            content,
            target,
            replacement,
            allow_multiple,
            anchor_line,
            reject_ambiguous
          )

        _auto ->
          # Try Tier 2 (exact) first as it preserves verbatim layout, then
          # Tier 3 (fuzzy). Ambiguous exact matches fail immediately without
          # falling back to Tier 3. Tier 1 is deliberately opt-in only.
          case tier2_exact_match(
                 content,
                 target,
                 replacement,
                 allow_multiple,
                 anchor_line,
                 reject_ambiguous
               ) do
            {:ok, _} = res ->
              res

            {:error, {:ambiguous_match, _}} = err ->
              err

            {:error, :not_found} ->
              tier3_fuzzy_match(
                content,
                target,
                replacement,
                allow_multiple,
                anchor_line,
                reject_ambiguous
              )
          end
      end
    end
  end

  @doc """
  Produces actionable diagnostic context explaining why `target` failed to patch
  uniquely against `content` (exact/fuzzy duplicate line numbers or the closest
  matching line window in the file).
  """
  @spec diagnose_failure(String.t(), String.t()) :: String.t()
  def diagnose_failure(content, target) when is_binary(content) and is_binary(target) do
    cond do
      target == "" ->
        "Target text is empty; provide non-empty target lines to match."

      content == "" ->
        "Target file is empty; no matching lines exist."

      true ->
        diagnose_non_empty(content, target)
    end
  end

  # --- Tier 1: AST Matching (opt-in via `tier: :ast`) ---
  #
  # Performs whole-expression replacement only: the matched expression's exact
  # source range is spliced out and replaced, so comments outside the replaced
  # expression are preserved (a full AST round-trip via Macro.to_string/1 would
  # destroy them). Whenever precise source ranges are unavailable, this tier
  # returns {:error, :not_found} instead of rewriting the whole file.

  defp tier1_ast_match(
         content,
         target,
         replacement,
         allow_multiple,
         anchor_line,
         reject_ambiguous
       ) do
    with {:ok, content_ast} <- parse_quoted(content),
         {:ok, target_ast} <- parse_quoted(target),
         {:ok, _repl_ast} <- parse_quoted(replacement) do
      target_clean = strip_meta(target_ast)
      ranges = content |> expression_ranges(content_ast, target_clean) |> non_overlapping()

      select_and_replace_ast_ranges(
        content,
        ranges,
        replacement,
        allow_multiple,
        anchor_line,
        reject_ambiguous
      )
    else
      _ -> {:error, :not_found}
    end
  end

  defp select_and_replace_ast_ranges(
         _content,
         [],
         _replacement,
         _allow_multiple,
         _anchor_line,
         _reject_ambiguous
       ),
       do: {:error, :not_found}

  defp select_and_replace_ast_ranges(
         content,
         ranges,
         replacement,
         allow_multiple,
         anchor_line,
         reject_ambiguous
       ) do
    if length(ranges) == 1 or allow_multiple do
      {:ok, %{content: replace_ranges(content, ranges, replacement), tier: :ast}}
    else
      indexed =
        Enum.map(ranges, fn {start_off, _end_off} = range ->
          {range, offset_to_line(content, start_off)}
        end)

      match_lines = Enum.map(indexed, &elem(&1, 1))

      case disambiguate_by_line(indexed, anchor_line, &elem(&1, 1)) do
        {:ok, {range, _line}} ->
          {:ok, %{content: replace_ranges(content, [range], replacement), tier: :ast}}

        :error ->
          if reject_ambiguous,
            do: {:error, {:ambiguous_match, match_lines}},
            else: {:error, :not_found}
      end
    end
  end

  defp parse_quoted(source) do
    Code.string_to_quoted(source, token_metadata: true, emit_warnings: false)
  end

  defp expression_ranges(content, ast, target_clean) do
    offsets = line_offsets(content)

    {_, ranges} =
      Macro.prewalk(ast, [], fn node, acc ->
        case ast_source_range(node) do
          {start_pos, end_pos} ->
            if strip_meta(node) == target_clean do
              case absolute_range(offsets, start_pos, end_pos, content) do
                {:ok, range} -> {node, [range | acc]}
                :error -> {node, acc}
              end
            else
              {node, acc}
            end

          nil ->
            {node, acc}
        end
      end)

    Enum.reverse(ranges)
  end

  defp ast_source_range({_, meta, _}) when is_list(meta) do
    line = Keyword.get(meta, :line)
    column = Keyword.get(meta, :column)
    end_line = Keyword.get(meta, :ending_line)
    end_column = Keyword.get(meta, :ending_column)

    if line && column && end_line && end_column do
      {{line, column}, {end_line, end_column}}
    end
  end

  defp ast_source_range(_), do: nil

  defp absolute_range(offsets, {line, column}, {end_line, end_column}, content) do
    start_offset = line_start(offsets, line) + (column - 1)
    end_offset = line_start(offsets, end_line) + (end_column - 1)

    if start_offset >= 0 and end_offset > start_offset and end_offset <= byte_size(content) do
      {:ok, {start_offset, end_offset}}
    else
      :error
    end
  end

  defp line_offsets(content) do
    content
    |> String.split("\n")
    |> Enum.map_reduce(0, fn line, acc ->
      {acc, acc + byte_size(line) + 1}
    end)
    |> elem(0)
  end

  defp line_start(offsets, line), do: Enum.at(offsets, line - 1, -1)

  # Keeps only non-overlapping ranges (outermost wins) so a target that also
  # matches a nested expression is not spliced twice.
  defp non_overlapping(ranges) do
    ranges
    |> Enum.sort()
    |> Enum.reduce({[], -1}, fn
      {start, stop}, {acc, last_end} when start >= last_end ->
        {[{start, stop} | acc], stop}

      _, acc ->
        acc
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp replace_ranges(content, ranges, replacement) do
    ranges
    |> Enum.reverse()
    |> Enum.reduce(content, fn {start, stop}, acc ->
      binary_part(acc, 0, start) <> replacement <> binary_part(acc, stop, byte_size(acc) - stop)
    end)
  end

  defp strip_meta({form, _meta, args}) when is_list(args) do
    {form, [], Enum.map(args, &strip_meta/1)}
  end

  defp strip_meta({form, _meta, arg}) do
    {form, [], strip_meta(arg)}
  end

  defp strip_meta(list) when is_list(list) do
    Enum.map(list, &strip_meta/1)
  end

  defp strip_meta(other), do: other

  # --- Tier 2: Exact Matching ---

  defp tier2_exact_match(
         content,
         target,
         replacement,
         allow_multiple,
         anchor_line,
         reject_ambiguous
       ) do
    case :binary.matches(content, target) do
      [] ->
        {:error, :not_found}

      [{start, len}] ->
        {:ok, %{content: replace_byte_range(content, start, len, replacement), tier: :exact}}

      matches when allow_multiple ->
        new_content = replace_exact_matches(content, matches, replacement)
        {:ok, %{content: new_content, tier: :exact}}

      matches ->
        indexed =
          Enum.map(matches, fn {start, _len} = range ->
            {range, offset_to_line(content, start)}
          end)

        match_lines = Enum.map(indexed, &elem(&1, 1))

        case disambiguate_by_line(indexed, anchor_line, &elem(&1, 1)) do
          {:ok, {{start, len}, _line}} ->
            {:ok, %{content: replace_byte_range(content, start, len, replacement), tier: :exact}}

          :error when reject_ambiguous ->
            {:error, {:ambiguous_match, match_lines}}

          :error ->
            new_content = String.replace(content, target, replacement, global: false)
            {:ok, %{content: new_content, tier: :exact}}
        end
    end
  end

  defp replace_byte_range(content, start, len, replacement) do
    prefix = binary_part(content, 0, start)
    suffix_start = start + len
    suffix = binary_part(content, suffix_start, byte_size(content) - suffix_start)
    prefix <> replacement <> suffix
  end

  defp replace_exact_matches(content, matches, replacement) do
    matches
    |> Enum.reverse()
    |> Enum.reduce(content, fn {start, len}, acc ->
      replace_byte_range(acc, start, len, replacement)
    end)
  end

  # --- Tier 3: Fuzzy Matching & Indentation Alignment ---

  defp tier3_fuzzy_match(
         content,
         target,
         replacement,
         allow_multiple,
         anchor_line,
         reject_ambiguous
       ) do
    content_lines = split_lines(content)
    target_lines = split_lines(target)

    # Remove leading and trailing empty lines from target for matching
    {trimmed_target_lines, _prefix_empty, _suffix_empty} = trim_empty_surrounding(target_lines)

    if trimmed_target_lines == [] do
      {:error, :not_found}
    else
      norm_target = Enum.map(trimmed_target_lines, &normalize_line/1)
      target_len = length(norm_target)
      matches = find_all_window_matches(content_lines, norm_target, target_len)

      case select_matches(matches, allow_multiple, anchor_line, reject_ambiguous) do
        {:ok, selected} ->
          apply_fuzzy_replacement(
            content,
            content_lines,
            trimmed_target_lines,
            target_len,
            selected,
            replacement
          )

        {:error, _reason} = err ->
          err
      end
    end
  end

  # Rejects ambiguous matches: multiple candidates require `allow_multiple`,
  # or a unique closest match relative to `anchor_line` (e.g. a diff hunk's
  # old_start) to be selected.
  defp select_matches([], _allow_multiple, _anchor_line, _reject_ambiguous),
    do: {:error, :not_found}

  defp select_matches(matches, allow_multiple, anchor_line, reject_ambiguous) do
    cond do
      length(matches) == 1 or allow_multiple ->
        {:ok, matches}

      anchor_line != nil ->
        case disambiguate_by_line(matches, anchor_line, &(&1 + 1)) do
          {:ok, best_idx} ->
            {:ok, [best_idx]}

          :error when reject_ambiguous ->
            {:error, {:ambiguous_match, Enum.map(matches, &(&1 + 1))}}

          :error ->
            {:error, :not_found}
        end

      reject_ambiguous ->
        {:error, {:ambiguous_match, Enum.map(matches, &(&1 + 1))}}

      true ->
        {:error, :not_found}
    end
  end

  defp disambiguate_by_line(_items, nil, _line_fn), do: :error

  defp disambiguate_by_line(items, anchor_line, line_fn) do
    [best | rest] = Enum.sort_by(items, &abs(line_fn.(&1) - anchor_line))

    case rest do
      [] ->
        {:ok, best}

      [next | _] ->
        if abs(line_fn.(best) - anchor_line) < abs(line_fn.(next) - anchor_line) do
          {:ok, best}
        else
          :error
        end
    end
  end

  defp normalize_anchor_line(line) when is_integer(line) and line >= 1, do: line
  defp normalize_anchor_line(_), do: nil

  defp offset_to_line(_content, byte_offset) when byte_offset <= 0, do: 1

  defp offset_to_line(content, byte_offset) do
    prefix = binary_part(content, 0, min(byte_offset, byte_size(content)))
    length(:binary.matches(prefix, "\n")) + 1
  end

  defp find_all_window_matches(content_lines, norm_target, target_len) do
    if length(content_lines) < target_len do
      []
    else
      Enum.filter(0..(length(content_lines) - target_len), fn idx ->
        content_lines
        |> Enum.slice(idx, target_len)
        |> Enum.map(&normalize_line/1) == norm_target
      end)
    end
  end

  defp apply_fuzzy_replacement(
         content,
         content_lines,
         trimmed_target_lines,
         target_len,
         match_idxs,
         replacement
       ) do
    replacement_lines = split_lines(replacement)
    first_target_line = hd(trimmed_target_lines)
    target_indent = extract_indent(first_target_line)

    # Apply bottom-up so earlier match indices stay valid while splicing.
    new_lines =
      match_idxs
      |> Enum.sort(:desc)
      |> Enum.reduce(content_lines, fn match_idx, acc_lines ->
        file_indent = acc_lines |> Enum.at(match_idx) |> extract_indent()
        reindented = reindent_lines(replacement_lines, file_indent, target_indent)

        before_lines = Enum.take(acc_lines, match_idx)
        after_lines = Enum.drop(acc_lines, match_idx + target_len)

        before_lines ++ reindented ++ after_lines
      end)

    eol = detect_eol(content)
    new_content = Enum.join(new_lines, eol)

    # Preserve trailing newline if original content had it
    final_content =
      if String.ends_with?(content, "\n") and not String.ends_with?(new_content, "\n") do
        new_content <> eol
      else
        new_content
      end

    {:ok, %{content: final_content, tier: :fuzzy}}
  end

  defp reindent_lines(replacement_lines, file_indent, target_indent) do
    Enum.map(replacement_lines, fn line ->
      cond do
        String.trim(line) == "" ->
          ""

        String.starts_with?(line, target_indent) ->
          rel = String.replace_prefix(line, target_indent, "")
          file_indent <> rel

        true ->
          file_indent <> String.trim_leading(line)
      end
    end)
  end

  defp split_lines(text), do: String.split(text, ~r/\r?\n/)

  defp detect_eol(content) do
    if String.contains?(content, "\r\n"), do: "\r\n", else: "\n"
  end

  defp normalize_line(line) do
    line
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end

  defp extract_indent(line) do
    case Regex.run(~r/^[ \t]*/, line) do
      [indent] -> indent
      _ -> ""
    end
  end

  defp trim_empty_surrounding(lines) do
    prefix_empty = Enum.take_while(lines, &(String.trim(&1) == ""))
    after_prefix = Enum.drop_while(lines, &(String.trim(&1) == ""))
    reversed = Enum.reverse(after_prefix)
    suffix_empty = Enum.take_while(reversed, &(String.trim(&1) == ""))
    trimmed = reversed |> Enum.drop_while(&(String.trim(&1) == "")) |> Enum.reverse()
    {trimmed, length(prefix_empty), length(suffix_empty)}
  end

  # --- Failure Diagnostics ---

  defp diagnose_non_empty(content, target) do
    case :binary.matches(content, target) do
      [_single] ->
        diagnose_closest_window(content, target)

      matches when length(matches) > 1 ->
        lines = Enum.map(matches, fn {start, _len} -> offset_to_line(content, start) end)

        "Found #{length(lines)} exact occurrences of target at lines #{Enum.join(lines, ", ")}. " <>
          "Provide anchor_line near the intended edit (e.g., anchor_line: #{hd(lines)}), " <>
          "include more surrounding context in target, or set allow_multiple: true."

      [] ->
        diagnose_fuzzy_or_closest(content, target)
    end
  end

  defp diagnose_fuzzy_or_closest(content, target) do
    content_lines = split_lines(content)
    {trimmed_target, _, _} = target |> split_lines() |> trim_empty_surrounding()

    if trimmed_target == [] do
      "Target contains only whitespace lines; provide code lines to match."
    else
      norm_target = Enum.map(trimmed_target, &normalize_line/1)
      fuzzy_matches = find_all_window_matches(content_lines, norm_target, length(norm_target))

      cond do
        length(fuzzy_matches) > 1 ->
          lines = Enum.map(fuzzy_matches, &(&1 + 1))

          "Found #{length(lines)} whitespace-normalized occurrences of target at lines #{Enum.join(lines, ", ")}. " <>
            "Provide anchor_line near the intended edit (e.g., anchor_line: #{hd(lines)}), " <>
            "include exact surrounding context, or set allow_multiple: true."

        length(fuzzy_matches) == 1 ->
          idx = hd(fuzzy_matches)
          end_idx = idx + length(norm_target) - 1
          snippet = format_line_window(content_lines, idx, end_idx)

          "Closest match (whitespace differs) at lines #{idx + 1}-#{end_idx + 1}:\n#{snippet}"

        true ->
          diagnose_closest_window(content, target)
      end
    end
  end

  defp diagnose_closest_window(content, target) do
    content_lines = split_lines(content)
    {trimmed_target, _, _} = target |> split_lines() |> trim_empty_surrounding()

    if content_lines == [] or trimmed_target == [] do
      "No matching lines found in file."
    else
      norm_content = Enum.map(content_lines, &normalize_line/1)
      norm_target = Enum.map(trimmed_target, &normalize_line/1)

      case find_best_window(norm_content, norm_target) do
        {best_start, best_len, best_score} when best_score >= 0.25 ->
          ctx_start = max(best_start - 1, 0)
          ctx_end = min(best_start + best_len, length(content_lines) - 1)
          snippet = format_line_window(content_lines, ctx_start, ctx_end)
          pct = round(best_score * 100)

          "Closest matching window in file (lines #{best_start + 1}-#{best_start + best_len}, ~#{pct}% similar):\n#{snippet}\n" <>
            "Update target to match the exact lines above or provide anchor_line."

        _ ->
          "No similar lines found across #{length(content_lines)} line(s) in file."
      end
    end
  end

  defp find_best_window(norm_content, norm_target) do
    content_len = length(norm_content)
    window_len = min(length(norm_target), content_len)
    target_slice = Enum.take(norm_target, window_len)
    max_start = content_len - window_len
    starts = candidate_window_starts(norm_content, target_slice, max_start)

    Enum.reduce(starts, {0, window_len, 0.0}, fn start_idx, {_, _, best_score} = best ->
      window = Enum.slice(norm_content, start_idx, window_len)
      score = window_similarity(window, target_slice)
      if score > best_score, do: {start_idx, window_len, score}, else: best
    end)
  end

  defp candidate_window_starts(_norm_content, _norm_target, max_start) when max_start <= 300 do
    0..max_start
  end

  defp candidate_window_starts(norm_content, norm_target, max_start) do
    {anchor_target_line, anchor_offset} =
      norm_target
      |> Enum.with_index()
      |> Enum.max_by(fn {line, _idx} -> byte_size(line) end, fn -> {"", 0} end)

    if anchor_target_line == "" do
      0..min(max_start, 200)
    else
      norm_content
      |> Enum.with_index()
      |> Enum.map(fn {line, idx} -> {line_similarity(line, anchor_target_line), idx} end)
      |> Enum.sort_by(&elem(&1, 0), :desc)
      |> Enum.take(25)
      |> Enum.map(fn {_score, idx} ->
        idx |> Kernel.-(anchor_offset) |> max(0) |> min(max_start)
      end)
      |> Enum.uniq()
    end
  end

  defp window_similarity([], _target_slice), do: 0.0

  defp window_similarity(window, target_slice) do
    scores = Enum.zip_with(window, target_slice, &line_similarity/2)
    Enum.sum(scores) / length(scores)
  end

  defp line_similarity(a, b) do
    cond do
      a == "" and b == "" ->
        0.15

      a == "" or b == "" ->
        0.0

      a == b ->
        1.0

      true ->
        base = String.jaro_distance(a, b)
        if String.contains?(a, b) or String.contains?(b, a), do: max(base, 0.72), else: base
    end
  end

  defp format_line_window(content_lines, start_idx, end_idx) do
    capped_end = min(end_idx, start_idx + @diag_max_lines - 1)

    content_lines
    |> Enum.slice(start_idx..capped_end)
    |> Enum.with_index(start_idx + 1)
    |> Enum.map_join("\n", fn {line, line_no} ->
      "  #{line_no}: #{truncate_diag_line(line)}"
    end)
  end

  defp truncate_diag_line(line) do
    if String.length(line) > @diag_max_line_chars do
      String.slice(line, 0, @diag_max_line_chars) <> "..."
    else
      line
    end
  end
end
