defmodule JsonRpcFramer do
  @moduledoc """
  Streaming Content-Length framer for JSON-RPC / LSP / MCP stdio transports.
  """

  @default_max_bytes 1_048_576

  @type t :: %{buffer: binary(), max_content_length: pos_integer()}

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %{
      buffer: "",
      max_content_length: Keyword.get(opts, :max_content_length, @default_max_bytes)
    }
  end

  @spec encode(binary()) :: binary()
  def encode(payload) when is_binary(payload) do
    # BUG 1: uses character length instead of byte_size
    "Content-Length: #{String.length(payload)}\r\n\r\n" <> payload
  end

  @spec feed(t(), binary()) :: {:ok, [binary()], t()} | {:error, term(), t()}
  def feed(%{buffer: buffer} = state, chunk) when is_binary(chunk) do
    combined = buffer <> chunk

    case String.split(combined, "\r\n\r\n", parts: 2) do
      [headers, rest] ->
        # BUG 2: case-sensitive header lookup, no validation, and no multi-frame loop
        case String.split(headers, "Content-Length:", parts: 2) do
          [_, len_str] ->
            len = len_str |> String.trim() |> String.to_integer()

            if String.length(rest) >= len do
              payload = String.slice(rest, 0, len)
              remainder = String.slice(rest, len, String.length(rest) - len)
              {:ok, [payload], %{state | buffer: remainder}}
            else
              {:ok, [], %{state | buffer: combined}}
            end

          _ ->
            {:ok, [], %{state | buffer: combined}}
        end

      _ ->
        {:ok, [], %{state | buffer: combined}}
    end
  end
end
