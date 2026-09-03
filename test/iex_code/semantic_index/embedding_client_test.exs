defmodule IexCode.SemanticIndex.EmbeddingClientTest do
  @moduledoc """
  Requirement R2: Offline Local Semantic Codebase Indexing & Vector Search.
  Tests for IexCode.SemanticIndex.EmbeddingClient:
  - Local inference server connection (Ollama, LM Studio, llama.cpp)
  - OpenAI-compatible /v1/embeddings and Ollama native /api/embeddings protocols
  - Batch embedding and L2 unit-normalization
  - Mock Plug request validation and error resiliency
  """
  use ExUnit.Case, async: false

  alias IexCode.SemanticIndex.EmbeddingClient
  alias IexCode.SemanticIndex.Vector

  # Mock Plug for OpenAI-compatible /v1/embeddings endpoint
  defmodule MockOpenAIEmbeddingPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(%Plug.Conn{path_info: ["v1", "embeddings"], method: "POST"} = conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      payload = Jason.decode!(body)
      input = payload["input"]

      embeddings =
        case input do
          text when is_binary(text) ->
            [%{"embedding" => generate_synthetic_embedding(384), "index" => 0}]

          list when is_list(list) ->
            Enum.with_index(list)
            |> Enum.map(fn {_text, idx} ->
              %{"embedding" => generate_synthetic_embedding(384), "index" => idx}
            end)
        end

      response = %{
        "object" => "list",
        "data" => embeddings,
        "model" => payload["model"] || "nomic-embed-text",
        "usage" => %{"total_tokens" => 42}
      }

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(response))
    end

    def call(%Plug.Conn{path_info: ["api", "embeddings"], method: "POST"} = conn, _opts) do
      # Ollama native format
      {:ok, _body, conn} = read_body(conn)
      response = %{"embedding" => generate_synthetic_embedding(384)}

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(response))
    end

    def call(conn, _opts) do
      send_resp(conn, 404, "Not Found")
    end

    defp generate_synthetic_embedding(dim) do
      # Generate deterministic unit vector
      raw = for i <- 1..dim, do: :math.sin(i)
      mag = :math.sqrt(Enum.reduce(raw, 0.0, fn x, acc -> acc + x * x end))
      Enum.map(raw, fn x -> x / mag end)
    end
  end

  describe "Tier 1: Embedding API Interaction & Response Parsing" do
    test "T1_R2_EMB_01: embed/2 embeds single text via mock plug returning unit vector" do
      opts = [
        plug: {MockOpenAIEmbeddingPlug, []},
        base_url: "http://localhost:11434",
        model: "nomic-embed-text"
      ]

      {:ok, [vector]} = EmbeddingClient.embed("def search_codebase(query), do: ...", opts)

      assert is_list(vector)
      assert length(vector) == 384
      # Must be unit-normalized
      norm = Vector.l2_norm(vector)
      assert abs(norm - 1.0) < 1.0e-4
    end

    test "T1_R2_EMB_02: embed/2 handles batch of texts returning ordered vectors" do
      opts = [
        plug: {MockOpenAIEmbeddingPlug, []},
        base_url: "http://localhost:11434",
        model: "nomic-embed-text"
      ]

      inputs = [
        "Module A: data ingestion",
        "Module B: consensus voting",
        "Module C: rollback scrubber"
      ]

      {:ok, vectors} = EmbeddingClient.embed(inputs, opts)

      assert is_list(vectors)
      assert length(vectors) == 3

      Enum.each(vectors, fn vec ->
        assert length(vec) == 384
        assert abs(Vector.l2_norm(vec) - 1.0) < 1.0e-4
      end)
    end

    test "T1_R2_EMB_03: supports binary return option for zero-copy SQLite persistence" do
      opts = [
        plug: {MockOpenAIEmbeddingPlug, []},
        base_url: "http://localhost:11434",
        return: :binary
      ]

      {:ok, [binary_vec]} = EmbeddingClient.embed("def binary_optimization, do: :ok", opts)

      assert is_binary(binary_vec)
      assert byte_size(binary_vec) == 384 * 4
    end
  end

  describe "Tier 2: Error Handling & Resilience" do
    test "T2_R2_EMB_01: returns structured error when local inference server is unreachable" do
      # Point to an unallocated loopback port
      opts = [
        base_url: "http://127.0.0.1:59999",
        retry: false,
        timeout: 200
      ]

      result = EmbeddingClient.embed("test query", opts)

      assert match?({:error, _}, result)

      case result do
        {:error, reason} ->
          assert reason in [:connection_refused, :econnrefused, :timeout, :no_embedding_engine] or
                   is_binary(reason) or match?(%Req.TransportError{}, reason) or
                   match?({:http_error, _, _}, reason)
      end
    end

    test "T2_R2_EMB_02: server HTTP 500 error returns structured error" do
      failing_plug = fn conn ->
        Plug.Conn.send_resp(conn, 500, "Internal Model Crash")
      end

      opts = [plug: failing_plug, base_url: "http://localhost:11434"]
      result = EmbeddingClient.embed("some text", opts)

      assert match?({:error, _}, result)
    end

    test "T2_R2_EMB_03: empty input string or empty list returns clean result without error" do
      opts = [plug: {MockOpenAIEmbeddingPlug, []}, base_url: "http://localhost:11434"]

      assert {:ok, []} = EmbeddingClient.embed([], opts)
    end
  end
end
