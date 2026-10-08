defmodule IexCode.Test.LeanHarnessProvider do
  @moduledoc false
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, opts) do
    {:ok, body, conn} = read_body(conn, length: 2_000_000)
    request = Jason.decode!(body)

    send(
      opts[:receiver],
      {:lean_request,
       %{
         request_bytes: byte_size(body),
         request_estimated_tokens_bytes_div_4: ceil(byte_size(body) / 4),
         request_message_count: length(request["messages"]),
         request_tool_count: length(request["tools"] || []),
         effective_max_tokens: request["max_tokens"]
       }}
    )

    if opts[:status] do
      send_resp(conn, opts[:status], "Synthetic provider failure")
    else
      stream(conn, opts)
    end
  end

  defp stream(conn, opts) do
    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> send_chunked(200)

    server = self()
    Agent.update(opts[:sync], fn _ -> server end)

    if opts[:silent] do
      send(opts[:receiver], {:lean_silent_ready, self()})

      receive do
        :release -> :ok
      after
        5_000 -> raise "Silent fixture was not released"
      end
    end

    batches = opts[:batches] || 1

    conn =
      Enum.reduce(1..batches, conn, fn _, current ->
        if opts[:batches] do
          send(opts[:receiver], {:lean_batch_ready, self()})

          receive do
            :next -> :ok
          after
            5_000 -> raise "SSE fixture batch was not released"
          end
        end

        stream_chunks(current, div(opts[:chunks], batches))
      end)

    # No provider usage is invented for the synthetic fixture.
    case chunk(conn, "data: [DONE]\n\n") do
      {:ok, conn} -> conn
      {:error, _closed} -> conn
    end
  end

  defp stream_chunks(conn, count) do
    Enum.reduce_while(1..count, conn, fn _, current ->
      event = %{"choices" => [%{"delta" => %{"content" => "fixture "}}]}

      case chunk(current, "data: " <> Jason.encode!(event) <> "\n\n") do
        {:ok, next} ->
          receive do
            :ack -> {:cont, next}
            :halt -> {:halt, next}
          after
            5_000 -> raise "SSE fixture callback was not acknowledged"
          end

        {:error, _closed} ->
          {:halt, current}
      end
    end)
  end
end
