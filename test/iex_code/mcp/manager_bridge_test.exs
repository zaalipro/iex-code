defmodule IexCode.MCP.ManagerBridgeTest do
  use ExUnit.Case, async: false

  alias IexCode.MCP.{Manager, ToolBridge}

  setup do
    elixir = System.find_executable("elixir")
    script = Path.join([File.cwd!(), "test", "support", "fake_mcp_server.exs"])

    manager =
      start_supervised!(
        {Manager,
         name: :"mcp_manager_#{System.unique_integer([:positive])}",
         servers: %{"fake" => %{command: elixir, args: [script], env: %{}}},
         timeout_ms: 15_000}
      )

    %{manager: manager, elixir: elixir, script: script}
  end

  test "connects, lists tools, reports status, and calls through", %{
    manager: manager,
    elixir: elixir,
    script: script
  } do
    assert Manager.list_servers(manager) == ["fake"]
    assert {:ok, [tool]} = Manager.list_tools(manager, "fake")
    assert tool["name"] == "echo"

    assert {:ok, status} = Manager.server_status("fake", manager)
    assert is_pid(status.pid)
    assert status.status == :connected
    assert status.crash_count == 0
    assert status.last_error == nil
    assert status.config == %{command: elixir, args: [script], env: %{}}

    assert {:ok, %{"content" => [%{"text" => "echo:yo"}]}} =
             Manager.call_tool(manager, "fake", "echo", %{"text" => "yo"})
  end

  test "unknown servers and tools error", %{manager: manager} do
    assert {:error, :mcp_server_unknown} = Manager.list_tools(manager, "ghost")
    assert {:error, :mcp_server_unknown} = Manager.server_status("ghost", manager)
    assert {:error, :mcp_server_unknown} = Manager.reconnect("ghost", manager)
    assert {:error, :mcp_server_unknown} = Manager.call_tool(manager, "ghost", "echo", %{})

    assert {:error, {:mcp_error, -32602, _}} =
             Manager.call_tool(manager, "fake", "nope", %{})
  end

  test "bridge builds definitions and executes", %{manager: manager} do
    assert [%{name: "mcp__fake__echo", parameters: %{"type" => "object"}}] =
             ToolBridge.definitions(manager)

    assert {:ok, "echo:hi"} = ToolBridge.execute(manager, "mcp__fake__echo", %{"text" => "hi"})

    assert {:ok, "echo:alias"} =
             ToolBridge.execute_mcp_tool(manager, "mcp__fake__echo", %{"text" => "alias"})

    assert {:error, :mcp_bad_tool_name} = ToolBridge.execute(manager, "mcp__broken", %{})
    assert {:error, :mcp_server_unknown} = ToolBridge.execute(manager, "mcp__ghost__echo", %{})
  end

  test "bridge splits names and exposes max_output_bytes" do
    assert ToolBridge.max_output_bytes() == 256_000
    assert {:ok, "srv", "tool"} = ToolBridge.split("mcp__srv__tool")
    assert {:ok, "srv", "a__b"} = ToolBridge.split("mcp__srv__a__b")
    assert {:error, :mcp_bad_tool_name} = ToolBridge.split("mcp__srv")
    assert {:error, :mcp_bad_tool_name} = ToolBridge.split("read_file")
  end
end
