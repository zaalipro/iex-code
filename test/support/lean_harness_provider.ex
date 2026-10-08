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

    conn =
      Enum.reduce_while(1..opts[:chunks], conn, fn _, current ->
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

    # No provider usage is invented for the synthetic fixture.
    case chunk(conn, "data: [DONE]\n\n") do
      {:ok, conn} -> conn
      {:error, _closed} -> conn
    end
  end
end
