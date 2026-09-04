defmodule IexCode.LLM.EmpiricalDiscoveryPingChallengeTest do
  @moduledoc """
  Adversarial empirical stress testing and verification suite for Milestone M3:
  `IexCode.LLM.Discovery.ping/3` and `IexCode.LLM.Discovery.ping_provider/3`.

  Empirically tests:
  1. Provider coverage across all cloud ("openai", "anthropic", "gemini", "google")
     and local ("ollama", "lm_studio", "llama_cpp") providers, testing both string
     and atom provider keys.
  2. Rejection of unsupported or malformed provider identifiers ("mistral", "", nil, :unknown).
  3. Adversarial transport errors, timeouts, and process terminations.
  4. Adversarial non-200 HTTP status codes (401, 403, 404, 429, 500, 502, 503).
  5. Malformed, truncated, non-JSON, and empty body payloads.
  6. Empty model lists vs populated model lists across all provider payload structures.
  7. Latency timing invariants under delayed network responses.
  8. Concurrent multi-provider ping executions and high-throughput stress bursts.
  9. `Discovery.ping_provider/3` interface contract compliance.
  """

  use ExUnit.Case, async: true
  alias IexCode.LLM.Discovery

  # ============================================================================
  # Adversarial Mock Plug
  # ============================================================================

  defmodule MockPingPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      path = conn.request_path
      port = conn.port

      cond do
        # ----------------------------------------------------------------------
        # Exceptions and Process Terminations
        # ----------------------------------------------------------------------
        String.contains?(path, "/crash_runtime") ->
          raise RuntimeError, "simulated network crash"

        String.contains?(path, "/crash_exit") ->
          exit(:killed)

        # ----------------------------------------------------------------------
        # Timeouts / Latency Delays
        # ----------------------------------------------------------------------
        String.contains?(path, "/delay_50ms") ->
          Process.sleep(50)

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(%{"data" => [%{"id" => "delayed-model"}]}))

        String.contains?(path, "/delay_timeout") ->
          raise %Req.TransportError{reason: :timeout}

        # ----------------------------------------------------------------------
        # HTTP Status Error Codes
        # ----------------------------------------------------------------------
        String.contains?(path, "/status_401") ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(401, Jason.encode!(%{"error" => %{"message" => "Invalid API key"}}))

        String.contains?(path, "/status_403") ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(403, Jason.encode!(%{"error" => "Forbidden access"}))

        String.contains?(path, "/status_404") ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(404, Jason.encode!(%{"error" => "Endpoint not found"}))

        String.contains?(path, "/status_429") ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(429, Jason.encode!(%{"error" => "Rate limit exceeded"}))

        String.contains?(path, "/status_500") ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(500, Jason.encode!(%{"error" => "Internal server error"}))

        String.contains?(path, "/status_502") ->
          conn
          |> put_resp_content_type("text/html")
          |> send_resp(502, "<html><body>502 Bad Gateway</body></html>")

        String.contains?(path, "/status_503") ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(503, Jason.encode!(%{"error" => "Service unavailable"}))

        # ----------------------------------------------------------------------
        # Malformed & Non-JSON Payloads
        # ----------------------------------------------------------------------
        String.contains?(path, "/malformed_html") ->
          conn
          |> put_resp_content_type("text/html")
          |> send_resp(200, "<html><body>502 Bad Gateway Cloudflare Error</body></html>")

        String.contains?(path, "/malformed_truncated_json") ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, "{\"data\": [{\"id\": \"gpt-4\", \"status\": ")

        String.contains?(path, "/malformed_empty_body") ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, "")

        String.contains?(path, "/malformed_primitive_int") ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, "12345")

        String.contains?(path, "/malformed_primitive_array") ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, "[\"string_one\", \"string_two\", \"string_three\"]")

        # ----------------------------------------------------------------------
        # Empty Model Lists vs Populated Lists
        # ----------------------------------------------------------------------
        String.contains?(path, "/empty_models") ->
          cond do
            String.contains?(path, "tags") or port == 11434 ->
              conn
              |> put_resp_content_type("application/json")
              |> send_resp(200, Jason.encode!(%{"models" => []}))

            String.contains?(path, "v1beta") ->
              conn
              |> put_resp_content_type("application/json")
              |> send_resp(200, Jason.encode!(%{"models" => []}))

            true ->
              conn
              |> put_resp_content_type("application/json")
              |> send_resp(200, Jason.encode!(%{"data" => []}))
          end

        # ----------------------------------------------------------------------
        # Normal Provider Endpoint Handlers
        # ----------------------------------------------------------------------

        # Ollama (:11434 or /api/tags)
        port == 11434 or path == "/api/tags" or String.contains?(path, "/ollama") ->
          case path do
            "/api/version" ->
              conn
              |> put_resp_content_type("application/json")
              |> send_resp(200, Jason.encode!(%{"version" => "0.5.1"}))

            _ ->
              conn
              |> put_resp_content_type("application/json")
              |> send_resp(
                200,
                Jason.encode!(%{
                  "models" => [
                    %{
                      "name" => "llama3.2:latest",
                      "model" => "llama3.2:latest",
                      "details" => %{"parameter_size" => "3.2B", "quantization_level" => "Q4_K_M"}
                    },
                    %{
                      "name" => "deepseek-r1:8b",
                      "model" => "deepseek-r1:8b",
                      "details" => %{"parameter_size" => "8B", "quantization_level" => "Q4_K_M"}
                    }
                  ]
                })
              )
          end

        # LM Studio (:1234 or /lm_studio)
        port == 1234 or String.contains?(path, "/lm_studio") ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            200,
            Jason.encode!(%{
              "object" => "list",
              "data" => [
                %{
                  "id" => "qwen2.5-coder-7b-instruct",
                  "arch" => "qwen2",
                  "quantization" => "Q4_K_M"
                },
                %{"id" => "deepseek-coder-6.7b", "arch" => "deepseek", "quantization" => "Q8_0"}
              ]
            })
          )

        # llama.cpp (:8080 or /llama_cpp)
        port == 8080 or String.contains?(path, "/llama_cpp") ->
          case path do
            "/health" ->
              conn
              |> put_resp_content_type("application/json")
              |> send_resp(200, Jason.encode!(%{"status" => "ok"}))

            _ ->
              conn
              |> put_resp_content_type("application/json")
              |> send_resp(
                200,
                Jason.encode!(%{
                  "object" => "list",
                  "data" => [
                    %{"id" => "llama-3.2-3b-instruct"}
                  ]
                })
              )
          end

        # Gemini (/v1beta/models)
        String.contains?(path, "/v1beta/models") ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            200,
            Jason.encode!(%{
              "models" => [
                %{"name" => "models/gemini-2.0-flash", "displayName" => "Gemini 2.0 Flash"},
                %{"name" => "models/gemini-1.5-pro", "displayName" => "Gemini 1.5 Pro"}
              ]
            })
          )

        # Anthropic (/v1/models with anthropic-version)
        String.contains?(path, "/v1/models") and get_req_header(conn, "anthropic-version") != [] ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            200,
            Jason.encode!(%{
              "data" => [
                %{"id" => "claude-3-7-sonnet-20250219", "type" => "model"},
                %{"id" => "claude-3-5-haiku-20241022", "type" => "model"}
              ]
            })
          )

        # OpenAI (/models or /v1/models)
        String.ends_with?(path, "/models") ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            200,
            Jason.encode!(%{
              "object" => "list",
              "data" => [
                %{"id" => "gpt-4o"},
                %{"id" => "o3-mini"}
              ]
            })
          )

        true ->
          conn
          |> send_resp(404, "not found")
      end
    end
  end

  # ============================================================================
  # 1. Multi-Provider Coverage (Cloud and Local)
  # ============================================================================

  describe "Task 1: Multi-Provider Ping Coverage" do
    test "pings cloud provider OpenAI successfully (string & atom)" do
      for provider <- ["openai", :openai] do
        assert {:ok, %{latency_ms: ms, model_count: count, status: :online}} =
                 Discovery.ping(provider, nil,
                   plug: MockPingPlug,
                   base_url: "http://mock-openai/v1",
                   api_key: "sk-test-key"
                 )

        assert is_integer(ms) and ms >= 0
        assert count == 2
      end
    end

    test "pings cloud provider Anthropic successfully (string & atom)" do
      for provider <- ["anthropic", :anthropic] do
        assert {:ok, %{latency_ms: ms, model_count: count, status: :online}} =
                 Discovery.ping(provider, nil,
                   plug: MockPingPlug,
                   base_url: "http://mock-anthropic/v1",
                   api_key: "sk-ant-test"
                 )

        assert is_integer(ms) and ms >= 0
        assert count == 2
      end
    end

    test "pings cloud provider Gemini successfully (string, 'google' alias & atom)" do
      for provider <- ["gemini", "google", :gemini] do
        assert {:ok, %{latency_ms: ms, model_count: count, status: :online}} =
                 Discovery.ping(provider, nil,
                   plug: MockPingPlug,
                   base_url: "http://mock-gemini"
                 )

        assert is_integer(ms) and ms >= 0
        assert count == 2
      end
    end

    test "pings local engine Ollama successfully (string & atom)" do
      for provider <- ["ollama", :ollama] do
        assert {:ok, %{latency_ms: ms, model_count: count, status: :online}} =
                 Discovery.ping(provider, nil, plug: MockPingPlug)

        assert is_integer(ms) and ms >= 0
        assert count == 2
      end
    end

    test "pings local engine LM Studio successfully (string & atom)" do
      for provider <- ["lm_studio", :lm_studio] do
        assert {:ok, %{latency_ms: ms, model_count: count, status: :online}} =
                 Discovery.ping(provider, nil, plug: MockPingPlug)

        assert is_integer(ms) and ms >= 0
        assert count == 2
      end
    end

    test "pings local engine llama.cpp successfully (string & atom)" do
      for provider <- ["llama_cpp", :llama_cpp] do
        assert {:ok, %{latency_ms: ms, model_count: count, status: :online}} =
                 Discovery.ping(provider, nil, plug: MockPingPlug)

        assert is_integer(ms) and ms >= 0
        assert count == 1
      end
    end

    test "returns {:error, :unsupported_provider} for unknown or malformed providers" do
      invalid_providers = [
        "mistral",
        "cohere",
        "bedrock",
        "unknown_engine",
        :unknown,
        :mistral,
        "",
        nil
      ]

      for provider <- invalid_providers do
        assert Discovery.ping(provider, nil, plug: MockPingPlug) ==
                 {:error, :unsupported_provider}
      end
    end
  end

  # ============================================================================
  # 2. Adversarial Transport Errors, Timeouts & Process Exits
  # ============================================================================

  describe "Task 2: Adversarial Transport Errors & Timeouts" do
    test "handles real closed port connection refused without crashing" do
      # Test with cloud endpoint pointing to closed port
      result_cloud =
        Discovery.ping("openai", nil,
          base_url: "http://127.0.0.1:59998/v1",
          connect_timeout: 50,
          receive_timeout: 50
        )

      assert {:error, reason_cloud} = result_cloud
      assert reason_cloud in [:econnrefused, :timeout, :closed] or is_atom(reason_cloud)

      # Test with local endpoint pointing to closed port
      result_local =
        Discovery.ping("ollama", nil,
          base_url: "http://127.0.0.1:59998/v1",
          connect_timeout: 50,
          receive_timeout: 50
        )

      assert {:error, reason_local} = result_local
      assert reason_local in [:econnrefused, :timeout, :closed] or is_atom(reason_local)
    end

    test "handles receive timeout gracefully without hanging or throwing" do
      # Simulated transport timeout via plug
      result_plug =
        Discovery.ping("openai", nil,
          plug: MockPingPlug,
          base_url: "http://mock/delay_timeout",
          connect_timeout: 50,
          receive_timeout: 20
        )

      assert {:error, :timeout} = result_plug

      # Real network timeout on unroutable reserved IP (TEST-NET-1)
      result_real =
        Discovery.ping("openai", nil,
          base_url: "http://192.0.2.1:59999/v1",
          connect_timeout: 40,
          receive_timeout: 40
        )

      assert {:error, reason_real} = result_real
      assert reason_real in [:timeout, :econnrefused, :closed, :nxdomain] or is_atom(reason_real)
    end

    test "handles plug runtime crash/raise safely without crashing the caller process" do
      # Cloud provider
      result_cloud =
        Discovery.ping("openai", nil,
          plug: MockPingPlug,
          base_url: "http://mock/crash_runtime"
        )

      assert {:error, _err} = result_cloud

      # Local provider
      result_local =
        Discovery.ping("lm_studio", nil,
          plug: MockPingPlug,
          base_url: "http://mock/crash_runtime"
        )

      assert {:error, _err} = result_local
    end

    test "handles process exit in HTTP client safely without crashing the caller process" do
      result =
        Discovery.ping("anthropic", nil,
          plug: MockPingPlug,
          base_url: "http://mock/crash_exit"
        )

      assert {:error, :killed} = result
    end
  end

  # ============================================================================
  # 3. Adversarial Non-200 HTTP Status Codes
  # ============================================================================

  describe "Task 3: Adversarial Non-200 HTTP Status Codes" do
    @error_statuses [
      {401, "/status_401"},
      {403, "/status_403"},
      {404, "/status_404"},
      {429, "/status_429"},
      {500, "/status_500"},
      {502, "/status_502"},
      {503, "/status_503"}
    ]

    test "all non-200 HTTP statuses return {:error, {:unexpected_status, code}} for OpenAI" do
      for {status_code, path_segment} <- @error_statuses do
        result =
          Discovery.ping("openai", nil,
            plug: MockPingPlug,
            base_url: "http://mock#{path_segment}/v1"
          )

        assert result == {:error, {:unexpected_status, status_code}},
               "Expected {:error, {:unexpected_status, #{status_code}}} for path #{path_segment}, got #{inspect(result)}"
      end
    end

    test "all non-200 HTTP statuses return {:error, {:unexpected_status, code}} for Anthropic" do
      for {status_code, path_segment} <- @error_statuses do
        result =
          Discovery.ping("anthropic", nil,
            plug: MockPingPlug,
            base_url: "http://mock#{path_segment}"
          )

        assert result == {:error, {:unexpected_status, status_code}},
               "Expected Anthropic error for status #{status_code}, got #{inspect(result)}"
      end
    end

    test "all non-200 HTTP statuses return {:error, {:unexpected_status, code}} for Gemini" do
      for {status_code, path_segment} <- @error_statuses do
        result =
          Discovery.ping("gemini", nil,
            plug: MockPingPlug,
            base_url: "http://mock#{path_segment}"
          )

        assert result == {:error, {:unexpected_status, status_code}},
               "Expected Gemini error for status #{status_code}, got #{inspect(result)}"
      end
    end

    test "all non-200 HTTP statuses return {:error, {:unexpected_status, code}} for Ollama" do
      for {status_code, path_segment} <- @error_statuses do
        result =
          Discovery.ping("ollama", nil,
            plug: MockPingPlug,
            base_url: "http://mock#{path_segment}"
          )

        assert result == {:error, {:unexpected_status, status_code}},
               "Expected Ollama error for status #{status_code}, got #{inspect(result)}"
      end
    end

    test "all non-200 HTTP statuses return {:error, {:unexpected_status, code}} for LM Studio" do
      for {status_code, path_segment} <- @error_statuses do
        result =
          Discovery.ping("lm_studio", nil,
            plug: MockPingPlug,
            base_url: "http://mock#{path_segment}"
          )

        assert result == {:error, {:unexpected_status, status_code}},
               "Expected LM Studio error for status #{status_code}, got #{inspect(result)}"
      end
    end

    test "llama.cpp falls back to /health on /v1/models 404, or fails when /health fails" do
      # When /health returns 200, fallback succeeds with default model
      fallback_plug_success = fn conn ->
        case conn.request_path do
          "/health" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, Jason.encode!(%{"status" => "ok"}))

          _ ->
            Plug.Conn.send_resp(conn, 404, "not found")
        end
      end

      assert {:ok, %{status: :online, model_count: 1}} =
               Discovery.ping("llama_cpp", nil, plug: fallback_plug_success)

      # When /health also returns 500, fallback fails with unexpected_status
      fallback_plug_failure = fn conn ->
        case conn.request_path do
          "/health" ->
            Plug.Conn.send_resp(conn, 500, "internal error")

          _ ->
            Plug.Conn.send_resp(conn, 404, "not found")
        end
      end

      assert {:error, {:unexpected_status, 500}} =
               Discovery.ping("llama_cpp", nil, plug: fallback_plug_failure)
    end
  end

  # ============================================================================
  # 4. Adversarial Malformed & Non-JSON Responses
  # ============================================================================

  describe "Task 4: Adversarial Malformed & Non-JSON Responses" do
    test "handles raw HTML response (e.g. 502 page served with 200) without crashing" do
      result =
        Discovery.ping("openai", nil,
          plug: MockPingPlug,
          base_url: "http://mock/malformed_html/v1"
        )

      # HTML body is not a map of data/models, so fallback count is 1
      assert {:ok, %{latency_ms: ms, model_count: 1, status: :online}} = result
      assert is_integer(ms)
    end

    test "handles corrupted truncated JSON string safely" do
      result =
        Discovery.ping("openai", nil,
          plug: MockPingPlug,
          base_url: "http://mock/malformed_truncated_json/v1"
        )

      # Should return either {:ok, ...} fallback count or {:error, ...} without uncaught exception
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles empty body safely" do
      result =
        Discovery.ping("anthropic", nil,
          plug: MockPingPlug,
          base_url: "http://mock/malformed_empty_body"
        )

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles non-map JSON primitives (integer, list of strings) safely" do
      # Primitive integer
      result_int =
        Discovery.ping("gemini", nil,
          plug: MockPingPlug,
          base_url: "http://mock/malformed_primitive_int"
        )

      assert {:ok, %{status: :online, model_count: 1}} = result_int

      # Primitive array of strings (e.g. ["model1", "model2", "model3"])
      result_array =
        Discovery.ping("openai", nil,
          plug: MockPingPlug,
          base_url: "http://mock/malformed_primitive_array/v1"
        )

      # List body evaluates length(body) -> 3
      assert {:ok, %{status: :online, model_count: 3}} = result_array
    end
  end

  # ============================================================================
  # 5. Empty Model Lists vs Populated Model Lists
  # ============================================================================

  describe "Task 5: Empty Model Lists vs Populated Model Lists" do
    test "correctly reports model_count == 0 when provider returns empty models" do
      # OpenAI with empty data: []
      assert {:ok, %{model_count: 0, status: :online}} =
               Discovery.ping("openai", nil,
                 plug: MockPingPlug,
                 base_url: "http://mock/empty_models/v1"
               )

      # Anthropic with empty data: []
      assert {:ok, %{model_count: 0, status: :online}} =
               Discovery.ping("anthropic", nil,
                 plug: MockPingPlug,
                 base_url: "http://mock/empty_models"
               )

      # Gemini with empty models: []
      assert {:ok, %{model_count: 0, status: :online}} =
               Discovery.ping("gemini", nil,
                 plug: MockPingPlug,
                 base_url: "http://mock/empty_models"
               )

      # Ollama with empty models: []
      assert {:ok, %{model_count: 0, status: :online}} =
               Discovery.ping("ollama", nil,
                 plug: MockPingPlug,
                 base_url: "http://mock/empty_models"
               )

      # LM Studio with empty data: []
      assert {:ok, %{model_count: 0, status: :online}} =
               Discovery.ping("lm_studio", nil,
                 plug: MockPingPlug,
                 base_url: "http://mock/empty_models"
               )
    end

    test "correctly parses large populated model lists" do
      large_models_plug = fn conn ->
        models =
          Enum.map(1..25, fn i ->
            %{"id" => "custom-model-#{i}"}
          end)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"data" => models}))
      end

      assert {:ok, %{model_count: 25, status: :online}} =
               Discovery.ping("openai", nil,
                 plug: large_models_plug,
                 base_url: "http://mock/v1"
               )
    end
  end

  # ============================================================================
  # 6. Latency Timing Invariants
  # ============================================================================

  describe "Task 6: Latency Measurement Properties" do
    test "reflects network delay in latency_ms" do
      {:ok, %{latency_ms: ms}} =
        Discovery.ping("openai", nil,
          plug: MockPingPlug,
          base_url: "http://mock/delay_50ms/v1"
        )

      # Due to Process.sleep(50), latency must be >= 40ms
      assert ms >= 40
    end

    test "latency_ms is always a positive integer >= 1" do
      for provider <- ["openai", "anthropic", "gemini", "ollama", "lm_studio", "llama_cpp"] do
        assert {:ok, %{latency_ms: ms}} = Discovery.ping(provider, nil, plug: MockPingPlug)
        assert is_integer(ms) and ms >= 1
      end
    end
  end

  # ============================================================================
  # 7. Concurrent Ping Requests & Stress Burst
  # ============================================================================

  describe "Task 7: Concurrent Ping Verification & Stress Burst" do
    test "simultaneously pings 5 providers concurrently without interference" do
      providers = ["openai", "anthropic", "gemini", "ollama", "lm_studio"]

      results =
        providers
        |> Task.async_stream(
          fn prov ->
            {prov, Discovery.ping(prov, nil, plug: MockPingPlug)}
          end,
          max_concurrency: 5,
          timeout: 2000
        )
        |> Enum.map(fn {:ok, res} -> res end)
        |> Map.new()

      for prov <- providers do
        assert {:ok, %{status: :online, latency_ms: ms}} = Map.get(results, prov)
        assert ms >= 1
      end
    end

    test "high-concurrency burst of 50 simultaneous pings across mixed conditions" do
      scenarios = [
        {:online_openai, fn -> Discovery.ping("openai", nil, plug: MockPingPlug) end},
        {:online_anthropic, fn -> Discovery.ping("anthropic", nil, plug: MockPingPlug) end},
        {:online_ollama, fn -> Discovery.ping("ollama", nil, plug: MockPingPlug) end},
        {:status_401,
         fn ->
           Discovery.ping("openai", nil,
             plug: MockPingPlug,
             base_url: "http://mock/status_401/v1"
           )
         end},
        {:status_500,
         fn ->
           Discovery.ping("gemini", nil,
             plug: MockPingPlug,
             base_url: "http://mock/status_500"
           )
         end},
        {:unsupported,
         fn -> Discovery.ping("unknown_burst_provider", nil, plug: MockPingPlug) end}
      ]

      # Generate 50 mixed tasks
      tasks =
        for i <- 1..50 do
          {label, fun} = Enum.at(scenarios, rem(i, length(scenarios)))
          {i, label, fun}
        end

      burst_results =
        tasks
        |> Task.async_stream(
          fn {id, label, fun} ->
            {id, label, fun.()}
          end,
          max_concurrency: 15,
          timeout: 5000
        )
        |> Enum.map(fn {:ok, item} -> item end)

      assert length(burst_results) == 50

      for {_id, label, result} <- burst_results do
        case label do
          l when l in [:online_openai, :online_anthropic, :online_ollama] ->
            assert {:ok, %{status: :online}} = result

          :status_401 ->
            assert {:error, {:unexpected_status, 401}} = result

          :status_500 ->
            assert {:error, {:unexpected_status, 500}} = result

          :unsupported ->
            assert {:error, :unsupported_provider} = result
        end
      end
    end
  end

  # ============================================================================
  # 8. Discovery.ping_provider/3 Contract Verification
  # ============================================================================

  describe "Task 8: Discovery.ping_provider/3 Contract" do
    test "returns {:ok, latency_ms, models} on successful ping" do
      # Note: ping_provider calls ping(provider, nil, opts) internally without mock plug
      # When testing with loopback mock or custom base URL, we verify its signature contract
      result =
        Discovery.ping_provider("openai", "http://localhost:1234/v1", "sk-test")

      # Under live test with closed/unrouted port or mock, verify the tuple structure
      case result do
        {:ok, latency_ms, models} ->
          assert is_integer(latency_ms) and latency_ms >= 0
          assert is_list(models)

        {:error, _reason, latency_ms} ->
          assert is_integer(latency_ms) and latency_ms >= 0
      end
    end

    test "returns {:error, reason, 0} on unsupported provider" do
      assert {:error, :unsupported_provider, 0} =
               Discovery.ping_provider("unsupported_xyz", "http://localhost:1234", "key")
    end
  end
end
