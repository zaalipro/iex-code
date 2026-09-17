defmodule IexCode.MCP.ClientTest do
  use ExUnit.Case, async: false

  alias IexCode.MCP.Client

  setup do
    elixir = System.find_executable("elixir")
    script = Path.join([File.cwd!(), "test", "support", "fake_mcp_server.exs"])
    %{elixir: elixir, script: script}
  end

  test "initialize, list tools, and call a tool", %{elixir: elixir, script: script} do
    client =
      start_supervised!({Client, command: elixir, args: [script], timeout_ms: 15_000})

    assert {:ok, info} = Client.initialize(client, timeout_ms: 15_000)
    assert info["serverInfo"]["name"] == "fake"

    assert {:ok, [tool]} = Client.list_tools(client, timeout_ms: 15_000)
    assert tool["name"] == "echo"
    assert tool["inputSchema"]["type"] == "object"

    assert {:ok, %{"content" => [%{"text" => "echo:hi"}]}} =
             Client.call_tool(client, "echo", %{"text" => "hi"}, timeout_ms: 15_000)
  end

  test "server errors surface codes", %{elixir: elixir, script: script} do
    client =
      start_supervised!({Client, command: elixir, args: [script], timeout_ms: 15_000})

    assert {:ok, _info} = Client.initialize(client, timeout_ms: 15_000)

    assert {:error, {:mcp_error, -32602, "unknown tool"}} =
             Client.call_tool(client, "nope", %{}, timeout_ms: 15_000)
  end

  test "missing command fails fast" do
    Process.flag(:trap_exit, true)

    assert {:error, {:mcp_no_command, "definitely-not-a-real-command-xyz"}} =
             Client.start_link(command: "definitely-not-a-real-command-xyz")
  end
end
