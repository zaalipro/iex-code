defmodule IexCode.LLM.EmpiricalStreamChallengeTest do
  @moduledoc """
  Empirical Challenge Test Suite for Milestone M1.
  Conducted by Challenger 2.

  Adversarial stress vectors:
  1. `ThinkTagParser` pathological chunk split boundaries:
     - 1-character chunks (<, t, h, i, n, k, >)
     - Split closing tags (</thi, nk>, and all index variations)
     - Multiple sequential and interleaved <think> blocks
     - Extreme whitespace (indentation, multiline CoT, trailing spaces)
     - False tag prefixes and lookahead recovery (HTML/comparisons)
     - Partial tag stream termination and flush/1 recovery
  2. `Reasoning.resolve_profile/4` under malformed overrides:
     - Negative budgets (clamped >= 1024/2048)
     - Extreme token counts (negative, zero, massive numbers)
     - Invalid reasoning effort strings (graceful fallbacks)
     - Strict temperature omission on OpenAI reasoning models
     - Anthropic max_tokens > budget_tokens invariant enforcement
  3. `AppSettings.changeset/2` model override validation:
     - Rejection of negative budgets, extreme token counts, invalid effort strings
     - Rejection of unknown keys, non-map types, and oversized matrices
  """

  use ExUnit.Case, async: true
  alias IexCode.LLM.Reasoning
  alias IexCode.LLM.ThinkTagParser
  alias IexCode.Settings.AppSettings

  # ============================================================================
  # 1. ThinkTagParser Pathological Streaming Stress Tests
  # ============================================================================

  describe "ThinkTagParser pathological chunk split boundaries" do
    test "processes 1-character chunk streaming across <think> and </think> tags" do
      # Stream '<', 't', 'h', 'i', 'n', 'k', '>'
      chunks = [
        "<",
        "t",
        "h",
        "i",
        "n",
        "k",
        ">",
        "r",
        "e",
        "a",
        "s",
        "o",
        "n",
        "i",
        "n",
        "g",
        "<",
        "/",
        "t",
        "h",
        "i",
        "n",
        "k",
        ">",
        "r",
        "e",
        "s",
        "u",
        "l",
        "t"
      ]

      {final_text, final_reason, final_parser} =
        Enum.reduce(chunks, {"", "", ThinkTagParser.new()}, fn chunk, {acc_t, acc_r, parser} ->
          {t, r, updated} = ThinkTagParser.process_chunk(parser, chunk)
          {acc_t <> t, acc_r <> r, updated}
        end)

      assert final_text == "result"
      assert final_reason == "reasoning"
      assert final_parser.state == :outside
      assert final_parser.buffer == ""

      {flush_t, flush_r, _} = ThinkTagParser.flush(final_parser)
      assert flush_t == ""
      assert flush_r == ""
    end

    test "streams entire realistic response exclusively as 1-character chunks without dropping a single byte" do
      full_response =
        "Initial text before thoughts.\n" <>
          "<think>\n" <>
          "Step 1: Check constraints α = 0.5\n" <>
          "Step 2: Complexity is O(N log N)\n" <>
          "Step 3: Edge cases handled: [0, -1, 1000]\n" <>
          "</think>\n" <>
          "Final answer: α = 0.5 verified."

      chunks = String.graphemes(full_response)

      {final_text, final_reason, final_parser} =
        Enum.reduce(chunks, {"", "", ThinkTagParser.new()}, fn chunk, {acc_t, acc_r, parser} ->
          {t, r, updated} = ThinkTagParser.process_chunk(parser, chunk)
          {acc_t <> t, acc_r <> r, updated}
        end)

      expected_reasoning =
        "\nStep 1: Check constraints α = 0.5\n" <>
          "Step 2: Complexity is O(N log N)\n" <>
          "Step 3: Edge cases handled: [0, -1, 1000]\n"

      expected_clean_text =
        "Initial text before thoughts.\n\nFinal answer: α = 0.5 verified."

      assert final_reason == expected_reasoning
      assert final_text == expected_clean_text
      assert final_parser.state == :outside
      assert final_parser.buffer == ""
    end

    test "handles split closing tag </think> across every single possible boundary index" do
      # All possible 2-way splits of "</think>" (length 8)
      tag = "</think>"
      tag_len = String.length(tag)

      split_variants =
        for split_at <- 1..(tag_len - 1) do
          {String.slice(tag, 0, split_at), String.slice(tag, split_at..-1//1)}
        end

      # For each split variant, stream chunks that break exactly at that boundary
      for {prefix, suffix} <- split_variants do
        chunks = [
          "Intro <think>Solving step-by-step",
          " with careful analysis",
          prefix,
          suffix <> " The final answer is 42."
        ]

        {final_text, final_reason, final_parser} =
          Enum.reduce(chunks, {"", "", ThinkTagParser.new()}, fn chunk, {acc_t, acc_r, parser} ->
            {t, r, updated} = ThinkTagParser.process_chunk(parser, chunk)
            {acc_t <> t, acc_r <> r, updated}
          end)

        assert final_reason == "Solving step-by-step with careful analysis",
               "Failed for closing split: #{inspect(prefix)} + #{inspect(suffix)}"

        assert final_text == "Intro  The final answer is 42.",
               "Failed for closing split: #{inspect(prefix)} + #{inspect(suffix)}"

        assert final_parser.state == :outside
        assert final_parser.buffer == ""
      end
    end

    test "handles split opening tag <think> across every single possible boundary index" do
      # All possible 2-way splits of "<think>" (length 7)
      tag = "<think>"
      tag_len = String.length(tag)

      split_variants =
        for split_at <- 1..(tag_len - 1) do
          {String.slice(tag, 0, split_at), String.slice(tag, split_at..-1//1)}
        end

      for {prefix, suffix} <- split_variants do
        chunks = [
          "Pre-analysis ",
          prefix,
          suffix <> "Calculated 100% correctly</think> Done!"
        ]

        {final_text, final_reason, final_parser} =
          Enum.reduce(chunks, {"", "", ThinkTagParser.new()}, fn chunk, {acc_t, acc_r, parser} ->
            {t, r, updated} = ThinkTagParser.process_chunk(parser, chunk)
            {acc_t <> t, acc_r <> r, updated}
          end)

        assert final_reason == "Calculated 100% correctly",
               "Failed for opening split: #{inspect(prefix)} + #{inspect(suffix)}"

        assert final_text == "Pre-analysis  Done!",
               "Failed for opening split: #{inspect(prefix)} + #{inspect(suffix)}"

        assert final_parser.state == :outside
        assert final_parser.buffer == ""
      end
    end

    test "handles multiple sequential <think> blocks in a single stream with chunk splits" do
      chunks = [
        "Header\n<think>Round 1 reasoning",
        "</thi",
        "nk>\nMiddle text\n<",
        "thi",
        "nk>Round 2 reasoning</think>\nTrailer"
      ]

      {final_text, final_reason, final_parser} =
        Enum.reduce(chunks, {"", "", ThinkTagParser.new()}, fn chunk, {acc_t, acc_r, parser} ->
          {t, r, updated} = ThinkTagParser.process_chunk(parser, chunk)
          {acc_t <> t, acc_r <> r, updated}
        end)

      assert final_text == "Header\n\nMiddle text\n\nTrailer"
      assert final_reason == "Round 1 reasoningRound 2 reasoning"
      assert final_parser.state == :outside
      assert final_parser.buffer == ""
    end

    test "preserves exact whitespace, tabs, and indentation inside and surrounding think blocks" do
      chunks = [
        "  \t\n  ",
        "<think>\n",
        "    def solve(n):\n",
        "        # tabbed comment\n",
        "        \treturn n * 2\n",
        "</think>",
        "  \n  Result: ok  \n"
      ]

      {final_text, final_reason, final_parser} =
        Enum.reduce(chunks, {"", "", ThinkTagParser.new()}, fn chunk, {acc_t, acc_r, parser} ->
          {t, r, updated} = ThinkTagParser.process_chunk(parser, chunk)
          {acc_t <> t, acc_r <> r, updated}
        end)

      assert final_reason ==
               "\n    def solve(n):\n        # tabbed comment\n        \treturn n * 2\n"

      assert final_text == "  \t\n    \n  Result: ok  \n"
      assert final_parser.state == :outside
    end

    test "whitespace-only separation between multiple consecutive <think> tags" do
      chunks = [
        "<think>Round A</think>",
        "   \n\t   ",
        "<think>Round B</think>"
      ]

      {final_text, final_reason, final_parser} =
        Enum.reduce(chunks, {"", "", ThinkTagParser.new()}, fn chunk, {acc_t, acc_r, parser} ->
          {t, r, updated} = ThinkTagParser.process_chunk(parser, chunk)
          {acc_t <> t, acc_r <> r, updated}
        end)

      assert final_text == "   \n\t   "
      assert final_reason == "Round ARound B"
      assert final_parser.state == :outside
    end

    test "recovers safely from false tag prefixes and lookahead buffering without dropping characters" do
      # Text contains '<th' and '</th' that are NOT <think> or </think>
      chunks = [
        "Theorem: for all x < 10 and y <thi",
        "ngs and z </",
        "thou do <think>real thought</think> output"
      ]

      {final_text, final_reason, final_parser} =
        Enum.reduce(chunks, {"", "", ThinkTagParser.new()}, fn chunk, {acc_t, acc_r, parser} ->
          {t, r, updated} = ThinkTagParser.process_chunk(parser, chunk)
          {acc_t <> t, acc_r <> r, updated}
        end)

      assert final_text == "Theorem: for all x < 10 and y <things and z </thou do  output"
      assert final_reason == "real thought"
      assert final_parser.state == :outside
      assert final_parser.buffer == ""
    end

    test "flush/1 recovers trailing partial buffer when stream ends abruptly" do
      # Stream terminates while buffering partial prefix "<thi"
      parser = ThinkTagParser.new()
      {text, reason, parser} = ThinkTagParser.process_chunk(parser, "Incomplete statement <thi")
      assert text == "Incomplete statement "
      assert reason == ""
      assert parser.buffer == "<thi"

      {flushed_text, flushed_reason, reset_parser} = ThinkTagParser.flush(parser)
      assert flushed_text == "<thi"
      assert flushed_reason == ""
      assert reset_parser.buffer == ""

      # Stream terminates inside think tag with partial closing prefix "</thi"
      parser2 = ThinkTagParser.new()
      {_, _, parser2} = ThinkTagParser.process_chunk(parser2, "<think>Inside thought </thi")
      assert parser2.state == :inside
      assert parser2.buffer == "</thi"

      {flushed_text2, flushed_reason2, reset_parser2} = ThinkTagParser.flush(parser2)
      assert flushed_text2 == ""
      assert flushed_reason2 == "</thi"
      assert reset_parser2.buffer == ""
    end

    test "extract/1 extracts multiple think blocks and handles edge cases" do
      # Multiple blocks
      input = "<think>Step 1</think>Result 1<think>Step 2</think>Result 2"
      {thought, clean} = ThinkTagParser.extract(input)
      assert thought == "Step 1\n\nStep 2"
      assert clean == "Result 1Result 2"

      # Empty think block
      {thought_empty, clean_empty} = ThinkTagParser.extract("<think></think>Clean only")
      assert thought_empty == ""
      assert clean_empty == "Clean only"

      # Unclosed think block (falls back safely without crashing)
      {thought_unclosed, clean_unclosed} = ThinkTagParser.extract("<think>Never closed")
      assert is_nil(thought_unclosed)
      assert clean_unclosed == "<think>Never closed"

      # Unicode inside thinking
      {thought_unicode, clean_unicode} =
        ThinkTagParser.extract("<think>Calculated π ≈ 3.14159 and λ = 42</think>Done ✔")

      assert thought_unicode == "Calculated π ≈ 3.14159 and λ = 42"
      assert clean_unicode == "Done ✔"
    end
  end

  # ============================================================================
  # 2. Reasoning.resolve_profile/4 Stress Tests
  # ============================================================================

  describe "Reasoning.resolve_profile/4 stress test under malformed overrides" do
    test "Anthropic clamps negative budgets to >= 1024, temp to 1.0, and enforces max_tokens > budget" do
      settings = %AppSettings{
        default_thinking_budget: 4096,
        temperature: 0.7,
        max_tokens: 4096
      }

      # Negative budget passed via turn opts
      profile =
        Reasoning.resolve_profile("anthropic", "claude-3-7-sonnet", settings,
          budget_tokens: -5000,
          max_tokens: -100
        )

      assert profile.thinking_budget >= 1024
      assert profile.temperature == 1.0
      assert profile.max_tokens > profile.thinking_budget
      assert profile.max_tokens >= profile.thinking_budget + 1024
      assert profile.reasoning_effort == "medium"
    end

    test "Anthropic enforces max_tokens > budget_tokens when user passes max_tokens <= budget" do
      settings = %AppSettings{
        temperature: 0.5,
        max_tokens: 4096
      }

      # User requests budget of 16000 but max_tokens of only 4000
      profile =
        Reasoning.resolve_profile("anthropic", "claude-3-7-sonnet", settings,
          budget_tokens: 16_000,
          max_tokens: 4_000
        )

      assert profile.thinking_budget == 16_000
      assert profile.max_tokens > 16_000
      assert profile.max_tokens >= 17_024
      assert profile.temperature == 1.0
    end

    test "Anthropic when reasoning_effort is none cleanly disables extended thinking" do
      settings = %AppSettings{
        default_reasoning_effort: "medium",
        default_thinking_budget: 4096,
        temperature: 0.35,
        max_tokens: 4096
      }

      profile =
        Reasoning.resolve_profile("anthropic", "claude-3-7-sonnet", settings,
          reasoning_effort: "none"
        )

      assert is_nil(profile.thinking_budget)
      assert profile.reasoning_effort == "none"
      assert profile.temperature == 0.35
      assert profile.max_tokens == 4096
    end

    test "OpenAI reasoning models strictly omit temperature even when user explicitly passes temperature override" do
      settings = %AppSettings{
        temperature: 0.8,
        max_tokens: 4096,
        model_overrides: %{
          "o3-mini" => %{
            "temperature" => 0.9,
            "max_tokens" => 8000
          }
        }
      }

      for model <- ["o1", "o3", "o3-mini", "o4"] do
        profile =
          Reasoning.resolve_profile("openai", model, settings,
            temperature: 0.95,
            reasoning_effort: "high"
          )

        assert is_nil(profile.temperature),
               "Model #{model} must have nil temperature to avoid HTTP 400 rejection"

        assert profile.reasoning_effort == "high"
        assert is_nil(profile.thinking_budget)

        # Verify serialized payload strictly omits "temperature" and "max_tokens"
        payload =
          Reasoning.serialize_payload(
            "openai",
            model,
            [%{"role" => "user", "content" => "test"}],
            "system",
            settings,
            temperature: 0.95
          )

        refute Map.has_key?(payload, "temperature"),
               "Payload for #{model} must NOT contain 'temperature'"

        refute Map.has_key?(payload, "max_tokens"),
               "Payload for #{model} must NOT contain 'max_tokens'"

        assert Map.has_key?(payload, "max_completion_tokens"),
               "Payload for #{model} must use 'max_completion_tokens'"
      end
    end

    test "OpenAI normalizes invalid reasoning effort strings to 'medium'" do
      settings = %AppSettings{default_reasoning_effort: "medium"}

      invalid_efforts = [
        "ultra_insane",
        "super_high",
        "123",
        "CRITICAL",
        "undefined"
      ]

      for effort <- invalid_efforts do
        profile =
          Reasoning.resolve_profile("openai", "o3-mini", settings, reasoning_effort: effort)

        assert profile.reasoning_effort == "medium",
               "Expected 'medium' fallback for invalid effort: #{inspect(effort)}"
      end

      # "max" should normalize to "high"
      profile_max =
        Reasoning.resolve_profile("openai", "o3-mini", settings, reasoning_effort: "max")

      assert profile_max.reasoning_effort == "high"

      # "none" should normalize to nil for OpenAI
      profile_none =
        Reasoning.resolve_profile("openai", "o3-mini", settings, reasoning_effort: "none")

      assert is_nil(profile_none.reasoning_effort)
    end

    test "Gemini models clamp negative budget to >= 1024 and support reasoning_effort none" do
      settings = %AppSettings{temperature: 0.7, max_tokens: 4096}

      profile =
        Reasoning.resolve_profile("gemini", "gemini-2.0-flash-thinking", settings,
          thinking_budget: -500
        )

      assert profile.thinking_budget >= 1024
      assert profile.max_tokens > profile.thinking_budget

      profile_none =
        Reasoning.resolve_profile("gemini", "gemini-2.0-flash-thinking", settings,
          reasoning_effort: "none"
        )

      assert profile_none.thinking_budget == 0
      assert profile_none.reasoning_effort == "none"
    end

    test "Local DeepSeek R1 models clamp negative budget to >= 2048 and default temperature to 0.6" do
      settings = %AppSettings{temperature: 0.2, max_tokens: 4096}

      profile =
        Reasoning.resolve_profile("ollama", "deepseek-r1:14b", settings, thinking_budget: -100)

      assert profile.thinking_budget >= 2048
      assert profile.temperature == 0.6
      assert profile.capabilities.type == :local
    end

    test "handles malformed non-numeric strings and irregular types in overrides" do
      # Strings that cannot be parsed as numbers
      profile =
        Reasoning.resolve_profile("anthropic", "claude-3-7-sonnet", nil,
          budget_tokens: "not_a_number",
          max_tokens: "invalid_tokens",
          temperature: "invalid_temp"
        )

      # Should fall back gracefully to defaults
      assert profile.thinking_budget == 4096
      assert profile.max_tokens >= 5120
      assert profile.temperature == 1.0

      # Arbitrary non-map / non-list opts
      profile_safe = Reasoning.resolve_profile("openai", "gpt-4o", nil, :invalid_opts)
      assert profile_safe.max_tokens == 4096
      assert profile_safe.temperature == 0.2
    end
  end

  # ============================================================================
  # 3. AppSettings.changeset/2 Model Overrides Validation Stress Tests
  # ============================================================================

  describe "AppSettings.changeset/2 model override sanitization and validation" do
    setup do
      # Valid base settings struct
      base = %AppSettings{}
      {:ok, base: base}
    end

    test "rejects negative or sub-1024 budgets in model_overrides", %{base: base} do
      invalid_budgets = [-1000, -1, 0, 500, 1023]

      for budget <- invalid_budgets do
        cs =
          AppSettings.changeset(base, %{
            model_overrides: %{
              "claude-3-7-sonnet" => %{"budget_tokens" => budget}
            }
          })

        refute cs.valid?, "Expected changeset to reject budget #{budget}"

        assert %{model_overrides: ["contains an invalid model override configuration"]} =
                 errors_on(cs)
      end

      # 1024 is the minimum valid budget
      valid_cs =
        AppSettings.changeset(base, %{
          model_overrides: %{
            "claude-3-7-sonnet" => %{"budget_tokens" => 1024}
          }
        })

      assert valid_cs.valid?
    end

    test "rejects budgets exceeding 128_000 in model_overrides", %{base: base} do
      cs =
        AppSettings.changeset(base, %{
          model_overrides: %{
            "claude-3-7-sonnet" => %{"budget_tokens" => 128_001}
          }
        })

      refute cs.valid?
      assert %{model_overrides: _} = errors_on(cs)

      valid_cs =
        AppSettings.changeset(base, %{
          model_overrides: %{
            "claude-3-7-sonnet" => %{"budget_tokens" => 128_000}
          }
        })

      assert valid_cs.valid?
    end

    test "rejects zero, negative, and excessive max_tokens in model_overrides", %{base: base} do
      invalid_tokens = [-100, -1, 0, 128_001, 1_000_000]

      for tokens <- invalid_tokens do
        cs =
          AppSettings.changeset(base, %{
            model_overrides: %{
              "o3-mini" => %{"max_tokens" => tokens}
            }
          })

        refute cs.valid?, "Expected changeset to reject max_tokens #{tokens}"
        assert %{model_overrides: _} = errors_on(cs)
      end

      # Boundaries 1 and 128_000 are valid
      assert AppSettings.changeset(base, %{
               model_overrides: %{"o3-mini" => %{"max_tokens" => 1}}
             }).valid?

      assert AppSettings.changeset(base, %{
               model_overrides: %{"o3-mini" => %{"max_tokens" => 128_000}}
             }).valid?
    end

    test "rejects invalid reasoning effort strings in model_overrides", %{base: base} do
      invalid_efforts = [
        "extreme",
        "ultra",
        "super_high",
        "123",
        ""
      ]

      for effort <- invalid_efforts do
        cs =
          AppSettings.changeset(base, %{
            model_overrides: %{
              "o3-mini" => %{"reasoning_effort" => effort}
            }
          })

        refute cs.valid?, "Expected changeset to reject reasoning_effort #{inspect(effort)}"
        assert %{model_overrides: _} = errors_on(cs)
      end

      # Allowed efforts: none, low, medium, high, max
      for valid_effort <- ~w(none low medium high max) do
        cs =
          AppSettings.changeset(base, %{
            model_overrides: %{
              "o3-mini" => %{"reasoning_effort" => valid_effort}
            }
          })

        assert cs.valid?, "Expected changeset to accept reasoning_effort #{valid_effort}"
      end
    end

    test "rejects out-of-range temperatures in model_overrides", %{base: base} do
      invalid_temps = [-0.1, -1.0, 2.1, 5.0, 100.0]

      for temp <- invalid_temps do
        cs =
          AppSettings.changeset(base, %{
            model_overrides: %{
              "gpt-4o" => %{"temperature" => temp}
            }
          })

        refute cs.valid?, "Expected changeset to reject temperature #{temp}"
        assert %{model_overrides: _} = errors_on(cs)
      end

      # Valid boundaries 0.0 and 2.0
      assert AppSettings.changeset(base, %{
               model_overrides: %{"gpt-4o" => %{"temperature" => 0.0}}
             }).valid?

      assert AppSettings.changeset(base, %{
               model_overrides: %{"gpt-4o" => %{"temperature" => 2.0}}
             }).valid?
    end

    test "rejects unauthorized / injected keys in model_overrides", %{base: base} do
      cs =
        AppSettings.changeset(base, %{
          model_overrides: %{
            "o3-mini" => %{
              "reasoning_effort" => "high",
              "system_prompt_override" => "malicious prompt injection",
              "api_key" => "sk-secret"
            }
          }
        })

      refute cs.valid?

      assert %{model_overrides: ["contains an invalid model override configuration"]} =
               errors_on(cs)
    end

    test "rejects non-map or oversized model_overrides", %{base: base} do
      # Non-map types
      for invalid <- ["not_a_map", 123, true, [1, 2, 3]] do
        cs = AppSettings.changeset(base, %{model_overrides: invalid})
        refute cs.valid?
        assert %{model_overrides: _} = errors_on(cs)
      end

      # Model name exceeding 240 bytes
      oversized_name = String.duplicate("a", 241)

      cs_name =
        AppSettings.changeset(base, %{
          model_overrides: %{
            oversized_name => %{"reasoning_effort" => "high"}
          }
        })

      refute cs_name.valid?
      assert %{model_overrides: _} = errors_on(cs_name)

      # Map with 129 entries (> 128 limit)
      oversized_map =
        for i <- 1..129, into: %{} do
          {"model-#{i}", %{"reasoning_effort" => "medium"}}
        end

      cs_limit = AppSettings.changeset(base, %{model_overrides: oversized_map})
      refute cs_limit.valid?

      assert %{model_overrides: ["must be a map with at most 128 model overrides"]} =
               errors_on(cs_limit)
    end

    test "validates top-level default_reasoning_effort and default_thinking_budget", %{base: base} do
      # Invalid default effort
      cs_effort = AppSettings.changeset(base, %{default_reasoning_effort: "invalid_effort"})
      refute cs_effort.valid?
      assert %{default_reasoning_effort: _} = errors_on(cs_effort)

      # Invalid default budget (< 1024)
      cs_budget_low = AppSettings.changeset(base, %{default_thinking_budget: 1000})
      refute cs_budget_low.valid?
      assert %{default_thinking_budget: _} = errors_on(cs_budget_low)

      # Invalid default budget (> 128_000)
      cs_budget_high = AppSettings.changeset(base, %{default_thinking_budget: 128_001})
      refute cs_budget_high.valid?
      assert %{default_thinking_budget: _} = errors_on(cs_budget_high)

      # Valid defaults
      cs_valid =
        AppSettings.changeset(base, %{
          default_reasoning_effort: "high",
          default_thinking_budget: 8192
        })

      assert cs_valid.valid?
    end
  end

  # ============================================================================
  # Helper to format changeset errors
  # ============================================================================

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
