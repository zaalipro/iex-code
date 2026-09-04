defmodule IexCodeWeb.CommandPalette do
  @moduledoc """
  Command Palette 2.0 search indexing and fuzzy ranking engine.
  Provides instant keyboard navigation across actions, views, project files,
  sessions, active swarms, model endpoints, git branches, and terminal commands.
  """

  @actions [
    %{
      id: "run_all_tests",
      category: :action,
      title: "Run All Tests",
      subtitle: "Execute full ExUnit suite with progress",
      icon: "hero-beaker",
      shortcut: "Cmd+T",
      event: "run_tests",
      params: %{"mode" => "all"},
      preview: %{
        category: :action,
        shortcut: "Cmd+T",
        description: "Execute full ExUnit suite with live test progress and result streaming",
        target_tab: "tests",
        event: "run_tests",
        params: %{"mode" => "all"}
      }
    },
    %{
      id: "run_failed_tests",
      category: :action,
      title: "Run Failed Tests",
      subtitle: "Re-run only previously failed tests",
      icon: "hero-arrow-path",
      shortcut: "Cmd+Shift+T",
      event: "run_tests",
      params: %{"mode" => "failed"},
      preview: %{
        category: :action,
        shortcut: "Cmd+Shift+T",
        description: "Re-run failing tests from the previous test suite execution",
        target_tab: "tests",
        event: "run_tests",
        params: %{"mode" => "failed"}
      }
    },
    %{
      id: "run_stale_tests",
      category: :action,
      title: "Run Stale Tests",
      subtitle: "Run tests affected by modified files",
      icon: "hero-bolt",
      shortcut: "",
      event: "run_tests",
      params: %{"mode" => "stale"},
      preview: %{
        category: :action,
        shortcut: "",
        description: "Run tests mapped to files modified in the active git working tree",
        target_tab: "tests",
        event: "run_tests",
        params: %{"mode" => "stale"}
      }
    },
    %{
      id: "start_goal",
      category: :action,
      title: "Start New Goal",
      subtitle: "Launch autonomous multi-agent swarm",
      icon: "hero-flag",
      shortcut: "Cmd+G",
      event: "open_goal_modal",
      params: %{},
      preview: %{
        category: :action,
        shortcut: "Cmd+G",
        description: "Launch a new durable asynchronous swarm goal with supervisor fleet",
        target_tab: "swarm",
        event: "open_goal_modal",
        params: %{}
      }
    },
    %{
      id: "trigger_autofix",
      category: :action,
      title: "Trigger AutoFix Studio",
      subtitle: "Auto-repair test failures & compiler errors",
      icon: "hero-sparkles",
      shortcut: "Cmd+Shift+F",
      event: "open_autofix_studio",
      params: %{},
      preview: %{
        category: :action,
        shortcut: "Cmd+Shift+F",
        description: "Generate and review 1-click patches for ExUnit test failures",
        target_tab: "tests",
        event: "open_autofix_studio",
        params: %{}
      }
    },
    %{
      id: "ast_search",
      category: :action,
      title: "AST Symbol Search",
      subtitle: "Query functions, macros, and modules",
      icon: "hero-magnifying-glass",
      shortcut: "Cmd+Shift+O",
      event: "open_ast_explorer",
      params: %{},
      preview: %{
        category: :action,
        shortcut: "Cmd+Shift+O",
        description: "Inspect code structure, function callers, and module definitions",
        target_tab: "ast",
        event: "open_ast_explorer",
        params: %{}
      }
    },
    %{
      id: "new_task",
      category: :action,
      title: "New Kanban Task",
      subtitle: "Create task and dispatch to worker",
      icon: "hero-plus",
      shortcut: "Cmd+N",
      event: "toggle_new_task_modal",
      params: %{},
      preview: %{
        category: :action,
        shortcut: "Cmd+N",
        description: "Create a new task card in the workflow kanban board",
        target_tab: "kanban",
        event: "toggle_new_task_modal",
        params: %{}
      }
    },
    %{
      id: "new_session",
      category: :action,
      title: "New Session",
      subtitle: "Start clean session in current workspace",
      icon: "hero-document-plus",
      shortcut: "",
      event: "new_session",
      params: %{},
      preview: %{
        category: :action,
        shortcut: "",
        description: "Initialize a new interactive reasoning and coding session",
        target_tab: "chat",
        event: "new_session",
        params: %{}
      }
    },
    %{
      id: "toggle_swarm",
      category: :action,
      title: "Toggle Swarm Mode",
      subtitle: "Switch between Single Agent & 4-Agent Swarm",
      icon: "hero-cpu-chip",
      shortcut: "",
      event: "toggle_swarm",
      params: %{},
      preview: %{
        category: :action,
        shortcut: "",
        description: "Toggle session orchestration between single agent and 4-agent swarm fleet",
        target_tab: "swarm",
        event: "toggle_swarm",
        params: %{}
      }
    },
    %{
      id: "open_settings",
      category: :action,
      title: "Settings & API Keys",
      subtitle: "Open model, execution, swarm, research, and runtime settings",
      icon: "hero-cog-6-tooth",
      shortcut: "Cmd+,",
      event: "open_settings_page",
      params: %{},
      preview: %{
        category: :action,
        shortcut: "Cmd+,",
        description:
          "Configure LLM providers, API keys, execution timeouts, and swarm fleet defaults",
        target_tab: "settings",
        event: "open_settings_page",
        params: %{}
      }
    },
    %{
      id: "open_settings_providers",
      category: :action,
      title: "Settings: Providers & Models",
      subtitle: "AI provider endpoints, latency diagnostics, and model discovery",
      icon: "hero-cpu-chip",
      shortcut: "Cmd+, P",
      event: "open_settings_providers",
      params: %{"tab" => "providers"},
      preview: %{
        category: :action,
        shortcut: "Cmd+, P",
        description: "Configure OpenAI, Anthropic, Gemini, Ollama, LM Studio, and llama.cpp",
        target_tab: "settings",
        event: "open_settings_providers",
        params: %{"tab" => "providers"}
      }
    },
    %{
      id: "open_settings_reasoning",
      category: :action,
      title: "Settings: Reasoning & Thinking Effort",
      subtitle: "Reasoning effort, thinking budgets, and per-model override matrix",
      icon: "hero-sparkles",
      shortcut: "Cmd+, R",
      event: "open_settings_reasoning",
      params: %{"tab" => "reasoning"},
      preview: %{
        category: :action,
        shortcut: "Cmd+, R",
        description:
          "Adjust o1/o3 reasoning effort, Claude 3.7 extended thinking, and Gemini budgets",
        target_tab: "settings",
        event: "open_settings_reasoning",
        params: %{"tab" => "reasoning"}
      }
    },
    %{
      id: "open_settings_safety",
      category: :action,
      title: "Settings: Tool Safety & Approvals",
      subtitle: "Autonomous tool execution safety tiers and category approvals",
      icon: "hero-shield-check",
      shortcut: "Cmd+, S",
      event: "open_settings_safety",
      params: %{"tab" => "safety"},
      preview: %{
        category: :action,
        shortcut: "Cmd+, S",
        description: "Set full auto, prompt dangerous, or read only execution modes",
        target_tab: "settings",
        event: "open_settings_safety",
        params: %{"tab" => "safety"}
      }
    },
    %{
      id: "open_settings_context",
      category: :action,
      title: "Settings: Context Compaction & Personas",
      subtitle: "Context compaction thresholds, strategies, and workspace personas",
      icon: "hero-document-text",
      shortcut: "Cmd+, C",
      event: "open_settings_context",
      params: %{"tab" => "context"},
      preview: %{
        category: :action,
        shortcut: "Cmd+, C",
        description: "Set token compaction strategies, system prompts, and personas",
        target_tab: "settings",
        event: "open_settings_context",
        params: %{"tab" => "context"}
      }
    },
    %{
      id: "open_settings_environment",
      category: :action,
      title: "Settings: Environment & Secrets",
      subtitle: "Custom environment variables and execution sandbox modes",
      icon: "hero-variable",
      shortcut: "Cmd+, E",
      event: "open_settings_environment",
      params: %{"tab" => "environment"},
      preview: %{
        category: :action,
        shortcut: "Cmd+, E",
        description: "Configure isolated or inherit_filtered subshell sandbox and env vars",
        target_tab: "settings",
        event: "open_settings_environment",
        params: %{"tab" => "environment"}
      }
    },
    %{
      id: "open_settings_appearance",
      category: :action,
      title: "Settings: Sound & Appearance",
      subtitle: "Desktop sound effects, chimes, theme accents, and layout density",
      icon: "hero-speaker-wave",
      shortcut: "Cmd+, A",
      event: "open_settings_appearance",
      params: %{"tab" => "appearance"},
      preview: %{
        category: :action,
        shortcut: "Cmd+, A",
        description: "Adjust volume, completion chimes, error alerts, and theme styling",
        target_tab: "settings",
        event: "open_settings_appearance",
        params: %{"tab" => "appearance"}
      }
    },
    %{
      id: "git_fetch",
      category: :action,
      title: "Git Fetch & Status",
      subtitle: "Refresh repository status and diffs",
      icon: "hero-arrow-down-tray",
      shortcut: "",
      event: "refresh_git_status",
      params: %{},
      preview: %{
        category: :action,
        shortcut: "",
        description: "Fetch latest remote git changes and refresh repository status",
        target_tab: "changes",
        event: "refresh_git_status",
        params: %{}
      }
    },
    %{
      id: "detach_terminal",
      category: :action,
      title: "Detach Terminal Window",
      subtitle: "Open standalone Terminal Multiplexer in native window",
      icon: "hero-arrow-top-right-on-square",
      shortcut: "Cmd+Shift+T",
      event: "detach_window",
      params: %{"tool" => "terminal"},
      preview: %{
        category: :action,
        shortcut: "Cmd+Shift+T",
        description: "Detach integrated Terminal Multiplexer into standalone macOS window",
        target_tab: "terminal",
        event: "detach_window",
        params: %{"tool" => "terminal"}
      }
    },
    %{
      id: "detach_diff",
      category: :action,
      title: "Detach Git & Diff Window",
      subtitle: "Open standalone Git Staging Hub in native window",
      icon: "hero-arrow-top-right-on-square",
      shortcut: "Cmd+Shift+D",
      event: "detach_window",
      params: %{"tool" => "diff"},
      preview: %{
        category: :action,
        shortcut: "Cmd+Shift+D",
        description: "Detach Git Staging and Diff Inspector into standalone macOS window",
        target_tab: "changes",
        event: "detach_window",
        params: %{"tool" => "diff"}
      }
    },
    %{
      id: "detach_dag",
      category: :action,
      title: "Detach DAG Visualizer Window",
      subtitle: "Open standalone DAG Map & Deep Research in native window",
      icon: "hero-arrow-top-right-on-square",
      shortcut: "Cmd+Shift+M",
      event: "detach_window",
      params: %{"tool" => "dag"},
      preview: %{
        category: :action,
        shortcut: "Cmd+Shift+M",
        description: "Detach DAG Map Visualizer & Deep Research into standalone macOS window",
        target_tab: "research",
        event: "detach_window",
        params: %{"tool" => "dag"}
      }
    }
  ]

  @views [
    %{
      id: "view_kanban",
      category: :view,
      title: "Dashboard / Kanban",
      subtitle: "Task board, workflow columns & priorities",
      icon: "hero-squares-2x2",
      tab: "kanban",
      shortcut: "",
      preview: %{
        category: :view,
        shortcut: "",
        description:
          "Workflow kanban task board with draggable priority columns and state tracking",
        target_tab: "kanban"
      }
    },
    %{
      id: "view_swarm",
      category: :view,
      title: "Coach & Swarm Telemetry",
      subtitle: "Live agent cards, iteration progress & reasoning",
      icon: "hero-sparkles",
      tab: "swarm",
      shortcut: "",
      preview: %{
        category: :view,
        shortcut: "",
        description: "Live visual swarm canvas, supervisor steering, and agent telemetry feeds",
        target_tab: "swarm"
      }
    },
    %{
      id: "view_calendar",
      category: :view,
      title: "Scheduled Tasks & Calendar",
      subtitle: "Time slots, presence availability & cron jobs",
      icon: "hero-calendar",
      tab: "calendar",
      shortcut: "",
      preview: %{
        category: :view,
        shortcut: "",
        description:
          "Scheduled recurring tasks, agent cron jobs, and workspace presence calendar",
        target_tab: "calendar"
      }
    },
    %{
      id: "view_changes",
      category: :view,
      title: "Progress & Diffs Hub",
      subtitle: "Git staging, multi-file diffs & commit generation",
      icon: "hero-code-bracket",
      tab: "changes",
      shortcut: "",
      preview: %{
        category: :view,
        shortcut: "",
        description:
          "Side-by-side & unified git diff inspector with word-level diffs and staging",
        target_tab: "changes"
      }
    },
    %{
      id: "view_tests",
      category: :view,
      title: "Visual Test Runner & AutoFix",
      subtitle: "ExUnit runner, failure cards & 1-click patches",
      icon: "hero-beaker",
      tab: "tests",
      shortcut: "",
      preview: %{
        category: :view,
        shortcut: "",
        description: "Real-time ExUnit test runner with failure cards and 1-click AutoFix studio",
        target_tab: "tests"
      }
    },
    %{
      id: "view_ast",
      category: :view,
      title: "AST Query Explorer",
      subtitle: "Code structure, function definitions & callers",
      icon: "hero-cube-transparent",
      tab: "ast",
      shortcut: "",
      preview: %{
        category: :view,
        shortcut: "",
        description: "Symbol graph query engine indexing functions, macros, and references",
        target_tab: "ast"
      }
    },
    %{
      id: "view_chat",
      category: :view,
      title: "Chat Assistant",
      subtitle: "Interactive reasoning & prompt dialog",
      icon: "hero-chat-bubble-left-right",
      tab: "chat",
      shortcut: "",
      preview: %{
        category: :view,
        shortcut: "",
        description:
          "Interactive AI coding dialogue with artifact generation and reasoning traces",
        target_tab: "chat"
      }
    },
    %{
      id: "view_files",
      category: :view,
      title: "Resources & Files",
      subtitle: "Project tree & interactive inline code editor",
      icon: "hero-folder",
      tab: "files",
      shortcut: "",
      preview: %{
        category: :view,
        shortcut: "",
        description: "Workspace file tree with inline code editor and multi-buffer tabs",
        target_tab: "files"
      }
    },
    %{
      id: "view_terminal",
      category: :view,
      title: "Terminal Shell",
      subtitle: "Integrated command executor & log streamer",
      icon: "hero-command-line",
      tab: "terminal",
      shortcut: "",
      preview: %{
        category: :view,
        shortcut: "",
        description:
          "Full-duplex PTY terminal emulator with quick command actions and output log streaming",
        target_tab: "terminal"
      }
    },
    %{
      id: "view_research",
      category: :view,
      title: "Deep Research & Reasoning",
      subtitle: "Web scraping, query synthesis & multi-source evidence",
      icon: "hero-academic-cap",
      tab: "research",
      shortcut: "",
      preview: %{
        category: :view,
        shortcut: "",
        description:
          "Autonomous deep research engine with DAG queries and source citation graphs",
        target_tab: "research"
      }
    }
  ]

  @default_terminal_commands [
    %{command: "mix test", desc: "Run full ExUnit test suite"},
    %{command: "mix precommit", desc: "Run format, compile, unlock, test verification"},
    %{command: "mix format", desc: "Format Elixir codebase"},
    %{command: "git status", desc: "Show workspace git status"},
    %{command: "git diff", desc: "Inspect unstaged file changes"},
    %{command: "iex -S mix", desc: "Start interactive Elixir console"}
  ]

  @standard_cloud_models [
    %{
      id: "claude-3-7-sonnet",
      name: "Claude 3.7 Sonnet",
      provider: "anthropic",
      local?: false,
      endpoint: "api.anthropic.com"
    },
    %{
      id: "claude-3-5-haiku",
      name: "Claude 3.5 Haiku",
      provider: "anthropic",
      local?: false,
      endpoint: "api.anthropic.com"
    },
    %{
      id: "gpt-4o",
      name: "GPT-4o",
      provider: "openai",
      local?: false,
      endpoint: "api.openai.com"
    },
    %{
      id: "gemini-2.5-pro",
      name: "Gemini 2.5 Pro",
      provider: "google",
      local?: false,
      endpoint: "generativelanguage.googleapis.com"
    }
  ]

  @categories [
    {"all", "All"},
    {"actions", "Actions"},
    {"swarms", "Swarms"},
    {"files", "Files"},
    {"models", "Models"},
    {"branches", "Branches"},
    {"terminal", "Terminal"},
    {"views", "Views"},
    {"sessions", "Sessions"}
  ]

  def actions, do: @actions
  def views, do: @views
  def categories, do: @categories
  def default_terminal_commands, do: @default_terminal_commands
  def standard_cloud_models, do: @standard_cloud_models

  @doc """
  Performs fuzzy search across actions, views, project files, sessions,
  active swarms, model endpoints, git branches, and terminal commands.

  Preserves backward compatibility:
  `search(query, files, sessions, category_filter \\\\ "all", extra \\\\ %{})`
  """
  def search(query, files, sessions, category_filter \\ "all", extra \\ %{}) do
    query_str = if is_binary(query), do: query, else: ""
    cat_filter = if is_binary(category_filter), do: category_filter, else: "all"
    extra_map = if is_map(extra), do: extra, else: %{}

    files_list = if is_list(files), do: files, else: []
    sessions_list = if is_list(sessions), do: sessions, else: []

    {effective_query, effective_category} = parse_query_prefix(query_str, cat_filter)
    q = String.downcase(String.trim(effective_query))

    valid_categories = [
      "all",
      "actions",
      "views",
      "files",
      "sessions",
      "swarms",
      "models",
      "branches",
      "terminal"
    ]

    if effective_category not in valid_categories or byte_size(q) > 200 do
      []
    else
      workspace_root = Map.get(extra_map, :workspace_root, ".")

      prep =
        if q != "" do
          q_len = byte_size(q)
          q_chars = String.graphemes(q)
          q_chars_count = length(q_chars)
          {q, q_len, q_chars, q_chars_count}
        else
          nil
        end

      actions =
        if effective_category in ["all", "actions"] do
          if q == "" do
            Enum.map(@actions, fn a -> a |> build_action_item() |> Map.put(:score, 0) end)
          else
            @actions
            |> Enum.map(&build_action_item/1)
            |> filter_and_rank_items(prep)
          end
        else
          []
        end

      views =
        if effective_category in ["all", "views"] do
          if q == "" do
            Enum.map(@views, fn v -> v |> build_view_item() |> Map.put(:score, 0) end)
          else
            @views
            |> Enum.map(&build_view_item/1)
            |> filter_and_rank_items(prep)
          end
        else
          []
        end

      file_items =
        if effective_category in ["all", "files"] do
          if q == "" do
            files_list
            |> Enum.take(25)
            |> Enum.map(fn p ->
              p
              |> build_file_item()
              |> Map.put(:score, 0)
              |> attach_file_preview(workspace_root)
            end)
          else
            search_files(files_list, prep, workspace_root)
          end
        else
          []
        end

      session_items =
        if effective_category in ["all", "sessions"] do
          if q == "" do
            sessions_list
            |> Enum.take(10)
            |> Enum.map(fn s -> s |> build_session_item() |> Map.put(:score, 0) end)
          else
            sessions_list
            |> Enum.map(&build_session_item/1)
            |> filter_and_rank_items(prep)
            |> Enum.take(10)
          end
        else
          []
        end

      swarms_data =
        case Map.get(extra_map, :swarms) do
          list when is_list(list) -> list
          _ -> []
        end

      swarm_items =
        if effective_category in ["all", "swarms"] do
          if q == "" do
            swarms_data
            |> Enum.take(10)
            |> Enum.map(fn s -> s |> build_swarm_item() |> Map.put(:score, 0) end)
          else
            swarms_data
            |> Enum.map(&build_swarm_item/1)
            |> filter_and_rank_items(prep)
            |> Enum.take(10)
          end
        else
          []
        end

      models_data =
        case Map.get(extra_map, :models) do
          list when is_list(list) -> list
          _ -> @standard_cloud_models
        end

      model_items =
        if effective_category in ["all", "models"] do
          if q == "" do
            models_data
            |> Enum.take(10)
            |> Enum.map(fn m -> m |> build_model_item() |> Map.put(:score, 0) end)
          else
            models_data
            |> Enum.map(&build_model_item/1)
            |> filter_and_rank_items(prep)
            |> Enum.take(10)
          end
        else
          []
        end

      branches_data =
        case Map.get(extra_map, :branches) do
          list when is_list(list) -> list
          _ -> []
        end

      branch_items =
        if effective_category in ["all", "branches"] do
          if q == "" do
            branches_data
            |> Enum.take(15)
            |> Enum.map(fn b -> b |> build_branch_item() |> Map.put(:score, 0) end)
          else
            branches_data
            |> Enum.map(&build_branch_item/1)
            |> filter_and_rank_items(prep)
            |> Enum.take(15)
          end
        else
          []
        end

      terminal_data =
        case Map.get(extra_map, :terminal_commands) do
          list when is_list(list) -> list
          _ -> @default_terminal_commands
        end

      terminal_items =
        if effective_category in ["all", "terminal"] do
          if q == "" do
            terminal_data
            |> Enum.take(15)
            |> Enum.map(fn t ->
              t
              |> build_terminal_item(workspace_root)
              |> Map.put(:score, 0)
            end)
          else
            terminal_data
            |> Enum.map(&build_terminal_item(&1, workspace_root))
            |> filter_and_rank_items(prep)
            |> Enum.take(15)
          end
        else
          []
        end

      all_items =
        actions ++
          views ++
          file_items ++
          session_items ++
          swarm_items ++
          model_items ++
          branch_items ++
          terminal_items

      if effective_category == "all" and q != "" do
        Enum.sort_by(all_items, fn item ->
          {-Map.get(item, :score, 0), to_string(item[:title])}
        end)
      else
        all_items
      end
    end
  end

  # ============================================================================
  # Prefix Shortcut Syntax Parser
  # ============================================================================

  def parse_query_prefix(raw_query, category_filter) do
    trimmed = String.trim(raw_query || "")

    cond do
      String.starts_with?(trimmed, "> ") ->
        {String.trim_leading(trimmed, "> "), "actions"}

      trimmed == ">" ->
        {"", "actions"}

      String.starts_with?(trimmed, ">") ->
        {String.trim_leading(trimmed, ">"), "actions"}

      String.starts_with?(trimmed, "@ ") ->
        {String.trim_leading(trimmed, "@ "), "swarms"}

      trimmed == "@" ->
        {"", "swarms"}

      String.starts_with?(trimmed, "@") ->
        {String.trim_leading(trimmed, "@"), "swarms"}

      String.starts_with?(trimmed, "# ") ->
        {String.trim_leading(trimmed, "# "), "files"}

      trimmed == "#" ->
        {"", "files"}

      String.starts_with?(trimmed, "#") ->
        {String.trim_leading(trimmed, "#"), "files"}

      String.starts_with?(trimmed, "$ ") ->
        {String.trim_leading(trimmed, "$ "), "models"}

      trimmed == "$" ->
        {"", "models"}

      String.starts_with?(trimmed, "$") ->
        {String.trim_leading(trimmed, "$"), "models"}

      String.starts_with?(trimmed, "/ ") ->
        {String.trim_leading(trimmed, "/ "), "branches"}

      trimmed == "/" ->
        {"", "branches"}

      String.starts_with?(trimmed, "/") and not String.contains?(trimmed, ".") and
          length(String.split(trimmed, "/")) <= 2 ->
        {String.trim_leading(trimmed, "/"), "branches"}

      String.starts_with?(trimmed, "! ") ->
        {String.trim_leading(trimmed, "! "), "terminal"}

      trimmed == "!" ->
        {"", "terminal"}

      String.starts_with?(trimmed, "!") ->
        {String.trim_leading(trimmed, "!"), "terminal"}

      true ->
        {trimmed, category_filter}
    end
  end

  # ============================================================================
  # Fuzzy Ranking & Scoring Engine (Pure Elixir)
  # ============================================================================

  @doc """
  Computes match score between query and target string.
  Returns `{:ok, score}` or `:nomatch`.
  """
  def score(query, target) when is_binary(query) and is_binary(target) do
    # Immediate O(1) guard against huge query attacks before any allocations
    # In UTF-8, 1 character is at most 4 bytes, so byte_size > 800 is always > 200 characters
    if byte_size(query) > 800 do
      :nomatch
    else
      q = String.downcase(String.trim(query))
      q_len = String.length(q)

      cond do
        q == "" ->
          {:ok, 0}

        q_len > 200 ->
          :nomatch

        byte_size(q) > byte_size(target) ->
          :nomatch

        true ->
          t = String.downcase(String.trim(target))
          t_len = String.length(t)

          cond do
            q_len > t_len ->
              :nomatch

            t == q ->
              {:ok, 1000}

            String.starts_with?(t, q) ->
              {:ok, 500 + q_len * 10}

            String.contains?(t, q) ->
              boundary_bonus = if boundary_at_substring?(t, q), do: 50, else: 0
              {:ok, 300 + q_len * 10 + boundary_bonus}

            true ->
              subsequence_score(q, t)
          end
      end
    end
  end

  def score(_query, _target), do: :nomatch

  def matches_query?(_target, ""), do: true

  def matches_query?(target, q) do
    case score(q, to_string(target || "")) do
      {:ok, s} when s > 0 -> true
      _ -> false
    end
  end

  defp boundary_at_substring?(target, query) do
    case :binary.match(target, query) do
      {0, _len} ->
        true

      {pos, _len} when pos > 0 ->
        prev_byte = :binary.at(target, pos - 1)
        prev_byte in [?_, ?-, ?/, ?., ?\s, ?:, ?@, ?$, ?!, ?>]

      :nomatch ->
        false
    end
  end

  defp is_subsequence?(<<>>, _), do: true
  defp is_subsequence?(q, t) when byte_size(q) > byte_size(t), do: false

  defp is_subsequence?(<<c::utf8, rest_q::binary>>, t) do
    case :binary.match(t, <<c::utf8>>) do
      {pos, len} ->
        rem_len = byte_size(t) - pos - len

        if rem_len >= byte_size(rest_q) do
          is_subsequence?(rest_q, :binary.part(t, pos + len, rem_len))
        else
          false
        end

      :nomatch ->
        false
    end
  end

  defp is_subsequence?(_, _), do: false

  defp subsequence_score(q, t) do
    q_len = byte_size(q)
    t_len = byte_size(t)

    if q_len > t_len or not is_subsequence?(q, t) do
      :nomatch
    else
      q_chars = String.graphemes(q)
      match_subsequence(q_chars, t, 0, nil, nil, 100, t_len, length(q_chars))
    end
  end

  defp match_subsequence([], _t, _curr_offset, _prev_pos, _prev_end, acc_score, _t_len, _rem),
    do: {:ok, acc_score}

  defp match_subsequence(
         [q_char | rest_q],
         t,
         curr_offset,
         prev_pos,
         prev_end,
         acc_score,
         t_len,
         rem
       ) do
    rem_len = t_len - curr_offset

    if rem_len < rem do
      :nomatch
    else
      case :binary.match(t, q_char, scope: {curr_offset, rem_len}) do
        {match_pos, match_len} ->
          is_boundary =
            match_pos == 0 or
              :binary.at(t, match_pos - 1) in [?_, ?-, ?/, ?., ?\s, ?:, ?@, ?$, ?!, ?>]

          contiguous_bonus = if prev_end != nil and match_pos == prev_end, do: 20, else: 0
          boundary_bonus = if is_boundary, do: 50, else: 0

          gap_penalty =
            if prev_end != nil and match_pos > prev_end,
              do: min(match_pos - prev_end, 20),
              else: 0

          first_bonus = if prev_pos == nil and match_pos == 0, do: 40, else: 0

          new_score =
            acc_score + boundary_bonus + contiguous_bonus + first_bonus - gap_penalty

          match_subsequence(
            rest_q,
            t,
            match_pos + match_len,
            match_pos,
            match_pos + match_len,
            new_score,
            t_len,
            rem - 1
          )

        :nomatch ->
          :nomatch
      end
    end
  end

  defp search_files(files, {q, q_len, q_chars, q_chars_count}, workspace_root) do
    if q_len > 200 do
      []
    else
      has_slash = :binary.match(q, "/") != :nomatch
      has_space = :binary.match(q, " ") != :nomatch
      first_char = if q_chars != [], do: hd(q_chars), else: nil
      last_char = if q_chars != [], do: List.last(q_chars), else: nil
      mid_char = if q_chars_count >= 3, do: Enum.at(q_chars, div(q_chars_count, 2)), else: nil

      files
      |> Enum.reduce([], fn p, acc ->
        case match_file(
               p,
               q,
               q_len,
               has_slash,
               has_space,
               q_chars,
               q_chars_count,
               first_char,
               last_char,
               mid_char
             ) do
          nil -> acc
          {p, s} -> [{p, s} | acc]
        end
      end)
      |> Enum.sort_by(fn {p, s} -> {-s, p} end)
      |> Enum.take(25)
      |> Enum.map(fn {p, s} ->
        p
        |> build_file_item()
        |> Map.put(:score, s)
        |> attach_file_preview(workspace_root)
      end)
    end
  end

  defp search_files(files, q, workspace_root) when is_binary(q) do
    q_len = byte_size(q)
    q_chars = String.graphemes(q)
    q_chars_count = length(q_chars)
    search_files(files, {q, q_len, q_chars, q_chars_count}, workspace_root)
  end

  defp match_file(
         p,
         q,
         q_len,
         has_slash,
         has_space,
         q_chars,
         q_chars_count,
         first_char,
         last_char,
         mid_char
       ) do
    p_len = byte_size(p)

    cond do
      q_len > p_len ->
        nil

      has_space and :binary.match(p, " ") == :nomatch ->
        nil

      first_char != nil and :binary.match(p, first_char) == :nomatch ->
        nil

      last_char != nil and :binary.match(p, last_char) == :nomatch ->
        nil

      mid_char != nil and :binary.match(p, mid_char) == :nomatch ->
        nil

      has_slash ->
        case :binary.match(p, q) do
          {0, _} ->
            {p, 500 + q_len * 10}

          {pos, _} ->
            is_boundary = :binary.at(p, pos - 1) in [?_, ?-, ?/, ?., ?\s, ?:, ?@, ?$, ?!, ?>]
            boundary_bonus = if is_boundary, do: 50, else: 0
            {p, 300 + q_len * 10 + boundary_bonus}

          :nomatch ->
            if q_chars_count <= p_len and is_subsequence?(q, p) do
              case match_subsequence(q_chars, p, 0, nil, nil, 100, p_len, q_chars_count) do
                {:ok, s} when s > 0 -> {p, s}
                _ -> nil
              end
            else
              nil
            end
        end

      true ->
        bn = fast_basename(p)
        bn_len = byte_size(bn)

        case :binary.match(bn, q) do
          {0, _} ->
            {p, 500 + q_len * 10}

          {pos, _} ->
            is_boundary = :binary.at(bn, pos - 1) in [?_, ?-, ?/, ?., ?\s, ?:, ?@, ?$, ?!, ?>]
            boundary_bonus = if is_boundary, do: 50, else: 0
            {p, 300 + q_len * 10 + boundary_bonus}

          :nomatch ->
            case :binary.match(p, q) do
              {0, _} ->
                {p, 500 + q_len * 10}

              {pos, _} ->
                is_boundary = :binary.at(p, pos - 1) in [?_, ?-, ?/, ?., ?\s, ?:, ?@, ?$, ?!, ?>]
                boundary_bonus = if is_boundary, do: 50, else: 0
                {p, 300 + q_len * 10 + boundary_bonus}

              :nomatch ->
                if is_subsequence?(q, p) do
                  if q_len <= bn_len and is_subsequence?(q, bn) do
                    case match_subsequence(q_chars, bn, 0, nil, nil, 100, bn_len, q_chars_count) do
                      {:ok, bs} when bs > 0 ->
                        {p, bs}

                      _ ->
                        case match_subsequence(q_chars, p, 0, nil, nil, 100, p_len, q_chars_count) do
                          {:ok, s} when s > 0 -> {p, s}
                          _ -> nil
                        end
                    end
                  else
                    case match_subsequence(q_chars, p, 0, nil, nil, 100, p_len, q_chars_count) do
                      {:ok, s} when s > 0 -> {p, s}
                      _ -> nil
                    end
                  end
                else
                  nil
                end
            end
        end
    end
  end

  defp fast_basename(p) when is_binary(p) do
    find_last_slash(p, byte_size(p) - 1)
  end

  defp fast_basename(p), do: Path.basename(to_string(p))

  defp find_last_slash(p, -1), do: p

  defp find_last_slash(p, idx) do
    if :binary.at(p, idx) == ?/ do
      rem_len = byte_size(p) - idx - 1
      if rem_len > 0, do: :binary.part(p, idx + 1, rem_len), else: p
    else
      find_last_slash(p, idx - 1)
    end
  end

  defp build_file_item(p) do
    %{
      id: "file_#{p}",
      category: :file,
      title: fast_basename(p),
      subtitle: p,
      icon: file_icon(p),
      path: p,
      score: 0
    }
  end

  defp filter_and_rank_items(items, "") do
    Enum.map(items, &Map.put_new(&1, :score, 0))
  end

  defp filter_and_rank_items(items, nil) do
    Enum.map(items, &Map.put_new(&1, :score, 0))
  end

  defp filter_and_rank_items(items, {q, q_len, q_chars, q_chars_count}) do
    if q_len > 200 do
      []
    else
      items
      |> Enum.map(fn item ->
        s = item_score_prepared(item, q, q_len, q_chars, q_chars_count)
        Map.put(item, :score, s)
      end)
      |> Enum.filter(fn item -> item.score > 0 end)
      |> Enum.sort_by(fn item -> {-item.score, to_string(item[:title])} end)
    end
  end

  defp filter_and_rank_items(items, q) when is_binary(q) do
    q_len = byte_size(q)
    q_chars = String.graphemes(q)
    q_chars_count = length(q_chars)
    filter_and_rank_items(items, {q, q_len, q_chars, q_chars_count})
  end

  defp item_score_prepared(item, q, q_len, q_chars, q_chars_count) do
    fields = searchable_fields(item)

    Enum.reduce(fields, 0, fn field, max_s ->
      case score_with_prepared(q, q_len, q_chars, q_chars_count, field) do
        {:ok, s} -> max(max_s, s)
        :nomatch -> max_s
      end
    end)
  end

  defp score_with_prepared(_q, _q_len, _q_chars, _q_chars_count, nil), do: :nomatch

  defp score_with_prepared(q, q_len, q_chars, q_chars_count, target) when is_binary(target) do
    if q_len > byte_size(target) do
      :nomatch
    else
      t = String.downcase(String.trim(target))
      t_len = byte_size(t)

      cond do
        q_len > t_len ->
          :nomatch

        t == q ->
          {:ok, 1000}

        String.starts_with?(t, q) ->
          {:ok, 500 + q_len * 10}

        String.contains?(t, q) ->
          boundary_bonus = if boundary_at_substring?(t, q), do: 50, else: 0
          {:ok, 300 + q_len * 10 + boundary_bonus}

        true ->
          if is_subsequence?(q, t) do
            match_subsequence(q_chars, t, 0, nil, nil, 100, t_len, q_chars_count)
          else
            :nomatch
          end
      end
    end
  end

  defp score_with_prepared(q, q_len, q_chars, q_chars_count, target) do
    score_with_prepared(q, q_len, q_chars, q_chars_count, to_string(target))
  end

  defp searchable_fields(item) do
    base = [item.title, item.subtitle]

    extras =
      case item.category do
        :action -> [item.id, Map.get(item, :shortcut, ""), Map.get(item, :event, "")]
        :view -> [item.id, Map.get(item, :tab, ""), Map.get(item, :shortcut, "")]
        :file -> []
        :session -> [Map.get(item, :session_id, "")]
        :swarm -> [Map.get(item, :run_id, ""), get_in(item, [:preview, :objective]) || ""]
        :model -> [Map.get(item, :model_id, ""), to_string(Map.get(item, :provider, ""))]
        :branch -> [Map.get(item, :branch, "")]
        :terminal -> [Map.get(item, :command, "")]
        _ -> []
      end

    Enum.reject(base ++ extras, &is_nil/1)
  end

  # ============================================================================
  # Entity Builders & Preview Adapters
  # ============================================================================

  defp build_action_item(action) do
    Map.put_new(action, :preview, %{
      category: :action,
      shortcut: action[:shortcut] || "",
      description: action[:subtitle] || "",
      target_tab: action[:params]["tool"] || action[:params]["mode"] || "",
      event: action[:event],
      params: action[:params] || %{}
    })
  end

  defp build_view_item(view) do
    Map.put_new(view, :preview, %{
      category: :view,
      shortcut: view[:shortcut] || "",
      description: view[:subtitle] || "",
      target_tab: view[:tab] || ""
    })
  end

  defp attach_file_preview(file_item, workspace_root) do
    path = file_item.path
    ext = Path.extname(path)
    preview_info = read_file_preview(path, workspace_root)

    preview = %{
      category: :file,
      path: path,
      filename: Path.basename(path),
      ext: ext,
      size: preview_info.size,
      lines: preview_info.lines,
      syntax: syntax_for_ext(ext),
      preview_lines: preview_info.preview_lines
    }

    Map.put(file_item, :preview, preview)
  end

  defp read_file_preview(path, workspace_root) do
    cache_key = {:command_palette_file_preview, workspace_root, path}

    case Process.get(cache_key) do
      nil ->
        result = do_read_file_preview(path, workspace_root)
        Process.put(cache_key, result)
        result

      cached ->
        cached
    end
  end

  defp do_read_file_preview(path, workspace_root) do
    full_path =
      cond do
        is_binary(workspace_root) and workspace_root != "" and not (Path.type(path) == :absolute) ->
          Path.join(workspace_root, path)

        true ->
          path
      end

    case File.read(full_path) do
      {:ok, content} ->
        size = byte_size(content)
        lines = :binary.split(content, ["\r\n", "\n"], [:global])
        line_count = length(lines)

        preview_lines =
          lines
          |> Enum.take(12)
          |> Enum.with_index(1)
          |> Enum.map(fn {line, num} -> {num, line} end)

        %{size: size, lines: line_count, preview_lines: preview_lines}

      _ ->
        %{size: 0, lines: 0, preview_lines: []}
    end
  end

  defp build_session_item(session) do
    id = to_string(Map.get(session, :id, ""))
    title = Map.get(session, :title)
    display_title = if title && title != "", do: title, else: "Session #{String.slice(id, 0..7)}"
    subtitle = format_session_subtitle(session)

    %{
      id: "session_#{id}",
      category: :session,
      title: display_title,
      subtitle: subtitle,
      icon: "hero-document-text",
      session_id: id,
      preview: %{
        category: :session,
        session_id: id,
        title: display_title,
        subtitle: subtitle,
        message_count: Map.get(session, :message_count, 0),
        model: Map.get(session, :model_name, "default"),
        updated_at: subtitle
      }
    }
  end

  defp format_session_subtitle(session) do
    id = to_string(Map.get(session, :id, ""))
    updated_at = Map.get(session, :updated_at)

    case updated_at do
      %DateTime{} = dt -> "Updated #{Calendar.strftime(dt, "%b %d, %H:%M")}"
      %NaiveDateTime{} = ndt -> "Updated #{Calendar.strftime(ndt, "%b %d, %H:%M")}"
      str when is_binary(str) and str != "" -> "Updated #{str}"
      _ -> "Session #{String.slice(id, 0..7)}"
    end
  end

  defp build_swarm_item(run) do
    id = to_string(Map.get(run, :id, ""))
    objective = Map.get(run, :objective) || "Swarm Run #{String.slice(id, 0..7)}"
    status = to_string(Map.get(run, :status, "queued"))
    mode = to_string(Map.get(run, :mode, "swarm"))
    progress = Map.get(run, :progress, 0) || 0
    in_tokens = Map.get(run, :input_tokens, 0) || 0
    out_tokens = Map.get(run, :output_tokens, 0) || 0
    agents = Map.get(run, :agent_count, 4) || 4

    %{
      id: "swarm_#{id}",
      category: :swarm,
      title: objective,
      subtitle: "Status: #{status} • Mode: #{mode} • #{progress}% complete",
      icon: "hero-sparkles",
      run_id: id,
      run: run,
      preview: %{
        category: :swarm,
        run_id: id,
        status: status,
        mode: mode,
        objective: objective,
        progress: progress,
        tokens: in_tokens + out_tokens,
        active_agents: agents
      }
    }
  end

  defp build_model_item(model) do
    id = to_string(Map.get(model, :id, Map.get(model, :name, "")))
    name = Map.get(model, :name, id)
    provider = to_string(Map.get(model, :provider, "anthropic"))

    local? =
      Map.get(
        model,
        :local?,
        String.contains?(provider, "local") or String.contains?(provider, "ollama")
      )

    endpoint =
      Map.get(model, :endpoint, if(local?, do: "localhost:11434", else: "api.#{provider}.com"))

    %{
      id: "model_#{id}",
      category: :model,
      title: name,
      subtitle: "#{provider} • #{if local?, do: "Local Offline", else: "Cloud API"}",
      icon: "hero-cpu-chip",
      model_id: id,
      provider: provider,
      preview: %{
        category: :model,
        name: name,
        model_id: id,
        provider: provider,
        endpoint: endpoint,
        local?: local?,
        status: :online
      }
    }
  end

  defp build_branch_item(branch) do
    name =
      if is_map(branch), do: Map.get(branch, :name, ""), else: to_string(branch)

    current? = if is_map(branch), do: Map.get(branch, :current?, false), else: false
    upstream = if is_map(branch), do: Map.get(branch, :upstream, nil), else: nil

    subtitle =
      if current?,
        do: "Current branch • #{upstream || "local"}",
        else: "Git branch • #{upstream || "local"}"

    %{
      id: "branch_#{name}",
      category: :branch,
      title: name,
      subtitle: subtitle,
      icon: "hero-code-bracket",
      branch: name,
      preview: %{
        category: :branch,
        name: name,
        current?: current?,
        upstream: upstream,
        head_commit: "HEAD"
      }
    }
  end

  defp build_terminal_item(term_cmd, workspace_root) do
    cmd =
      if is_map(term_cmd), do: Map.get(term_cmd, :command, ""), else: to_string(term_cmd)

    desc =
      if is_map(term_cmd),
        do: Map.get(term_cmd, :desc, "Terminal command preset"),
        else: "Terminal command preset"

    %{
      id: "terminal_#{cmd}",
      category: :terminal,
      title: cmd,
      subtitle: desc,
      icon: "hero-command-line",
      command: cmd,
      preview: %{
        category: :terminal,
        command: cmd,
        description: desc,
        directory: workspace_root || "."
      }
    }
  end

  def syntax_for_ext(ext) do
    case ext do
      ".ex" -> "Elixir"
      ".exs" -> "Elixir Script"
      ".heex" -> "HEEx"
      ".js" -> "JavaScript"
      ".ts" -> "TypeScript"
      ".css" -> "CSS"
      ".md" -> "Markdown"
      ".json" -> "JSON"
      ".sql" -> "SQL"
      ".sh" -> "Shell"
      _ -> "Plain Text"
    end
  end

  def file_icon(path) do
    case Path.extname(path) do
      ".ex" -> "hero-code-bracket"
      ".exs" -> "hero-code-bracket-square"
      ".heex" -> "hero-cube"
      ".js" -> "hero-cpu-chip"
      ".css" -> "hero-paint-brush"
      ".md" -> "hero-document-text"
      ".json" -> "hero-document-chart-bar"
      _ -> "hero-document"
    end
  end
end
