defmodule IexCode.ToolsSandboxTest do
  use ExUnit.Case, async: false

  alias IexCode.Sandbox
  alias IexCode.Tools

  test "run_command honors explicit sandbox policies" do
    sandbox =
      start_supervised!(
        {Sandbox.Manager, name: :"tool_sandbox_#{System.unique_integer([:positive])}"}
      )

    args = %{
      "command" => "echo sandboxed-tool",
      "sandbox_policy" => %{"reads" => ["/"], "writes" => [], "network" => "deny"},
      "__sandbox_server__" => sandbox,
      "__sandbox_backend__" => :none
    }

    # strict (default) + no backend fails closed
    assert {:error, message} = Tools.execute("run_command", args, System.tmp_dir!())
    assert message =~ "no_sandbox_backend"

    loose = put_in(args["sandbox_policy"]["strict"], false)
    assert {:ok, output} = Tools.execute("run_command", loose, System.tmp_dir!())
    assert output =~ "sandboxed-tool"
  end

  test "run_command without a policy keeps legacy behavior" do
    assert {:ok, output} =
             Tools.execute("run_command", %{"command" => "echo legacy"}, System.tmp_dir!())

    assert output =~ "legacy"
  end
end
