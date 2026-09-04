defmodule IexCode.LLM.EmpiricalPayloadChallengeTest do
  @moduledoc """
  Empirical verification and challenge test suite for Milestone M1:
  Adaptive Multi-Provider Reasoning Engine & Settings Persistence.

  Adversarially verifies:
  1. OpenAI reasoning models (o1, o3, o3-mini, o4): strictly omit "temperature",
     include "reasoning_effort", and map "max_completion_tokens" (never "max_tokens").
  2. Anthropic Claude 3.7 Sonnet extended thinking: strictly clamps "temperature" to 1.0,
     includes "thinking" map with "budget_tokens", and enforces "max_tokens > budget_tokens".
  3. Thinking disabled (reasoning_effort: "none"): strictly omits thinking map and preserves
     user-configured temperature.
  4. Per-model overrides matrix: validates that model-specific overrides supersede global
     settings, and turn-level options supersede model overrides.
  5. Boundary conditions and stress inputs: string-encoded numbers, nil settings, map settings,
     prefixed model names, and unknown effort levels.
  """

  use ExUnit.Case, async: true

  alias IexCode.LLM.Capabilities
  alias IexCode.LLM.Reasoning
  alias IexCode.Settings.AppSettings

  @sample_messages [%{"role" => "user", "content" => "Solve Dijkstra with priority queue"}]
  @sample_system "You are an expert systems engineer."

  # ============================================================================
  # Challenge 1: OpenAI Reasoning Models (o1, o3, o3-mini, o4)
  # ============================================================================

  describe "Challenge 1: OpenAI reasoning models (o1, o3, o3-mini, o4)" do
    @openai_reasoning_models [
      "o1",
      "o1-preview",
      "o1-mini",
      "o1-2024-12-17",
      "o3",
      "o3-mini",
      "o3-mini-2025-01-31",
      "o4",
      "o4-mini",
      "openai/o1",
      "openai/o3-mini",
      "openai/o4"
    ]

    test "all OpenAI reasoning model variants strictly omit 'temperature' and 'max_tokens', and include 'max_completion_tokens'" do
      settings = %AppSettings{
        default_reasoning_effort: "medium",
        temperature: 0.7,
        max_tokens: 4096
      }

      for model <- @openai_reasoning_models do
        payload =
          Reasoning.serialize_payload("openai", model, @sample_messages, @sample_system, settings)

        assert payload["model"] == model,
               "Expected model to be #{model}, got #{payload["model"]}"

        # Invariant 1: temperature MUST NOT be present in payload
        refute Map.has_key?(payload, "temperature"),
               "Model #{model} must NOT serialize 'temperature' (would cause OpenAI HTTP 400)"

        # Invariant 2: max_tokens MUST NOT be present; max_completion_tokens must be used
        refute Map.has_key?(payload, "max_tokens"),
               "Model #{model} must NOT serialize 'max_tokens' (deprecated on reasoning models)"

        assert payload["max_completion_tokens"] == 4096,
               "Model #{model} must serialize 'max_completion_tokens'"

        # Invariant 3: reasoning_effort must be present with valid level
        assert payload["reasoning_effort"] in ["low", "medium", "high"],
               "Model #{model} must serialize reasoning_effort, got #{inspect(payload["reasoning_effort"])}"
      end
    end

    test "OpenAI reasoning effort levels serialize correctly ('low', 'medium', 'high', 'max')" do
      settings = %AppSettings{max_tokens: 5000}

      for {input_effort, expected_payload_effort} <- [
            {"low", "low"},
            {"medium", "medium"},
            {"high", "high"},
            {"max", "high"},
            {:low, "low"},
            {:medium, "medium"},
            {:high, "high"},
            {:max, "high"}
          ] do
        payload =
          Reasoning.serialize_payload(
            "openai",
            "o3-mini",
            @sample_messages,
            @sample_system,
            settings,
            reasoning_effort: input_effort
          )

        refute Map.has_key?(payload, "temperature")
        assert payload["reasoning_effort"] == expected_payload_effort
        assert payload["max_completion_tokens"] == 5000
      end
    end

    test "OpenAI reasoning model with reasoning_effort 'none' omits reasoning_effort while STILL omitting temperature" do
      settings = %AppSettings{
        temperature: 0.8,
        max_tokens: 6000
      }

      payload =
        Reasoning.serialize_payload(
          "openai",
          "o1",
          @sample_messages,
          @sample_system,
          settings,
          reasoning_effort: "none"
        )

      # temperature must STILL be omitted because o1 rejects it regardless of effort setting
      refute Map.has_key?(payload, "temperature"),
             "OpenAI reasoning models must never include temperature even when reasoning_effort is 'none'"

      refute Map.has_key?(payload, "reasoning_effort"),
             "reasoning_effort 'none' should omit the reasoning_effort field from OpenAI payload"

      assert payload["max_completion_tokens"] == 6000
      refute Map.has_key?(payload, "max_tokens")
    end

    test "standard OpenAI models (e.g. gpt-4o) retain temperature and max_tokens, omitting reasoning fields" do
      settings = %AppSettings{
        temperature: 0.7,
        max_tokens: 2048,
        default_reasoning_effort: "high"
      }

      payload =
        Reasoning.serialize_payload(
          "openai",
          "gpt-4o",
          @sample_messages,
          @sample_system,
          settings
        )

      assert payload["model"] == "gpt-4o"
      assert payload["temperature"] == 0.7
      assert payload["max_tokens"] == 2048
      refute Map.has_key?(payload, "reasoning_effort")
      refute Map.has_key?(payload, "max_completion_tokens")
    end
  end

  # ============================================================================
  # Challenge 2: Anthropic Claude 3.7 Extended Thinking
  # ============================================================================

  describe "Challenge 2: Anthropic Claude 3.7 extended thinking" do
    @anthropic_thinking_models [
      "claude-3-7-sonnet",
      "claude-3-7-sonnet-20250219",
      "claude-3.7-sonnet",
      "claude-4",
      "claude-4-opus",
      "anthropic/claude-3-7-sonnet"
    ]

    test "all Claude 3.7 variants with thinking enabled strictly clamp temperature to 1.0" do
      # Test with varied temperatures that would fail Anthropic validation if not clamped
      for temp <- [0.0, 0.2, 0.5, 0.7, 1.5, 2.0] do
        settings = %AppSettings{
          default_thinking_budget: 4096,
          temperature: temp,
          max_tokens: 8192
        }

        for model <- @anthropic_thinking_models do
          payload =
            Reasoning.serialize_payload(
              "anthropic",
              model,
              @sample_messages,
              @sample_system,
              settings
            )

          assert payload["temperature"] === 1.0,
                 "Anthropic Claude 3.7 thinking payload temperature must strictly be 1.0 for model #{model} (was #{temp})"
        end
      end
    end

    test "Anthropic extended thinking serializes valid thinking map with budget_tokens" do
      settings = %AppSettings{
        default_thinking_budget: 4096,
        max_tokens: 8192
      }

      payload =
        Reasoning.serialize_payload(
          "anthropic",
          "claude-3-7-sonnet",
          @sample_messages,
          @sample_system,
          settings,
          budget_tokens: 5000
        )

      assert payload["thinking"] == %{
               "type" => "enabled",
               "budget_tokens" => 5000
             }
    end

    test "Anthropic extended thinking enforces invariant: max_tokens > budget_tokens" do
      # Case A: max_tokens was originally set SMALLER than budget_tokens
      settings = %AppSettings{
        default_thinking_budget: 4096,
        max_tokens: 2048
      }

      payload =
        Reasoning.serialize_payload(
          "anthropic",
          "claude-3-7-sonnet",
          @sample_messages,
          @sample_system,
          settings,
          budget_tokens: 4096
        )

      budget = payload["thinking"]["budget_tokens"]
      max_t = payload["max_tokens"]

      assert max_t > budget,
             "max_tokens (#{max_t}) must be strictly greater than budget_tokens (#{budget})"

      assert max_t >= budget + 1024,
             "max_tokens must have at least 1024 token buffer above budget"

      # Case B: max_tokens set equal to budget_tokens
      payload_eq =
        Reasoning.serialize_payload(
          "anthropic",
          "claude-3-7-sonnet",
          @sample_messages,
          @sample_system,
          settings,
          budget_tokens: 4096,
          max_tokens: 4096
        )

      assert payload_eq["max_tokens"] > payload_eq["thinking"]["budget_tokens"]
    end

    test "Anthropic budget_tokens clamps to minimum 1024" do
      settings = %AppSettings{max_tokens: 4096}

      payload =
        Reasoning.serialize_payload(
          "anthropic",
          "claude-3-7-sonnet",
          @sample_messages,
          @sample_system,
          settings,
          budget_tokens: 256
        )

      assert payload["thinking"]["budget_tokens"] == 1024,
             "Budget under 1024 must be clamped to min_budget 1024"

      assert payload["max_tokens"] > 1024
    end

    test "Anthropic standard model (claude-3-5-sonnet) does not enable thinking and preserves temperature" do
      settings = %AppSettings{
        temperature: 0.3,
        max_tokens: 4096,
        default_thinking_budget: 4096
      }

      payload =
        Reasoning.serialize_payload(
          "anthropic",
          "claude-3-5-sonnet",
          @sample_messages,
          @sample_system,
          settings
        )

      assert payload["model"] == "claude-3-5-sonnet"
      assert payload["temperature"] == 0.3
      refute Map.has_key?(payload, "thinking")
      assert payload["max_tokens"] == 4096
    end
  end

  # ============================================================================
  # Challenge 3: Thinking Disabled (reasoning_effort: "none")
  # ============================================================================

  describe "Challenge 3: Thinking disabled (reasoning_effort: 'none')" do
    test "Anthropic Claude 3.7 with reasoning_effort 'none' strictly omits thinking map and preserves temperature" do
      settings = %AppSettings{
        temperature: 0.45,
        max_tokens: 3000,
        default_reasoning_effort: "high",
        default_thinking_budget: 8192
      }

      payload =
        Reasoning.serialize_payload(
          "anthropic",
          "claude-3-7-sonnet",
          @sample_messages,
          @sample_system,
          settings,
          reasoning_effort: "none"
        )

      # Thinking map must NOT be present
      refute Map.has_key?(payload, "thinking"),
             "Payload must omit 'thinking' map when reasoning_effort is 'none'"

      # Temperature must be preserved as user configured (NOT clamped to 1.0)
      assert payload["temperature"] == 0.45,
             "Payload temperature must match user setting 0.45 when thinking is disabled"

      # max_tokens must NOT be inflated above what user specified
      assert payload["max_tokens"] == 3000
    end

    test "Anthropic Claude 3.7 with atom :none in opts omits thinking map and preserves temperature" do
      settings = %AppSettings{
        temperature: 0.25,
        max_tokens: 4000
      }

      payload =
        Reasoning.serialize_payload(
          "anthropic",
          "claude-3-7-sonnet",
          @sample_messages,
          nil,
          settings,
          reasoning_effort: :none
        )

      refute Map.has_key?(payload, "thinking")
      assert payload["temperature"] == 0.25
      assert payload["max_tokens"] == 4000
    end

    test "Anthropic payload omits system field when system_prompt is nil or empty" do
      settings = %AppSettings{temperature: 0.3}

      payload_nil =
        Reasoning.serialize_payload(
          "anthropic",
          "claude-3-7-sonnet",
          @sample_messages,
          nil,
          settings,
          reasoning_effort: "none"
        )

      refute Map.has_key?(payload_nil, "system")

      payload_empty =
        Reasoning.serialize_payload(
          "anthropic",
          "claude-3-7-sonnet",
          @sample_messages,
          "",
          settings,
          reasoning_effort: "none"
        )

      refute Map.has_key?(payload_empty, "system")
    end
  end

  # ============================================================================
  # Challenge 4: Per-Model Overrides Matrix
  # ============================================================================

  describe "Challenge 4: Per-model overrides matrix" do
    setup do
      settings = %AppSettings{
        default_reasoning_effort: "low",
        default_thinking_budget: 2048,
        temperature: 0.2,
        max_tokens: 3000,
        model_overrides: %{
          "o3-mini" => %{
            "reasoning_effort" => "high",
            "max_tokens" => 8000
          },
          "claude-3-7-sonnet" => %{
            "budget_tokens" => 6144,
            "temperature" => 0.5,
            "max_tokens" => 12000
          },
          "gpt-4o" => %{
            "temperature" => 0.85,
            "max_tokens" => 6000
          }
        }
      }

      %{settings: settings}
    end

    test "unoverridden model inherits global settings", %{settings: settings} do
      # o1 is not in model_overrides -> gets global defaults
      payload =
        Reasoning.serialize_payload("openai", "o1", @sample_messages, @sample_system, settings)

      assert payload["reasoning_effort"] == "low"
      assert payload["max_completion_tokens"] == 3000
      refute Map.has_key?(payload, "temperature")
    end

    test "model-specific override supersedes global settings", %{settings: settings} do
      # o3-mini has override: effort="high", max_tokens=8000 (global is "low", 3000)
      payload =
        Reasoning.serialize_payload(
          "openai",
          "o3-mini",
          @sample_messages,
          @sample_system,
          settings
        )

      assert payload["reasoning_effort"] == "high",
             "Model override 'high' should supersede global default 'low'"

      assert payload["max_completion_tokens"] == 8000,
             "Model override max_tokens 8000 should supersede global 3000"

      refute Map.has_key?(payload, "temperature")

      # claude-3-7-sonnet has override: budget_tokens=6144, max_tokens=12000
      anthropic_payload =
        Reasoning.serialize_payload(
          "anthropic",
          "claude-3-7-sonnet",
          @sample_messages,
          @sample_system,
          settings
        )

      assert anthropic_payload["thinking"]["budget_tokens"] == 6144
      assert anthropic_payload["max_tokens"] == 12000
      assert anthropic_payload["temperature"] === 1.0

      # gpt-4o has override: temperature=0.85, max_tokens=6000
      gpt_payload =
        Reasoning.serialize_payload(
          "openai",
          "gpt-4o",
          @sample_messages,
          @sample_system,
          settings
        )

      assert gpt_payload["temperature"] == 0.85
      assert gpt_payload["max_tokens"] == 6000
    end

    test "turn-level options supersede model-specific overrides", %{settings: settings} do
      # o3-mini override specifies reasoning_effort "high" and max_tokens 8000,
      # but turn opts specify "low" and 2500
      payload =
        Reasoning.serialize_payload(
          "openai",
          "o3-mini",
          @sample_messages,
          @sample_system,
          settings,
          reasoning_effort: "low",
          max_tokens: 2500
        )

      assert payload["reasoning_effort"] == "low",
             "Turn option 'low' must supersede model override 'high'"

      assert payload["max_completion_tokens"] == 2500,
             "Turn option max_tokens 2500 must supersede model override 8000"
    end

    test "model overrides work with provider-prefixed model names", %{settings: settings} do
      # Query with "openai/o3-mini" should match override keyed by "o3-mini"
      payload =
        Reasoning.serialize_payload(
          "openai",
          "openai/o3-mini",
          @sample_messages,
          @sample_system,
          settings
        )

      assert payload["reasoning_effort"] == "high"
      assert payload["max_completion_tokens"] == 8000
    end

    test "model overrides work when override key itself has provider prefix" do
      settings = %AppSettings{
        default_reasoning_effort: "low",
        model_overrides: %{
          "openai/o3-mini" => %{
            "reasoning_effort" => "high",
            "max_tokens" => 9999
          }
        }
      }

      payload =
        Reasoning.serialize_payload(
          "openai",
          "openai/o3-mini",
          @sample_messages,
          @sample_system,
          settings
        )

      assert payload["reasoning_effort"] == "high"
      assert payload["max_completion_tokens"] == 9999
    end
  end

  # ============================================================================
  # Challenge 5: Boundary Conditions, Malformed Inputs & Stress Invariants
  # ============================================================================

  describe "Challenge 5: Boundary conditions, malformed inputs & stress invariants" do
    test "handles string-encoded numbers in overrides gracefully without raising" do
      settings = %AppSettings{
        model_overrides: %{
          "o3-mini" => %{
            "max_tokens" => "16384",
            "reasoning_effort" => "high"
          },
          "claude-3-7-sonnet" => %{
            "budget_tokens" => "8192",
            "max_tokens" => "20000",
            "temperature" => "0.7"
          }
        }
      }

      o3_payload =
        Reasoning.serialize_payload(
          "openai",
          "o3-mini",
          @sample_messages,
          @sample_system,
          settings
        )

      assert o3_payload["max_completion_tokens"] == 16384
      assert o3_payload["reasoning_effort"] == "high"

      anthropic_payload =
        Reasoning.serialize_payload(
          "anthropic",
          "claude-3-7-sonnet",
          @sample_messages,
          @sample_system,
          settings
        )

      assert anthropic_payload["thinking"]["budget_tokens"] == 8192
      assert anthropic_payload["max_tokens"] == 20000
      assert anthropic_payload["temperature"] === 1.0
    end

    test "handles nil settings safely" do
      payload =
        Reasoning.serialize_payload("openai", "o3-mini", @sample_messages, @sample_system, nil)

      assert payload["model"] == "o3-mini"
      assert payload["reasoning_effort"] == "medium"
      refute Map.has_key?(payload, "temperature")
      assert is_integer(payload["max_completion_tokens"])
    end

    test "handles plain map settings (e.g. from JSON or unmarshalled session data)" do
      settings_map = %{
        "default_reasoning_effort" => "high",
        "default_thinking_budget" => 8192,
        "max_tokens" => 10000,
        "model_overrides" => %{
          "o1" => %{"reasoning_effort" => "low"}
        }
      }

      payload =
        Reasoning.serialize_payload(
          "openai",
          "o1",
          @sample_messages,
          @sample_system,
          settings_map
        )

      assert payload["reasoning_effort"] == "low"
      assert payload["max_completion_tokens"] == 10000
      refute Map.has_key?(payload, "temperature")
    end

    test "capabilities access behaviour supports both struct dot-syntax and map access syntax" do
      caps = Capabilities.detect("openai", "o3-mini")

      assert caps.reasoning_supported? == true
      assert caps[:reasoning_supported?] == true
      assert caps.type == :openai
      assert caps[:type] == :openai
      assert caps.supports_temperature? == false
      assert caps[:supports_temperature?] == false
    end

    test "Gemini thinking models serialize thinkingConfig with thinkingBudget" do
      settings = %AppSettings{
        default_thinking_budget: 4096,
        max_tokens: 8192
      }

      payload =
        Reasoning.serialize_payload(
          "gemini",
          "gemini-2.0-flash-thinking",
          @sample_messages,
          @sample_system,
          settings
        )

      assert get_in(payload, ["generationConfig", "thinkingConfig", "thinkingBudget"]) == 4096
      assert get_in(payload, ["generationConfig", "maxOutputTokens"]) >= 5120
      assert is_list(payload["contents"])
      assert payload["systemInstruction"]["parts"] == [%{"text" => @sample_system}]
    end

    test "Local DeepSeek R1 serializes options with num_ctx and default temperature 0.6" do
      settings = %AppSettings{
        temperature: 0.2
      }

      payload =
        Reasoning.serialize_payload(
          "ollama",
          "deepseek-r1:14b",
          @sample_messages,
          @sample_system,
          settings
        )

      assert payload["options"]["num_ctx"] == 16384
      assert payload["options"]["temperature"] == 0.6
    end
  end
end
