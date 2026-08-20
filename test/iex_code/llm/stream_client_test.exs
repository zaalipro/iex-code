defmodule IexCode.LLM.StreamClientTest do
  use ExUnit.Case, async: false
  alias IexCode.LLM.StreamClient

  defmodule MockStreamPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      case conn.request_path do
        "/openai/stream" ->
          conn =
            conn
            |> put_resp_header("content-type", "text/event-stream")
            |> send_chunked(200)

          chunk1 =
            "data: {\"choices\":[{\"delta\":{\"content\":\"Hello \",\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\"}}]},\"finish_reason\":null}]}\n\n"

          chunk2 =
            "data: {\"choices\":[{\"delta\":{\"content\":\"world!\",\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\" \\\"test.ex\\\"}\"}}]},\"finish_reason\":null}]}\n\n"

          chunk3 = "data: [DONE]\n\n"

          {:ok, conn} = chunk(conn, chunk1)
          {:ok, conn} = chunk(conn, chunk2)
          {:ok, conn} = chunk(conn, chunk3)
          conn

        "/anthropic/stream" ->
          conn =
            conn
            |> put_resp_header("content-type", "text/event-stream")
            |> send_chunked(200)

          chunk1 =
            "event: content_block_start\ndata: {\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"call_ant\",\"name\":\"write_file\"}}\n\n"

          chunk2 =
            "event: content_block_delta\ndata: {\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\": \\\"foo.ex\\\"}\"}}\n\n"

          chunk3 =
            "event: content_block_delta\ndata: {\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"Written!\"}}\n\n"

          chunk4 = "event: message_stop\ndata: {}\n\n"

          {:ok, conn} = chunk(conn, chunk1)
          {:ok, conn} = chunk(conn, chunk2)
          {:ok, conn} = chunk(conn, chunk3)
          {:ok, conn} = chunk(conn, chunk4)
          conn

        "/error/500" ->
          conn
          |> put_resp_header("content-type", "application/json")
          |> send_resp(500, "{\"error\": \"Internal Server Error\"}")
      end
    end
  end

  setup_all do
    server =
      start_supervised!(
        {Bandit, plug: MockStreamPlug, port: 0, ip: :loopback, startup_log: false}
      )

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)
    {:ok, %{port: port, server: server}}
  end

  describe "StreamClient.stream/2" do
    test "streams OpenAI chunks, emits callbacks, and accumulates tool calls", %{port: port} do
      {:ok, chunks_agent} = Agent.start_link(fn -> [] end)
      on_chunk = fn chunk -> Agent.update(chunks_agent, fn l -> [chunk | l] end) end

      request_opts = [
        provider: "openai",
        url: "http://127.0.0.1:#{port}/openai/stream",
        body: %{"model" => "gpt-4o", "messages" => []}
      ]

      assert {:ok, resp} = StreamClient.stream(request_opts, on_chunk)
      chunks = Agent.get(chunks_agent, & &1) |> Enum.reverse()
      Agent.stop(chunks_agent)

      # Callbacks received
      assert chunks == ["Hello ", "world!"]

      # Final message text accumulated
      assert resp.text == "Hello world!"

      # Tool call accumulated and decoded
      assert length(resp.tool_calls) == 1
      [tc] = resp.tool_calls
      assert tc.id == "call_1"
      assert tc.name == "read_file"
      assert tc.args == %{"path" => "test.ex"}
    end

    test "streams Anthropic chunks and parses input json delta", %{port: port} do
      {:ok, chunks_agent} = Agent.start_link(fn -> [] end)
      on_chunk = fn chunk -> Agent.update(chunks_agent, fn l -> [chunk | l] end) end

      request_opts = [
        provider: "anthropic",
        url: "http://127.0.0.1:#{port}/anthropic/stream",
        body: %{"model" => "claude-3-7-sonnet", "messages" => []}
      ]

      assert {:ok, resp} = StreamClient.stream(request_opts, on_chunk)
      chunks = Agent.get(chunks_agent, & &1)
      Agent.stop(chunks_agent)

      assert chunks == ["Written!"]
      assert resp.text == "Written!"

      assert length(resp.tool_calls) == 1
      [tc] = resp.tool_calls
      assert tc.id == "call_ant"
      assert tc.name == "write_file"
      assert tc.args == %{"path" => "foo.ex"}
    end

    test "handles HTTP error status codes", %{port: port} do
      request_opts = [
        provider: "openai",
        url: "http://127.0.0.1:#{port}/error/500",
        body: %{}
      ]

      assert {:error, %{status: 500}} = StreamClient.stream(request_opts)
    end
  end
end
