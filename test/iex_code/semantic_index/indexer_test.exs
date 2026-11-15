defmodule IexCode.SemanticIndex.IndexerTest do
  @moduledoc """
  Requirement R2: Offline Local Semantic Codebase Indexing & Vector Search.
  Tests for IexCode.SemanticIndex.Indexer:
  - SQLite code_embeddings persistence and schema verification
  - Incremental SHA-256 file change detection and cache invalidation
  - Sub-second ranked cosine similarity retrieval (top-K)
  - Tool execution via IexCode.Tools ("semantic_code_search")
  """
  use IexCode.DataCase, async: false

  import Ecto.Query

  alias IexCode.Repo
  alias IexCode.SemanticIndex.{CodeEmbedding, Indexer, Vector}
  alias IexCode.Projects
  alias IexCode.Tools

  setup do
    unique_id = System.unique_integer([:positive])
    temp_dir = Path.join(System.tmp_dir!(), "iex_indexer_test_#{unique_id}")
    File.mkdir_p!(Path.join(temp_dir, "lib"))

    # Populate temporary project with realistic code files
    file_a = """
    defmodule Auth.TokenManager do
      @moduledoc "Handles JWT token issuance and cryptographic verification."

      def sign_token(user_id) do
        "token_for_\#{user_id}"
      end

      def verify_token(token) do
        String.starts_with?(token, "token_for_")
      end
    end
    """

    file_b = """
    defmodule Storage.VectorStore do
      @moduledoc "Persists packed float32 embeddings into SQLite tables."

      def insert_vector(key, binary_vec) do
        :ok
      end

      def nearest_neighbors(query_vec, limit) do
        []
      end
    end
    """

    File.write!(Path.join(temp_dir, "lib/auth_token.ex"), file_a)
    File.write!(Path.join(temp_dir, "lib/vector_store.ex"), file_b)

    File.write!(
      Path.join(temp_dir, "README.md"),
      "# Auth and Vector Storage\nProvides token authorization and vector nearest neighbors.\n"
    )

    {:ok, project} =
      Projects.create_project(%{
        name: "Indexer Test Project #{unique_id}",
        root_path: temp_dir
      })

    on_exit(fn ->
      File.rm_rf(temp_dir)
    end)

    {:ok, project: project, temp_dir: temp_dir}
  end

  describe "Tier 1: Codebase Indexing & SQLite Storage" do
    test "T1_R2_IDX_01: indexes project files creating code_embeddings records", %{
      project: project,
      temp_dir: temp_dir
    } do
      {:ok, summary} = Indexer.index_project(project.id, temp_dir)

      # Flexible match on summary fields
      indexed_count = summary[:indexed] || summary[:files_indexed] || 0
      chunks_count = summary[:chunks] || summary[:chunks_created] || 0
      assert indexed_count >= 2
      assert chunks_count >= 2

      stats = Indexer.stats(project.id)
      total_chunks = stats[:ets_chunks] || stats[:db_chunks] || stats[:total_chunks] || 0
      assert total_chunks >= 2
    end

    test "T1_R2_IDX_02: incremental indexing skips unchanged files (0 re-embeddings)", %{
      project: project,
      temp_dir: temp_dir
    } do
      {:ok, initial_summary} = Indexer.index_project(project.id, temp_dir)
      initial_indexed = initial_summary[:indexed] || initial_summary[:files_indexed] || 0
      assert initial_indexed >= 2

      # Immediate second run with unchanged files
      {:ok, second_summary} = Indexer.index_project(project.id, temp_dir)
      second_indexed = second_summary[:indexed] || second_summary[:files_indexed] || 0
      second_skipped = second_summary[:skipped] || second_summary[:files_skipped] || 0
      assert second_indexed == 0
      assert second_skipped >= 2
    end

    test "T1_R2_IDX_03: modifying single file updates only its chunks", %{
      project: project,
      temp_dir: temp_dir
    } do
      {:ok, _} = Indexer.index_project(project.id, temp_dir)

      # Modify auth_token.ex
      modified_auth = """
      defmodule Auth.TokenManager do
        def revoke_token(token), do: :revoked
      end
      """

      File.write!(Path.join(temp_dir, "lib/auth_token.ex"), modified_auth)

      {:ok, update_summary} = Indexer.index_project(project.id, temp_dir)
      updated = update_summary[:indexed] || update_summary[:files_indexed] || 0
      skipped = update_summary[:skipped] || update_summary[:files_skipped] || 0
      assert updated == 1
      assert skipped >= 1
    end

    test "T1_R2_IDX_04: deleting a file on disk purges its indexed chunks", %{
      project: project,
      temp_dir: temp_dir
    } do
      {:ok, _} = Indexer.index_project(project.id, temp_dir)
      stats_before = Indexer.stats(project.id)
      chunks_before = stats_before[:ets_chunks] || stats_before[:db_chunks] || 0

      File.rm!(Path.join(temp_dir, "lib/vector_store.ex"))
      {:ok, _} = Indexer.index_project(project.id, temp_dir)

      stats_after = Indexer.stats(project.id)
      chunks_after = stats_after[:ets_chunks] || stats_after[:db_chunks] || 0
      assert chunks_after < chunks_before
    end
  end

  describe "Tier 1 & 2: Sub-Second Ranked Semantic Code Retrieval" do
    test "T1_R2_IDX_05: search returns ranked results matching query semantics", %{
      project: project,
      temp_dir: temp_dir
    } do
      {:ok, _} = Indexer.index_project(project.id, temp_dir)

      {time_us, {:ok, results}} =
        :timer.tc(fn ->
          Indexer.search(project.id, "JWT cryptographic signature verification",
            limit: 5,
            threshold: 0.1
          )
        end)

      # Sub-second execution (< 100ms)
      assert time_us < 100_000

      assert is_list(results)
      assert length(results) >= 1

      first = hd(results)
      assert Map.has_key?(first, :file_path)
      assert Map.has_key?(first, :score)
      assert first.file_path =~ "auth_token.ex" or first.file_path =~ "README.md"
    end

    test "T1_R2_IDX_06: search respects limit, path filter, and threshold options", %{
      project: project,
      temp_dir: temp_dir
    } do
      {:ok, _} = Indexer.index_project(project.id, temp_dir)

      {:ok, limited} = Indexer.search(project.id, "token", limit: 1, threshold: 0.0)
      assert length(limited) <= 1

      {:ok, filtered} =
        Indexer.search(project.id, "completely unrelated quantum physics", threshold: 0.99)

      assert length(filtered) == 0
    end

    test "T1_R2_IDX_07: agent tool semantic_code_search executes cleanly", %{
      project: project,
      temp_dir: temp_dir
    } do
      {:ok, _} = Indexer.index_project(project.id, temp_dir)

      tool_args = %{
        "query" => "token verification",
        "limit" => 5,
        "project_id" => project.id
      }

      {:ok, output} = Tools.execute("semantic_code_search", tool_args, temp_dir)

      assert is_binary(output) or is_map(output) or is_list(output)
    end
  end

  describe "Tier 2: Boundary & Corner Cases" do
    test "T2_R2_IDX_01: indexing empty directory produces 0 chunks without error", %{
      project: project
    } do
      empty_dir =
        Path.join(System.tmp_dir!(), "iex_empty_project_#{System.unique_integer([:positive])}")

      File.mkdir_p!(empty_dir)

      {:ok, summary} = Indexer.index_project(project.id, empty_dir)
      indexed = summary[:indexed] || summary[:files_indexed] || 0
      assert indexed == 0

      File.rm_rf(empty_dir)
    end

    test "T2_R2_IDX_02: query on unindexed project returns empty list cleanly" do
      unindexed_id = Ecto.UUID.generate()
      assert {:ok, []} = Indexer.search(unindexed_id, "find anything")
    end
  end

  describe "Round 3: Model/Dimension Consistency & Search Safety" do
    test "re-indexes unchanged files when embedding model or dimensions change", %{
      project: project,
      temp_dir: temp_dir
    } do
      {:ok, first} =
        Indexer.index_project(project.id, temp_dir, model: "fallback-hash-384")

      assert first.indexed >= 2
      assert first.skipped == 0

      stored_384 =
        Repo.all(from(e in CodeEmbedding, where: e.project_id == ^project.id))

      assert stored_384 != []
      assert Enum.all?(stored_384, &(&1.model == "fallback-hash-384" and &1.dimensions == 384))

      # Same model + same content -> skipped
      {:ok, second} =
        Indexer.index_project(project.id, temp_dir, model: "fallback-hash-384")

      assert second.indexed == 0
      assert second.skipped == first.indexed

      # Switch model -> 768-dim nomic-embed-text -> must re-index instead of skipping
      {:ok, switched} =
        Indexer.index_project(project.id, temp_dir, model: "nomic-embed-text")

      assert switched.indexed == first.indexed
      assert switched.skipped == 0

      stored_768 =
        Repo.all(from(e in CodeEmbedding, where: e.project_id == ^project.id))

      assert Enum.all?(
               stored_768,
               &(&1.model == "nomic-embed-text" and &1.dimensions == 768 and
                   byte_size(&1.embedding) == 768 * 4)
             )

      # Mutate dimensions in DB while keeping same model -> must detect stale dimension and re-index
      Repo.update_all(
        from(e in CodeEmbedding, where: e.project_id == ^project.id),
        set: [dimensions: 384]
      )

      {:ok, repaired} =
        Indexer.index_project(project.id, temp_dir, model: "nomic-embed-text")

      assert repaired.indexed == first.indexed
      assert repaired.skipped == 0
    end

    test "search_in_memory and hybrid search safely handle mismatched vector dimensions in ETS",
         %{
           project: project,
           temp_dir: temp_dir
         } do
      {:ok, _} = Indexer.index_project(project.id, temp_dir, model: "nomic-embed-text")

      table = Indexer.table_name()
      stale_384 = Vector.normalize(Vector.pack(for i <- 1..384, do: :math.sin(i)))
      corrupted_odd = <<1, 2, 3, 4, 5>>

      :ets.insert(
        table,
        {
          "stale_384_chunk",
          project.id,
          "lib/stale_384.ex",
          1,
          5,
          "sign_token_stale",
          "def",
          "def sign_token_stale(x), do: x",
          stale_384
        }
      )

      :ets.insert(
        table,
        {
          "corrupted_chunk",
          project.id,
          "lib/corrupted.ex",
          1,
          5,
          "broken_vec",
          "def",
          "def broken_vec, do: :ok",
          corrupted_odd
        }
      )

      # Pure vector search with 768-dim query against 384-dim + corrupted ETS entries must not crash
      assert {:ok, vec_results} =
               Indexer.search(project.id, "sign_token",
                 mode: :vector,
                 model: "nomic-embed-text",
                 threshold: 0.0
               )

      refute Enum.any?(vec_results, &(&1.file_path in ["lib/stale_384.ex", "lib/corrupted.ex"]))

      # Hybrid mode also survives mismatched vectors and can still retrieve via BM25
      assert {:ok, hybrid_results} =
               Indexer.search(project.id, "sign_token_stale",
                 mode: :hybrid,
                 model: "nomic-embed-text",
                 threshold: 0.1
               )

      assert Enum.any?(hybrid_results, &(&1.file_path == "lib/stale_384.ex"))
    end
  end

  describe "Round 3: Workspace Symlink & File-Size Safety" do
    test "blocks external symlink escapes, symlink loops, dangling links, and oversized files", %{
      project: project,
      temp_dir: temp_dir
    } do
      outside_dir =
        Path.join(System.tmp_dir!(), "iex_outside_#{System.unique_integer([:positive])}")

      File.mkdir_p!(outside_dir)
      outside_file = Path.join(outside_dir, "secret.ex")
      File.write!(outside_file, "defmodule OutsideSecret, do: def leak_secret, do: :leaked\n")

      on_exit(fn -> File.rm_rf(outside_dir) end)

      # 1. Symlink to file outside project_root
      :ok = File.ln_s(outside_file, Path.join(temp_dir, "lib/escape_file.ex"))

      # 2. Symlink to directory outside project_root
      :ok = File.ln_s(outside_dir, Path.join(temp_dir, "escape_dir"))

      # 3. Directory symlink loops (direct parent loop & mutual loop) + dangling symlink
      :ok = File.ln_s("..", Path.join(temp_dir, "lib/parent_loop"))
      File.mkdir_p!(Path.join(temp_dir, "dir_a"))
      File.mkdir_p!(Path.join(temp_dir, "dir_b"))
      :ok = File.ln_s("../dir_b", Path.join(temp_dir, "dir_a/to_b"))
      :ok = File.ln_s("../dir_a", Path.join(temp_dir, "dir_b/to_a"))
      :ok = File.ln_s("does_not_exist.ex", Path.join(temp_dir, "lib/dangling.ex"))

      # 4. Oversized file (> @max_index_file_bytes)
      oversized_bytes = Indexer.max_index_file_bytes() + 1

      File.write!(
        Path.join(temp_dir, "lib/too_large.md"),
        String.duplicate("x", oversized_bytes)
      )

      # 5. Legitimate boundary-sized file (<= @max_index_file_bytes)
      File.write!(
        Path.join(temp_dir, "lib/boundary_ok.md"),
        "# Boundary OK\nboundary_sentinel_token\n"
      )

      {:ok, summary} = Indexer.index_project(project.id, temp_dir)
      assert summary.indexed >= 3

      indexed_paths =
        Repo.all(
          from(e in CodeEmbedding,
            where: e.project_id == ^project.id,
            select: e.file_path,
            distinct: true
          )
        )

      refute "lib/escape_file.ex" in indexed_paths
      refute Enum.any?(indexed_paths, &String.starts_with?(&1, "escape_dir"))
      refute "lib/too_large.md" in indexed_paths
      refute "lib/dangling.ex" in indexed_paths
      assert "lib/boundary_ok.md" in indexed_paths

      assert {:ok, []} = Indexer.search(project.id, "leak_secret", mode: :lexical, threshold: 0.1)
    end
  end

  describe "Round 3: Hybrid, Vector, and Lexical Search Modes" do
    test "hybrid mode boosts exact symbol recall under fallback-hash-384 and preserves result contract",
         %{project: project, temp_dir: temp_dir} do
      File.write!(Path.join(temp_dir, "lib/merkle.ex"), """
      defmodule Crypto.MerkleProof do
        def compute_merkle_root_digest(leaves) do
          Enum.join(leaves, ":")
        end
      end
      """)

      File.write!(Path.join(temp_dir, "lib/noise.ex"), """
      defmodule App.NoiseDigest do
        # Mentions compute and digest and root in long narrative comments
        def summarize_everything(a, b) do
          "digest compute root digest compute root \#{inspect(a)} \#{inspect(b)}"
        end
      end
      """)

      {:ok, _} = Indexer.index_project(project.id, temp_dir, model: "fallback-hash-384")

      {:ok, results} =
        Indexer.search(project.id, "compute_merkle_root_digest",
          model: "fallback-hash-384",
          mode: :hybrid,
          threshold: 0.4,
          limit: 5
        )

      assert length(results) >= 1
      top = hd(results)
      assert top.file_path == "lib/merkle.ex"
      assert top.symbol_name == "compute_merkle_root_digest"
      assert top.chunk_type == "function"
      assert is_integer(top.start_line)
      assert is_integer(top.end_line)
      assert is_binary(top.content)
      assert is_float(top.score)
      assert top.score >= 0.4 and top.score <= 1.0
      assert top.match_percent >= 40 and top.match_percent <= 100
    end

    test "mode: :lexical executes without embedding HTTP calls while :vector and :hybrid surface endpoint errors",
         %{project: project, temp_dir: temp_dir} do
      {:ok, _} = Indexer.index_project(project.id, temp_dir)

      failing_plug = fn _conn ->
        raise "EmbeddingClient must not be called in :lexical mode"
      end

      assert {:ok, lexical_results} =
               Indexer.search(project.id, "verify_token",
                 mode: :lexical,
                 plug: failing_plug,
                 base_url: "http://127.0.0.1:59999",
                 threshold: 0.3
               )

      assert length(lexical_results) >= 1
      assert hd(lexical_results).file_path == "lib/auth_token.ex"
      assert hd(lexical_results).symbol_name == "verify_token"

      # Path prefix filter works in :lexical mode
      assert {:ok, []} =
               Indexer.search(project.id, "verify_token",
                 mode: :lexical,
                 path: "lib/vector_store",
                 threshold: 0.1
               )

      # :vector and :hybrid hit the unreachable endpoint and return {:error, _}
      assert {:error, _} =
               Indexer.search(project.id, "verify_token",
                 mode: :vector,
                 base_url: "http://127.0.0.1:59999",
                 timeout: 100,
                 retry: false
               )

      assert {:error, _} =
               Indexer.search(project.id, "verify_token",
                 mode: :hybrid,
                 base_url: "http://127.0.0.1:59999",
                 timeout: 100,
                 retry: false
               )

      assert {:error, {:invalid_mode, :bogus}} =
               Indexer.search(project.id, "verify_token", mode: :bogus)
    end

    test "mode: :vector preserves pure cosine similarity ordering", %{
      project: project,
      temp_dir: temp_dir
    } do
      # Deterministic plug where vector_store.ex matches the query embedding purely by vector,
      # even though auth_token.ex has the lexical token "verify_token"
      semantic_plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        %{"input" => inputs} = Jason.decode!(body)

        data =
          inputs
          |> Enum.with_index()
          |> Enum.map(fn {text, idx} ->
            vec =
              cond do
                String.contains?(text, "VectorStore") -> [1.0, 0.0, 0.0, 0.0]
                text == "verify_token" -> [1.0, 0.0, 0.0, 0.0]
                true -> [0.0, 1.0, 0.0, 0.0]
              end

            %{"embedding" => vec, "index" => idx}
          end)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"data" => data}))
      end

      {:ok, _} =
        Indexer.index_project(project.id, temp_dir,
          plug: semantic_plug,
          model: "custom-4",
          dimensions: 4
        )

      # Pure :vector returns vector_store.ex (cosine 1.0) and excludes auth_token.ex (cosine 0.0)
      assert {:ok, vec_results} =
               Indexer.search(project.id, "verify_token",
                 mode: :vector,
                 plug: semantic_plug,
                 model: "custom-4",
                 threshold: 0.5
               )

      assert vec_results != []
      assert Enum.all?(vec_results, &(&1.file_path == "lib/vector_store.ex"))
      assert hd(vec_results).score == 1.0
    end
  end
end
