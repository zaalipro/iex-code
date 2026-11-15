defmodule IexCode.LLM.CapabilitiesTest do
  use ExUnit.Case, async: true
  alias IexCode.LLM.Capabilities

  describe "detect/2" do
    test "detects OpenAI reasoning models (o1, o3, o3-mini, o4)" do
      models = ["o1", "o1-preview", "o1-mini", "o1-2024-12-17", "o3", "o3-mini", "o4", "o4-mini"]

      for model <- models do
        caps = Capabilities.detect("openai", model)
        assert caps.reasoning_supported == true
        assert caps.reasoning_supported? == true
        assert caps.type == :openai
        assert caps.reasoning_type == :reasoning_effort
        refute caps.supports_temperature?
        refute Capabilities.supports_temperature?("openai", model)
        refute Capabilities.supports_extended_thinking?("openai", model)
        assert Capabilities.reasoning_model?("openai", model)
        assert caps.default_effort == "medium"
        assert is_nil(caps.default_budget)
      end
    end

    test "detects OpenAI models with catalog prefix (e.g. openai/o3-mini)" do
      caps = Capabilities.detect("openai", "openai/o3-mini")
      assert caps.reasoning_supported? == true
      assert caps.type == :openai
      refute caps.supports_temperature?
    end

    test "detects Anthropic Claude 3.7 Sonnet extended thinking models" do
      models = [
        "claude-3-7-sonnet",
        "claude-3-7-sonnet-20250219",
        "claude-3.7-sonnet",
        "anthropic/claude-3-7-sonnet",
        "claude-4-sonnet"
      ]

      for model <- models do
        caps = Capabilities.detect("anthropic", model)
        assert caps.reasoning_supported == true
        assert caps.reasoning_supported? == true
        assert caps.type == :anthropic
        assert caps.reasoning_type == :budget_tokens
        assert caps.supports_temperature?
        assert caps.requires_temperature_1_0?
        assert caps.supports_extended_thinking?
        assert Capabilities.supports_extended_thinking?("anthropic", model)
        assert Capabilities.reasoning_model?("anthropic", model)
        assert caps.default_budget == 4096
        assert caps.min_budget == 1024
      end
    end

    test "detects Gemini thinking models" do
      models = [
        "gemini-2.0-flash-thinking-exp",
        "gemini-2.5-flash-thinking",
        "gemini-3.8-flash-thinking",
        "google/gemini-2.0-flash-thinking-exp"
      ]

      for model <- models do
        caps = Capabilities.detect("gemini", model)
        assert caps.reasoning_supported == true
        assert caps.reasoning_supported? == true
        assert caps.type == :gemini
        assert caps.reasoning_type == :thinking_budget
        assert caps.supports_temperature?
        refute caps.requires_temperature_1_0?
        refute caps.supports_extended_thinking?
        assert Capabilities.reasoning_model?("gemini", model)
        assert caps.default_budget == 4096
      end
    end

    test "detects Local / DeepSeek R1 and QwQ think tag models" do
      models = [
        "deepseek-r1",
        "deepseek-r1:14b",
        "deepseek-r1:70b",
        "r1-1776",
        "qwen-qwq-32b",
        "qwq-32b"
      ]

      for model <- models do
        caps = Capabilities.detect("ollama", model)
        assert caps.reasoning_supported == true
        assert caps.reasoning_supported? == true
        assert caps.type == :local
        assert caps.reasoning_type == :think_tags
        assert caps.supports_temperature?
        refute caps.requires_temperature_1_0?
        refute caps.supports_extended_thinking?
        assert Capabilities.reasoning_model?("ollama", model)
        assert caps.default_budget == 8192
        assert caps.min_budget == 2048
      end
    end

    test "detects standard models as non-reasoning" do
      standard_cases = [
        {"openai", "gpt-4o"},
        {"openai", "gpt-4o-mini"},
        {"anthropic", "claude-3-5-sonnet-20241022"},
        {"anthropic", "claude-3-haiku-20240307"},
        {"ollama", "llama-3.1-8b"},
        {"ollama", "mistral-7b"}
      ]

      for {provider, model} <- standard_cases do
        caps = Capabilities.detect(provider, model)
        refute caps.reasoning_supported
        refute caps.reasoning_supported?
        assert caps.type == :none
        assert caps.reasoning_type == :none
        assert caps.supports_temperature?
        refute caps.requires_temperature_1_0?
        refute caps.supports_extended_thinking?
        refute Capabilities.reasoning_model?(provider, model)
        assert caps.default_effort == "none"
        assert is_nil(caps.default_budget)
      end
    end

    test "supports Map/Access syntax on capability structs" do
      caps = Capabilities.detect("openai", "o3-mini")
      assert caps[:reasoning_supported] == true
      assert caps[:type] == :openai
      assert caps[:supports_temperature] == false
    end

    test "handles nil and boundary values safely" do
      caps = Capabilities.detect("openai", nil)
      refute caps.reasoning_supported?
      assert caps.type == :none

      caps_empty = Capabilities.detect(nil, "")
      refute caps_empty.reasoning_supported?
    end

    test "detects 2025-2026 OpenAI frontier reasoning models (gpt-5*, codex*) with effort suffixes" do
      for model <- ["gpt-5", "gpt-5-mini", "gpt-5.2", "gpt-5.3-codex", "codex", "codex-mini"] do
        caps = Capabilities.detect("openai", model)
        assert caps.reasoning_supported? == true
        assert caps.type == :openai
        assert caps.reasoning_type == :reasoning_effort
        refute caps.supports_temperature?
        assert caps.max_output_tokens == 100_000
        assert caps.default_effort == "medium"
      end

      assert Capabilities.detect("openai", "gpt-5-minimal").default_effort == "minimal"
      assert Capabilities.detect("openai", "gpt-5-low").default_effort == "low"
      assert Capabilities.detect("openai", "gpt-5-medium").default_effort == "medium"
      assert Capabilities.detect("openai", "gpt-5-high").default_effort == "high"
      assert Capabilities.detect("openai", "gpt-5.2-xhigh").default_effort == "xhigh"
      assert Capabilities.detect("openai", "codex-xhigh").default_effort == "xhigh"

      for std_model <- ["gpt-4o", "gpt-4o-mini", "gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano"] do
        std_caps = Capabilities.detect("openai", std_model)
        refute std_caps.reasoning_supported?
        assert std_caps.type == :none
        assert std_caps.supports_temperature?
      end
    end

    test "detects Anthropic Claude 4/4.5/4.6/5 extended thinking prefixes and suffix budgets" do
      models = [
        "claude-sonnet-4",
        "claude-sonnet-4-20250514",
        "claude-sonnet-4-5",
        "claude-sonnet-4.6",
        "claude-opus-4",
        "claude-opus-4-1",
        "claude-opus-4-6",
        "claude-haiku-4-5",
        "claude-haiku-4.5",
        "claude-sonnet-5",
        "claude-opus-5",
        "claude-5"
      ]

      for model <- models do
        caps = Capabilities.detect("anthropic", model)
        assert caps.reasoning_supported? == true
        assert caps.type == :anthropic
        assert caps.reasoning_type == :budget_tokens
        assert caps.requires_temperature_1_0? == true
        assert caps.supports_extended_thinking? == true
        assert caps.max_output_tokens == 64_000
        assert caps.default_budget == 4_096
      end

      assert Capabilities.detect("anthropic", "claude-opus-4-6-high").default_budget == 16_384
      assert Capabilities.detect("anthropic", "claude-opus-4-6-xhigh").default_budget == 32_000
    end

    test "detects Gemini 2.5/3/4 models across native gemini/google and OpenAI proxy providers" do
      for provider <- ["gemini", "google"],
          model <- [
            "gemini-2.5-pro",
            "gemini-2.5-flash",
            "gemini-3-pro",
            "gemini-3.7-flash-high",
            "gemini-4-pro",
            "carbon",
            "hydrogen",
            "argon",
            "gemini-3-carbon"
          ] do
        caps = Capabilities.detect(provider, model)
        assert caps.reasoning_supported? == true
        assert caps.type == :gemini
        assert caps.reasoning_type == :thinking_budget
        assert caps.default_budget == 4_096
        assert caps.min_budget == 1_024
        assert caps.max_output_tokens == 65_536
      end

      proxy_caps = Capabilities.detect("openai", "gemini-3.7-flash-high")
      assert proxy_caps.type == :openai
      assert proxy_caps.reasoning_type == :reasoning_effort
      assert proxy_caps.supports_temperature? == true
      assert proxy_caps.default_effort == "high"
      assert proxy_caps.max_output_tokens == 65_536

      assert Capabilities.detect("openai", "gemini-2.5-pro").default_effort == "medium"
      assert Capabilities.detect("openai", "gemini-4-pro-xhigh").default_effort == "xhigh"
    end
  end
end
