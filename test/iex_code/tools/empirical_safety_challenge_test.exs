defmodule IexCode.Tools.EmpiricalSafetyChallengeTest do
  @moduledoc """
  Empirical Challenge Test Suite for Milestone M2.
  Adversarially verifies:
    1. Safety tier permutations across all 17 tools (full_auto, prompt_dangerous, read_only).
    2. Read-only mutating tool invariants, default AppSettings behaviors, and privilege escalation vulnerabilities.
    3. ContextCompactor stress testing with 100+ turns, massive outputs, and token bounding.
    4. Exit code and diff header preservation.
    5. Empirical reproduction of compactor output expansion, exit code duplication, and unbounded summary bugs.
  """
  use ExUnit.Case, async: true

  alias IexCode.LLM.ContextCompactor
  alias IexCode.Settings.AppSettings
  alias IexCode.Tools
  alias IexCode.Tools.SafetyPolicy

  @mutating_tools ~w(write_file patch_file multi_patch run_command git_commit git_stage)
  @readonly_tools ~w(
    read_file
    list_dir
    grep_search
    ast_search
    semantic_code_search
    git_status
    git_diff
    git_generate_commit
    run_tests
    web_search
    fetch_url
  )

  @all_17_tools @mutating_tools ++ @readonly_tools

  # ---------------------------------------------------------------------------
  # Task 1: Safety Tier Permutations Across All 17 Tools
  # ---------------------------------------------------------------------------
  describe "Permutations Matrix: All 17 Tools across Safety Tiers" do
    test "verifies total tool count matches the 17 defined tools" do
      definitions = Tools.tool_definitions(:all)
      tool_names = Enum.map(definitions, & &1.name) |> Enum.sort()

      assert length(@all_17_tools) == 17
      assert length(tool_names) == 17
      assert Enum.sort(@all_17_tools) == tool_names
    end

    test "full_auto mode permits all 17 tools without prompts or denials" do
      clean_settings = %AppSettings{
        tool_approval_mode: "full_auto",
        tool_category_overrides: %{}
      }

      for tool <- @all_17_tools do
        assert SafetyPolicy.evaluate(tool, clean_settings) == :allow,
               "Expected tool #{tool} to be :allow in full_auto"

        # Also test atom representation
        assert SafetyPolicy.evaluate(String.to_atom(tool), clean_settings) == :allow,
               "Expected atom tool #{tool} to be :allow in full_auto"
      end
    end

    test "prompt_dangerous mode prompts for 6 mutating tools and permits 11 read-only tools" do
      clean_settings = %AppSettings{
        tool_approval_mode: "prompt_dangerous",
        tool_category_overrides: %{}
      }

      for tool <- @mutating_tools do
        result = SafetyPolicy.evaluate(tool, clean_settings)

        assert match?({:prompt, reason} when is_binary(reason), result),
               "Expected mutating tool #{tool} to return {:prompt, reason} in prompt_dangerous, got: #{inspect(result)}"

        assert match?({:prompt, _}, SafetyPolicy.evaluate(String.to_atom(tool), clean_settings))
      end

      for tool <- @readonly_tools do
        assert SafetyPolicy.evaluate(tool, clean_settings) == :allow,
               "Expected read-only tool #{tool} to be :allow in prompt_dangerous"

        assert SafetyPolicy.evaluate(String.to_atom(tool), clean_settings) == :allow
      end
    end

    test "read_only mode (with clean overrides) denies 6 mutating tools and permits 11 read-only tools" do
      clean_settings = %AppSettings{
        tool_approval_mode: "read_only",
        tool_category_overrides: %{}
      }

      for tool <- @mutating_tools do
        result = SafetyPolicy.evaluate(tool, clean_settings)

        assert match?({:deny, reason} when is_binary(reason), result),
               "Expected mutating tool #{tool} to be denied in read_only mode, got: #{inspect(result)}"

        assert match?({:deny, _}, SafetyPolicy.evaluate(String.to_atom(tool), clean_settings))
      end

      for tool <- @readonly_tools do
        assert SafetyPolicy.evaluate(tool, clean_settings) == :allow,
               "Expected read-only tool #{tool} to be :allow in read_only mode"

        assert SafetyPolicy.evaluate(String.to_atom(tool), clean_settings) == :allow
      end
    end

    test "stress tests tier x category override matrix across all 5 categories" do
      categories = ~w(shell_execution file_mutations git_push web_search read_only)
      override_values = ~w(auto prompt deny)

      # Sample tool for each category
      category_sample = %{
        "shell_execution" => "run_command",
        "file_mutations" => "write_file",
        "git_push" => "git_commit",
        "web_search" => "web_search",
        "read_only" => "read_file"
      }

      for cat <- categories, override <- override_values do
        tool = category_sample[cat]

        # Case 1: In full_auto mode
        settings_fa = %AppSettings{
          tool_approval_mode: "full_auto",
          tool_category_overrides: %{cat => override}
        }

        result_fa = SafetyPolicy.evaluate(tool, settings_fa)

        case override do
          "deny" -> assert match?({:deny, _}, result_fa)
          "auto" -> assert result_fa == :allow
          "prompt" -> assert match?({:prompt, _}, result_fa)
        end

        # Case 2: In prompt_dangerous mode
        settings_pd = %AppSettings{
          tool_approval_mode: "prompt_dangerous",
          tool_category_overrides: %{cat => override}
        }

        result_pd = SafetyPolicy.evaluate(tool, settings_pd)

        case override do
          "deny" -> assert match?({:deny, _}, result_pd)
          "auto" -> assert result_pd == :allow
          "prompt" -> assert match?({:prompt, _}, result_pd)
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Task 2: Adversarial Safety Invariants & Bypass Vulnerability Analysis
  # ---------------------------------------------------------------------------
  describe "Adversarial Stress Testing: read_only Mode Invariants & Bypasses" do
    test "REMEDIATION VERIFICATION 1: AppSettings default overrides strictly deny mutating tools in read_only mode" do
      # When a user or system instantiates standard %AppSettings{tool_approval_mode: "read_only"},
      # schema defaults populate tool_category_overrides with prompt defaults.
      default_settings = %AppSettings{tool_approval_mode: "read_only"}

      assert default_settings.tool_category_overrides == %{
               "shell_execution" => "prompt",
               "file_mutations" => "prompt",
               "git_push" => "prompt",
               "web_search" => "auto"
             }

      # Because read_only tier takes precedence before category_overrides in SafetyPolicy.evaluate,
      # mutating tools return {:deny, ...} strictly and cannot be prompted or approved.
      for mutating_tool <- @mutating_tools do
        result = SafetyPolicy.evaluate(mutating_tool, default_settings)

        assert result ==
                 {:deny, "Mutating tool '#{mutating_tool}' is prohibited in read_only mode"},
               "Expected mutating tool #{mutating_tool} to be denied in read_only mode, got: #{inspect(result)}"
      end
    end

    test "REMEDIATION VERIFICATION 2: Category override 'auto' cannot escalate mutating tools in read_only mode" do
      # Adversarial scenario: an attacker/agent specifies category override "auto"
      # while the system is supposedly locked into "read_only" mode.
      escalated_settings = %AppSettings{
        tool_approval_mode: "read_only",
        tool_category_overrides: %{
          "file_mutations" => "auto",
          "shell_execution" => "auto",
          "git_push" => "auto"
        }
      }

      # Empirically proves that mutating tools are strictly denied despite 'auto' overrides!
      for mutating_tool <- @mutating_tools do
        result = SafetyPolicy.evaluate(mutating_tool, escalated_settings)

        assert result ==
                 {:deny, "Mutating tool '#{mutating_tool}' is prohibited in read_only mode"},
               "Expected mutating tool #{mutating_tool} to be strictly denied, got: #{inspect(result)}"
      end
    end

    test "VULNERABILITY PROOF 3: Session overrides can hijack tool_approval_mode to full_auto" do
      # If session_overrides contains "tool_approval_mode" => "full_auto",
      # it completely overrides the database AppSettings read_only tier.
      clean_ro_settings = %AppSettings{
        tool_approval_mode: "read_only",
        tool_category_overrides: %{}
      }

      session_hijack = %{"tool_approval_mode" => "full_auto"}

      for mutating_tool <- @mutating_tools do
        result = SafetyPolicy.evaluate(mutating_tool, clean_ro_settings, session_hijack)

        assert result == :allow,
               "Defect verification: session override hijacked read_only mode to full_auto for #{mutating_tool}"
      end
    end

    test "VULNERABILITY PROOF 4: Whitespace and case variations escape category categorization" do
      clean_ro_settings = %AppSettings{
        tool_approval_mode: "read_only",
        tool_category_overrides: %{}
      }

      # Because category_for_tool checks exact match in list:
      # "write_file " or "WRITE_FILE" maps to "other"
      assert SafetyPolicy.category_for_tool("write_file ") == "other"
      assert SafetyPolicy.category_for_tool("WRITE_FILE") == "other"
      assert SafetyPolicy.category_for_tool("run_command\n") == "other"

      # And because "other" is not in @mutating_categories:
      refute SafetyPolicy.mutating_category?("other")

      # Therefore in read_only mode, evaluate returns :allow for untrimmed/cased tools!
      assert SafetyPolicy.evaluate("write_file ", clean_ro_settings) == :allow
      assert SafetyPolicy.evaluate("WRITE_FILE", clean_ro_settings) == :allow
      assert SafetyPolicy.evaluate("run_command\n", clean_ro_settings) == :allow
    end
  end

  # ---------------------------------------------------------------------------
  # Task 3: ContextCompactor Stress Harness (100+ Turns & Massive Histories)
  # ---------------------------------------------------------------------------
  describe "ContextCompactor 100+ Turns Stress Harness" do
    setup do
      root = %{"role" => "user", "content" => "Execute full system integration test suite"}

      # Generate 120 alternating turns (60 assistant turns, 60 tool execution results)
      history_120 =
        Enum.flat_map(1..60, fn i ->
          tool_type = Enum.at(~w(grep diff command test file_view), rem(i, 5))

          tool_content =
            case tool_type do
              "grep" ->
                "Showing 45 matches found in 12 files:\n" <>
                  String.duplicate(
                    "lib/app/worker_#{i}.ex:#{i}: def process_job(job), do: :ok\n",
                    25
                  )

              "diff" ->
                "diff --git a/lib/app_#{i}.ex b/lib/app_#{i}.ex\n" <>
                  String.duplicate(
                    "+ def step_#{i}, do: {:ok, #{i}}\n- def step_#{i}, do: :error\n",
                    20
                  )

              "command" ->
                "Exit Code 0\n" <>
                  String.duplicate("Compiling 14 files (.ex)\nGenerated iex_code app\n", 15)

              "test" ->
                "Exit Code 1\nRunning ExUnit with seed 12345\n" <>
                  String.duplicate(
                    "1) test step_#{i} (AppTest)\n     Assertion failed: expected :ok got :error\n",
                    10
                  )

              "file_view" ->
                "Showing lines 1 to 100 of file_#{i}.ex:\n" <>
                  String.duplicate(
                    "defmodule Module#{i} do\n  @moduledoc false\n  def run, do: #{i}\nend\n",
                    15
                  )
            end

          [
            %{"role" => "assistant", "content" => "Executing iteration #{i} verification check"},
            %{"role" => "tool", "content" => tool_content}
          ]
        end)

      messages_121 = [root | history_120]

      settings = %AppSettings{
        context_window_tokens: 16_000,
        context_prune_threshold_percent: 75,
        context_compaction_strategy: "token_compaction",
        keep_recent_turns: 6
      }

      %{messages: messages_121, settings: settings}
    end

    test "handles 121 turns with linear token estimation", %{messages: messages} do
      assert length(messages) == 121

      tokens = ContextCompactor.estimate_tokens(messages)
      # 121 turns should produce substantial tokens (> 15,000)
      assert tokens > 15_000
    end

    test "token_compaction bounds 121-turn history to within threshold", %{
      messages: messages,
      settings: settings
    } do
      initial_tokens = ContextCompactor.estimate_tokens(messages)

      trigger_budget =
        trunc(settings.context_window_tokens * (settings.context_prune_threshold_percent / 100))

      assert initial_tokens > trigger_budget

      compacted = ContextCompactor.compact(messages, settings)

      compacted_tokens = ContextCompactor.estimate_tokens(compacted)

      # Compacted tokens must be strictly bounded below trigger budget
      assert compacted_tokens <= trigger_budget
      # Cascade to sliding window guarantees length == 1 (root) + 6 (recent)
      assert length(compacted) == 7
      assert List.first(compacted)["content"] == "Execute full system integration test suite"
    end

    test "sliding_window retains root prompt and latest K turns", %{
      messages: messages,
      settings: settings
    } do
      sw_settings = %{settings | context_compaction_strategy: "sliding_window"}

      compacted = ContextCompactor.compact(messages, sw_settings)

      # 1 root + 6 recent turns = 7 messages
      assert length(compacted) == 7
      assert List.first(compacted)["role"] == "user"
      assert List.first(compacted)["content"] == "Execute full system integration test suite"

      # The last message must match the last message of the original history
      assert List.last(compacted) == List.last(messages)
    end

    test "rolling_summary preserves root prompt, injects summary checkpoint, and retains recent turns",
         %{
           messages: messages,
           settings: settings
         } do
      rs_settings = %{settings | context_compaction_strategy: "rolling_summary"}

      compacted = ContextCompactor.compact(messages, rs_settings)

      # 1 root + 1 summary checkpoint + 6 recent turns = 8 messages
      assert length(compacted) == 8
      assert List.first(compacted)["content"] == "Execute full system integration test suite"

      summary_msg = Enum.at(compacted, 1)
      assert summary_msg["role"] == "system"
      assert summary_msg["content"] =~ "Summary of earlier conversation history:"
      assert summary_msg["content"] =~ "- Assistant planned:"
      assert summary_msg["content"] =~ "- Tool executed:"

      # The last message must match the original tail
      assert List.last(compacted) == List.last(messages)
    end

    test "no-op when messages are below trigger threshold", %{settings: settings} do
      small_messages = [
        %{"role" => "user", "content" => "Hello"},
        %{"role" => "assistant", "content" => "How can I help you today?"}
      ]

      assert ContextCompactor.compact(small_messages, settings) == small_messages
    end
  end

  # ---------------------------------------------------------------------------
  # Task 4: Error Exit Code & Diff Header Preservation
  # ---------------------------------------------------------------------------
  describe "Preservation of Exit Codes and Diff Headers" do
    test "preserves non-zero exit codes (Exit Code 1, 127, 255) during tool compaction" do
      for exit_code <- [1, 2, 127, 255] do
        bulky_error =
          "Exit Code #{exit_code}\n" <>
            String.duplicate("Stack trace line in compilation error\n", 80)

        msg = %{"role" => "tool", "content" => bulky_error}
        compacted = ContextCompactor.compact_tool_message(msg)

        assert String.contains?(compacted["content"], "Exit Code #{exit_code}"),
               "Failed to preserve Exit Code #{exit_code} after compaction"

        assert String.contains?(compacted["content"], "compacted")
      end
    end

    test "preserves git diff markers during compaction" do
      bulky_diff =
        "diff --git a/lib/core.ex b/lib/core.ex\nindex 1234567..89abcdef 100644\n--- a/lib/core.ex\n+++ b/lib/core.ex\n" <>
          String.duplicate("@@ -1,5 +1,6 @@\n+ added_line();\n- removed_line();\n", 80)

      msg = %{"role" => "tool", "content" => bulky_diff}
      compacted = ContextCompactor.compact_tool_message(msg)

      assert String.contains?(compacted["content"], "diff --git a/lib/core.ex b/lib/core.ex")
      assert String.contains?(compacted["content"], "compacted")
    end

    test "repetitive diffs across 100 turns are compacted and bounded to budget" do
      root = %{"role" => "user", "content" => "Refactor codebase with git diffs"}

      diff_history =
        Enum.flat_map(1..50, fn i ->
          diff_body =
            "diff --git a/lib/file_#{i}.ex b/lib/file_#{i}.ex\n" <>
              String.duplicate("+ line_#{i}_added();\n- line_#{i}_removed();\n", 40)

          [
            %{"role" => "assistant", "content" => "Applying diff for file_#{i}"},
            %{"role" => "tool", "content" => diff_body}
          ]
        end)

      messages = [root | diff_history]
      assert length(messages) == 101

      settings = %AppSettings{
        context_window_tokens: 16_000,
        context_prune_threshold_percent: 75,
        context_compaction_strategy: "token_compaction",
        keep_recent_turns: 6
      }

      initial_tokens = ContextCompactor.estimate_tokens(messages)
      trigger_budget = 12_000
      assert initial_tokens > trigger_budget

      compacted = ContextCompactor.compact(messages, settings)
      compacted_tokens = ContextCompactor.estimate_tokens(compacted)

      # Strictly bounded to trigger budget (pruning individual diffs achieves budget without needing sliding_window cascade)
      assert compacted_tokens <= trigger_budget
      assert compacted_tokens < initial_tokens / 3
      assert length(compacted) == 101
      assert List.first(compacted)["content"] == "Refactor codebase with git diffs"

      # Verify tool messages contain the compaction marker
      sample_tool_msg = Enum.at(compacted, 2)
      assert sample_tool_msg["role"] == "tool"
      assert sample_tool_msg["content"] =~ "compacted"
    end

    test "exit code format variations: colon format is preserved, but lowercase 'exit code 1' fails to trigger non-tool compaction" do
      # Colon format "Exit Code: 127" starts with "Exit Code", so it is recognized:
      colon_msg = %{
        "role" => "tool",
        "content" => "Exit Code: 127\n" <> String.duplicate("failed to execute\n", 80)
      }

      compacted_colon = ContextCompactor.compact_tool_message(colon_msg)
      assert compacted_colon["content"] =~ "Exit Code: 127"

      # Lowercase "exit code 1" in an assistant message (not role: tool):
      # is_tool_result_content? fails because it looks for exact case "Exit Code":
      lowercase_msg = %{
        "role" => "assistant",
        "content" => "exit code 1\n" <> String.duplicate("uncaught error\n", 80)
      }

      compacted_lower = ContextCompactor.compact_tool_message(lowercase_msg)
      # Does not compact because exact case "Exit Code" was not matched
      assert compacted_lower["content"] == lowercase_msg["content"]
    end
  end

  # ---------------------------------------------------------------------------
  # Task 5: Empirical Verification of Compactor Remediation
  # ---------------------------------------------------------------------------
  describe "Empirical Verification of Compactor Implementation Remediation" do
    test "REMEDIATION VERIFICATION 1: Few-line massive tool outputs shrink size and report valid compaction banner" do
      # When a tool output has fewer than 16 lines but exceeds @max_tool_output_chars (1500 chars),
      # compact_few_lines slices head and tail without overlapping lines or emitting negative line counts.
      single_massive_line = String.duplicate("X", 50_000)
      two_line_output = "Exit Code 1\n" <> single_massive_line

      msg = %{"role" => "tool", "content" => two_line_output}
      compacted = ContextCompactor.compact_tool_message(msg)

      compacted_content = compacted["content"]

      # Remediation: compacted content is strictly SMALLER than original
      assert byte_size(compacted_content) < byte_size(two_line_output)
      assert byte_size(compacted_content) < 2_000

      # Remediation: no negative line count reported, valid compaction banner present
      refute compacted_content =~ "compacted -"
      assert compacted_content =~ "compacted"
      assert compacted_content =~ "Exit Code 1"
    end

    test "REMEDIATION VERIFICATION 2: Exit Code line is preserved and never duplicated in compacted header" do
      multiline_output =
        "Exit Code 1\n" <>
          Enum.map_join(1..100, "\n", fn i -> "line #{i}: verbose test output exceeding limit" end)

      assert byte_size(multiline_output) > 1500

      msg = %{"role" => "tool", "content" => multiline_output}
      compacted = ContextCompactor.compact_tool_message(msg)

      content = compacted["content"]

      # Verify that "Exit Code 1" appears exactly once at the beginning, not duplicated
      refute content =~ "Exit Code 1\nExit Code 1\n"
      assert String.starts_with?(content, "Exit Code 1\nline 1:")
    end

    test "REMEDIATION VERIFICATION 3: rolling_summary enforces token budget limit" do
      large_history =
        Enum.flat_map(1..200, fn i ->
          [
            %{
              "role" => "user",
              "content" => "User request #{i} #{String.duplicate("data ", 20)}"
            },
            %{
              "role" => "assistant",
              "content" => "Assistant plan #{i} #{String.duplicate("plan ", 20)}"
            }
          ]
        end)

      messages = [%{"role" => "user", "content" => "Root task"} | large_history]

      tiny_budget_settings = %AppSettings{
        context_window_tokens: 2_000,
        context_prune_threshold_percent: 50,
        context_compaction_strategy: "rolling_summary",
        keep_recent_turns: 6
      }

      compacted = ContextCompactor.compact(messages, tiny_budget_settings)
      compacted_tokens = ContextCompactor.estimate_tokens(compacted)
      trigger_budget = 1_000

      # Remediation: compacted tokens strictly bounded to trigger budget (1,000 tokens)
      assert compacted_tokens <= trigger_budget
      assert length(compacted) == 8
      assert Enum.at(compacted, 1)["role"] == "system"
      assert Enum.at(compacted, 1)["content"] =~ "Summary of earlier conversation history"
    end
  end
end
