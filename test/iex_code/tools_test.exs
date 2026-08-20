defmodule IexCode.ToolsTest do
  use ExUnit.Case, async: false
  alias IexCode.Tools

  @tag :tmp_dir
  test "reads and writes files correctly", %{tmp_dir: tmp_dir} do
    test_file = "test_module.ex"
    content = "defmodule TestMod do\n  def hello, do: :world\nend\n"

    assert {:ok, _msg} =
             Tools.execute("write_file", %{"path" => test_file, "content" => content}, tmp_dir)

    assert {:ok, read_content} = Tools.execute("read_file", %{"path" => test_file}, tmp_dir)
    assert String.contains?(read_content, "defmodule TestMod")

    # Test patch_file
    patch_args = %{
      "path" => test_file,
      "target_content" => ":world",
      "replacement_content" => ":universe"
    }

    assert {:ok, _} = Tools.execute("patch_file", patch_args, tmp_dir)
    assert {:ok, patched} = Tools.execute("read_file", %{"path" => test_file}, tmp_dir)
    assert String.contains?(patched, ":universe")
  end

  @tag :tmp_dir
  test "lists directory and grep search", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "app.ex"), "defmodule App do\n  def run, do: :ok\nend")

    assert {:ok, list_out} = Tools.execute("list_dir", %{"path" => ""}, tmp_dir)
    assert String.contains?(list_out, "app.ex")

    assert {:ok, grep_out} = Tools.execute("grep_search", %{"query" => "def run"}, tmp_dir)
    assert String.contains?(grep_out, "app.ex")
  end

  @tag :tmp_dir
  test "runs shell commands safely", %{tmp_dir: tmp_dir} do
    assert {:ok, output} =
             Tools.execute("run_command", %{"command" => "echo 'hello from elixir'"}, tmp_dir)

    assert String.contains?(output, "hello from elixir")
  end
end
