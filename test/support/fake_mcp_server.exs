# Fake MCP stdio server for tests. Stdlib only (no Jason): extracts the
# request id/method with Regex and emits canned JSON-RPC responses.
defmodule FakeMCPServer do
  def run do
    case IO.read(:stdio, :line) do
      :eof -> :ok
      {:error, _} -> :ok
      line when is_binary(line) -> handle(line) && run()
    end
  end

  defp handle(line) do
    id = capture(line, ~r/"id"\s*:\s*([^,}]+)/)
    method = capture(line, ~r/"method"\s*:\s*"([^"]+)"/)

    case {id, method} do
      {nil, _} ->
        :ok

      {_id, "notifications/initialized"} ->
        :ok

      {id, "initialize"} ->
        respond(
          id,
          ~s("protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"fake","version":"1"})
        )

      {id, "tools/list"} ->
        respond(
          id,
          ~s("tools":[{"name":"echo","description":"Echo text","inputSchema":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}}])
        )

      {id, "tools/call"} ->
        name = capture(line, ~r/"name"\s*:\s*"([^"]+)"/)

        if name == "echo" do
          text = capture(line, ~r/"text"\s*:\s*"((?:[^"\\]|\\.)*)"/) || ""
          respond(id, ~s("content":[{"type":"text","text":"echo:#{text}"}]))
        else
          respond_error(id, -32602, "unknown tool")
        end

      {id, _other} ->
        respond_error(id, -32601, "method not found")
    end
  end

  defp capture(line, regex) do
    case Regex.run(regex, line) do
      [_, value] -> String.trim(value)
      _ -> nil
    end
  end

  defp respond(id, result_body) do
    IO.write(:stdio, ~s({"jsonrpc":"2.0","id":#{id},"result":{#{result_body}}}\n))
  end

  defp respond_error(id, code, message) do
    IO.write(
      :stdio,
      ~s({"jsonrpc":"2.0","id":#{id},"error":{"code":#{code},"message":"#{message}"}}\n)
    )
  end
end

FakeMCPServer.run()
