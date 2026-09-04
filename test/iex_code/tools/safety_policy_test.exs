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
      for tool <- ~w(write_file patch_file multi_patch) do
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
            ~w(read_file list_dir grep_search ast_search semantic_code_search git_status git_diff git_generate_commit run_tests) do
        assert SafetyPolicy.category_for_tool(tool) == "read_only"
      end
    end

    test "returns 'other' for unknown tools" do
      assert SafetyPolicy.category_for_tool("arbitrary_unknown_tool") == "other"
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

      assert {:prompt, reason3} = SafetyPolicy.evaluate("git_commit", settings)
      assert reason3 =~ "modifies files or executes commands"

      assert SafetyPolicy.evaluate("read_file", settings) == :allow
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

      assert {:deny, reason3} = SafetyPolicy.evaluate("git_commit", settings)
      assert reason3 =~ "prohibited in read_only mode"

      assert SafetyPolicy.evaluate("read_file", settings) == :allow
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
  end
end
