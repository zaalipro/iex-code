defmodule IexCode.LLM.ConfigurationResolutionTest do
  use IexCode.DataCase, async: false

  alias IexCode.E2E.MockLLMServer
  alias IexCode.LLM
  alias IexCode.Settings

  test "nil-session requests use the configured global temperature" do
    {:ok, server_pid, server} = MockLLMServer.start(scenario: :standard_completion)
    on_exit(fn -> MockLLMServer.stop(server_pid) end)

    assert {:ok, _settings} =
             Settings.update_settings(%{
               default_model_provider: "openai",
               default_model: "gpt-test",
               temperature: 0.73,
               openai_api_key: "test-key",
               openai_base_url: "#{server.url}/v1",
               anthropic_api_key: nil
             })

    _result =
      LLM.chat(
        [%{role: "user", content: "temperature probe"}],
        "system",
        nil,
        fn _chunk -> :ok end,
        receive_timeout: 2_000
      )

    assert [%{path: "/v1/chat/completions", body: body}] =
             MockLLMServer.get_requests(server_pid)

    assert body["model"] == "gpt-test"
    assert body["temperature"] == 0.73
  end

  test "does not fall back when the explicitly selected provider has no credential" do
    {:ok, server_pid, server} = MockLLMServer.start(scenario: :standard_completion)
    on_exit(fn -> MockLLMServer.stop(server_pid) end)

    assert {:ok, _settings} =
             Settings.update_settings(%{
               openai_api_key: "openai-only",
               openai_base_url: "#{server.url}/v1",
               anthropic_api_key: nil
             })

    session = %{
      model_provider: "anthropic",
      model_name: "claude-selected",
      temperature: 0.2
    }

    assert {:error, :no_api_key} =
             LLM.chat(
               [%{role: "user", content: "must not cross providers"}],
               "system",
               session
             )

    assert MockLLMServer.get_requests(server_pid) == []
  end

  test "explicit OpenAI-compatible transport accepts an opaque Claude-looking model id" do
    {:ok, server_pid, server} = MockLLMServer.start(scenario: :standard_completion)
    on_exit(fn -> MockLLMServer.stop(server_pid) end)

    assert {:ok, _settings} =
             Settings.update_settings(%{
               openai_api_key: "proxy-key",
               openai_base_url: "#{server.url}/v1",
               anthropic_api_key: nil
             })

    assert {:ok, _response} =
             LLM.chat(
               [%{role: "user", content: "use the selected compatible endpoint"}],
               "system",
               %{
                 model_provider: "openai",
                 model_name: "claude-proxy-alias",
                 temperature: 0.2
               },
               fn _chunk -> :ok end,
               receive_timeout: 2_000
             )

    assert [%{path: "/v1/chat/completions", body: %{"model" => "claude-proxy-alias"}}] =
             MockLLMServer.get_requests(server_pid)
  end

  test "resolved routes do not reread a changed global endpoint" do
    {:ok, pinned_pid, pinned} = MockLLMServer.start(scenario: :standard_completion)
    {:ok, changed_pid, changed} = MockLLMServer.start(scenario: :standard_completion)

    on_exit(fn ->
      MockLLMServer.stop(pinned_pid)
      MockLLMServer.stop(changed_pid)
    end)

    route = %{
      "provider" => "openai",
      "model" => "gpt-pinned",
      "api_key" => "pinned-key",
      "base_url" => "#{pinned.url}/v1",
      "temperature" => 0.1
    }

    assert {:ok, _settings} =
             Settings.update_settings(%{
               openai_api_key: "changed-key",
               openai_base_url: "#{changed.url}/v1"
             })

    assert {:ok, _response} =
             LLM.chat(
               [%{role: "user", content: "use the validated route"}],
               "system",
               %{model_provider: "openai", model_name: "gpt-pinned", temperature: 0.2},
               fn _chunk -> :ok end,
               resolved_route: route,
               max_tokens: 128,
               receive_timeout: 2_000
             )

    assert [%{path: "/v1/chat/completions", body: %{"model" => "gpt-pinned"}}] =
             MockLLMServer.get_requests(pinned_pid)

    assert MockLLMServer.get_requests(changed_pid) == []
  end

  test "provider execution rejects model identifiers over the shared byte limit" do
    {:ok, server_pid, server} = MockLLMServer.start(scenario: :standard_completion)
    on_exit(fn -> MockLLMServer.stop(server_pid) end)

    oversized_model = String.duplicate("m", 241)

    assert {:error, :invalid_model_name} =
             LLM.chat(
               [%{role: "user", content: "must fail before transport"}],
               "system",
               %{model_provider: "openai", model_name: oversized_model, temperature: 0.2}
             )

    assert {:error, :invalid_resolved_route} =
             LLM.chat(
               [%{role: "user", content: "must fail before resolved transport"}],
               "system",
               nil,
               fn _chunk -> :ok end,
               resolved_route: %{
                 provider: "openai",
                 model: oversized_model,
                 api_key: "test-key",
                 base_url: "#{server.url}/v1",
                 temperature: 0.2
               },
               max_tokens: 128
             )

    assert MockLLMServer.get_requests(server_pid) == []
  end

  test "explicit provider is authoritative over model-family-looking identifiers" do
    assert LLM.effective_provider("openai", "claude-test") == "openai"
    assert LLM.effective_provider("anthropic", "gpt-test") == "anthropic"
    assert LLM.effective_provider("anthropic", "custom-model") == "anthropic"
    assert LLM.effective_provider(nil, "claude-test") == "anthropic"
  end

  test "OpenAI reasoning model o3-mini omits temperature and serializes reasoning_effort and max_completion_tokens" do
    {:ok, server_pid, server} = MockLLMServer.start(scenario: :standard_completion)
    on_exit(fn -> MockLLMServer.stop(server_pid) end)

    assert {:ok, _settings} =
             Settings.update_settings(%{
               default_model_provider: "openai",
               default_model: "o3-mini",
               default_reasoning_effort: "high",
               openai_api_key: "test-openai-key",
               openai_base_url: "#{server.url}/v1",
               anthropic_api_key: nil
             })

    assert {:ok, _response} =
             LLM.chat(
               [%{role: "user", content: "reasoning probe"}],
               "system instructions",
               nil,
               fn _chunk -> :ok end,
               receive_timeout: 2_000
             )

    assert [%{path: "/v1/chat/completions", body: body}] =
             MockLLMServer.get_requests(server_pid)

    assert body["model"] == "o3-mini"
    assert body["reasoning_effort"] == "high"
    assert body["max_completion_tokens"] == 4096
    refute Map.has_key?(body, "temperature")
    refute Map.has_key?(body, "max_tokens")
  end

  test "Anthropic Claude 3.7 model clamps temperature to 1.0 and serializes thinking budget" do
    {:ok, server_pid, server} = MockLLMServer.start(scenario: :standard_completion)
    on_exit(fn -> MockLLMServer.stop(server_pid) end)

    assert {:ok, _settings} =
             Settings.update_settings(%{
               default_model_provider: "anthropic",
               default_model: "claude-3-7-sonnet",
               default_thinking_budget: 4096,
               temperature: 0.2,
               anthropic_api_key: "test-anthropic-key",
               anthropic_base_url: server.url,
               openai_api_key: nil
             })

    assert {:ok, _response} =
             LLM.chat(
               [%{role: "user", content: "extended thinking probe"}],
               "system",
               nil,
               fn _chunk -> :ok end,
               receive_timeout: 2_000
             )

    assert [%{path: "/v1/messages", body: body}] =
             MockLLMServer.get_requests(server_pid)

    assert body["model"] == "claude-3-7-sonnet"
    assert body["temperature"] == 1.0
    assert body["thinking"] == %{"type" => "enabled", "budget_tokens" => 4096}
    assert body["max_tokens"] > 4096
  end
end
