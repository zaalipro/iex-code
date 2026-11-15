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
    "file_mutations" => ~w(write_file patch_file multi_patch rename_symbol),
    "autonomy" => ~w(update_plan request_input spawn_agent),
    # mcp_tools members are dynamic (mcp__server__tool); matched by prefix.
    "mcp_tools" => [],
    "git_push" => ~w(git_stage git_commit),
    "web_search" => ~w(web_search fetch_url),
    "read_only" => ~w(
      read_file
      list_dir
      grep_search
      ast_search
      find_references
      lsp_query
      semantic_code_search
      repo_map
      diagnostics
      git_status
      git_diff
      git_generate_commit
      run_tests
    )
  }

  @tool_aliases %{
    "view_file" => "read_file",
    "replace_file_content" => "patch_file",
    "write_to_file" => "write_file",
    "find_by_name" => "list_dir"
  }

  @mutating_categories ~w(shell_execution file_mutations git_push mcp_tools)
  @read_only_permitted_categories ~w(read_only web_search autonomy)
  @valid_tiers ~w(full_auto prompt_dangerous read_only)

  @doc """
  Returns the predefined map of tool categories.
  """
  @spec categories() :: %{String.t() => list(String.t())}
  def categories, do: @categories

  @doc """
  Returns the category name for a given tool name.
  """
  @spec category_for_tool(String.t() | atom() | term()) :: String.t()
  def category_for_tool(nil), do: "other"

  def category_for_tool(tool_name) when is_atom(tool_name) do
    tool_name
    |> Atom.to_string()
    |> category_for_tool()
  end

  def category_for_tool(tool_name) when is_binary(tool_name) do
    if String.valid?(tool_name) do
      normalized =
        tool_name
        |> String.trim()
        |> String.downcase()

      if String.starts_with?(normalized, "mcp__") do
        "mcp_tools"
      else
        canonical = Map.get(@tool_aliases, normalized, normalized)

        Enum.find_value(@categories, "other", fn {cat, tools} ->
          if canonical in tools, do: cat
        end)
      end
    else
      "other"
    end
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
  @spec evaluate(String.t() | atom() | term(), AppSettings.t() | map() | nil, map()) ::
          :allow | {:prompt, String.t()} | {:deny, String.t()}
  def evaluate(tool_name, settings \\ nil, session_overrides \\ %{}) do
    trimmed_tool = trim_tool_name(tool_name)
    normalized_tool = safe_downcase(trimmed_tool)
    category = category_for_tool(normalized_tool)

    tier = resolve_tier(settings, session_overrides)
    overrides = resolve_category_overrides(settings, session_overrides)

    category_override = Map.get(overrides, category)

    cond do
      tier == "read_only" and mutating_category?(category) ->
        {:deny, "Mutating tool '#{trimmed_tool}' is prohibited in read_only mode"}

      tier == "read_only" and category not in @read_only_permitted_categories ->
        {:deny, "Unrecognized tool '#{trimmed_tool}' is prohibited in read_only mode"}

      category_override == "deny" ->
        {:deny, "Category '#{category}' is disabled by policy override"}

      category_override == "auto" ->
        :allow

      category_override == "prompt" ->
        {:prompt, "Category '#{category}' requires user approval by policy override"}

      tier == "full_auto" ->
        :allow

      tier == "prompt_dangerous" and mutating_category?(category) ->
        {:prompt, "Tool '#{trimmed_tool}' modifies files or executes commands"}

      true ->
        :allow
    end
  end

  defp resolve_tier(settings, session_overrides) do
    base_tier = extract_settings_tier(settings) || "prompt_dangerous"

    # read_only in stored/passed settings is a hard ceiling that session overrides cannot escalate.
    if base_tier == "read_only" do
      "read_only"
    else
      case extract_session_tier(session_overrides) do
        {:ok, tier} -> tier
        :absent -> base_tier
        :invalid -> "prompt_dangerous"
      end
    end
  end

  defp extract_settings_tier(nil), do: nil

  defp extract_settings_tier(%AppSettings{tool_approval_mode: mode}) do
    normalize_tier(mode)
  end

  defp extract_settings_tier(settings_map) when is_map(settings_map) do
    str_tier = settings_map |> Map.get("tool_approval_mode") |> normalize_tier()
    atom_tier = settings_map |> Map.get(:tool_approval_mode) |> normalize_tier()

    if str_tier == "read_only" or atom_tier == "read_only" do
      "read_only"
    else
      str_tier || atom_tier
    end
  end

  defp extract_settings_tier(_), do: nil

  defp extract_session_tier(session_overrides) when is_map(session_overrides) do
    raw_candidates =
      [
        Map.get(session_overrides, "tool_approval_mode"),
        Map.get(session_overrides, :tool_approval_mode)
      ]
      |> Enum.reject(&is_nil/1)

    case raw_candidates do
      [] ->
        :absent

      candidates ->
        normalized = Enum.map(candidates, &normalize_tier/1)

        cond do
          "read_only" in normalized -> {:ok, "read_only"}
          Enum.any?(normalized, &is_nil/1) -> :invalid
          "prompt_dangerous" in normalized -> {:ok, "prompt_dangerous"}
          true -> {:ok, hd(normalized)}
        end
    end
  end

  defp extract_session_tier(_), do: :absent

  defp normalize_tier(nil), do: nil

  defp normalize_tier(tier) when is_atom(tier) do
    tier |> Atom.to_string() |> normalize_tier()
  end

  defp normalize_tier(tier) when is_binary(tier) do
    if String.valid?(tier) do
      normalized = tier |> String.trim() |> String.downcase()
      if normalized in @valid_tiers, do: normalized, else: nil
    else
      nil
    end
  end

  defp normalize_tier(_), do: nil

  defp trim_tool_name(nil), do: ""
  defp trim_tool_name(name) when is_atom(name), do: name |> Atom.to_string() |> String.trim()

  defp trim_tool_name(name) when is_binary(name) do
    if String.valid?(name), do: String.trim(name), else: inspect(name)
  end

  defp trim_tool_name(other), do: inspect(other)

  defp safe_downcase(str) when is_binary(str) do
    if String.valid?(str), do: String.downcase(str), else: ""
  end

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
      with {:ok, key_str} <- normalize_override_token(k),
           {:ok, val_str} <- normalize_override_token(v) do
        Map.put(acc, key_str, val_str)
      else
        _ -> acc
      end
    end)
  end

  defp stringify_keys(_), do: %{}

  defp normalize_override_token(val) when is_atom(val) and not is_nil(val) do
    {:ok, val |> Atom.to_string() |> String.trim() |> String.downcase()}
  end

  defp normalize_override_token(val) when is_binary(val) do
    if String.valid?(val) do
      {:ok, val |> String.trim() |> String.downcase()}
    else
      :error
    end
  end

  defp normalize_override_token(_), do: :error
end
