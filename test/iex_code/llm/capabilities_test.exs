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
  end
end
