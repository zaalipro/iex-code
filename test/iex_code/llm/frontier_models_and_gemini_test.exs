defmodule IexCode.LLM.FrontierModelsAndGeminiTest do
  use ExUnit.Case, async: false

  alias IexCode.Execution.{ModelRoute, Policy}
  alias IexCode.LLM
  alias IexCode.LLM.{Anthropic, Capabilities, Gemini, OpenAI, Reasoning, RequestPreparation}

  defmodule MockGeminiPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      agent = Keyword.fetch!(opts, :agent)
      {:ok, raw_body, conn} = read_body(conn)
      decoded_body = if raw_body == "", do: %{}, else: Jason.decode!(raw_body)

      record = %{
        method: conn.method,
        path: conn.request_path,
        query_string: conn.query_string,
        headers: Map.new(conn.req_headers),
        body: decoded_body
      }

      handler =
        Agent.get_and_update(agent, fn state ->
          {state.handler, %{state | requests: state.requests ++ [record]}}
        end)

      handler.(conn, record)
    end
  end

  setup do
    agent =
      start_supervised!(
        {Agent,
         fn ->
           %{
             requests: [],
             handler: fn conn, _req ->
               Plug.Conn.send_resp(conn, 200, Jason.encode!(%{"candidates" => []}))
             end
           }
         end}
      )

    server =
      start_supervised!(
        {Bandit, plug: {MockGeminiPlug, agent: agent}, port: 0, ip: :loopback, startup_log: false}
      )

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)

    %{
      agent: agent,
      base_url: "http://127.0.0.1:#{port}/v1beta"
    }
  end

  defp set_handler(agent, fun) do
    Agent.update(agent, fn state -> %{state | handler: fun} end)
  end

  defp get_requests(agent) do
    Agent.get(agent, & &1.requests)
  end

  describe "Frontier capability detection & reasoning normalization" do
    test "OpenAI gpt-5* and codex* models enable reasoning_effort and keep gpt-4.1* standard" do
      for {model, expected_effort} <- [
            {"gpt-5", "medium"},
            {"gpt-5-minimal", "minimal"},
            {"gpt-5-low", "low"},
            {"gpt-5-medium", "medium"},
            {"gpt-5-high", "high"},
            {"gpt-5.2-xhigh", "xhigh"},
            {"codex", "medium"},
            {"codex-mini-latest", "medium"},
            {"codex-high", "high"},
            {"openai/gpt-5-xhigh", "xhigh"}
          ] do
        caps = Capabilities.detect("openai", model)
        assert caps.type == :openai
        assert caps.reasoning_supported? == true
        assert caps.reasoning_type == :reasoning_effort
        assert caps.supports_temperature? == false
        assert caps.max_output_tokens == 100_000
        assert caps.default_effort == expected_effort
      end

      for standard <- ["gpt-4o", "gpt-4o-mini", "gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano"] do
        caps = Capabilities.detect("openai", standard)
        assert caps.type == :none
        assert caps.reasoning_supported? == false
        assert caps.supports_temperature? == true
      end
    end

    test "OpenAI.build_body normalizes minimal, xhigh, max, and none efforts" do
      messages = [%{role: "user", content: "Solve constraint system"}]

      body_min = OpenAI.build_body(messages, "sys", model: "gpt-5", reasoning_effort: "minimal")
      assert body_min["reasoning_effort"] == "minimal"
      assert body_min["max_completion_tokens"] == 4096
      refute Map.has_key?(body_min, "temperature")

      body_xhigh = OpenAI.build_body(messages, "sys", model: "codex-xhigh")
      assert body_xhigh["reasoning_effort"] == "xhigh"

      body_max = OpenAI.build_body(messages, "sys", model: "gpt-5", reasoning_effort: "max")
      assert body_max["reasoning_effort"] == "high"

      body_none = OpenAI.build_body(messages, "sys", model: "gpt-5", reasoning_effort: "none")
      refute Map.has_key?(body_none, "reasoning_effort")
      assert body_none["max_completion_tokens"] == 4096
      refute Map.has_key?(body_none, "temperature")

      assert Reasoning.normalize_openai_effort("minimal") == "minimal"
      assert Reasoning.normalize_openai_effort("xhigh") == "xhigh"
      assert Reasoning.normalize_openai_effort("max") == "high"
      assert is_nil(Reasoning.normalize_openai_effort("none"))

      gemini_profile = Reasoning.resolve_profile("google", "gemini-3-pro", nil)
      assert gemini_profile.capabilities.type == :gemini
      assert gemini_profile.thinking_budget == 4_096

      gemini_proxy_profile = Reasoning.resolve_profile("openai", "gemini-3.7-flash-high", nil)
      assert gemini_proxy_profile.capabilities.type == :openai
      assert gemini_proxy_profile.capabilities.supports_temperature? == true
      assert gemini_proxy_profile.reasoning_effort == "high"
    end

    test "Anthropic Claude 4/4.5/4.6/5 models enable extended thinking and infer -high/-xhigh budgets" do
      for {model, expected_budget} <- [
            {"claude-3-7-sonnet", 4_096},
            {"claude-4-sonnet", 4_096},
            {"claude-sonnet-4-20250514", 4_096},
            {"claude-sonnet-4-5", 4_096},
            {"claude-opus-4-1", 4_096},
            {"claude-opus-4-6", 4_096},
            {"claude-haiku-4-5-20251001", 4_096},
            {"claude-sonnet-5", 4_096},
            {"claude-opus-5", 4_096},
            {"claude-5", 4_096},
            {"claude-sonnet-4-6-high", 16_384},
            {"claude-opus-4-6-xhigh", 32_000}
          ] do
        caps = Capabilities.detect("anthropic", model)
        assert caps.type == :anthropic
        assert caps.reasoning_type == :budget_tokens
        assert caps.requires_temperature_1_0? == true
        assert caps.supports_extended_thinking? == true
        assert caps.max_output_tokens == 64_000
        assert caps.default_budget == expected_budget
      end

      body_high =
        Anthropic.build_body([%{role: "user", content: "hi"}], "sys",
          model: "claude-opus-4-6-high",
          max_tokens: 4096
        )

      assert body_high["temperature"] == 1.0
      assert body_high["thinking"] == %{"type" => "enabled", "budget_tokens" => 16_384}
      assert body_high["max_tokens"] >= 17_408
    end
  end

  describe "Gemini.build_body/3 and RequestPreparation.measure/4" do
    test "builds systemInstruction, multi-turn functionCall/functionResponse contents, tools, and thinkingConfig" do
      tools = [
        %{
          name: "read_file",
          description: "Read workspace file",
          parameters: %{
            type: "object",
            properties: %{path: %{type: "string"}},
            required: ["path"],
            additionalProperties: false
          }
        }
      ]

      messages = [
        %{role: "user", content: "Inspect lib/foo.ex and lib/bar.ex"},
        %{
          role: "assistant",
          content: "",
          tool_calls: [
            %{id: "call_1", name: "read_file", args: %{"path" => "lib/foo.ex"}},
            %{id: "call_2", name: "read_file", args: %{"path" => "lib/bar.ex"}}
          ]
        },
        %{role: "tool", tool_call_id: "call_1", content: "defmodule Foo, do: :ok"},
        %{role: "tool", tool_call_id: "call_2", content: "defmodule Bar, do: :ok"}
      ]

      body =
        Gemini.build_body(messages, "Follow workspace rules.",
          model: "gemini-3-pro",
          temperature: 0.2,
          max_tokens: 4096,
          thinking_budget: 4096,
          tools: tools
        )

      refute Map.has_key?(body, "stream")
      assert body["systemInstruction"] == %{"parts" => [%{"text" => "Follow workspace rules."}]}

      assert [%{"functionDeclarations" => [decl]}] = body["tools"]
      assert decl["name"] == "read_file"
      refute Map.has_key?(decl["parameters"], "additionalProperties")

      assert body["generationConfig"]["temperature"] == 0.2
      assert body["generationConfig"]["maxOutputTokens"] == 5120
      assert body["generationConfig"]["thinkingConfig"]["thinkingBudget"] == 4096

      assert [user_turn, model_turn, merged_tool_turn] = body["contents"]

      assert user_turn == %{
               "role" => "user",
               "parts" => [%{"text" => "Inspect lib/foo.ex and lib/bar.ex"}]
             }

      assert model_turn == %{
               "role" => "model",
               "parts" => [
                 %{
                   "functionCall" => %{"name" => "read_file", "args" => %{"path" => "lib/foo.ex"}}
                 },
                 %{
                   "functionCall" => %{"name" => "read_file", "args" => %{"path" => "lib/bar.ex"}}
                 }
               ]
             }

      assert merged_tool_turn == %{
               "role" => "user",
               "parts" => [
                 %{
                   "functionResponse" => %{
                     "name" => "read_file",
                     "response" => %{"result" => "defmodule Foo, do: :ok"}
                   }
                 },
                 %{
                   "functionResponse" => %{
                     "name" => "read_file",
                     "response" => %{"result" => "defmodule Bar, do: :ok"}
                   }
                 }
               ]
             }
    end

    test "RequestPreparation.prepare/4 and measure/4 account for Gemini contents, systemInstruction, and generationConfig" do
      messages = [%{role: "user", content: "Check Gemini token budgeting"}]

      opts = [
        model: "gemini-2.5-pro",
        max_tokens: 2048,
        thinking_budget: 4096,
        tools: [%{name: "list_dir", description: "List dir", parameters: %{type: "object"}}],
        budget_settings: %{context_window_tokens: 32_000}
      ]

      assert {:ok, prepared} =
               RequestPreparation.prepare(Gemini, messages, "System directive", opts)

      assert prepared.metrics.reserve == 5120
      assert prepared.metrics.instructions > 2
      assert prepared.metrics.transcript > 2
      assert prepared.metrics.tools > 2
      assert prepared.metrics.generation_config > 0
      assert prepared.metrics.estimated_tokens + prepared.metrics.reserve <= 32_000
    end
  end

  describe "Gemini HTTP & SSE transport" do
    test "returns {:error, :no_api_key} without network requests when api_key is missing", ctx do
      assert {:error, :no_api_key} =
               Gemini.chat([%{role: "user", content: "hello"}], "sys",
                 api_key: "",
                 base_url: ctx.base_url
               )

      assert {:error, :no_api_key} =
               Gemini.chat([%{role: "user", content: "hello"}], "sys",
                 api_key: nil,
                 base_url: ctx.base_url
               )

      assert get_requests(ctx.agent) == []
    end

    test "streams SSE (:streamGenerateContent?alt=sse), extracts thought parts vs text, tool calls, and usageMetadata",
         ctx do
      set_handler(ctx.agent, fn conn, _req ->
        conn =
          conn
          |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
          |> Plug.Conn.send_chunked(200)

        sse_payload =
          "data: " <>
            Jason.encode!(%{
              "candidates" => [
                %{
                  "content" => %{
                    "role" => "model",
                    "parts" => [
                      %{"thought" => true, "text" => "Analyzing file layout... "},
                      %{"text" => "Hello "}
                    ]
                  }
                }
              ],
              "usageMetadata" => %{"promptTokenCount" => 40}
            }) <>
            "\r\n\r\n" <>
            "data: " <>
            Jason.encode!(%{
              "candidates" => [
                %{
                  "content" => %{
                    "role" => "model",
                    "parts" => [
                      %{"thought" => true, "text" => "Selecting read_file."},
                      %{"text" => "world 🚀!"},
                      %{
                        "functionCall" => %{
                          "id" => "gem_call_1",
                          "name" => "read_file",
                          "args" => %{"path" => "mix.exs"}
                        }
                      }
                    ]
                  },
                  "finishReason" => "STOP"
                }
              ],
              "usageMetadata" => %{
                "promptTokenCount" => 40,
                "candidatesTokenCount" => 15,
                "thoughtsTokenCount" => 25,
                "totalTokenCount" => 80
              }
            }) <> "\r\n\r\n"

        # Stream in small 7-byte slices to stress UTF-8 & SSE framing
        Stream.unfold(sse_payload, fn
          "" ->
            nil

          bin when byte_size(bin) <= 7 ->
            {bin, ""}

          <<chunk::binary-size(7), rest::binary>> ->
            {chunk, rest}
        end)
        |> Enum.reduce(conn, fn slice, acc_conn ->
          {:ok, next_conn} = Plug.Conn.chunk(acc_conn, slice)
          next_conn
        end)
      end)

      parent = self()

      assert {:ok, resp} =
               Gemini.chat(
                 [%{role: "user", content: "Inspect mix.exs"}],
                 "Be concise",
                 [
                   api_key: "gem-secret-key",
                   base_url: ctx.base_url,
                   model: "gemini-2.5-pro",
                   stream: true
                 ],
                 fn chunk -> send(parent, {:chunk, chunk}) end
               )

      assert resp.text == "Hello world 🚀!"
      assert resp.reasoning == "Analyzing file layout... Selecting read_file."
      assert resp.stop_reason == "STOP"

      assert [%{id: "gem_call_1", name: "read_file", args: %{"path" => "mix.exs"}}] =
               resp.tool_calls

      assert resp.usage == %{
               prompt_tokens: 40,
               completion_tokens: 40,
               thoughts_tokens: 25,
               total_tokens: 80
             }

      chunks = collect_chunks([])
      assert Enum.join(chunks, "") == "Hello world 🚀!"
      refute Enum.join(chunks, "") =~ "Analyzing file layout"

      assert [req] = get_requests(ctx.agent)
      assert req.path == "/v1beta/models/gemini-2.5-pro:streamGenerateContent"
      assert req.query_string == "alt=sse"
      assert req.headers["x-goog-api-key"] == "gem-secret-key"
    end

    test "supports non-streaming (:generateContent) with thought parts and functionCall", ctx do
      set_handler(ctx.agent, fn conn, _req ->
        body = %{
          "candidates" => [
            %{
              "content" => %{
                "role" => "model",
                "parts" => [
                  %{"thought" => true, "text" => "Non-streamed reasoning."},
                  %{"text" => "Completed analysis."},
                  %{
                    "functionCall" => %{
                      "name" => "list_dir",
                      "args" => %{"path" => "lib"}
                    }
                  }
                ]
              },
              "finishReason" => "STOP"
            }
          ],
          "usageMetadata" => %{
            "promptTokenCount" => 22,
            "candidatesTokenCount" => 10,
            "thoughtsTokenCount" => 8,
            "totalTokenCount" => 40
          }
        }

        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(body))
      end)

      parent = self()

      assert {:ok, resp} =
               Gemini.chat(
                 [%{role: "user", content: "List lib"}],
                 "System",
                 [
                   api_key: "gem-nonstream-key",
                   base_url: ctx.base_url,
                   model: "google/gemini-3-pro",
                   stream: false
                 ],
                 fn chunk -> send(parent, {:chunk, chunk}) end
               )

      assert resp.text == "Completed analysis."
      assert resp.reasoning == "Non-streamed reasoning."
      assert [%{name: "list_dir", args: %{"path" => "lib"}}] = resp.tool_calls
      assert resp.usage.prompt_tokens == 22
      assert resp.usage.completion_tokens == 18
      assert resp.usage.total_tokens == 40
      assert_receive {:chunk, "Completed analysis."}

      assert [req] = get_requests(ctx.agent)
      assert req.path == "/v1beta/models/gemini-3-pro:generateContent"
      assert req.query_string == ""
    end

    test "polls cancelled? between SSE chunks and aborts cleanly with partial output", ctx do
      counter = start_supervised!({Agent, fn -> 0 end}, id: :cancel_counter)

      set_handler(ctx.agent, fn conn, _req ->
        conn =
          conn
          |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
          |> Plug.Conn.send_chunked(200)

        chunk1 =
          "data: " <>
            Jason.encode!(%{
              "candidates" => [%{"content" => %{"parts" => [%{"text" => "First part"}]}}]
            }) <> "\n\n"

        chunk2 =
          "data: " <>
            Jason.encode!(%{
              "candidates" => [%{"content" => %{"parts" => [%{"text" => " second part"}]}}]
            }) <> "\n\n"

        {:ok, conn} = Plug.Conn.chunk(conn, chunk1)

        case Plug.Conn.chunk(conn, chunk2) do
          {:ok, conn} -> conn
          {:error, _} -> conn
        end
      end)

      cancelled? = fn ->
        count = Agent.get_and_update(counter, &{&1, &1 + 1})
        count >= 2
      end

      assert {:ok, resp} =
               Gemini.chat(
                 [%{role: "user", content: "Cancel me"}],
                 "",
                 api_key: "gem-cancel-key",
                 base_url: ctx.base_url,
                 cancelled?: cancelled?
               )

      assert resp.stop_reason == :cancelled
      assert resp.text == "First part"
    end

    test "classifies HTTP errors and redacts API key from error payloads", ctx do
      set_handler(ctx.agent, fn conn, _req ->
        Plug.Conn.send_resp(conn, 401, "Invalid credential gem-secret-xyz")
      end)

      assert {:error, %{status: 401, kind: :auth, body: body}} =
               Gemini.chat([%{role: "user", content: "hi"}], "",
                 api_key: "gem-secret-xyz",
                 base_url: ctx.base_url,
                 stream: true
               )

      refute body =~ "gem-secret-xyz"
      assert body =~ "[REDACTED]"
    end
  end

  describe "LLM gateway & ModelRoute wiring + invariants" do
    test "preserves LLM.effective_provider(\"openai\", \"gemini-3.7-flash-high\") == \"openai\" and exact v1 policy digest" do
      assert LLM.effective_provider("openai", "gemini-3.7-flash-high") == "openai"
      assert LLM.effective_provider("gemini", "gemini-2.5-pro") == "gemini"
      assert LLM.effective_provider("google", "gemini-2.5-pro") == "gemini"

      assert {:ok, policy} = Policy.from_settings(%{})

      assert policy["model_route_sha256"] ==
               "534796b017880f757da49ce898f1c150d6550ea6c407142f115e52cf65e7eb0d"
    end

    test "ModelRoute resolves gemini routes with default base_url and gemini_api_key/google_api_key",
         ctx do
      policy = %{"model_provider" => "gemini", "model_name" => "gemini-2.5-pro"}
      settings = %{gemini_api_key: "gem-live-key"}

      assert {:ok, stamped} = ModelRoute.put_digest(policy, settings)
      assert is_binary(stamped["model_route_sha256"])

      assert {:ok, route} = ModelRoute.resolve(stamped, settings)
      assert route["provider"] == "gemini"
      assert route["base_url"] == "https://generativelanguage.googleapis.com/v1beta"
      assert route["api_key"] == "gem-live-key"
      assert route["thinking_budget"] == 4_096

      google_settings = %{"google_api_key" => "goog-fallback-key"}
      assert {:ok, google_route} = ModelRoute.resolve(stamped, google_settings)
      assert google_route["api_key"] == "goog-fallback-key"

      # Route end-to-end through LLM.chat with resolved_route
      set_handler(ctx.agent, fn conn, _req ->
        conn =
          conn
          |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
          |> Plug.Conn.send_chunked(200)

        sse =
          "data: " <>
            Jason.encode!(%{
              "candidates" => [
                %{
                  "content" => %{"role" => "model", "parts" => [%{"text" => "Routed Gemini OK"}]},
                  "finishReason" => "STOP"
                }
              ],
              "usageMetadata" => %{
                "promptTokenCount" => 10,
                "candidatesTokenCount" => 4,
                "totalTokenCount" => 14
              }
            }) <> "\n\n"

        {:ok, conn} = Plug.Conn.chunk(conn, sse)
        conn
      end)

      local_settings = %{
        gemini_api_key: "routed-secret",
        gemini_base_url: ctx.base_url
      }

      assert {:ok, local_stamped} = ModelRoute.put_digest(policy, local_settings)
      assert {:ok, local_route} = ModelRoute.resolve(local_stamped, local_settings)

      assert {:ok, resp} =
               LLM.chat(
                 [%{role: "user", content: "Ping native Gemini"}],
                 "System prompt",
                 nil,
                 fn _chunk -> :ok end,
                 resolved_route: local_route,
                 allowed_tools: []
               )

      assert resp.text == "Routed Gemini OK"
      assert resp.usage.total_tokens == 14
    end
  end

  defp collect_chunks(acc) do
    receive do
      {:chunk, c} -> collect_chunks([c | acc])
    after
      20 -> Enum.reverse(acc)
    end
  end
end
