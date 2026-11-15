defmodule IexCode.SemanticIndex.Indexer do
  @moduledoc """
  Incremental semantic codebase indexer and sub-second hybrid vector + BM25 search engine.
  Features:
  - Incremental SHA-256 + model + dimension change detection: re-indexes stale embeddings when file content, model, or dimensions change.
  - Workspace symlink containment and file-size bounds during directory traversal.
  - SQLite persistence via `code_embeddings` table.
  - In-memory ETS cache (`:iex_code_semantic_cache`) for sub-10ms similarity queries.
  - Hybrid RRF (`:hybrid`), pure dense cosine (`:vector`), and pure BM25 lexical (`:lexical`) search modes.
  """

  use GenServer
  require Logger
  import Ecto.Query

  alias IexCode.Repo
  alias IexCode.SemanticIndex.Chunker
  alias IexCode.SemanticIndex.CodeEmbedding
  alias IexCode.SemanticIndex.EmbeddingClient
  alias IexCode.SemanticIndex.HybridRanker
  alias IexCode.SemanticIndex.Vector
  alias IexCode.WorkspacePath

  @table_name :iex_code_semantic_cache
  @max_index_file_bytes 1_048_576

  @excluded_dirs [
    "_build",
    "deps",
    ".git",
    ".agents",
    "tmp",
    "node_modules",
    "priv/static"
  ]
  @allowed_extensions [
    ".ex",
    ".exs",
    ".heex",
    ".md",
    ".json",
    ".js",
    ".ts",
    ".css",
    ".html",
    ".yml",
    ".yaml"
  ]

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(init_arg) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc """
  Ensures ETS table is created and returns its name.
  """
  def table_name, do: @table_name

  @doc """
  Returns the maximum allowed file size (in bytes) for indexing.
  """
  @spec max_index_file_bytes() :: pos_integer()
  def max_index_file_bytes, do: @max_index_file_bytes

  @doc """
  Indexes a project workspace incrementally.
  """
  def index_project(project_id, root_path, opts \\ []) do
    GenServer.call(__MODULE__, {:index_project, project_id, root_path, opts}, 120_000)
  end

  @doc """
  Performs sub-second ranked code search across indexed code chunks.

  Supports `mode: :hybrid | :vector | :lexical` (default `:hybrid`):
  - `:hybrid` — fuses dense cosine similarity and code-aware BM25 lexical ranking via RRF.
  - `:vector` — pure dense cosine similarity ranking.
  - `:lexical` — pure BM25 lexical ranking without calling the embedding client.
  """
  @spec search(String.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def search(project_id, query, opts \\ []) when is_binary(project_id) and is_binary(query) do
    limit = max(0, Keyword.get(opts, :limit, 10))
    threshold = Keyword.get(opts, :threshold, 0.4)
    path_filter = Keyword.get(opts, :path)

    case normalize_mode(Keyword.get(opts, :mode, :hybrid)) do
      {:ok, :lexical} ->
        ensure_table()
        results = search_lexical(project_id, query, threshold, path_filter, limit, opts)
        {:ok, results}

      {:ok, mode} when mode in [:hybrid, :vector] ->
        case EmbeddingClient.embed(query, Keyword.put(opts, :return, :binary)) do
          {:ok, [query_vector | _]} ->
            ensure_table()

            results =
              case mode do
                :vector ->
                  search_in_memory(project_id, query_vector, threshold, path_filter, limit)

                :hybrid ->
                  search_hybrid(
                    project_id,
                    query,
                    query_vector,
                    threshold,
                    path_filter,
                    limit,
                    opts
                  )
              end

            {:ok, results}

          {:ok, []} ->
            {:ok, []}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Warms up in-memory ETS cache from SQLite for a given project.
  """
  def warm_cache(project_id) do
    GenServer.call(__MODULE__, {:warm_cache, project_id}, 30_000)
  end

  @doc """
  Returns indexed chunk stats for a project.
  """
  def stats(project_id) do
    ensure_table()

    ets_count =
      :ets.select_count(@table_name, [
        {{:_, project_id, :_, :_, :_, :_, :_, :_, :_}, [], [true]}
      ])

    db_count =
      Repo.one(
        from(e in CodeEmbedding,
          where: e.project_id == ^project_id,
          select: count(e.id)
        )
      ) || 0

    %{ets_chunks: ets_count, db_chunks: db_count}
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_init_arg) do
    ensure_table()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:index_project, project_id, root_path, opts}, _from, state) do
    result = do_index_project(project_id, root_path, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:warm_cache, project_id}, _from, state) do
    count = do_warm_cache(project_id)
    {:reply, {:ok, count}, state}
  end

  # ============================================================================
  # Indexing Engine
  # ============================================================================

  defp do_index_project(project_id, root_path, opts) do
    files = list_indexable_files(root_path)
    existing_meta = fetch_existing_file_meta(project_id)

    model =
      case Keyword.get(opts, :model) do
        m when is_binary(m) and m != "" -> m
        _ -> EmbeddingClient.default_model()
      end

    expected_dimensions =
      Keyword.get(opts, :dimensions) || EmbeddingClient.model_dimension(model)

    results =
      Enum.reduce(files, %{indexed: 0, chunks: 0, skipped: 0}, fn rel_path, acc ->
        with {:ok, safe_path} <- WorkspacePath.resolve(root_path, rel_path),
             {:ok, %File.Stat{type: :regular, size: size}} <- File.stat(safe_path),
             true <- size <= @max_index_file_bytes,
             {:ok, content} <- File.read(safe_path) do
          file_hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

          if file_up_to_date?(existing_meta, rel_path, file_hash, model, expected_dimensions) do
            # Ensure chunks are loaded into ETS cache even if skipped in DB
            ensure_cached(project_id, rel_path)
            %{acc | skipped: acc.skipped + 1}
          else
            index_file(project_id, rel_path, content, file_hash, model, opts, acc)
          end
        else
          _ ->
            acc
        end
      end)

    # Prune files that no longer exist
    prune_deleted_files(project_id, Map.keys(existing_meta) -- files)

    {:ok, results}
  end

  defp fetch_existing_file_meta(project_id) do
    Repo.all(
      from(e in CodeEmbedding,
        where: e.project_id == ^project_id,
        select: {e.file_path, e.file_hash, e.model, e.dimensions},
        distinct: true
      )
    )
    |> Enum.group_by(&elem(&1, 0), fn {_path, hash, model, dims} ->
      {hash, model, dims}
    end)
  end

  defp file_up_to_date?(existing_meta, rel_path, file_hash, model, dimensions) do
    case Map.get(existing_meta, rel_path) do
      [{^file_hash, ^model, ^dimensions}] -> true
      _ -> false
    end
  end

  defp index_file(project_id, rel_path, content, file_hash, model, opts, acc) do
    delete_file_entries(project_id, rel_path)
    chunks = Chunker.chunk_file(rel_path, content)

    if chunks == [] do
      acc
    else
      chunk_texts = Enum.map(chunks, & &1.content)

      embed_opts =
        opts
        |> Keyword.put(:model, model)
        |> Keyword.put(:return, :binary)

      case EmbeddingClient.embed(chunk_texts, embed_opts) do
        {:ok, vectors} ->
          new_count =
            Enum.zip(chunks, vectors)
            |> Enum.map(fn {chunk, vector} ->
              now = DateTime.utc_now() |> DateTime.truncate(:second)
              actual_dimensions = Vector.dimension(vector)

              attrs = %{
                id: Ecto.UUID.generate(),
                project_id: project_id,
                file_path: rel_path,
                file_hash: file_hash,
                chunk_index: chunk.chunk_index,
                chunk_type: chunk.chunk_type,
                symbol_name: chunk.symbol_name,
                symbol_type: chunk.symbol_type,
                start_line: chunk.start_line,
                end_line: chunk.end_line,
                content: chunk.content,
                embedding: vector,
                dimensions: actual_dimensions,
                model: model,
                inserted_at: now,
                updated_at: now
              }

              %CodeEmbedding{}
              |> CodeEmbedding.changeset(attrs)
              |> Repo.insert!()

              :ets.insert(
                @table_name,
                {
                  attrs.id,
                  project_id,
                  rel_path,
                  chunk.start_line,
                  chunk.end_line,
                  chunk.symbol_name,
                  chunk.symbol_type,
                  chunk.content,
                  vector
                }
              )
            end)
            |> length()

          %{acc | indexed: acc.indexed + 1, chunks: acc.chunks + new_count}

        {:error, reason} ->
          Logger.warning("Failed to embed #{rel_path}: #{inspect(reason)}")
          acc
      end
    end
  end

  # ============================================================================
  # Search Engines (:vector, :lexical, :hybrid)
  # ============================================================================

  defp normalize_mode(mode) when mode in [:hybrid, :vector, :lexical], do: {:ok, mode}
  defp normalize_mode("hybrid"), do: {:ok, :hybrid}
  defp normalize_mode("vector"), do: {:ok, :vector}
  defp normalize_mode("lexical"), do: {:ok, :lexical}
  defp normalize_mode(other), do: {:error, {:invalid_mode, other}}

  defp search_in_memory(project_id, query_vector, threshold, path_filter, limit) do
    project_entries(project_id, path_filter)
    |> Enum.reduce([], fn {id, path, start_l, end_l, sym_name, sym_type, content, vec}, acc ->
      if valid_vector_pair?(query_vector, vec) do
        score = Vector.dot_product(query_vector, vec)
        result = format_result(id, path, start_l, end_l, sym_name, sym_type, content, score)
        if result.score >= threshold, do: [result | acc], else: acc
      else
        acc
      end
    end)
    |> Enum.sort_by(&{-&1.score, &1.file_path, &1.start_line})
    |> Enum.take(limit)
  end

  defp search_lexical(project_id, query, threshold, path_filter, limit, opts) do
    candidates =
      project_id
      |> project_entries(path_filter)
      |> Enum.map(fn {id, path, start_l, end_l, sym_name, sym_type, content, _vec} ->
        %{
          id: id,
          file_path: path,
          start_line: start_l,
          end_line: end_l,
          symbol_name: sym_name,
          symbol_type: sym_type,
          content: content
        }
      end)

    candidates
    |> HybridRanker.rank_lexical(query, Keyword.put(opts, :include_zero, threshold <= 0.0))
    |> Enum.map(fn item ->
      format_result(
        item.id,
        item.file_path,
        item.start_line,
        item.end_line,
        item.symbol_name,
        item.symbol_type,
        item.content,
        item.score
      )
    end)
    |> Enum.filter(&(&1.score >= threshold))
    |> Enum.take(limit)
  end

  defp search_hybrid(project_id, query, query_vector, threshold, path_filter, limit, opts) do
    entries = project_entries(project_id, path_filter)

    if entries == [] do
      []
    else
      candidates =
        Enum.map(entries, fn {id, path, start_l, end_l, sym_name, sym_type, content, vec} ->
          dense_score =
            if valid_vector_pair?(query_vector, vec) do
              max(0.0, Vector.dot_product(query_vector, vec))
            else
              0.0
            end

          %{
            id: id,
            file_path: path,
            start_line: start_l,
            end_line: end_l,
            symbol_name: sym_name,
            symbol_type: sym_type,
            content: content,
            dense_score: dense_score
          }
        end)

      min_dense = if threshold <= 0.0, do: 0.0, else: min(0.15, threshold)

      dense_ranked =
        candidates
        |> Enum.filter(&(&1.dense_score > min_dense))
        |> Enum.map(&Map.put(&1, :score, &1.dense_score))
        |> Enum.sort_by(&{-&1.score, &1.file_path, &1.start_line})

      lexical_ranked = HybridRanker.rank_lexical(candidates, query, opts)

      rrf_opts =
        opts
        |> Keyword.put_new(:k, 60)
        |> Keyword.put_new(:dense_weight, 1.0)
        |> Keyword.put_new(:lexical_weight, 1.15)
        |> Keyword.put(:normalization, :max)

      fused = HybridRanker.rrf_fuse(dense_ranked, lexical_ranked, rrf_opts)

      if fused == [] do
        []
      else
        signal_ceiling =
          fused
          |> Enum.reduce(0.0, fn item, acc ->
            combined =
              1.0 - (1.0 - min(1.0, item.dense_score)) * (1.0 - min(1.0, item.lexical_score))

            max(acc, combined)
          end)
          |> min(1.0)

        fused
        |> Enum.map(fn item ->
          item_max = max(item.dense_score, item.lexical_score)
          raw_hybrid = item.score * signal_ceiling

          calibrated =
            if item.dense_score > min_dense and item.lexical_score > 0.0 do
              raw_hybrid
            else
              min(raw_hybrid, item_max)
            end

          score = min(1.0, max(0.0, calibrated))

          format_result(
            item.id,
            item.file_path,
            item.start_line,
            item.end_line,
            item.symbol_name,
            item.symbol_type,
            item.content,
            score
          )
        end)
        |> Enum.filter(&(&1.score >= threshold))
        |> Enum.sort_by(&{-&1.score, &1.file_path, &1.start_line})
        |> Enum.take(limit)
      end
    end
  end

  defp project_entries(project_id, path_filter) do
    entries =
      :ets.select(@table_name, [
        {
          {:"$1", project_id, :"$2", :"$3", :"$4", :"$5", :"$6", :"$7", :"$8"},
          [],
          [{{:"$1", :"$2", :"$3", :"$4", :"$5", :"$6", :"$7", :"$8"}}]
        }
      ])

    if is_binary(path_filter) and path_filter != "" do
      Enum.filter(entries, fn {_id, path, _start, _end, _name, _type, _content, _vec} ->
        String.starts_with?(path, path_filter)
      end)
    else
      entries
    end
  end

  defp valid_vector_pair?(vec_a, vec_b)
       when is_binary(vec_a) and is_binary(vec_b) and
              byte_size(vec_a) > 0 and
              byte_size(vec_a) == byte_size(vec_b) and
              rem(byte_size(vec_b), 4) == 0,
       do: true

  defp valid_vector_pair?(_, _), do: false

  defp format_result(id, path, start_l, end_l, sym_name, sym_type, content, score) do
    rounded = Float.round(score * 1.0, 4)

    %{
      id: id,
      file_path: path,
      start_line: start_l,
      end_line: end_l,
      symbol_name: sym_name,
      symbol_type: sym_type,
      chunk_type: derive_chunk_type(sym_type),
      content: content,
      score: rounded,
      match_percent: round(max(0.0, rounded) * 100)
    }
  end

  defp derive_chunk_type(sym_type) when sym_type in ["def", "defp", "function"], do: "function"
  defp derive_chunk_type(sym_type) when sym_type in ["defmodule", "module"], do: "module"
  defp derive_chunk_type(sym_type) when sym_type in ["defmacro", "macro"], do: "macro"
  defp derive_chunk_type(sym_type) when sym_type in ["spec", "@spec"], do: "spec"
  defp derive_chunk_type(sym_type) when sym_type in ["type", "@type"], do: "type"

  defp derive_chunk_type(sym_type)
       when sym_type in ["doc", "moduledoc", "@doc", "@moduledoc"],
       do: "doc"

  defp derive_chunk_type(sym_type) when sym_type in ["file", nil], do: "text"
  defp derive_chunk_type(other), do: to_string(other)

  # ============================================================================
  # Cache & Storage Helpers
  # ============================================================================

  defp do_warm_cache(project_id) do
    ensure_table()
    :ets.match_delete(@table_name, {:_, project_id, :_, :_, :_, :_, :_, :_, :_})

    embeddings =
      Repo.all(
        from(e in CodeEmbedding,
          where: e.project_id == ^project_id
        )
      )

    Enum.each(embeddings, &insert_ets_embedding/1)

    length(embeddings)
  end

  defp ensure_cached(project_id, file_path) do
    exists? =
      :ets.match(@table_name, {:_, project_id, file_path, :_, :_, :_, :_, :_, :_}, 1) !=
        :"$end_of_table"

    unless exists? do
      embeddings =
        Repo.all(
          from(e in CodeEmbedding,
            where: e.project_id == ^project_id and e.file_path == ^file_path
          )
        )

      Enum.each(embeddings, &insert_ets_embedding/1)
    end
  end

  defp insert_ets_embedding(e) do
    :ets.insert(
      @table_name,
      {
        e.id,
        e.project_id,
        e.file_path,
        e.start_line,
        e.end_line,
        e.symbol_name,
        e.symbol_type,
        e.content,
        e.embedding
      }
    )
  end

  defp delete_file_entries(project_id, file_path) do
    Repo.delete_all(
      from(e in CodeEmbedding,
        where: e.project_id == ^project_id and e.file_path == ^file_path
      )
    )

    :ets.match_delete(@table_name, {:_, project_id, file_path, :_, :_, :_, :_, :_, :_})
  end

  defp prune_deleted_files(project_id, deleted_files) when is_list(deleted_files) do
    Enum.each(deleted_files, fn path ->
      delete_file_entries(project_id, path)
    end)
  end

  # ============================================================================
  # Workspace-Contained Directory Traversal
  # ============================================================================

  defp list_indexable_files(root_path) when is_binary(root_path) do
    case WorkspacePath.resolve(root_path, "") do
      {:ok, canonical_root} ->
        {files, _visited} = walk_dir(root_path, "", MapSet.new([canonical_root]))
        Enum.sort(files)

      {:error, _} ->
        []
    end
  end

  defp list_indexable_files(_), do: []

  defp walk_dir(root, rel, visited_dirs) do
    dir = if rel == "", do: root, else: Path.join(root, rel)

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.map(fn entry ->
          entry_rel = if rel == "", do: entry, else: Path.join(rel, entry)
          full = Path.join(dir, entry)
          {entry, entry_rel, File.lstat(full)}
        end)
        |> Enum.sort_by(fn
          {_, _, {:ok, %File.Stat{type: :symlink}}} -> 1
          _ -> 0
        end)
        |> Enum.reduce({[], visited_dirs}, fn {entry, entry_rel, lstat},
                                              {acc_files, acc_visited} ->
          if excluded_entry?(entry, entry_rel) do
            {acc_files, acc_visited}
          else
            handle_entry(root, entry, entry_rel, lstat, acc_files, acc_visited)
          end
        end)

      _ ->
        {[], visited_dirs}
    end
  end

  defp handle_entry(
         root,
         _entry,
         entry_rel,
         {:ok, %File.Stat{type: :directory}},
         acc_files,
         acc_visited
       ) do
    descend_directory(root, entry_rel, acc_files, acc_visited)
  end

  defp handle_entry(
         root,
         entry,
         entry_rel,
         {:ok, %File.Stat{type: :regular, size: size}},
         acc_files,
         acc_visited
       ) do
    if size <= @max_index_file_bytes and indexable_extension?(entry) and
         match?({:ok, _}, WorkspacePath.resolve(root, entry_rel)) do
      {[entry_rel | acc_files], acc_visited}
    else
      {acc_files, acc_visited}
    end
  end

  defp handle_entry(
         root,
         entry,
         entry_rel,
         {:ok, %File.Stat{type: :symlink}},
         acc_files,
         acc_visited
       ) do
    case WorkspacePath.resolve(root, entry_rel) do
      {:ok, canonical_target} ->
        case File.stat(canonical_target) do
          {:ok, %File.Stat{type: :directory}} ->
            if Path.basename(canonical_target) in @excluded_dirs do
              {acc_files, acc_visited}
            else
              descend_resolved_directory(
                root,
                entry_rel,
                canonical_target,
                acc_files,
                acc_visited
              )
            end

          {:ok, %File.Stat{type: :regular, size: size}} ->
            if size <= @max_index_file_bytes and indexable_extension?(entry) do
              {[entry_rel | acc_files], acc_visited}
            else
              {acc_files, acc_visited}
            end

          _ ->
            {acc_files, acc_visited}
        end

      {:error, _} ->
        {acc_files, acc_visited}
    end
  end

  defp handle_entry(_root, _entry, _entry_rel, _other, acc_files, acc_visited) do
    {acc_files, acc_visited}
  end

  defp descend_directory(root, entry_rel, acc_files, acc_visited) do
    case WorkspacePath.resolve(root, entry_rel) do
      {:ok, canonical_dir} ->
        descend_resolved_directory(root, entry_rel, canonical_dir, acc_files, acc_visited)

      {:error, _} ->
        {acc_files, acc_visited}
    end
  end

  defp descend_resolved_directory(root, entry_rel, canonical_dir, acc_files, acc_visited) do
    if MapSet.member?(acc_visited, canonical_dir) do
      {acc_files, acc_visited}
    else
      {sub_files, next_visited} =
        walk_dir(root, entry_rel, MapSet.put(acc_visited, canonical_dir))

      {sub_files ++ acc_files, next_visited}
    end
  end

  defp excluded_entry?(entry, entry_rel) do
    entry in @excluded_dirs or entry_rel in @excluded_dirs
  end

  defp indexable_extension?(filename) do
    (Path.extname(filename) |> String.downcase()) in @allowed_extensions
  end

  defp ensure_table do
    case :ets.whereis(@table_name) do
      :undefined ->
        try do
          :ets.new(@table_name, [:set, :public, :named_table, read_concurrency: true])
        rescue
          ArgumentError -> @table_name
        end

      _ ->
        @table_name
    end
  end
end
