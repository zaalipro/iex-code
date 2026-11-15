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

  test "tool definitions enforce an explicit execution manifest" do
    all_names = Tools.tool_definitions() |> Enum.map(& &1.name)
    assert "web_search" in all_names
    assert "fetch_url" in all_names
    assert "find_references" in all_names
    assert "rename_symbol" in all_names

    assert [%{name: "web_search"}] = Tools.tool_definitions(["web_search"])
    assert [] = Tools.tool_definitions([])
    assert [%{name: "fetch_url"}] = Tools.tool_definitions(MapSet.new(["fetch_url"]))
  end

  @tag :tmp_dir
  test "ast_search tool enforces workspace containment while direct Tools.ast_search/2 stays compatible",
       %{tmp_dir: tmp_dir} do
    parent_dir = Path.dirname(tmp_dir)
    outside_name = "outside_ast_#{System.unique_integer([:positive])}.ex"
    outside_file = Path.join(parent_dir, outside_name)

    File.write!(outside_file, "defmodule SecretOutsideMod do\n  def leak, do: :nope\nend\n")
    on_exit(fn -> File.rm(outside_file) end)

    File.write!(
      Path.join(tmp_dir, "inside.ex"),
      "defmodule InsideMod do\n  def safe_fn(x), do: x\nend\n"
    )

    assert {:ok, inside_out} =
             Tools.execute("ast_search", %{"query" => "safe_fn"}, tmp_dir)

    assert inside_out =~ "safe_fn"

    assert {:error, escape_err} =
             Tools.execute(
               "ast_search",
               %{"query" => "SecretOutsideMod", "path" => "../#{outside_name}"},
               tmp_dir
             )

    assert escape_err =~ "Path escapes the workspace"

    assert {:ok, direct_entries} = Tools.ast_search("safe_fn", tmp_dir)
    assert Enum.any?(direct_entries, &(&1.name == "safe_fn"))
  end

  @tag :tmp_dir
  test "find_references and rename_symbol tools inspect and refactor workspace symbols safely",
       %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "lib"))

    File.write!(Path.join(tmp_dir, "lib/billing.ex"), """
    defmodule DemoApp.Billing do
      # compute_total/2 comment should be ignored
      def compute_total(items, tax_rate) do
        Enum.sum(items) * (1.0 + tax_rate)
      end
    end
    """)

    File.write!(Path.join(tmp_dir, "lib/checkout.ex"), """
    defmodule DemoApp.Checkout do
      alias DemoApp.Billing

      def finalize(items) do
        label = "compute_total literal stays untouched"
        {label, Billing.compute_total(items, 0.1)}
      end
    end
    """)

    assert {:ok, refs_out} =
             Tools.execute(
               "find_references",
               %{"symbol" => "DemoApp.Billing.compute_total/2"},
               tmp_dir
             )

    assert refs_out =~ "lib/billing.ex:3:"
    assert refs_out =~ "[definition]"
    assert refs_out =~ "lib/checkout.ex:6:"
    assert refs_out =~ "[call]"
    refute refs_out =~ "lib/billing.ex:2:"
    refute refs_out =~ "lib/checkout.ex:5:"

    assert {:error, escape_ref_err} =
             Tools.execute(
               "find_references",
               %{"symbol" => "DemoApp.Billing", "path" => "../../etc"},
               tmp_dir
             )

    assert escape_ref_err =~ "Path escapes the workspace"

    # Dry run computes diff without modifying files on disk
    assert {:ok, dry_out} =
             Tools.execute(
               "rename_symbol",
               %{
                 "symbol" => "DemoApp.Billing.compute_total/2",
                 "new_name" => "calculate_total",
                 "dry_run" => true
               },
               tmp_dir
             )

    assert dry_out =~ "Dry run: would rename"
    assert dry_out =~ "calculate_total"
    assert File.read!(Path.join(tmp_dir, "lib/billing.ex")) =~ "def compute_total("

    # Live rename mutates definitions and aliased call sites while preserving comments & strings
    assert {:ok, rename_out} =
             Tools.execute(
               "rename_symbol",
               %{
                 "symbol" => "DemoApp.Billing.compute_total/2",
                 "new_name" => "calculate_total"
               },
               tmp_dir
             )

    assert rename_out =~ "Renamed 2 occurrence(s) across 2 file(s)"
    billing_after = File.read!(Path.join(tmp_dir, "lib/billing.ex"))
    checkout_after = File.read!(Path.join(tmp_dir, "lib/checkout.ex"))

    assert billing_after =~ "def calculate_total(items, tax_rate)"
    assert billing_after =~ "# compute_total/2 comment should be ignored"
    assert checkout_after =~ "Billing.calculate_total(items, 0.1)"
    assert checkout_after =~ "\"compute_total literal stays untouched\""
  end
end
