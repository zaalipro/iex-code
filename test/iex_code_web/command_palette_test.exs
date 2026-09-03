defmodule IexCodeWeb.CommandPaletteTest do
  use ExUnit.Case, async: true

  alias IexCodeWeb.CommandPalette

  @sample_files [
    "lib/iex_code/application.ex",
    "lib/iex_code_web/command_palette.ex",
    "lib/iex_code_web/live/workspace_live.ex",
    "test/iex_code_web/command_palette_test.exs",
    "assets/js/app.js",
    "assets/css/app.css"
  ]

  @sample_sessions [
    %{
      id: "sess-abc-123",
      title: "UI Cockpit Refactoring",
      message_count: 14,
      model_name: "claude-3-7-sonnet",
      updated_at: DateTime.utc_now()
    },
    %{
      id: "sess-xyz-987",
      title: "AST Symbol Search Development",
      message_count: 5,
      model_name: "gpt-4o",
      updated_at: DateTime.utc_now()
    }
  ]

  @sample_extra %{
    swarms: [
      %{
        id: "swarm-100",
        objective: "Autonomous regression verification and auto-fix",
        status: "running",
        mode: "swarm",
        progress: 80,
        input_tokens: 5000,
        output_tokens: 2500,
        agent_count: 4
      }
    ],
    models: [
      %{
        id: "local-llama",
        name: "Llama 3 8B Local",
        provider: "ollama",
        local?: true,
        endpoint: "localhost:11434"
      }
    ],
    branches: [
      %{
        name: "feature/command-palette-v2",
        current?: true,
        upstream: "origin/feature/command-palette-v2"
      },
      %{
        name: "main",
        current?: false,
        upstream: "origin/main"
      }
    ],
    terminal_commands: [
      %{command: "mix test", desc: "Run ExUnit test suite"},
      %{command: "mix compile", desc: "Compile project"}
    ],
    workspace_root: "."
  }

  # ============================================================================
  # 1. score/2 Scoring Rules & Safeguards
  # ============================================================================
  describe "score/2 scoring engine" do
    test "exact match yields score of 1000" do
      assert {:ok, 1000} = CommandPalette.score("test", "test")
      assert {:ok, 1000} = CommandPalette.score("workspace_live", "workspace_live")
    end

    test "case insensitivity and whitespace trimming" do
      assert {:ok, 1000} = CommandPalette.score("  CALCULATOR  ", "calculator")
      assert {:ok, 1000} = CommandPalette.score("calculator", "CALCULATOR")
    end

    test "prefix match yields score >= 500 based on query length" do
      assert {:ok, s1} = CommandPalette.score("work", "workspace")
      assert s1 == 500 + 4 * 10

      assert {:ok, s2} = CommandPalette.score("run", "Run All Tests")
      assert s2 == 500 + 3 * 10
    end

    test "substring match with and without word boundary bonus" do
      # With word boundary (preceded by '_', '/', or space)
      assert {:ok, s_boundary} = CommandPalette.score("live", "workspace_live")
      assert s_boundary == 300 + 4 * 10 + 50

      # Without word boundary
      assert {:ok, s_noboundary} = CommandPalette.score("ork", "workspace")
      assert s_noboundary == 300 + 3 * 10
    end

    test "subsequence matching with word boundary and gap penalty" do
      # 'wklv' in 'workspace_live':
      # 'w' at 0 (first bonus 40 + boundary bonus 50 + base 100) = 190
      # 'k' at 4 (gap 3) = 187
      # 'l' at 10 (boundary bonus 50, gap 5) = 232
      # 'v' at 12 (gap 1) = 231
      assert {:ok, score} = CommandPalette.score("wklv", "workspace_live")
      assert score == 231
      assert score > 100
    end

    test "huge query safeguard: queries > 200 chars return :nomatch immediately" do
      # Query length > 200 characters against shorter target
      huge_query = String.duplicate("a", 201)
      assert CommandPalette.score(huge_query, "short_target") == :nomatch

      # Query length > 200 characters against LONGER target (safeguard flaw test)
      long_target = String.duplicate("a_b_c_", 100)
      assert CommandPalette.score(huge_query, long_target) == :nomatch

      # 1000-char query against 4000-char target
      q_1000 = String.duplicate("ab", 500)
      t_4000 = String.duplicate("a_b_", 1000)
      assert CommandPalette.score(q_1000, t_4000) == :nomatch
    end

    test "inverted character sequences and non-matches return :nomatch" do
      assert CommandPalette.score("cba", "abc") == :nomatch
      assert CommandPalette.score("zyx", "xyz") == :nomatch
      assert CommandPalette.score("vlk", "workspace_live") == :nomatch
      assert CommandPalette.score("palette_command", "command_palette") == :nomatch
      assert CommandPalette.score("qqqqqqqq", "workspace_live.ex") == :nomatch
    end

    test "empty, nil, or invalid arguments return safely" do
      assert CommandPalette.score("", "target") == {:ok, 0}
      assert CommandPalette.score("   ", "target") == {:ok, 0}
      assert CommandPalette.score(nil, "target") == :nomatch
      assert CommandPalette.score("query", nil) == :nomatch
      assert CommandPalette.score(123, "target") == :nomatch
    end

    test "matches_query?/2 returns boolean" do
      assert CommandPalette.matches_query?("workspace_live", "wklv") == true
      assert CommandPalette.matches_query?("workspace_live", "xyz") == false
      assert CommandPalette.matches_query?("anything", "") == true
      assert CommandPalette.matches_query?(nil, "test") == false
    end
  end

  # ============================================================================
  # 2. parse_query_prefix/2 Prefix Shortcut Syntax
  # ============================================================================
  describe "parse_query_prefix/2" do
    test "parses action prefix '>'" do
      assert CommandPalette.parse_query_prefix("> run", "all") == {"run", "actions"}
      assert CommandPalette.parse_query_prefix(">run", "all") == {"run", "actions"}
      assert CommandPalette.parse_query_prefix(">", "all") == {"", "actions"}
      assert CommandPalette.parse_query_prefix("> ", "all") == {"", "actions"}
    end

    test "parses swarm prefix '@'" do
      assert CommandPalette.parse_query_prefix("@ autonomous", "all") == {"autonomous", "swarms"}
      assert CommandPalette.parse_query_prefix("@autonomous", "all") == {"autonomous", "swarms"}
      assert CommandPalette.parse_query_prefix("@", "all") == {"", "swarms"}
    end

    test "parses files prefix '#'" do
      assert CommandPalette.parse_query_prefix("# palette.ex", "all") == {"palette.ex", "files"}
      assert CommandPalette.parse_query_prefix("#palette.ex", "all") == {"palette.ex", "files"}
      assert CommandPalette.parse_query_prefix("#", "all") == {"", "files"}
    end

    test "parses models prefix '$'" do
      assert CommandPalette.parse_query_prefix("$ claude", "all") == {"claude", "models"}
      assert CommandPalette.parse_query_prefix("$claude", "all") == {"claude", "models"}
      assert CommandPalette.parse_query_prefix("$", "all") == {"", "models"}
    end

    test "parses branches prefix '/'" do
      assert CommandPalette.parse_query_prefix("/ main", "all") == {"main", "branches"}
      assert CommandPalette.parse_query_prefix("/main", "all") == {"main", "branches"}
      assert CommandPalette.parse_query_prefix("/", "all") == {"", "branches"}
    end

    test "distinguishes single slash branch from multi-segment absolute filesystem path" do
      assert CommandPalette.parse_query_prefix("/usr/local/bin", "files") ==
               {"/usr/local/bin", "files"}

      assert CommandPalette.parse_query_prefix("/var/log/app.log", "all") ==
               {"/var/log/app.log", "all"}
    end

    test "parses terminal prefix '!'" do
      assert CommandPalette.parse_query_prefix("! mix test", "all") == {"mix test", "terminal"}
      assert CommandPalette.parse_query_prefix("!mix test", "all") == {"mix test", "terminal"}
      assert CommandPalette.parse_query_prefix("!", "all") == {"", "terminal"}
    end

    test "standard query without prefix preserves default category" do
      assert CommandPalette.parse_query_prefix("some text", "all") == {"some text", "all"}
      assert CommandPalette.parse_query_prefix("some text", "views") == {"some text", "views"}
    end
  end

  # ============================================================================
  # 3. search/5 Global Relevance Ranking & Tie-breaking
  # ============================================================================
  describe "search/5 global relevance ranking" do
    test "global ranking when q != '' in 'all' mode sorts across categories descending by match score" do
      # In 'all' mode with query 'changes':
      # 'view_changes' (category: :view, tab: 'changes') has exact match on tab -> score: 1000
      # 'start_goal' (category: :action) has weak subsequence in subtitle -> score: 220
      results =
        CommandPalette.search("changes", @sample_files, @sample_sessions, "all", @sample_extra)

      assert is_list(results)
      assert length(results) > 0

      # First result MUST be view_changes because its score is highest (1000)
      top_item = hd(results)
      assert top_item.id == "view_changes"
      assert top_item.category == :view
      assert top_item.score == 1000

      # Verify all results are monotonically non-increasing by score
      scores = Enum.map(results, & &1.score)
      assert scores == Enum.sort(scores, :desc)
    end

    test "exact action match appears at the top across all categories" do
      results =
        CommandPalette.search(
          "Run All Tests",
          @sample_files,
          @sample_sessions,
          "all",
          @sample_extra
        )

      assert length(results) > 0
      top_item = hd(results)
      assert top_item.id == "run_all_tests"
      assert top_item.category == :action
      assert top_item.score == 1000
    end

    test "empty query preserves clean categorized order" do
      results = CommandPalette.search("", @sample_files, @sample_sessions, "all", @sample_extra)

      # Actions should be at the head of the list in empty mode
      first_item = hd(results)
      assert first_item.category == :action
    end
  end

  # ============================================================================
  # 4. search/5 Defensive Input Guards
  # ============================================================================
  describe "search/5 defensive input guards" do
    test "handles nil files gracefully without raising" do
      results = CommandPalette.search("test", nil, @sample_sessions, "all", @sample_extra)
      assert is_list(results)
    end

    test "handles nil sessions gracefully without raising" do
      results = CommandPalette.search("test", @sample_files, nil, "all", @sample_extra)
      assert is_list(results)
    end

    test "handles non-list collections in extra map gracefully" do
      malformed_extra = %{
        swarms: "invalid_swarms_not_a_list",
        models: 12345,
        branches: nil,
        terminal_commands: :not_a_list
      }

      results =
        CommandPalette.search("test", @sample_files, @sample_sessions, "all", malformed_extra)

      assert is_list(results)
    end

    test "handles nil or non-map extra gracefully" do
      assert is_list(CommandPalette.search("test", @sample_files, @sample_sessions, "all", nil))

      assert is_list(
               CommandPalette.search("test", @sample_files, @sample_sessions, "all", "not_a_map")
             )
    end

    test "handles invalid category filter safely by returning empty list" do
      assert CommandPalette.search("test", @sample_files, @sample_sessions, "invalid_filter") ==
               []
    end
  end

  # ============================================================================
  # 5. 8-Category Indexing & Preview Extraction
  # ============================================================================
  describe "8-category entity indexing and previews" do
    test "indexes actions with valid preview cards" do
      actions = CommandPalette.search("", [], [], "actions")
      assert length(actions) == length(CommandPalette.actions())

      for item <- actions do
        assert item.category == :action
        assert is_map(item.preview)
        assert item.preview.category == :action
        assert Map.has_key?(item.preview, :target_tab)
      end
    end

    test "indexes views with valid preview cards" do
      views = CommandPalette.search("", [], [], "views")
      assert length(views) == length(CommandPalette.views())

      for item <- views do
        assert item.category == :view
        assert is_map(item.preview)
        assert item.preview.category == :view
        assert Map.has_key?(item.preview, :target_tab)
      end
    end

    test "indexes files and attaches preview metadata" do
      results = CommandPalette.search("command_palette", @sample_files, [], "files")
      assert length(results) > 0

      top = hd(results)
      assert top.category == :file
      assert is_map(top.preview)
      assert top.preview.category == :file
      assert top.preview.filename == "command_palette.ex"
      assert top.preview.ext == ".ex"
      assert top.preview.syntax == "Elixir"
    end

    test "indexes sessions with message count and preview" do
      results = CommandPalette.search("Cockpit", [], @sample_sessions, "sessions")
      assert length(results) > 0

      top = hd(results)
      assert top.category == :session
      assert top.preview.message_count == 14
      assert top.preview.model == "claude-3-7-sonnet"
    end

    test "indexes swarms from extra" do
      results = CommandPalette.search("regression", [], [], "swarms", @sample_extra)
      assert length(results) > 0

      top = hd(results)
      assert top.category == :swarm
      assert top.preview.progress == 80
      assert top.preview.tokens == 7500
    end

    test "indexes models from extra" do
      results = CommandPalette.search("Llama", [], [], "models", @sample_extra)
      assert length(results) > 0

      top = hd(results)
      assert top.category == :model
      assert top.preview.local? == true
      assert top.preview.endpoint == "localhost:11434"
    end

    test "indexes git branches from extra" do
      results = CommandPalette.search("palette-v2", [], [], "branches", @sample_extra)
      assert length(results) > 0

      top = hd(results)
      assert top.category == :branch
      assert top.preview.current? == true
    end

    test "indexes terminal commands from extra" do
      results = CommandPalette.search("compile", [], [], "terminal", @sample_extra)
      assert length(results) > 0

      top = hd(results)
      assert top.category == :terminal
      assert top.preview.command == "mix compile"
    end
  end
end
