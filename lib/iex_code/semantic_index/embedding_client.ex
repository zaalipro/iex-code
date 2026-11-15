defmodule IexCode.SemanticIndex.EmbeddingClient do
  @moduledoc """
  Client for generating vector embeddings via local inference engines (Ollama, LM Studio, llama.cpp).
  Zero cloud dependencies: queries local endpoints over HTTP using `Req`.
  Supports mock plug injection for deterministic test isolation.
  Automatically unit-normalizes generated vectors using `IexCode.SemanticIndex.Vector`.
  """

  require Logger
  alias IexCode.LLM.Discovery
  alias IexCode.SemanticIndex.Vector

  @default_dimension 384
  @default_model "nomic-embed-text"

  @doc """
  Returns the default embedding model name.
  """
  @spec default_model() :: String.t()
  def default_model, do: @default_model

  @doc """
  Generates vector embeddings for a single text or batch of texts.
  Always returns `{:ok, [vector, ...]}` where each vector is either a list of floats
  or a packed binary if `return: :binary` is specified.
  """
  @spec embed(String.t() | [String.t()], keyword()) ::
          {:ok, [binary()] | [[float()]]} | {:error, term()}
  def embed(input, opts \\ [])

  def embed([], _opts), do: {:ok, []}

  def embed(input, opts) do
    texts = if is_list(input), do: input, else: [input]
    model = resolve_model(opts)
    plug = Keyword.get(opts, :plug)
    explicit_base = Keyword.get(opts, :base_url)

    res =
      cond do
        plug != nil ->
          call_with_plug(texts, model, plug, opts)

        is_binary(explicit_base) and explicit_base != "" ->
          call_local_endpoint(texts, model, explicit_base, opts, allow_fallback: false)

        true ->
          case resolve_base_url() do
            base when is_binary(base) and base != "" ->
              call_local_endpoint(texts, model, base, opts, allow_fallback: true)

            nil ->
              fallback_embeddings(texts, model)
          end
      end

    case res do
      {:ok, packed_vectors} ->
        if Keyword.get(opts, :return) == :binary do
          {:ok, packed_vectors}
        else
          {:ok, Enum.map(packed_vectors, &Vector.unpack/1)}
        end

      error ->
        error
    end
  end

  @doc """
  Returns the vector dimension for the active embedding model.
  """
  @spec model_dimension(String.t() | term()) :: pos_integer()
  def model_dimension(model \\ @default_model)

  def model_dimension(model) when is_binary(model) do
    normalized = String.downcase(model)

    cond do
      String.contains?(normalized, "fallback-hash-768") -> 768
      String.contains?(normalized, "fallback-hash-384") -> 384
      String.contains?(normalized, "nomic") -> 768
      String.contains?(normalized, "bge-large") -> 1024
      String.contains?(normalized, "mxbai-embed-large") -> 1024
      String.contains?(normalized, "bge") -> 384
      String.contains?(normalized, "minilm") -> 384
      String.contains?(normalized, "bert") -> 768
      String.contains?(normalized, "text-embedding-3-large") -> 3072
      String.contains?(normalized, "text-embedding-3-small") -> 1536
      true -> @default_dimension
    end
  end

  def model_dimension(_), do: @default_dimension

  # ============================================================================
  # Provider Resolution & Requests
  # ============================================================================

  defp resolve_model(opts) do
    case Keyword.get(opts, :model) do
      model when is_binary(model) and model != "" -> model
      _ -> resolve_default_model()
    end
  end

  defp resolve_base_url do
    case Process.whereis(IexCode.LLM.Discovery.Server) do
      pid when is_pid(pid) ->
        status = Discovery.Server.get_status()

        cond do
          status[:ollama][:available?] -> status[:ollama][:base_url]
          status[:lm_studio][:available?] -> status[:lm_studio][:base_url]
          status[:llama_cpp][:available?] -> status[:llama_cpp][:base_url]
          true -> nil
        end

      _ ->
        nil
    end
  end

  defp resolve_default_model do
    @default_model
  end

  defp call_with_plug(texts, model, plug, opts) do
    timeout = Keyword.get(opts, :timeout, 5000)
    req = Req.new(plug: plug, base_url: "http://localhost:11434", receive_timeout: timeout)

    Req.post(req,
      url: "/v1/embeddings",
      json: %{model: model, input: texts}
    )
    |> parse_embedding_response()
  rescue
    e -> {:error, normalize_error(e)}
  end

  defp call_local_endpoint(texts, model, base_url, opts, allow_fallback: allow_fallback) do
    url = String.trim_trailing(base_url, "/") <> "/v1/embeddings"
    timeout = Keyword.get(opts, :timeout, 5000)

    req_opts = [
      json: %{model: model, input: texts},
      receive_timeout: timeout,
      connect_options: [timeout: timeout],
      retry: Keyword.get(opts, :retry, false)
    ]

    case Req.post(url, req_opts) |> parse_embedding_response() do
      {:ok, vectors} ->
        {:ok, vectors}

      {:error, reason} ->
        if allow_fallback do
          Logger.debug(
            "Local embedding request failed (#{inspect(reason)}), falling back to synthetic vectors"
          )

          fallback_embeddings(texts, model)
        else
          {:error, reason}
        end
    end
  rescue
    e ->
      if allow_fallback do
        Logger.debug(
          "Local embedding connection failed: #{inspect(e)}, falling back to synthetic vectors"
        )

        fallback_embeddings(texts, model)
      else
        {:error, normalize_error(e)}
      end
  end

  defp parse_embedding_response({:ok, %{status: 200, body: %{"data" => items} = body}})
       when is_list(items) and items != [] do
    sorted = Enum.sort_by(items, &Map.get(&1, "index", 0))

    if Enum.all?(sorted, &valid_embedding_item?/1) do
      vectors =
        Enum.map(sorted, fn %{"embedding" => floats} ->
          Vector.normalize(Vector.pack(floats))
        end)

      {:ok, vectors}
    else
      {:error, {:unexpected_response, 200, body}}
    end
  end

  defp parse_embedding_response({:ok, %{status: 200, body: %{"embedding" => floats} = body}})
       when is_list(floats) and floats != [] do
    if Enum.all?(floats, &is_number/1) do
      {:ok, [Vector.normalize(Vector.pack(floats))]}
    else
      {:error, {:unexpected_response, 200, body}}
    end
  end

  defp parse_embedding_response({:ok, %{status: status, body: body}}) when status >= 400 do
    {:error, {:http_error, status, body}}
  end

  defp parse_embedding_response({:ok, %{status: status, body: body}}) do
    {:error, {:unexpected_response, status, body}}
  end

  defp parse_embedding_response({:error, reason}) do
    {:error, normalize_error(reason)}
  end

  defp valid_embedding_item?(%{"embedding" => floats})
       when is_list(floats) and floats != [] do
    Enum.all?(floats, &is_number/1)
  end

  defp valid_embedding_item?(_), do: false

  defp normalize_error(%Mint.TransportError{reason: reason}), do: reason
  defp normalize_error(%Req.TransportError{reason: reason}), do: reason
  defp normalize_error(other), do: other

  # Deterministic hash-based pseudo-semantic vector generator for offline tests
  defp fallback_embeddings(texts, model) do
    dim = model_dimension(model)

    vectors =
      Enum.map(texts, fn text ->
        tokens =
          text
          |> String.downcase()
          |> String.split(~r/[^a-zA-Z0-9_]+/, trim: true)

        floats =
          for i <- 0..(dim - 1) do
            Enum.reduce(tokens, 0.0, fn tok, acc ->
              h = :erlang.phash2({tok, i}, 10_000) / 10_000.0 - 0.5
              acc + h
            end)
          end

        Vector.normalize(Vector.pack(floats))
      end)

    {:ok, vectors}
  end
end
