defmodule IexCode.Tools.SafetyPolicyTest do
  use ExUnit.Case, async: true
  alias IexCode.Settings.AppSettings
  alias IexCode.Tools.SafetyPolicy

  describe "category_for_tool/1" do
    test "correctly categorizes shell execution tools" do
      assert SafetyPolicy.category_for_tool("run_command") == "shell_execution"
      assert SafetyPolicy.category_for_tool(:run_command) == "shell_execution"
    end

    test "correctly categorizes file mutation tools" do
      for tool <- ~w(write_file patch_file multi_patch rename_symbol) do
        assert SafetyPolicy.category_for_tool(tool) == "file_mutations"
        assert SafetyPolicy.category_for_tool(String.to_atom(tool)) == "file_mutations"
      end
    end

    test "correctly categorizes git mutating tools" do
      assert SafetyPolicy.category_for_tool("git_stage") == "git_push"
      assert SafetyPolicy.category_for_tool("git_commit") == "git_push"
    end

    test "correctly categorizes web search tools" do
      assert SafetyPolicy.category_for_tool("web_search") == "web_search"
      assert SafetyPolicy.category_for_tool("fetch_url") == "web_search"
    end

    test "correctly categorizes read-only inspection tools" do
      for tool <-
            ~w(read_file list_dir grep_search ast_search find_references lsp_query semantic_code_search repo_map diagnostics git_status git_diff git_generate_commit run_tests) do
        assert SafetyPolicy.category_for_tool(tool) == "read_only"
      end
    end

    test "returns 'other' for unknown tools" do
      assert SafetyPolicy.category_for_tool("arbitrary_unknown_tool") == "other"
      assert SafetyPolicy.category_for_tool("git_push") == "other"
      assert SafetyPolicy.category_for_tool("bash") == "other"
      assert SafetyPolicy.category_for_tool("terminal_exec") == "other"
      assert SafetyPolicy.category_for_tool(nil) == "other"
    end

    test "normalizes whitespace, casing, MCP prefixes, and legacy aliases" do
      assert SafetyPolicy.category_for_tool("write_file ") == "file_mutations"
      assert SafetyPolicy.category_for_tool("WRITE_FILE") == "file_mutations"
      assert SafetyPolicy.category_for_tool("run_command\n") == "shell_execution"
      assert SafetyPolicy.category_for_tool("\t  RENAME_SYMBOL ") == "file_mutations"
      assert SafetyPolicy.category_for_tool("MCP__srv__tool") == "mcp_tools"
      assert SafetyPolicy.category_for_tool(" mcp__srv__tool\n") == "mcp_tools"
      assert SafetyPolicy.category_for_tool("REPLACE_FILE_CONTENT ") == "file_mutations"
      assert SafetyPolicy.category_for_tool(" VIEW_FILE ") == "read_only"
      assert SafetyPolicy.category_for_tool("WRITE_TO_FILE") == "file_mutations"
      assert SafetyPolicy.category_for_tool("Find_By_Name ") == "read_only"
    end
  end

  describe "mutating_category?/1" do
    test "identifies mutating categories" do
      assert SafetyPolicy.mutating_category?("shell_execution")
      assert SafetyPolicy.mutating_category?("file_mutations")
      assert SafetyPolicy.mutating_category?("git_push")
      refute SafetyPolicy.mutating_category?("read_only")
      refute SafetyPolicy.mutating_category?("web_search")
      refute SafetyPolicy.mutating_category?("other")
    end
  end

  describe "evaluate/3 global tiers" do
    test "full_auto allows both mutating and read-only tools" do
      settings = %AppSettings{
        tool_approval_mode: "full_auto",
        tool_category_overrides: %{}
      }

      assert SafetyPolicy.evaluate("run_command", settings) == :allow
      assert SafetyPolicy.evaluate("write_file", settings) == :allow
      assert SafetyPolicy.evaluate("git_commit", settings) == :allow
      assert SafetyPolicy.evaluate("read_file", settings) == :allow
      assert SafetyPolicy.evaluate("web_search", settings) == :allow
    end

    test "prompt_dangerous prompts for mutating tools and allows read-only tools" do
      settings = %AppSettings{
        tool_approval_mode: "prompt_dangerous",
        tool_category_overrides: %{}
      }

      assert {:prompt, reason1} = SafetyPolicy.evaluate("run_command", settings)
      assert reason1 =~ "modifies files or executes commands"

      assert {:prompt, reason2} = SafetyPolicy.evaluate("write_file", settings)
      assert reason2 =~ "modifies files or executes commands"

      assert {:prompt, reason_rename} = SafetyPolicy.evaluate("rename_symbol", settings)
      assert reason_rename =~ "modifies files or executes commands"

      assert {:prompt, reason3} = SafetyPolicy.evaluate("git_commit", settings)
      assert reason3 =~ "modifies files or executes commands"

      assert SafetyPolicy.evaluate("read_file", settings) == :allow
      assert SafetyPolicy.evaluate("find_references", settings) == :allow
      assert SafetyPolicy.evaluate("lsp_query", settings) == :allow
      assert SafetyPolicy.evaluate("grep_search", settings) == :allow
      assert SafetyPolicy.evaluate("web_search", settings) == :allow
    end

    test "read_only strictly denies mutating tools and allows read-only tools" do
      settings = %AppSettings{
        tool_approval_mode: "read_only",
        tool_category_overrides: %{}
      }

      assert {:deny, reason1} = SafetyPolicy.evaluate("run_command", settings)
      assert reason1 =~ "prohibited in read_only mode"

      assert {:deny, reason2} = SafetyPolicy.evaluate("write_file", settings)
      assert reason2 =~ "prohibited in read_only mode"

      assert {:deny, reason_rename} = SafetyPolicy.evaluate("rename_symbol", settings)
      assert reason_rename =~ "prohibited in read_only mode"

      assert {:deny, reason3} = SafetyPolicy.evaluate("git_commit", settings)
      assert reason3 =~ "prohibited in read_only mode"

      assert SafetyPolicy.evaluate("read_file", settings) == :allow
      assert SafetyPolicy.evaluate("find_references", settings) == :allow
      assert SafetyPolicy.evaluate("lsp_query", settings) == :allow
      assert SafetyPolicy.evaluate("git_diff", settings) == :allow
      assert SafetyPolicy.evaluate("web_search", settings) == :allow
    end
  end

  describe "evaluate/3 category overrides" do
    test "override to 'auto' permits dangerous tool in prompt_dangerous mode" do
      settings = %AppSettings{
        tool_approval_mode: "prompt_dangerous",
        tool_category_overrides: %{"file_mutations" => "auto"}
      }

      assert SafetyPolicy.evaluate("write_file", settings) == :allow
      # Other mutating category still prompts
      assert {:prompt, _} = SafetyPolicy.evaluate("run_command", settings)
    end

    test "override to 'deny' forbids tool even in full_auto mode" do
      settings = %AppSettings{
        tool_approval_mode: "full_auto",
        tool_category_overrides: %{"shell_execution" => "deny"}
      }

      assert {:deny, reason} = SafetyPolicy.evaluate("run_command", settings)
      assert reason =~ "disabled by policy override"
      assert SafetyPolicy.evaluate("write_file", settings) == :allow
    end

    test "override to 'prompt' intercepts tool even in full_auto mode" do
      settings = %AppSettings{
        tool_approval_mode: "full_auto",
        tool_category_overrides: %{"git_push" => "prompt"}
      }

      assert {:prompt, reason} = SafetyPolicy.evaluate("git_commit", settings)
      assert reason =~ "requires user approval by policy override"
    end

    test "session-level category overrides take precedence over settings-level overrides" do
      settings = %AppSettings{
        tool_approval_mode: "prompt_dangerous",
        tool_category_overrides: %{"shell_execution" => "prompt"}
      }

      session_overrides = %{
        "category_overrides" => %{"shell_execution" => "auto"}
      }

      assert SafetyPolicy.evaluate("run_command", settings, session_overrides) == :allow
    end

    test "session-level tool_approval_mode tier takes precedence" do
      settings = %AppSettings{
        tool_approval_mode: "prompt_dangerous",
        tool_category_overrides: %{}
      }

      assert SafetyPolicy.evaluate("run_command", settings, %{"tool_approval_mode" => "full_auto"}) ==
               :allow

      assert {:deny, _} =
               SafetyPolicy.evaluate("run_command", settings, %{
                 "tool_approval_mode" => "read_only"
               })
    end

    test "mutating tool in read_only mode is denied even when category override is 'prompt' or 'auto'" do
      settings_prompt = %AppSettings{
        tool_approval_mode: "read_only",
        tool_category_overrides: %{"file_mutations" => "prompt", "shell_execution" => "auto"}
      }

      assert {:deny, reason1} = SafetyPolicy.evaluate("write_file", settings_prompt)
      assert reason1 =~ "prohibited in read_only mode"

      assert {:deny, reason2} = SafetyPolicy.evaluate("run_command", settings_prompt)
      assert reason2 =~ "prohibited in read_only mode"
    end

    test "mutating tool in read_only mode is denied with default AppSettings overrides" do
      default_settings = %AppSettings{tool_approval_mode: "read_only"}

      assert {:deny, reason} = SafetyPolicy.evaluate("write_file", default_settings)
      assert reason =~ "prohibited in read_only mode"

      assert {:deny, reason2} = SafetyPolicy.evaluate("run_command", default_settings)
      assert reason2 =~ "prohibited in read_only mode"
    end

    test "read_only ceiling prevents session_overrides from escalating to full_auto or prompt_dangerous" do
      for settings <- [
            %AppSettings{tool_approval_mode: "read_only", tool_category_overrides: %{}},
            %{"tool_approval_mode" => "read_only"},
            %{tool_approval_mode: :read_only}
          ],
          escalation <- [
            %{"tool_approval_mode" => "full_auto"},
            %{"tool_approval_mode" => "prompt_dangerous"},
            %{tool_approval_mode: :full_auto},
            %{tool_approval_mode: "FULL_AUTO"}
          ] do
        assert {:deny, reason} = SafetyPolicy.evaluate("write_file", settings, escalation)
        assert reason =~ "prohibited in read_only mode"

        assert {:deny, reason2} = SafetyPolicy.evaluate("run_command", settings, escalation)
        assert reason2 =~ "prohibited in read_only mode"
      end
    end

    test "session_overrides can adjust tier when settings are full_auto, prompt_dangerous, or nil" do
      fa_settings = %AppSettings{tool_approval_mode: "full_auto", tool_category_overrides: %{}}

      assert {:deny, _} =
               SafetyPolicy.evaluate("run_command", fa_settings, %{
                 "tool_approval_mode" => "read_only"
               })

      assert SafetyPolicy.evaluate("run_command", nil, %{"tool_approval_mode" => "full_auto"}) ==
               :allow

      assert {:deny, _} =
               SafetyPolicy.evaluate("run_command", nil, %{"tool_approval_mode" => "read_only"})

      # Invalid tier in session_overrides fails closed to prompt_dangerous
      assert {:prompt, _} =
               SafetyPolicy.evaluate("run_command", fa_settings, %{
                 "tool_approval_mode" => "invalid_tier"
               })
    end

    test "evaluate/3 normalizes cased/padded tools and denies unrecognized tools in read_only mode" do
      ro_settings = %AppSettings{
        tool_approval_mode: "read_only",
        tool_category_overrides: %{"other" => "auto"}
      }

      pd_settings = %AppSettings{
        tool_approval_mode: "prompt_dangerous",
        tool_category_overrides: %{}
      }

      assert {:deny, _} = SafetyPolicy.evaluate("write_file ", ro_settings)
      assert {:deny, _} = SafetyPolicy.evaluate("WRITE_FILE", ro_settings)
      assert {:deny, _} = SafetyPolicy.evaluate("run_command\n", ro_settings)
      assert {:deny, _} = SafetyPolicy.evaluate("MCP__srv__tool", ro_settings)
      assert {:deny, _} = SafetyPolicy.evaluate("REPLACE_FILE_CONTENT ", ro_settings)

      assert {:prompt, _} = SafetyPolicy.evaluate("write_file ", pd_settings)
      assert {:prompt, _} = SafetyPolicy.evaluate("WRITE_FILE", pd_settings)
      assert {:prompt, _} = SafetyPolicy.evaluate("run_command\n", pd_settings)
      assert {:prompt, _} = SafetyPolicy.evaluate("MCP__srv__tool", pd_settings)
      assert {:prompt, _} = SafetyPolicy.evaluate("REPLACE_FILE_CONTENT ", pd_settings)

      # Unrecognized tools remain :allow in prompt_dangerous, but strictly :deny in read_only even with category override
      for unknown <- ~w(git_push bash terminal_exec arbitrary_unknown_tool) do
        assert SafetyPolicy.evaluate(unknown, pd_settings) == :allow

        assert SafetyPolicy.evaluate(unknown, ro_settings) ==
                 {:deny, "Unrecognized tool '#{unknown}' is prohibited in read_only mode"}
      end

      # read_only, web_search, and autonomy categories are permitted in read_only unless category-overridden
      assert SafetyPolicy.evaluate(" VIEW_FILE ", ro_settings) == :allow
      assert SafetyPolicy.evaluate("web_search", ro_settings) == :allow
      assert SafetyPolicy.evaluate("update_plan", ro_settings) == :allow

      ro_override_settings = %AppSettings{
        tool_approval_mode: "read_only",
        tool_category_overrides: %{"web_search" => "deny", "autonomy" => "prompt"}
      }

      assert {:deny, _} = SafetyPolicy.evaluate("web_search", ro_override_settings)
      assert {:prompt, _} = SafetyPolicy.evaluate("update_plan", ro_override_settings)
    end
  end
end
