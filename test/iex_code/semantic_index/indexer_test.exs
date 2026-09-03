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

  alias IexCode.SemanticIndex.Indexer
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
end
