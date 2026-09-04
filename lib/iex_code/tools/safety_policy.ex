defmodule IexCode.Tools.SafetyPolicy do
  @moduledoc """
  Autonomous tool safety engine governing tool execution tiers and approval flows.

  Supports 3 global execution safety tiers:
    * `"full_auto"`: Autonomous tool execution without user prompt (unless category overridden).
    * `"prompt_dangerous"`: Prompts for confirmation on mutating actions (shell, file write, git commit).
    * `"read_only"`: Strictly denies all mutating actions while allowing non-destructive inspection.

  Granular per-category overrides supersede the global tier:
    * `"auto"`: Always permits the category without prompting.
    * `"prompt"`: Intercepts execution and requests user approval.
    * `"deny"`: Strictly denies execution.
  """

  alias IexCode.Settings.AppSettings

  @categories %{
    "shell_execution" => ~w(run_command),
    "file_mutations" => ~w(write_file patch_file multi_patch),
    "git_push" => ~w(git_stage git_commit),
    "web_search" => ~w(web_search fetch_url),
    "read_only" => ~w(
      read_file
      list_dir
      grep_search
      ast_search
      semantic_code_search
      git_status
      git_diff
      git_generate_commit
      run_tests
    )
  }

  @mutating_categories ~w(shell_execution file_mutations git_push)

  @doc """
  Returns the predefined map of tool categories.
  """
  @spec categories() :: %{String.t() => list(String.t())}
  def categories, do: @categories

  @doc """
  Returns the category name for a given tool name.
  """
  @spec category_for_tool(String.t() | atom()) :: String.t()
  def category_for_tool(tool_name) when is_atom(tool_name) do
    category_for_tool(Atom.to_string(tool_name))
  end

  def category_for_tool(tool_name) when is_binary(tool_name) do
    Enum.find_value(@categories, "other", fn {cat, tools} ->
      if tool_name in tools, do: cat
    end)
  end

  def category_for_tool(_), do: "other"

  @doc """
  Returns true if the category performs mutations or shell commands.
  """
  @spec mutating_category?(String.t()) :: boolean()
  def mutating_category?(category) when is_binary(category) do
    category in @mutating_categories
  end

  def mutating_category?(_), do: false

  @doc """
  Evaluates whether a tool execution requires approval, is allowed, or is denied.
  Returns `:allow`, `{:prompt, reason}`, or `{:deny, reason}`.
  """
  @spec evaluate(String.t() | atom(), AppSettings.t() | map() | nil, map()) ::
          :allow | {:prompt, String.t()} | {:deny, String.t()}
  def evaluate(tool_name, settings \\ nil, session_overrides \\ %{}) do
    tool_str = to_string(tool_name)
    category = category_for_tool(tool_str)

    tier = resolve_tier(settings, session_overrides)
    overrides = resolve_category_overrides(settings, session_overrides)

    category_override =
      Map.get(overrides, category) ||
        Map.get(overrides, to_string(category))

    cond do
      tier == "read_only" and mutating_category?(category) ->
        {:deny, "Mutating tool '#{tool_str}' is prohibited in read_only mode"}

      category_override == "deny" ->
        {:deny, "Category '#{category}' is disabled by policy override"}

      category_override == "auto" ->
        :allow

      category_override == "prompt" ->
        {:prompt, "Category '#{category}' requires user approval by policy override"}

      tier == "full_auto" ->
        :allow

      tier == "prompt_dangerous" and mutating_category?(category) ->
        {:prompt, "Tool '#{tool_str}' modifies files or executes commands"}

      true ->
        :allow
    end
  end

  defp resolve_tier(nil, session_overrides) do
    extract_tier(session_overrides, "prompt_dangerous")
  end

  defp resolve_tier(%AppSettings{} = settings, session_overrides) do
    extract_tier(session_overrides, settings.tool_approval_mode || "prompt_dangerous")
  end

  defp resolve_tier(settings_map, session_overrides) when is_map(settings_map) do
    default_tier =
      Map.get(settings_map, "tool_approval_mode") ||
        Map.get(settings_map, :tool_approval_mode) ||
        "prompt_dangerous"

    extract_tier(session_overrides, default_tier)
  end

  defp extract_tier(session_overrides, fallback) when is_map(session_overrides) do
    Map.get(session_overrides, "tool_approval_mode") ||
      Map.get(session_overrides, :tool_approval_mode) ||
      fallback
  end

  defp extract_tier(_session_overrides, fallback), do: fallback

  defp resolve_category_overrides(settings, session_overrides) do
    base =
      case settings do
        %AppSettings{tool_category_overrides: overrides} when is_map(overrides) -> overrides
        %{tool_category_overrides: overrides} when is_map(overrides) -> overrides
        %{"tool_category_overrides" => overrides} when is_map(overrides) -> overrides
        _ -> %{}
      end

    session_cat_overrides =
      case session_overrides do
        %{"category_overrides" => o} when is_map(o) -> o
        %{category_overrides: o} when is_map(o) -> o
        %{"tool_category_overrides" => o} when is_map(o) -> o
        %{tool_category_overrides: o} when is_map(o) -> o
        _ -> %{}
      end

    Map.merge(stringify_keys(base), stringify_keys(session_cat_overrides))
  end

  defp stringify_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {k, v}, acc ->
      Map.put(acc, to_string(k), to_string(v))
    end)
  end

  defp stringify_keys(_), do: %{}
end
