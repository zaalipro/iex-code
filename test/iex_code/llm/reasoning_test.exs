defmodule IexCode.LLM.ReasoningTest do
  use ExUnit.Case, async: true
  alias IexCode.LLM.Reasoning
  alias IexCode.Settings.AppSettings

  describe "resolve_profile/4" do
    test "OpenAI reasoning models omit temperature and normalize reasoning_effort" do
      settings = %AppSettings{
        default_reasoning_effort: "medium",
        default_thinking_budget: 4096,
        temperature: 0.2,
        max_tokens: 4096
      }

      profile = Reasoning.resolve_profile("openai", "o3-mini", settings)

      assert is_nil(profile.temperature)
      assert profile.reasoning_effort == "medium"
      assert profile.max_tokens == 4096
      assert is_nil(profile.thinking_budget)
      assert profile.capabilities.type == :openai
    end

    test "Anthropic extended thinking clamps temperature to 1.0 and enforces max_tokens > budget" do
      settings = %AppSettings{
        default_reasoning_effort: "medium",
        default_thinking_budget: 4096,
        temperature: 0.2,
        max_tokens: 4096
      }

      profile = Reasoning.resolve_profile("anthropic", "claude-3-7-sonnet", settings)

      assert profile.temperature == 1.0
      assert profile.thinking_budget == 4096
      assert profile.max_tokens > profile.thinking_budget
      assert profile.max_tokens >= 5120
      assert profile.reasoning_effort == "medium"
    end

    test "Anthropic when thinking is disabled uses regular temperature and omits thinking" do
      settings = %AppSettings{
        default_reasoning_effort: "medium",
        default_thinking_budget: 4096,
        temperature: 0.3,
        max_tokens: 4096
      }

      profile =
        Reasoning.resolve_profile("anthropic", "claude-3-7-sonnet", settings,
          reasoning_effort: "none"
        )

      assert profile.temperature == 0.3
      assert is_nil(profile.thinking_budget)
      assert profile.reasoning_effort == "none"
    end

    test "Local DeepSeek R1 models default temperature to 0.6 and allocate budget" do
      settings = %AppSettings{
        temperature: 0.2,
        max_tokens: 4096
      }

      profile = Reasoning.resolve_profile("ollama", "deepseek-r1:14b", settings)

      assert profile.temperature == 0.6
      assert profile.thinking_budget >= 2048
      assert profile.capabilities.type == :local
    end

    test "Standard models preserve temperature and omit reasoning attributes" do
      settings = %AppSettings{
        temperature: 0.7,
        max_tokens: 2048
      }

      profile = Reasoning.resolve_profile("openai", "gpt-4o", settings)

      assert profile.temperature == 0.7
      assert profile.max_tokens == 2048
      assert is_nil(profile.reasoning_effort)
      assert is_nil(profile.thinking_budget)
    end

    test "precedence cascade: opts > per-model overrides > settings > global defaults" do
      settings = %AppSettings{
        default_reasoning_effort: "low",
        default_thinking_budget: 2048,
        temperature: 0.2,
        max_tokens: 3000,
        model_overrides: %{
          "o3-mini" => %{
            "reasoning_effort" => "medium",
            "max_tokens" => 6000
          }
        }
      }

      # 1. Setting global default takes effect when no override exists
      profile_o1 = Reasoning.resolve_profile("openai", "o1", settings)
      assert profile_o1.reasoning_effort == "low"
      assert profile_o1.max_tokens == 3000

      # 2. Per-model override takes precedence over global settings
      profile_o3 = Reasoning.resolve_profile("openai", "o3-mini", settings)
      assert profile_o3.reasoning_effort == "medium"
      assert profile_o3.max_tokens == 6000

      # 3. Explicit turn opts take precedence over model override
      profile_turn =
        Reasoning.resolve_profile("openai", "o3-mini", settings,
          reasoning_effort: "high",
          max_tokens: 8000
        )

      assert profile_turn.reasoning_effort == "high"
      assert profile_turn.max_tokens == 8000
    end
  end

  describe "serialize_payload/6" do
    test "OpenAI reasoning payload includes reasoning_effort, max_completion_tokens, and strictly omits temperature" do
      settings = %AppSettings{
        default_reasoning_effort: "high",
        max_tokens: 8192
      }

      messages = [%{"role" => "user", "content" => "Optimize algorithm"}]
      system_prompt = "You are a code assistant"

      payload =
        Reasoning.serialize_payload("openai", "o3-mini", messages, system_prompt, settings,
          tools: [%{name: "search", description: "Search code", parameters: %{type: "object"}}],
          stream: true
        )

      assert payload["model"] == "o3-mini"
      assert payload["reasoning_effort"] == "high"
      assert payload["max_completion_tokens"] == 8192
      refute Map.has_key?(payload, "temperature")
      refute Map.has_key?(payload, "max_tokens")
      assert payload["stream"] == true
      assert is_list(payload["tools"])
      assert length(payload["tools"]) == 1
      assert hd(payload["tools"])["type"] == "function"
      assert hd(payload["messages"])["role"] == "system"
    end

    test "Anthropic extended thinking payload includes thinking block, temperature 1.0, and elevates max_tokens" do
      settings = %AppSettings{
        default_thinking_budget: 4096,
        temperature: 0.2,
        max_tokens: 4096
      }

      messages = [%{"role" => "user", "content" => "Explain quantum computing"}]
      system_prompt = "Be thorough"

      payload =
        Reasoning.serialize_payload(
          "anthropic",
          "claude-3-7-sonnet",
          messages,
          system_prompt,
          settings,
          budget_tokens: 4096
        )

      assert payload["model"] == "claude-3-7-sonnet"
      assert payload["temperature"] == 1.0
      assert payload["thinking"] == %{"type" => "enabled", "budget_tokens" => 4096}
      assert payload["max_tokens"] > 4096
      assert payload["system"] == "Be thorough"
      assert is_list(payload["messages"])
    end

    test "Anthropic non-thinking payload omits thinking map and keeps user temperature" do
      settings = %AppSettings{
        temperature: 0.5,
        max_tokens: 4096
      }

      messages = [%{"role" => "user", "content" => "Hello"}]

      payload =
        Reasoning.serialize_payload(
          "anthropic",
          "claude-3-7-sonnet",
          messages,
          nil,
          settings,
          reasoning_effort: "none"
        )

      assert payload["model"] == "claude-3-7-sonnet"
      assert payload["temperature"] == 0.5
      refute Map.has_key?(payload, "thinking")
      refute Map.has_key?(payload, "system")
    end

    test "Standard OpenAI payload serializes temperature and max_tokens" do
      settings = %AppSettings{
        temperature: 0.7,
        max_tokens: 2048
      }

      messages = [%{"role" => "user", "content" => "Hi"}]

      payload = Reasoning.serialize_payload("openai", "gpt-4o", messages, nil, settings)

      assert payload["model"] == "gpt-4o"
      assert payload["temperature"] == 0.7
      assert payload["max_tokens"] == 2048
      refute Map.has_key?(payload, "reasoning_effort")
      refute Map.has_key?(payload, "max_completion_tokens")
    end

    test "Local DeepSeek R1 payload serializes options with num_ctx and temperature" do
      messages = [%{"role" => "user", "content" => "Solve puzzle"}]

      payload = Reasoning.serialize_payload("ollama", "deepseek-r1:14b", messages, nil, nil)

      assert payload["options"]["num_ctx"] == 16_384
      assert payload["options"]["temperature"] == 0.6
    end
  end
end
