defmodule IexCode.SemanticIndex.HybridRankerTest do
  use ExUnit.Case, async: true

  alias IexCode.SemanticIndex.HybridRanker

  describe "tokenize/1" do
    test "splits CamelCase, acronyms, and snake_case while preserving exact tokens" do
      camel_tokens = HybridRanker.tokenize("UserAuthController HTTPClient ASTSearch")

      assert "userauthcontroller" in camel_tokens
      assert "user" in camel_tokens
      assert "auth" in camel_tokens
      assert "controller" in camel_tokens
      assert "httpclient" in camel_tokens
      assert "http" in camel_tokens
      assert "client" in camel_tokens
      assert "astsearch" in camel_tokens
      assert "ast" in camel_tokens
      assert "search" in camel_tokens

      snake_tokens = HybridRanker.tokenize("fetch_existing_file_meta verify_token? insert!")

      assert "fetch_existing_file_meta" in snake_tokens
      assert "fetch" in snake_tokens
      assert "existing" in snake_tokens
      assert "file" in snake_tokens
      assert "meta" in snake_tokens
      assert "verify_token?" in snake_tokens
      assert "verify_token" in snake_tokens
      assert "verify" in snake_tokens
      assert "token" in snake_tokens
      assert "insert!" in snake_tokens
      assert "insert" in snake_tokens
    end

    test "splits module segments, atoms, module attributes, and file paths" do
      mod_tokens = HybridRanker.tokenize("MyApp.Auth.TokenManager")
      assert "myapp.auth.tokenmanager" in mod_tokens
      assert "myapp" in mod_tokens
      assert "my" in mod_tokens
      assert "app" in mod_tokens
      assert "auth" in mod_tokens
      assert "tokenmanager" in mod_tokens
      assert "token" in mod_tokens
      assert "manager" in mod_tokens

      sigil_tokens = HybridRanker.tokenize(":access_denied @max_index_file_bytes")
      assert ":access_denied" in sigil_tokens
      assert "access_denied" in sigil_tokens
      assert "access" in sigil_tokens
      assert "denied" in sigil_tokens
      assert "@max_index_file_bytes" in sigil_tokens
      assert "max_index_file_bytes" in sigil_tokens
      assert "max" in sigil_tokens
      assert "index" in sigil_tokens
      assert "file" in sigil_tokens
      assert "bytes" in sigil_tokens

      path_tokens = HybridRanker.tokenize("lib/iex_code/semantic_index/hybrid_ranker.ex")
      assert "lib" in path_tokens
      assert "iex_code" in path_tokens
      assert "semantic_index" in path_tokens
      assert "hybrid_ranker" in path_tokens
      assert "hybrid" in path_tokens
      assert "ranker" in path_tokens
      assert "ex" in path_tokens
    end

    test "handles nil, empty, pure punctuation, and preserves term repetition across words" do
      assert HybridRanker.tokenize(nil) == []
      assert HybridRanker.tokenize("") == []
      assert HybridRanker.tokenize("   --- ::: -> () {}   ") == []

      repeated = HybridRanker.tokenize("token check token verify token")
      assert Enum.count(repeated, &(&1 == "token")) == 3
    end
  end

  describe "rank_lexical/3" do
    test "orders exact symbol_name > prefix symbol_name > file_path > high-TF content" do
      candidates = [
        %{
          id: "content_heavy",
          symbol_name: "unrelated_helper",
          file_path: "lib/misc/other.ex",
          content: String.duplicate("verify_token ", 12)
        },
        %{
          id: "path_match",
          symbol_name: "other_fn",
          file_path: "lib/verify_token.ex",
          content: "def other_fn, do: :ok"
        },
        %{
          id: "prefix_symbol",
          symbol_name: "verify_token_expiry",
          file_path: "lib/a.ex",
          content: "def verify_token_expiry(t), do: t"
        },
        %{
          id: "exact_symbol",
          symbol_name: "verify_token",
          file_path: "lib/b.ex",
          content: "def verify_token(t), do: t"
        }
      ]

      ranked = HybridRanker.rank_lexical(candidates, "verify_token")

      assert Enum.map(ranked, & &1.id) == [
               "exact_symbol",
               "prefix_symbol",
               "path_match",
               "content_heavy"
             ]

      Enum.each(ranked, fn item ->
        assert item.score > 0.0 and item.score < 1.0
      end)
    end

    test "supports code-aware matching across CamelCase, atoms, and attributes" do
      candidates = [
        %{
          id: "atom_match",
          symbol_name: "check_access",
          file_path: "lib/auth.ex",
          content: "def check_access, do: {:error, :access_denied}"
        },
        %{
          id: "attr_match",
          symbol_name: "size_guard",
          file_path: "lib/limits.ex",
          content: "@max_index_file_bytes 1_048_576"
        },
        %{
          id: "camel_match",
          symbol_name: "MyApp.Auth.TokenManager",
          file_path: "lib/token_manager.ex",
          content: "defmodule MyApp.Auth.TokenManager, do: nil"
        }
      ]

      assert [%{id: "atom_match"}] = HybridRanker.rank_lexical(candidates, ":access_denied")

      assert [%{id: "attr_match"}] =
               HybridRanker.rank_lexical(candidates, "@max_index_file_bytes")

      assert [%{id: "camel_match"} | _] = HybridRanker.rank_lexical(candidates, "token manager")
    end

    test "handles tiny N=1/N=2 corpora without negative IDF and filters zero-overlap queries" do
      single = [
        %{
          id: "only",
          symbol_name: "sign_token",
          file_path: "lib/auth.ex",
          content: "def sign_token(id), do: id"
        }
      ]

      assert [%{id: "only", score: score}] = HybridRanker.rank_lexical(single, "sign_token")
      assert score > 0.5 and score < 1.0

      assert HybridRanker.rank_lexical(single, "quantum entanglement") == []

      assert [%{id: "only", score: zero_score}] =
               HybridRanker.rank_lexical(single, "quantum entanglement", include_zero: true)

      assert zero_score == 0.0
    end
  end

  describe "rrf_fuse/3" do
    test "fuses dense and lexical rankings using 1 / (k + rank) and normalizes to (0.0, 1.0]" do
      dense = [
        %{id: "a", file_path: "a.ex", score: 0.9},
        %{id: "b", file_path: "b.ex", score: 0.8},
        %{id: "c", file_path: "c.ex", score: 0.7}
      ]

      lexical = [
        %{id: "b", file_path: "b.ex", score: 0.95},
        %{id: "d", file_path: "d.ex", score: 0.85},
        %{id: "a", file_path: "a.ex", score: 0.50}
      ]

      # With k = 60:
      # a: 1/61 + 1/63
      # b: 1/62 + 1/61 (highest!)
      # c: 1/63
      # d: 1/62
      fused = HybridRanker.rrf_fuse(dense, lexical, k: 60)

      assert Enum.map(fused, & &1.id) == ["b", "a", "d", "c"]
      assert hd(fused).score == 1.0

      Enum.each(fused, fn item ->
        assert item.score > 0.0 and item.score <= 1.0
      end)
    end

    test "respects configurable k, list weights, theoretical normalization, and deduplicates repeats" do
      dense = [
        %{id: "only_dense", score: 0.9},
        %{id: "only_dense", score: 0.8},
        %{id: "shared", score: 0.7}
      ]

      lexical = [
        %{id: "shared", score: 0.9},
        %{id: "only_lex", score: 0.8}
      ]

      # With k=10 and lexical_weight=2.0:
      # shared: 1.0/(10+2) + 2.0/(10+1) = 1/12 + 2/11 = 0.26515...
      # only_lex: 2.0/(10+2) = 0.16666...
      # only_dense: 1.0/(10+1) = 0.09090...
      fused =
        HybridRanker.rrf_fuse(dense, lexical,
          k: 10,
          dense_weight: 1.0,
          lexical_weight: 2.0,
          normalization: :theoretical
        )

      assert Enum.map(fused, & &1.id) == ["shared", "only_lex", "only_dense"]

      max_theoretical = 3.0 / 11
      expected_shared = (1.0 / 12 + 2.0 / 11) / max_theoretical
      assert_in_delta hd(fused).score, expected_shared, 1.0e-6

      assert HybridRanker.rrf_fuse([], []) == []
    end
  end
end
