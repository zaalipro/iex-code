defmodule IexCode.Tools.MultiPatch.Matcher do
  @moduledoc """
  3-Tier Patch Matching Engine:
  1. Tier 1: AST Structural Matching (for valid Elixir code trees)
  2. Tier 2: Exact String / Substring Matching
  3. Tier 3: Fuzzy Normalization (whitespace & indentation alignment)
  """

  @type tier :: :ast | :exact | :fuzzy

  @doc """
  Attempts to match and replace `target` with `replacement` in `content`.
  Applies Tier 1 -> Tier 2 -> Tier 3 in order.
  """
  @spec patch(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{content: String.t(), tier: tier()}} | {:error, :not_found}
  def patch(content, target, replacement, opts \\ [])
      when is_binary(content) and is_binary(target) and is_binary(replacement) do
    allow_multiple = Keyword.get(opts, :allow_multiple, false)
    preferred_tier = Keyword.get(opts, :tier, :auto)

    case preferred_tier do
      :ast ->
        tier1_ast_match(content, target, replacement)

      :exact ->
        tier2_exact_match(content, target, replacement, allow_multiple)

      :fuzzy ->
        tier3_fuzzy_match(content, target, replacement)

      _auto ->
        # Try Tier 2 (exact) first if exact substring exists, as it preserves verbatim layout
        case tier2_exact_match(content, target, replacement, allow_multiple) do
          {:ok, _} = res ->
            res

          {:error, :not_found} ->
            # Try Tier 3 (Fuzzy) before Tier 1 to preserve comments and layout
            case tier3_fuzzy_match(content, target, replacement) do
              {:ok, _} = res ->
                res

              {:error, :not_found} ->
                tier1_ast_match(content, target, replacement)
            end
        end
    end
  end

  # --- Tier 1: AST Matching ---

  defp tier1_ast_match(content, target, replacement) do
    with {:ok, content_ast} <- Code.string_to_quoted(content),
         {:ok, target_ast} <- Code.string_to_quoted(target),
         {:ok, repl_ast} <- Code.string_to_quoted(replacement) do
      target_clean = strip_meta(target_ast)

      {new_ast, matched?} =
        Macro.postwalk(content_ast, false, fn node, matched? ->
          if strip_meta(node) == target_clean do
            {repl_ast, true}
          else
            {node, matched?}
          end
        end)

      if matched? do
        formatted = Macro.to_string(new_ast)
        # Format code using Code.format_string! if possible
        pretty_code =
          try do
            formatted |> Code.format_string!() |> IO.iodata_to_binary() |> Kernel.<>("\n")
          rescue
            _ -> formatted <> "\n"
          end

        {:ok, %{content: pretty_code, tier: :ast}}
      else
        {:error, :not_found}
      end
    else
      _ -> {:error, :not_found}
    end
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

  defp tier2_exact_match(content, target, replacement, allow_multiple) do
    if String.contains?(content, target) do
      new_content =
        if allow_multiple do
          String.replace(content, target, replacement)
        else
          String.replace(content, target, replacement, global: false)
        end

      {:ok, %{content: new_content, tier: :exact}}
    else
      {:error, :not_found}
    end
  end

  # --- Tier 3: Fuzzy Matching & Indentation Alignment ---

  defp tier3_fuzzy_match(content, target, replacement) do
    content_lines = String.split(content, ~r/\r?\n/)
    target_lines = String.split(target, ~r/\r?\n/)

    # Remove leading and trailing empty lines from target for matching
    {trimmed_target_lines, _prefix_empty, _suffix_empty} = trim_empty_surrounding(target_lines)

    if trimmed_target_lines == [] do
      {:error, :not_found}
    else
      norm_target = Enum.map(trimmed_target_lines, &normalize_line/1)
      target_len = length(norm_target)

      case find_window_match(content_lines, norm_target, target_len, 0) do
        {:ok, match_idx} ->
          # Indentation Alignment
          first_file_line = Enum.at(content_lines, match_idx)
          first_target_line = hd(trimmed_target_lines)

          file_indent = extract_indent(first_file_line)
          target_indent = extract_indent(first_target_line)

          replacement_lines = String.split(replacement, ~r/\r?\n/)

          reindented_repl =
            Enum.map(replacement_lines, fn line ->
              if String.trim(line) == "" do
                ""
              else
                if String.starts_with?(line, target_indent) do
                  rel = String.replace_prefix(line, target_indent, "")
                  file_indent <> rel
                else
                  file_indent <> String.trim_leading(line)
                end
              end
            end)

          before_lines = Enum.take(content_lines, match_idx)
          after_lines = Enum.drop(content_lines, match_idx + target_len)

          new_lines = before_lines ++ reindented_repl ++ after_lines
          new_content = Enum.join(new_lines, "\n")

          # Preserve trailing newline if original content had it
          final_content =
            if String.ends_with?(content, "\n") and not String.ends_with?(new_content, "\n") do
              new_content <> "\n"
            else
              new_content
            end

          {:ok, %{content: final_content, tier: :fuzzy}}

        :not_found ->
          {:error, :not_found}
      end
    end
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

  defp find_window_match(content_lines, norm_target, target_len, idx) do
    if idx + target_len > length(content_lines) do
      :not_found
    else
      window = Enum.slice(content_lines, idx, target_len)
      norm_window = Enum.map(window, &normalize_line/1)

      if norm_window == norm_target do
        {:ok, idx}
      else
        find_window_match(content_lines, norm_target, target_len, idx + 1)
      end
    end
  end
end
