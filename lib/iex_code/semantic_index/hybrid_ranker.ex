defmodule IexCode.SemanticIndex.HybridRanker do
  @moduledoc """
  Code-aware lexical tokenizer, BM25 scorer, and Reciprocal Rank Fusion (RRF) engine
  for hybrid semantic + lexical code retrieval.
  """

  @default_k1 1.2
  @default_rrf_k 60

  @symbol_weight 7.0
  @path_weight 3.5
  @content_weight 1.0

  @symbol_b 0.25
  @path_b 0.35
  @content_b 0.75

  @doc """
  Tokenizes code or natural language into lowercase searchable terms.

  Preserves exact symbol tokens (including `:atom`, `@attr`, `snake_case`,
  `MyApp.Auth.Token`, and trailing `?`/`!` predicates) while also emitting split
  `CamelCase`, `snake_case`, path, and module segments.
  """
  @spec tokenize(String.t() | nil) :: [String.t()]
  def tokenize(nil), do: []
  def tokenize(""), do: []

  def tokenize(text) when is_binary(text) do
    text
    |> String.split(~r/[\s\(\)\[\]\{\},;="<>\|&\+\*%\^~`\\#]+/, trim: true)
    |> Enum.flat_map(&expand_lexeme/1)
  end

  def tokenize(_), do: []

  @doc """
  Scores and ranks candidate code chunks using field-weighted BM25 over
  `symbol_name`, `file_path`, and `content`.

  Field boosts enforce:
  exact/prefix `symbol_name` match > `file_path` segment match > `content` term frequency.

  Returns candidate maps updated with normalized `:score` in `(0.0, 1.0)` (or `[0.0, 1.0)`
  if `include_zero: true` is passed), sorted descending by score.
  """
  @spec rank_lexical([map()], String.t(), keyword()) :: [map()]
  def rank_lexical(candidates, query, opts \\ [])

  def rank_lexical([], _query, _opts), do: []

  def rank_lexical(candidates, query, opts) when is_list(candidates) and is_binary(query) do
    query_tokens = query |> tokenize() |> Enum.uniq()

    if query_tokens == [] do
      if Keyword.get(opts, :include_zero, false) do
        Enum.map(candidates, &Map.put(&1, :score, 0.0))
      else
        []
      end
    else
      do_rank_lexical(candidates, query, query_tokens, opts)
    end
  end

  def rank_lexical(_, _, _), do: []

  @doc """
  Computes Reciprocal Rank Fusion over two ranked candidate lists using
  `weight / (k + rank)` and normalizes fused scores into `(0.0, 1.0]`.

  Options:
  - `:k` - RRF constant (default `60`)
  - `:dense_weight` - weight applied to dense list (default `1.0`)
  - `:lexical_weight` - weight applied to lexical list (default `1.0`)
  - `:normalization` - `:max` (default, scales top hit to `1.0`) or `:theoretical`
  """
  @spec rrf_fuse([map()], [map()], keyword()) :: [map()]
  def rrf_fuse(dense_ranked, lexical_ranked, opts \\ [])

  def rrf_fuse([], [], _opts), do: []

  def rrf_fuse(dense_ranked, lexical_ranked, opts)
      when is_list(dense_ranked) and is_list(lexical_ranked) do
    k = max(1, Keyword.get(opts, :k, @default_rrf_k))
    dense_weight = max(0.0, Keyword.get(opts, :dense_weight, 1.0) * 1.0)
    lexical_weight = max(0.0, Keyword.get(opts, :lexical_weight, 1.0) * 1.0)
    normalization = Keyword.get(opts, :normalization, :max)

    accumulated =
      %{}
      |> accumulate_list(dense_ranked, :dense, dense_weight, k)
      |> accumulate_list(lexical_ranked, :lexical, lexical_weight, k)

    if map_size(accumulated) == 0 do
      []
    else
      sorted =
        accumulated
        |> Map.values()
        |> Enum.sort_by(
          fn entry ->
            {-entry.rrf_raw, -max(entry.dense_score, entry.lexical_score), entry.key}
          end,
          :asc
        )

      denom =
        case normalization do
          :theoretical ->
            (dense_weight + lexical_weight) / (k + 1)

          _ ->
            hd(sorted).rrf_raw
        end

      Enum.map(sorted, fn entry ->
        norm_score =
          if denom > 0.0 do
            min(1.0, entry.rrf_raw / denom)
          else
            0.0
          end

        entry.item
        |> Map.put(:score, norm_score)
        |> Map.put(:dense_score, entry.dense_score)
        |> Map.put(:lexical_score, entry.lexical_score)
      end)
    end
  end

  # ============================================================================
  # Tokenizer Helpers
  # ============================================================================

  defp expand_lexeme(raw) do
    cleaned = clean_lexeme(raw)

    if cleaned == "" or not String.match?(cleaned, ~r/[a-zA-Z0-9]/) do
      []
    else
      lower_full = String.downcase(cleaned)

      {prefix_stripped, has_sigil?} =
        case cleaned do
          ":" <> rest -> {rest, true}
          "@" <> rest -> {rest, true}
          _ -> {cleaned, false}
        end

      base_no_pred = String.replace(prefix_stripped, ~r/[?!]+$/, "")
      lower_stripped = String.downcase(prefix_stripped)
      lower_no_pred = String.downcase(base_no_pred)

      segments =
        base_no_pred
        |> String.split(~r/[:.\/\-]+/, trim: true)
        |> Enum.flat_map(&expand_segment/1)

      candidates =
        [lower_full] ++
          if(has_sigil?, do: [lower_stripped], else: []) ++
          if(lower_no_pred != lower_stripped, do: [lower_no_pred], else: []) ++
          segments

      candidates
      |> Enum.filter(&(&1 != "" and String.match?(&1, ~r/[a-z0-9]/)))
      |> Enum.uniq()
    end
  end

  defp clean_lexeme(raw) do
    raw
    |> String.trim_leading("'")
    |> String.trim_leading(".")
    |> String.trim_leading("/")
    |> String.trim_leading("-")
    |> String.trim_trailing("'")
    |> String.trim_trailing(".")
    |> String.trim_trailing("/")
    |> String.trim_trailing("-")
    |> String.trim_trailing(":")
  end

  defp expand_segment(segment) do
    lower_seg = String.downcase(segment)

    snake_parts = String.split(segment, "_", trim: true)

    camel_parts =
      snake_parts
      |> Enum.flat_map(&split_camel_case/1)

    ([lower_seg] ++ Enum.map(snake_parts, &String.downcase/1) ++ camel_parts)
    |> Enum.filter(&(&1 != "" and String.match?(&1, ~r/[a-z0-9]/)))
    |> Enum.uniq()
  end

  defp split_camel_case(segment) do
    segment
    |> String.replace(~r/([A-Z]+)([A-Z][a-z])/, "\\1 \\2")
    |> String.replace(~r/([a-z\d])([A-Z])/, "\\1 \\2")
    |> String.split(" ", trim: true)
    |> Enum.map(&String.downcase/1)
  end

  # ============================================================================
  # BM25 Scoring Helpers
  # ============================================================================

  defp do_rank_lexical(candidates, query, query_tokens, opts) do
    k1 = Keyword.get(opts, :k1, @default_k1)
    sym_w = Keyword.get(opts, :symbol_weight, @symbol_weight)
    path_w = Keyword.get(opts, :path_weight, @path_weight)
    content_w = Keyword.get(opts, :content_weight, @content_weight)
    include_zero = Keyword.get(opts, :include_zero, false)

    docs =
      Enum.map(candidates, fn item ->
        sym_raw = field(item, :symbol_name, "symbol_name")
        path_raw = field(item, :file_path, "file_path")
        content_raw = field(item, :content, "content")

        sym_tokens = tokenize(sym_raw)
        path_tokens = tokenize(path_raw)
        content_tokens = tokenize(content_raw)

        %{
          item: item,
          symbol_raw: sym_raw,
          sym_freqs: Enum.frequencies(sym_tokens),
          sym_len: length(sym_tokens),
          path_freqs: Enum.frequencies(path_tokens),
          path_len: length(path_tokens),
          content_freqs: Enum.frequencies(content_tokens),
          content_len: length(content_tokens),
          all_terms: MapSet.new(sym_tokens ++ path_tokens ++ content_tokens)
        }
      end)

    n = length(docs)
    avg_sym = avg_field_len(docs, :sym_len)
    avg_path = avg_field_len(docs, :path_len)
    avg_content = avg_field_len(docs, :content_len)

    df_map =
      Enum.reduce(query_tokens, %{}, fn qt, acc ->
        count = Enum.count(docs, &MapSet.member?(&1.all_terms, qt))
        Map.put(acc, qt, count)
      end)

    idf_map =
      Map.new(query_tokens, fn qt ->
        df = Map.get(df_map, qt, 0)
        idf = :math.log(1.0 + (n - df + 0.5) / (df + 0.5))
        {qt, idf}
      end)

    # Cap missing terms (df == 0) at df = 1 weight in the normalization denominator so
    # unmatched natural-language stopwords do not collapse valid lexical matches.
    norm_idf_sum =
      Enum.reduce(query_tokens, 0.0, fn qt, acc ->
        df = max(1, Map.get(df_map, qt, 0))
        acc + :math.log(1.0 + (n - df + 0.5) / (df + 0.5))
      end)

    q_norm = query |> String.trim() |> String.downcase()

    scored =
      Enum.map(docs, fn doc ->
        raw_bm25 =
          Enum.reduce(query_tokens, 0.0, fn qt, acc ->
            idf = Map.get(idf_map, qt, 0.0)

            sym_tf = Map.get(doc.sym_freqs, qt, 0)
            path_tf = Map.get(doc.path_freqs, qt, 0)
            content_tf = Map.get(doc.content_freqs, qt, 0)

            sym_score = sym_w * bm25_tf(sym_tf, doc.sym_len, avg_sym, k1, @symbol_b)
            path_score = path_w * bm25_tf(path_tf, doc.path_len, avg_path, k1, @path_b)

            content_score =
              content_w * bm25_tf(content_tf, doc.content_len, avg_content, k1, @content_b)

            acc + idf * (sym_score + path_score + content_score)
          end)

        boosted_raw = apply_symbol_boost(raw_bm25, doc.symbol_raw, q_norm, query_tokens)

        norm_score =
          if boosted_raw > 0.0 and norm_idf_sum > 0.0 do
            boosted_raw / (boosted_raw + 1.2 * norm_idf_sum)
          else
            0.0
          end

        {boosted_raw, Map.put(doc.item, :score, norm_score)}
      end)

    scored
    |> Enum.filter(fn {_raw, item} -> include_zero or item.score > 0.0 end)
    |> Enum.sort_by(fn {raw, item} ->
      {-item.score, -raw, to_string(field(item, :file_path, "file_path") || ""),
       field(item, :start_line, "start_line") || 0}
    end)
    |> Enum.map(fn {_raw, item} -> item end)
  end

  defp avg_field_len(docs, key) do
    non_zero =
      docs
      |> Enum.map(&Map.get(&1, key))
      |> Enum.filter(&(&1 > 0))

    case non_zero do
      [] -> 1.0
      lens -> max(1.0, Enum.sum(lens) / length(lens))
    end
  end

  defp bm25_tf(0, _dl, _avg_dl, _k1, _b), do: 0.0

  defp bm25_tf(tf, dl, avg_dl, k1, b) do
    norm_len = 1.0 - b + b * (dl / max(1.0, avg_dl))
    tf * (k1 + 1.0) / (tf + k1 * norm_len)
  end

  defp apply_symbol_boost(raw_score, _symbol_name, "", _query_tokens), do: raw_score

  defp apply_symbol_boost(raw_score, _symbol_name, _q_norm, _query_tokens)
       when raw_score <= 0.0,
       do: raw_score

  defp apply_symbol_boost(raw_score, symbol_name, q_norm, query_tokens)
       when is_binary(symbol_name) and symbol_name != "" do
    sym_full = String.downcase(symbol_name)
    sym_no_arity = sym_full |> String.replace(~r/\/\d+$/, "")
    sym_leaf = sym_no_arity |> String.split(".") |> List.last() || sym_no_arity

    cond do
      q_norm in [sym_full, sym_no_arity, sym_leaf] ->
        raw_score * 1.5

      String.starts_with?(sym_no_arity, q_norm) or String.starts_with?(sym_leaf, q_norm) ->
        raw_score * 1.25

      Enum.any?(query_tokens, &(&1 in [sym_full, sym_no_arity, sym_leaf])) ->
        raw_score * 1.15

      true ->
        raw_score
    end
  end

  defp apply_symbol_boost(raw_score, _symbol_name, _q_norm, _query_tokens), do: raw_score

  # ============================================================================
  # RRF Helpers
  # ============================================================================

  defp accumulate_list(acc, _list, _kind, weight, _k) when weight <= 0.0, do: acc

  defp accumulate_list(acc, list, kind, weight, k) do
    {next_acc, _seen, _rank} =
      Enum.reduce(list, {acc, MapSet.new(), 1}, fn item, {map_acc, seen, rank} ->
        key = item_key(item, rank)

        if MapSet.member?(seen, key) do
          {map_acc, seen, rank}
        else
          contrib = weight / (k + rank)
          item_score = max(0.0, (field(item, :score, "score") || 0.0) * 1.0)

          updated =
            Map.update(
              map_acc,
              key,
              %{
                key: key,
                item: item,
                rrf_raw: contrib,
                dense_score: if(kind == :dense, do: item_score, else: 0.0),
                lexical_score: if(kind == :lexical, do: item_score, else: 0.0)
              },
              fn existing ->
                %{
                  existing
                  | item: Map.merge(existing.item, item),
                    rrf_raw: existing.rrf_raw + contrib,
                    dense_score:
                      if(kind == :dense,
                        do: max(existing.dense_score, item_score),
                        else: existing.dense_score
                      ),
                    lexical_score:
                      if(kind == :lexical,
                        do: max(existing.lexical_score, item_score),
                        else: existing.lexical_score
                      )
                }
              end
            )

          {updated, MapSet.put(seen, key), rank + 1}
        end
      end)

    next_acc
  end

  defp item_key(item, fallback_rank) do
    case field(item, :id, "id") do
      nil ->
        {
          field(item, :file_path, "file_path"),
          field(item, :start_line, "start_line"),
          field(item, :end_line, "end_line"),
          field(item, :symbol_name, "symbol_name"),
          fallback_rank
        }

      id ->
        id
    end
  end

  defp field(map, atom_key, string_key) when is_map(map) do
    case Map.fetch(map, atom_key) do
      {:ok, val} -> val
      :error -> Map.get(map, string_key)
    end
  end
end
