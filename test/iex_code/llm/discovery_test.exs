defmodule IexCode.LLM.DiscoveryTest do
  use ExUnit.Case, async: true

  alias IexCode.Execution.ModelRoute
  alias IexCode.LLM
  alias IexCode.LLM.Discovery
  alias IexCode.LLM.Discovery.Server, as: DiscoveryServer
  alias IexCode.LLM.OpenAI

  # Plug for simulating Ollama, LM Studio, and llama.cpp endpoints
  defmodule MockDiscoveryPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      case {conn.method, conn.request_path, conn.port} do
        # Ollama (:11434)
        {"GET", "/api/tags", 11434} ->
          body = %{
            "models" => [
              %{
                "name" => "llama3.2:latest",
                "model" => "llama3.2:latest",
                "size" => 2_019_393_189,
                "details" => %{
                  "parameter_size" => "3.2B",
                  "quantization_level" => "Q4_K_M",
                  "family" => "llama",
                  "format" => "gguf"
                }
              },
              %{
                "name" => "qwen2.5-coder:7b",
                "model" => "qwen2.5-coder:7b",
                "size" => 4_683_074_368,
                "details" => %{
                  "parameter_size" => "7.6B",
                  "quantization_level" => "Q4_K_M",
                  "family" => "qwen2",
                  "format" => "gguf"
                }
              }
            ]
          }

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(body))

        {"GET", "/api/version", 11434} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(%{"version" => "0.5.1"}))

        # LM Studio (:1234)
        {"GET", "/v1/models", 1234} ->
          body = %{
            "object" => "list",
            "data" => [
              %{
                "id" => "qwen2.5-coder-7b-instruct",
                "arch" => "qwen2",
                "quantization" => "Q4_K_M",
                "compatibility_type" => "gguf"
              }
            ]
          }

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(body))

        # llama.cpp (:8080)
        {"GET", "/v1/models", 8080} ->
          body = %{
            "object" => "list",
            "data" => [
              %{
                "id" => "llama-3.2-3b-instruct"
              }
            ]
          }

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(body))

        {"GET", "/health", 8080} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(%{"status" => "ok"}))

        # Simulated slow endpoint for timeout testing
        {"GET", "/slow", _} ->
          Process.sleep(100)
          send_resp(conn, 200, "ok")

        _ ->
          send_resp(conn, 404, "not found")
      end
    end
  end

  defmodule LlamaCppFallbackPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      case {conn.method, conn.request_path} do
        {"GET", "/v1/models"} ->
          # Returns empty list or 404
          send_resp(conn, 404, "not found")

        {"GET", "/health"} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(%{"status" => "ok"}))

        _ ->
          send_resp(conn, 404, "not found")
      end
    end
  end

  describe "Endpoint and provider classification" do
    test "is_local_endpoint? correctly detects loopback URLs" do
      assert Discovery.is_local_endpoint?("http://localhost:11434")
      assert Discovery.is_local_endpoint?("http://localhost:11434/v1")
      assert Discovery.is_local_endpoint?("http://127.0.0.1:1234")
      assert Discovery.is_local_endpoint?("http://127.0.0.1:8080/v1")
      assert Discovery.is_local_endpoint?("http://0.0.0.0:8080")
      assert Discovery.is_local_endpoint?("http://[::1]:11434")

      refute Discovery.is_local_endpoint?("https://api.openai.com/v1")
      refute Discovery.is_local_endpoint?("https://cli.llmotions.com/v1")
      refute Discovery.is_local_endpoint?("https://api.anthropic.com")
      refute Discovery.is_local_endpoint?("http://192.168.1.50:8080")
      refute Discovery.is_local_endpoint?(nil)
      refute Discovery.is_local_endpoint?("")
      refute Discovery.is_local_endpoint?(12345)
    end

    test "is_local_provider? correctly identifies local engines" do
      assert Discovery.is_local_provider?("ollama")
      assert Discovery.is_local_provider?("lm_studio")
      assert Discovery.is_local_provider?("llama_cpp")
      assert Discovery.is_local_provider?(:ollama)
      assert Discovery.is_local_provider?(:lm_studio)
      assert Discovery.is_local_provider?(:llama_cpp)

      refute Discovery.is_local_provider?("openai")
      refute Discovery.is_local_provider?("anthropic")
      refute Discovery.is_local_provider?(:openai)
      refute Discovery.is_local_provider?(nil)
    end

    test "default_base_url returns expected ports" do
      assert Discovery.default_base_url("ollama") == "http://localhost:11434/v1"
      assert Discovery.default_base_url("lm_studio") == "http://localhost:1234/v1"
      assert Discovery.default_base_url("llama_cpp") == "http://localhost:8080/v1"
      assert Discovery.default_base_url(:ollama) == "http://localhost:11434/v1"
      assert Discovery.default_base_url("unknown") == nil
    end
  end

  describe "Probing and Model Normalization" do
    test "probe_all successfully discovers Ollama, LM Studio, and llama.cpp" do
      {:ok, servers} = Discovery.probe_all(plug: MockDiscoveryPlug)

      assert length(servers) == 3

      ollama = Enum.find(servers, &(&1.provider == "ollama"))
      assert ollama.online == true
      assert ollama.version == "0.5.1"
      assert length(ollama.models) == 2

      llama_model = Enum.find(ollama.models, &(&1.id == "llama3.2:latest"))
      assert llama_model.provider == "ollama"
      assert llama_model.parameter_size == "3.2B"
      assert llama_model.quantization == "Q4_K_M"
      assert llama_model.format == "gguf"
      assert llama_model.size_bytes == 2_019_393_189
      assert llama_model.base_url == "http://localhost:11434/v1"

      lm_studio = Enum.find(servers, &(&1.provider == "lm_studio"))
      assert lm_studio.online == true
      assert length(lm_studio.models) == 1
      qwen = List.first(lm_studio.models)
      assert qwen.id == "qwen2.5-coder-7b-instruct"
      assert qwen.provider == "lm_studio"
      assert qwen.parameter_size == "qwen2"
      assert qwen.quantization == "Q4_K_M"

      llama_cpp = Enum.find(servers, &(&1.provider == "llama_cpp"))
      assert llama_cpp.online == true
      assert length(llama_cpp.models) == 1
      assert List.first(llama_cpp.models).id == "llama-3.2-3b-instruct"

      # Verify discovered_models extraction
      models = Discovery.discovered_models(servers)
      assert length(models) == 4
      assert Enum.map(models, & &1.id) |> Enum.member?("llama3.2:latest")
      assert Enum.map(models, & &1.id) |> Enum.member?("qwen2.5-coder-7b-instruct")
    end

    test "llama.cpp falls back to /health if /v1/models returns 404" do
      target = %{
        id: "llama_cpp",
        name: "llama.cpp",
        port: 8080,
        base_url: "http://localhost:8080/v1",
        probe_url: "http://localhost:8080/v1/models",
        health_url: "http://localhost:8080/health",
        version_url: nil
      }

      result = Discovery.probe_target(target, plug: LlamaCppFallbackPlug)
      assert result.online == true
      assert length(result.models) == 1
      assert List.first(result.models).id == "default"
    end

    test "handles offline server on closed port with fast failure" do
      offline_target = %{
        id: "offline_test",
        name: "Offline Test Server",
        port: 59998,
        base_url: "http://localhost:59998/v1",
        probe_url: "http://localhost:59998/api/tags",
        version_url: nil
      }

      {time_us, result} =
        :timer.tc(fn ->
          Discovery.probe_target(offline_target, connect_timeout: 300, receive_timeout: 400)
        end)

      # Should fail fast without blocking
      assert div(time_us, 1000) < 500
      assert result.online == false
      assert result.models == []
      assert result.error != nil
    end

    test "handles timeouts gracefully without crashing" do
      slow_target = %{
        id: "slow_server",
        name: "Slow Server",
        port: 9999,
        base_url: "http://localhost:9999/v1",
        probe_url: "http://localhost:9999/slow",
        version_url: nil
      }

      result = Discovery.probe_target(slow_target, plug: MockDiscoveryPlug, receive_timeout: 10)
      assert result.online == false
      assert result.models == []
    end
  end

  describe "Discovery.Server GenServer" do
    test "starts, caches probe status and models, and allows rescan with PubSub" do
      server_name = :"discovery_server_test_#{System.unique_integer([:positive])}"

      # Subscribe to PubSub topic
      Phoenix.PubSub.subscribe(IexCode.PubSub, "llm:discovery")

      {:ok, pid} =
        DiscoveryServer.start_link(
          name: server_name,
          enabled: false,
          probe_opts: [plug: MockDiscoveryPlug]
        )

      # Initially offline before scan
      assert DiscoveryServer.get_discovered_models(pid) == []
      servers = DiscoveryServer.get_status(pid)
      assert length(servers) == 3
      assert Enum.all?(servers, &(&1.online == false))

      # Trigger rescan
      {:ok, models} = DiscoveryServer.rescan(pid)
      assert length(models) == 4

      # Check state was cached
      assert length(DiscoveryServer.get_discovered_models(pid)) == 4
      updated_servers = DiscoveryServer.get_status(pid)
      assert Enum.all?(updated_servers, &(&1.online == true))

      # Check PubSub broadcast was received
      assert_receive {:local_models_discovered, received_models}, 1000
      assert length(received_models) == 4
    end
  end

  describe "Zero-Config Local Provider Routing" do
    test "LLM.effective_provider normalizes local providers" do
      assert LLM.effective_provider("ollama", "llama3.2") == "ollama"
      assert LLM.effective_provider("lm_studio", "qwen") == "lm_studio"
      assert LLM.effective_provider("llama_cpp", "llama") == "llama_cpp"
      assert LLM.effective_provider(:ollama, "llama3.2") == "ollama"
    end

    test "ModelRoute.resolve supplies 'local' credential for local provider" do
      policy = %{
        "model_provider" => "ollama",
        "model_name" => "llama3.2:latest",
        "temperature" => 0.2,
        "max_tokens" => 4096
      }

      settings = %{
        "default_model_provider" => "openai",
        "openai_api_key" => "",
        "openai_base_url" => "https://cli.llmotions.com/v1"
      }

      {:ok, route} = ModelRoute.resolve(policy, settings)
      assert route["provider"] == "ollama"
      assert route["model"] == "llama3.2:latest"
      assert route["base_url"] == "http://localhost:11434/v1"
      assert route["api_key"] == "local"
    end

    test "ModelRoute.resolve supplies 'local' credential for local base_url under openai" do
      policy = %{
        "model_provider" => "openai",
        "model_name" => "llama3.2:latest",
        "temperature" => 0.2,
        "max_tokens" => 4096
      }

      settings = %{
        "default_model_provider" => "openai",
        "openai_api_key" => "",
        "openai_base_url" => "http://localhost:11434/v1"
      }

      {:ok, route} = ModelRoute.resolve(policy, settings)
      assert route["provider"] == "openai"
      assert route["model"] == "llama3.2:latest"
      assert route["base_url"] == "http://localhost:11434/v1"
      assert route["api_key"] == "local"
    end

    test "OpenAI.chat defaults api_key to 'local' for local endpoints" do
      # Test with local endpoint and blank key - it passes key check
      # Even if network connection fails, error should be network rather than :no_api_key
      result =
        OpenAI.chat(
          [%{"role" => "user", "content" => "hi"}],
          nil,
          api_key: "",
          base_url: "http://localhost:59999/v1",
          model: "test-local",
          receive_timeout: 100
        )

      # Should NOT return {:error, :no_api_key}
      assert result != {:error, :no_api_key}
    end

    test "OpenAI.chat strictly enforces non-blank API key for cloud endpoints" do
      result =
        OpenAI.chat(
          [%{"role" => "user", "content" => "hi"}],
          nil,
          api_key: "",
          base_url: "https://api.openai.com/v1",
          model: "gpt-4o"
        )

      assert result == {:error, :no_api_key}
    end
  end
end
