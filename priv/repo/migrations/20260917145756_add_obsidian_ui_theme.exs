defmodule IexCode.Repo.Migrations.AddObsidianUiTheme do
  use Ecto.Migration

  # SQLite cannot alter a CHECK constraint in place, so this follows the
  # established app_settings table-rebuild pattern: create a fixed copy,
  # move the rows, swap the tables, restore the singleton index.
  # DDL mirrors the live schema; only ui_theme's default and IN list vary.

  @columns """
  id, anthropic_api_key, anthropic_base_url, openai_api_key, openai_base_url,
  default_model_provider, default_model, swarm_agent_count, auto_save,
  inserted_at, updated_at, temperature, max_tokens, search_providers,
  search_provider_order, research_depth, research_max_sources,
  research_parallelism, research_level, research_require_conflict_audit,
  research_max_cost_cents, research_max_tokens, research_time_budget_minutes,
  default_dispatch_mode, default_run_mode, default_run_priority,
  default_run_max_attempts, default_run_token_budget,
  default_run_cost_budget_cents, default_run_time_budget_minutes,
  goal_auto_start, agent_max_turns, swarm_max_retries, default_tools,
  lock_version, default_reasoning_effort, default_thinking_budget,
  model_overrides, tool_approval_mode, tool_category_overrides,
  context_window_tokens, context_prune_threshold_percent,
  context_compaction_strategy, keep_recent_turns, custom_system_prompt,
  workspace_persona, coding_style_rules, custom_env_vars, sandbox_mode,
  sound_enabled, sound_volume, completion_chime, error_alert_chime,
  approval_prompt_chime, theme_accent, layout_density, ui_theme,
  shadows_3d, effects_3d
  """

  @base_columns """
    id TEXT PRIMARY KEY,
    anthropic_api_key TEXT,
    anthropic_base_url TEXT DEFAULT 'https://api.anthropic.com',
    openai_api_key TEXT,
    openai_base_url TEXT DEFAULT 'https://cli.llmotions.com/v1',
    default_model_provider TEXT DEFAULT 'openai',
    default_model TEXT DEFAULT 'gemini-3.7-flash-high',
    swarm_agent_count INTEGER DEFAULT 4,
    auto_save INTEGER DEFAULT 1,
    inserted_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    temperature NUMERIC DEFAULT 0.2,
    max_tokens INTEGER DEFAULT 4096,
    search_providers TEXT NOT NULL DEFAULT ('{"bing":{"enabled":false},"brave":{"enabled":false},"duckduckgo":{"enabled":true},"exa":{"enabled":false},"google":{"enabled":false},"searxng":{"enabled":false},"serper":{"enabled":false},"tavily":{"enabled":false}}'),
    search_provider_order TEXT NOT NULL DEFAULT ('["tavily","brave","exa","serper","google","bing","searxng","duckduckgo"]'),
    research_depth TEXT NOT NULL DEFAULT 'standard',
    research_max_sources INTEGER NOT NULL DEFAULT 12,
    research_parallelism INTEGER NOT NULL DEFAULT 4,
    research_level TEXT NOT NULL DEFAULT 'medium'
      CONSTRAINT app_settings_research_level_check
      CHECK (research_level IN ('low', 'medium', 'high', 'ultra')),
    research_require_conflict_audit INTEGER NOT NULL DEFAULT 1,
    research_max_cost_cents INTEGER,
    research_max_tokens INTEGER,
    research_time_budget_minutes INTEGER,
    default_dispatch_mode TEXT NOT NULL DEFAULT 'background',
    default_run_mode TEXT NOT NULL DEFAULT 'swarm',
    default_run_priority TEXT NOT NULL DEFAULT 'normal',
    default_run_max_attempts INTEGER NOT NULL DEFAULT 3,
    default_run_token_budget INTEGER,
    default_run_cost_budget_cents INTEGER,
    default_run_time_budget_minutes INTEGER,
    goal_auto_start INTEGER NOT NULL DEFAULT 1,
    agent_max_turns INTEGER NOT NULL DEFAULT 8,
    swarm_max_retries INTEGER NOT NULL DEFAULT 3,
    default_tools TEXT NOT NULL DEFAULT ('{"ast_search":true,"web_search":false}'),
    lock_version INTEGER NOT NULL DEFAULT 1,
    "default_reasoning_effort" TEXT DEFAULT 'medium' NOT NULL,
    "default_thinking_budget" INTEGER DEFAULT 4096 NOT NULL,
    "model_overrides" TEXT DEFAULT ('{}') NOT NULL,
    "tool_approval_mode" TEXT DEFAULT 'prompt_dangerous' NOT NULL,
    "tool_category_overrides" TEXT DEFAULT ('{"file_mutations":"prompt","git_push":"prompt","shell_execution":"prompt","web_search":"auto"}') NOT NULL,
    "context_window_tokens" INTEGER DEFAULT 128000 NOT NULL,
    "context_prune_threshold_percent" INTEGER DEFAULT 75 NOT NULL,
    "context_compaction_strategy" TEXT DEFAULT 'token_compaction' NOT NULL,
    "keep_recent_turns" INTEGER DEFAULT 6 NOT NULL,
    "custom_system_prompt" TEXT,
    "workspace_persona" TEXT DEFAULT 'pragmatic_engineer' NOT NULL,
    "coding_style_rules" TEXT,
    "custom_env_vars" TEXT DEFAULT ('{}') NOT NULL,
    "sandbox_mode" TEXT DEFAULT 'inherit_filtered' NOT NULL,
    "sound_enabled" INTEGER DEFAULT true NOT NULL,
    "sound_volume" INTEGER DEFAULT 80 NOT NULL,
    "completion_chime" TEXT DEFAULT 'hero' NOT NULL,
    "error_alert_chime" TEXT DEFAULT 'basso' NOT NULL,
    "approval_prompt_chime" TEXT DEFAULT 'ping' NOT NULL,
    "theme_accent" TEXT DEFAULT 'cyan' NOT NULL,
    "layout_density" TEXT DEFAULT 'comfortable' NOT NULL
  """

  @tail_columns """
    , "shadows_3d" INTEGER DEFAULT true NOT NULL,
    "effects_3d" INTEGER DEFAULT true NOT NULL
  """

  @checks """
    , CONSTRAINT app_settings_default_dispatch_mode_check
        CHECK (default_dispatch_mode IN ('background', 'interactive'))
    , CONSTRAINT app_settings_default_run_mode_check
        CHECK (default_run_mode IN ('single', 'swarm', 'dag', 'research'))
    , CONSTRAINT app_settings_default_run_priority_check
        CHECK (default_run_priority IN ('low', 'normal', 'high', 'critical'))
    , CONSTRAINT app_settings_default_run_max_attempts_check
        CHECK (default_run_max_attempts BETWEEN 1 AND 10)
    , CONSTRAINT app_settings_default_run_token_budget_check
        CHECK (default_run_token_budget IS NULL OR default_run_token_budget BETWEEN 1 AND 10000000)
    , CONSTRAINT app_settings_default_run_cost_budget_check
        CHECK (default_run_cost_budget_cents IS NULL OR default_run_cost_budget_cents BETWEEN 1 AND 10000000)
    , CONSTRAINT app_settings_default_run_time_budget_check
        CHECK (default_run_time_budget_minutes IS NULL OR default_run_time_budget_minutes BETWEEN 1 AND 10080)
    , CONSTRAINT app_settings_goal_auto_start_check
        CHECK (goal_auto_start IN (0, 1))
    , CONSTRAINT app_settings_agent_max_turns_check
        CHECK (agent_max_turns BETWEEN 1 AND 20)
    , CONSTRAINT app_settings_swarm_max_retries_check
        CHECK (swarm_max_retries BETWEEN 0 AND 10)
    , CONSTRAINT app_settings_lock_version_positive
        CHECK (lock_version >= 1)
  """

  @obsidian_ui_theme """
    , "ui_theme" TEXT DEFAULT 'obsidian' NOT NULL
        CONSTRAINT app_settings_ui_theme_check
        CHECK (ui_theme IN ('obsidian', 'midnight', 'graphite', 'aurora', 'porcelain', 'sandstone'))
  """

  @legacy_ui_theme """
    , "ui_theme" TEXT DEFAULT 'midnight' NOT NULL
        CONSTRAINT app_settings_ui_theme_check
        CHECK (ui_theme IN ('midnight', 'graphite', 'aurora', 'porcelain', 'sandstone'))
  """

  def up do
    rebuild("app_settings_obsidian", @base_columns <> @obsidian_ui_theme <> @tail_columns <> @checks)
  end

  def down do
    execute("UPDATE app_settings SET ui_theme = 'midnight' WHERE ui_theme = 'obsidian'")
    rebuild("app_settings_legacy", @base_columns <> @legacy_ui_theme <> @tail_columns <> @checks)
  end

  defp rebuild(temporary_table, definition) do
    execute("CREATE TABLE #{temporary_table} (#{definition})")
    execute("INSERT INTO #{temporary_table} (#{@columns}) SELECT #{@columns} FROM app_settings")
    execute("DROP TABLE app_settings")
    execute("ALTER TABLE #{temporary_table} RENAME TO app_settings")

    execute("""
    CREATE UNIQUE INDEX app_settings_singleton_index
    ON app_settings ((CASE WHEN id IS NOT NULL THEN 1 ELSE NULL END))
    """)
  end
end
