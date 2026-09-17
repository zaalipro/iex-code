defmodule IexCode.MCP.CatalogTest do
  use ExUnit.Case, async: true

  alias IexCode.MCP.Catalog

  test "validates server specs" do
    assert {:ok, %{"files" => spec}} =
             Catalog.from_map(%{
               "servers" => %{
                 "files" => %{"command" => "npx", "args" => ["-y", "x"], "env" => %{"A" => "b"}}
               }
             })

    assert spec == %{command: "npx", args: ["-y", "x"], env: %{"A" => "b"}}
  end

  test "rejects bad shapes" do
    assert {:error, :mcp_catalog_shape} = Catalog.from_map(%{})

    assert {:error, {:mcp_server_field, "s", "command"}} =
             Catalog.from_map(%{"servers" => %{"s" => %{}}})

    assert {:error, {:mcp_server_field, "s", "args"}} =
             Catalog.from_map(%{"servers" => %{"s" => %{"command" => "c", "args" => "nope"}}})
  end

  test "loads catalog files" do
    dir = Path.join(System.tmp_dir!(), "mcp-cat-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    path = Path.join(dir, "mcp.json")
    File.write!(path, "{\"servers\":{\"s\":{\"command\":\"bin/srv\"}}}")
    assert {:ok, %{"s" => %{command: "bin/srv", args: [], env: %{}}}} = Catalog.from_file(path)

    assert {:error, {:mcp_catalog, _, _}} = Catalog.from_file(Path.join(dir, "missing.json"))
  end
end
