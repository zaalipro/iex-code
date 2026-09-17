defmodule IexCode.ToolsMCPTest do
  use ExUnit.Case, async: false

  alias IexCode.Tools
  alias IexCode.Tools.SafetyPolicy

  test "mcp tools route through the bridge and error cleanly" do
    assert {:error, :mcp_server_unknown} =
             Tools.execute("mcp__ghost__echo", %{"text" => "hi"}, System.tmp_dir!())

    assert {:error, :mcp_bad_tool_name} =
             Tools.execute("mcp__broken", %{}, System.tmp_dir!())
  end

  test "mcp tools are a prompting category" do
    assert SafetyPolicy.category_for_tool("mcp__srv__tool") == "mcp_tools"
    assert SafetyPolicy.mutating_category?("mcp_tools")
    assert SafetyPolicy.category_for_tool(:update_plan) == "autonomy"
  end
end
