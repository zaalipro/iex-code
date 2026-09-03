defmodule IexCodeWeb.EmpiricalChallengeM4Test do
  use ExUnit.Case, async: true

  alias IexCodeWeb.CommandPalette

  # ============================================================================
  # Fixtures & Generators
  # ============================================================================
  setup_all do
    # Generate 2,000 synthetic file paths with realistic project directory depth
    synthetic_files =
      for i <- 1..2000 do
        case rem(i, 5) do
          0 -> "lib/iex_code_web/live/workspace_live/views/dashboard_view_#{i}.ex"
          1 -> "apps/billing/lib/domain/services/billing/payment_processor_service_#{i}.ex"
          2 -> "test/iex_code/autonomous_swarm/orchestration_pipeline_worker_#{i}_test.exs"
          3 -> "assets/js/components/monaco_inline_editor_buffer_manager_#{i}.ts"
          4 -> "config/deploy/kubernetes/helm/charts/microservice_cluster_node_#{i}.yaml"
        end
      end

    # Generate 100 sessions
    synthetic_sessions =
      for i <- 1..100 do
        %{
          id: "sess-#{i}",
          title: "Architecture & Refactoring Session #{i}",
          message_count: rem(i * 7, 50),
          model_name: "claude-3-7-sonnet",
          updated_at: DateTime.utc_now()
        }
      end

    # Generate 50 swarms
    synthetic_swarms =
      for i <- 1..50 do
        %{
          id: "swarm-run-#{i}",
          objective: "Autonomous pipeline test verification and patch application ##{i}",
          status: Enum.at(["queued", "running", "completed", "failed"], rem(i, 4)),
          mode: "swarm",
          progress: rem(i * 13, 100),
          input_tokens: i * 500,
          output_tokens: i * 250,
          agent_count: 4
        }
      end

    # Generate 50 models
    synthetic_models =
      for i <- 1..50 do
        %{
          id: "custom-model-v#{i}",
          name: "DeepReason Model-v#{i} Spec",
          provider: Enum.at(["anthropic", "openai", "google", "ollama"], rem(i, 4)),
          local?: rem(i, 2) == 0,
          endpoint: "https://api.model-provider-#{i}.com/v1"
        }
      end

    # Generate 100 git branches
    synthetic_branches =
      for i <- 1..100 do
        %{
          name: "feature/swarm-agent-collaboration-pipeline-#{i}",
          current?: i == 1,
          upstream: "origin/feature/swarm-agent-collaboration-pipeline-#{i}"
        }
      end

    # Generate 50 terminal commands
    synthetic_terminal =
      for i <- 1..50 do
        %{
          command: "mix test.interactive --suite=domain_#{i} --trace",
          desc: "Execute ExUnit interactive trace runner for domain module ##{i}"
        }
      end

    extra = %{
      swarms: synthetic_swarms,
      models: synthetic_models,
      branches: synthetic_branches,
      terminal_commands: synthetic_terminal,
      workspace_root: "/Users/zaali/dev/iex-code"
    }

    %{
      files: synthetic_files,
      sessions: synthetic_sessions,
      extra: extra
    }
  end

  # ============================================================================
  # 1. Boundary Conditions & Extreme Inputs
  # ============================================================================
  describe "1. Boundary Conditions & Extreme Inputs" do
    test "1.1 Extremely long queries (1,000+ chars) execute safely in < 25ms and return empty list",
         %{
           files: files,
           sessions: sessions,
           extra: extra
         } do
      lengths = [1_000, 2_500, 5_000, 10_000, 50_000, 100_000]

      for len <- lengths do
        long_q = String.duplicate("long_query_pattern_", div(len, 19) + 1)

        {time_us, results} =
          :timer.tc(fn ->
            CommandPalette.search(long_q, files, sessions, "all", extra)
          end)

        assert time_us < 25_000,
               "Search with #{len}-char query took #{time_us / 1000}ms (exceeded 25ms limit)"

        assert results == [], "Massive query should yield empty list"

        # Also score/2 directly
        assert CommandPalette.score(long_q, "payment_processor_service_1.ex") == :nomatch
      end
    end

    test "1.2 Empty, nil, and whitespace-only queries return full default result set without raising",
         %{
           files: files,
           sessions: sessions,
           extra: extra
         } do
      queries = [
        "",
        nil,
        "   ",
        "\t\t\n\r  ",
        "  \t  \n  \r  "
      ]

      baseline = CommandPalette.search("", files, sessions, "all", extra)
      assert is_list(baseline)
      assert length(baseline) > 0

      for q <- queries do
        res = CommandPalette.search(q, files, sessions, "all", extra)
        assert is_list(res), "Failed on query #{inspect(q)}"

        assert length(res) == length(baseline),
               "Query #{inspect(q)} returned #{length(res)} items, expected #{length(baseline)}"
      end

      # Direct score checks on empty / nil
      assert CommandPalette.score("", "some_target") == {:ok, 0}
      assert CommandPalette.score("   ", "some_target") == {:ok, 0}
      assert CommandPalette.score(nil, "some_target") == :nomatch
      assert CommandPalette.score("query", nil) == :nomatch
    end

    test "1.3 Special regex / delimiter characters execute safely with zero crashes", %{
      files: files,
      sessions: sessions,
      extra: extra
    } do
      special_inputs = [
        "*",
        "?",
        "+",
        "(",
        ")",
        "[",
        "]",
        "{",
        "}",
        "^",
        "$",
        "\\",
        "/",
        "-",
        "_",
        ".",
        ".*",
        ".+",
        "[a-z]+",
        "\\d+",
        "(?:foo|bar)",
        ".*?",
        "+++",
        "***",
        "$$$",
        "^^^",
        "\\0",
        "\0",
        "\x00",
        "<script>alert(1)</script>",
        "!@#$%^&*()_+-=[]{}|;':\",./<>?",
        "\\\\\\\\",
        "\\n\\r\\t",
        "\"\"\"'''",
        "```elixir```",
        "foo[bar]",
        "(payment|billing)",
        "^lib/.*\\.ex$"
      ]

      for special <- special_inputs do
        # Individual search must not crash
        res = CommandPalette.search(special, files, sessions, "all", extra)
        assert is_list(res), "Failed on special input: #{inspect(special)}"

        # score/2 direct check
        s = CommandPalette.score(special, "lib/iex_code_web/command_palette.ex")
        assert s == :nomatch or match?({:ok, _}, s)
      end
    end

    test "1.4 Unicode, emojis, and multi-byte characters" do
      unicode_queries = [
        "🚀",
        "✨",
        "🔥",
        "ñ",
        "ç",
        "ü",
        "é",
        "ø",
        "日本語",
        "العربية",
        "Скрипт",
        "🚀 swarm",
        "🔥 test",
        "✨ visualizer"
      ]

      for uq <- unicode_queries do
        score = CommandPalette.score(uq, "🚀 swarm launcher")
        assert score == :nomatch or match?({:ok, _}, score)
      end

      # Boundary bonus check with unicode target
      assert match?({:ok, _}, CommandPalette.score("swarm", "🚀_swarm_launcher"))
    end

    test "1.5 Non-matching queries and inverted character sequences do NOT match" do
      # 1. Inverted characters must return :nomatch
      assert CommandPalette.score("cba", "abc") == :nomatch
      assert CommandPalette.score("zyx", "xyz") == :nomatch
      assert CommandPalette.score("evil_ecapskrow", "workspace_live") == :nomatch
      assert CommandPalette.score("seilf", "files") == :nomatch
      assert CommandPalette.score("txet", "test") == :nomatch

      # 2. Inverted word order without common subsequence
      assert CommandPalette.score("palette_command", "command_palette") == :nomatch
      assert CommandPalette.score("service_payment", "payment_service") == :nomatch

      # 3. Subsequence ordering strictly enforced
      assert {:ok, s1} = CommandPalette.score("wklv", "workspace_live")
      assert s1 > 100

      assert CommandPalette.score("vlk", "workspace_live") == :nomatch
      assert CommandPalette.score("exil", "lib/calc.ex") == :nomatch

      # 4. Completely unrelated random strings
      assert CommandPalette.score("qqqqqqqq", "workspace_live.ex") == :nomatch
      assert CommandPalette.score("zzzzzzzz", "Run All Tests") == :nomatch
    end

    test "1.6 All prefix shortcuts (>, @, #, $, /, !) parse accurately and isolate categories", %{
      files: files,
      sessions: sessions,
      extra: extra
    } do
      prefixes = [
        {">", "actions", :action, "> run", "run", ">run"},
        {"@", "swarms", :swarm, "@ pipeline", "pipeline", "@pipeline"},
        {"#", "files", :file, "# payment", "payment", "#payment"},
        {"$", "models", :model, "$ deepreason", "deepreason", "$deepreason"},
        {"/", "branches", :branch, "/ swarm-agent", "swarm-agent", "/swarm-agent"},
        {"!", "terminal", :terminal, "! interactive", "interactive", "!interactive"}
      ]

      for {pfx, expected_cat, expected_type, with_space, query_text, no_space} <- prefixes do
        # 1. Parsing with and without space
        assert CommandPalette.parse_query_prefix(pfx, "all") == {"", expected_cat}
        assert CommandPalette.parse_query_prefix(pfx <> " ", "all") == {"", expected_cat}
        assert CommandPalette.parse_query_prefix(with_space, "all") == {query_text, expected_cat}
        assert CommandPalette.parse_query_prefix(no_space, "all") == {query_text, expected_cat}

        # 2. Search execution: category isolation (0 cross-category bleeding)
        results = CommandPalette.search(with_space, files, sessions, "all", extra)
        assert is_list(results)
        assert length(results) > 0, "Expected results for #{with_space}"

        for item <- results do
          assert item.category == expected_type,
                 "Prefix #{pfx} should only return #{expected_type}, but got #{inspect(item.category)}: #{inspect(item.title)}"
        end

        # 3. Trailing space without query returns all items in that category
        empty_prefix_results = CommandPalette.search(pfx, files, sessions, "all", extra)
        assert is_list(empty_prefix_results)
        assert length(empty_prefix_results) > 0

        for item <- empty_prefix_results do
          assert item.category == expected_type,
                 "Prefix #{pfx} empty should only return #{expected_type}, but got #{inspect(item.category)}"
        end
      end
    end

    test "1.7 Branch prefix shortcut '/' vs multi-segment path distinction" do
      # Single slash alone -> branches
      assert CommandPalette.parse_query_prefix("/", "all") == {"", "branches"}
      assert CommandPalette.parse_query_prefix("/ ", "all") == {"", "branches"}

      # Branch search with space -> branches
      assert CommandPalette.parse_query_prefix("/ feature-branch", "all") ==
               {"feature-branch", "branches"}

      assert CommandPalette.parse_query_prefix("/ feature/foo", "all") ==
               {"feature/foo", "branches"}

      # Branch search without space (1-segment) -> branches
      assert CommandPalette.parse_query_prefix("/main", "all") == {"main", "branches"}
      assert CommandPalette.parse_query_prefix("/feature", "all") == {"feature", "branches"}

      # Multi-segment absolute filesystem path (e.g. /usr/local/bin) -> falls through to default filter
      assert CommandPalette.parse_query_prefix("/usr/local/bin", "files") ==
               {"/usr/local/bin", "files"}

      assert CommandPalette.parse_query_prefix("/path/to/file.ex", "all") ==
               {"/path/to/file.ex", "all"}
    end

    test "1.8 Defensive collection input guards on nil/malformed collections",
         %{
           files: files,
           sessions: sessions
         } do
      # Defensive nil files handling (no crash)
      assert is_list(CommandPalette.search("test", nil, sessions))

      # Defensive nil sessions handling (no crash)
      assert is_list(CommandPalette.search("test", files, nil))

      # Defensive non-enumerable extra[:swarms] handling (no crash)
      assert is_list(
               CommandPalette.search("test", files, sessions, "swarms", %{swarms: "not_a_list"})
             )

      # Valid category fallback when string is invalid
      assert CommandPalette.search("test", files, sessions, "invalid_category") == []
    end
  end

  # ============================================================================
  # 2. Empirical Performance Verification & SLA (< 25ms) Harness
  # ============================================================================
  describe "2. Performance Verification Across 2,000 Files & Multi-Category Collections" do
    test "2.1 Profile latency for all query types and enforce < 25ms SLA", %{
      files: files,
      sessions: sessions,
      extra: extra
    } do
      total_items =
        length(CommandPalette.actions()) +
          length(CommandPalette.views()) +
          length(files) +
          length(sessions) +
          length(extra.swarms) +
          length(extra.models) +
          length(extra.branches) +
          length(extra.terminal_commands)

      assert total_items == 2374

      benchmark_queries = [
        {"Empty query (all items indexed)", ""},
        {"Scoped swarm prefix (@)", "@ pipeline"},
        {"Scoped model prefix ($)", "$ DeepReason"},
        {"Scoped branch prefix (/)", "/ swarm-agent-collaboration"},
        {"Scoped terminal prefix (!)", "! interactive"},
        {"Scoped file prefix (#)", "# payment_processor_service_1200"},
        {"Exact action title (cross-category)", "Run All Tests"},
        {"File basename substring (cross-category)", "payment_processor_service_1500"},
        {"Word boundary subsequence (cross-category)", "payproc1500"},
        {"Deep path query (cross-category)", "apps/billing/lib"},
        {"Worst-case non-matching traversal (cross-category)",
         "zzzzzzzz_no_match_here_at_all_99999"}
      ]

      IO.puts(
        "\n================================================================================"
      )

      IO.puts("EMPIRICAL COMMAND PALETTE 2.0 PERFORMANCE HARNESS (Total: #{total_items} items)")
      IO.puts("================================================================================")

      results =
        for {label, query} <- benchmark_queries do
          # Warmup run
          _ = CommandPalette.search(query, files, sessions, "all", extra)

          durations_us =
            for _ <- 1..20 do
              {us, _} =
                :timer.tc(fn ->
                  CommandPalette.search(query, files, sessions, "all", extra)
                end)

              us
            end

          sorted = Enum.sort(durations_us)
          median_us = Enum.at(sorted, div(length(sorted), 2))
          p95_us = Enum.at(sorted, round(length(sorted) * 0.95) - 1)
          max_us = List.last(sorted)

          median_ms = Float.round(median_us / 1000, 2)
          p95_ms = Float.round(p95_us / 1000, 2)
          max_ms = Float.round(max_us / 1000, 2)

          status = if p95_ms < 25.0, do: "PASS (<25ms)", else: "FAIL (SLA VIOLATION)"

          IO.puts(
            "  • #{String.pad_trailing(label, 52)} | Med: #{String.pad_leading("#{median_ms}ms", 7)} | p95: #{String.pad_leading("#{p95_ms}ms", 7)} | Max: #{String.pad_leading("#{max_ms}ms", 7)} | #{status}"
          )

          {label, median_ms, p95_ms, max_ms}
        end

      IO.puts(
        "================================================================================\n"
      )

      # Assert each query obeys the strict 25ms SLA
      for {label, _med, p95, _max} <- results do
        assert p95 < 25.0,
               "SLA VIOLATION on #{label}: p95 was #{p95}ms (must be < 25.0ms)"
      end
    end
  end
end
