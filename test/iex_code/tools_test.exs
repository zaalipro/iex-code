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
    assert "lsp_query" in all_names

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

  @mock_lsp_server_py """
  import json
  import os
  import sys

  mode = sys.argv[1] if len(sys.argv) > 1 else "normal"
  extra = b""

  def frame(obj: dict) -> bytes:
      body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
      return f"Content-Length: {len(body)}\\r\\n\\r\\n".encode("ascii") + body

  def send_msg(obj: dict):
      os.write(1, frame(obj))

  def read_next():
      global extra
      while b"\\r\\n\\r\\n" not in extra:
          chunk = os.read(0, 4096)
          if not chunk:
              return None
          extra += chunk
      header_end = extra.index(b"\\r\\n\\r\\n")
      headers = extra[:header_end].decode("ascii", errors="replace")
      rest = extra[header_end + 4:]
      length = 0
      for line in headers.split("\\r\\n"):
          if line.lower().startswith("content-length:"):
              length = int(line.split(":", 1)[1].strip())
      while len(rest) < length:
          chunk = os.read(0, 4096)
          if not chunk:
              return None
          rest += chunk
      payload = rest[:length]
      extra = rest[length:]
      return json.loads(payload.decode("utf-8"))

  while True:
      msg = read_next()
      if msg is None:
          break
      method = msg.get("method")
      req_id = msg.get("id")
      params = msg.get("params") or {}

      if method == "initialize":
          send_msg({"jsonrpc": "2.0", "id": req_id, "result": {"capabilities": {"hoverProvider": True}}})
      elif method == "initialized":
          pass
      elif method == "textDocument/didOpen":
          pass
      elif method == "textDocument/definition":
          if mode == "escape_response":
              send_msg({
                  "jsonrpc": "2.0",
                  "id": req_id,
                  "result": {"uri": "file:///etc/passwd", "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 1}}}
              })
          else:
              uri = params["textDocument"]["uri"]
              send_msg({
                  "jsonrpc": "2.0",
                  "id": req_id,
                  "result": [{"uri": uri, "range": {"start": {"line": 2, "character": 9}, "end": {"line": 2, "character": 22}}}]
              })
      elif method == "textDocument/references":
          uri = params["textDocument"]["uri"]
          send_msg({
              "jsonrpc": "2.0",
              "id": req_id,
              "result": [
                  {"uri": uri, "range": {"start": {"line": 2, "character": 9}, "end": {"line": 2, "character": 22}}},
                  {"uri": uri, "range": {"start": {"line": 6, "character": 9}, "end": {"line": 6, "character": 22}}}
              ]
          })
      elif method == "textDocument/hover":
          send_msg({
              "jsonrpc": "2.0",
              "id": req_id,
              "result": {"contents": {"kind": "markdown", "value": "function resolveSymbol(name: string): string"}}
          })
      elif method == "textDocument/documentSymbol":
          uri = params["textDocument"]["uri"]
          send_msg({
              "jsonrpc": "2.0",
              "id": req_id,
              "result": [
                  {"name": "SymbolRegistry", "kind": 5, "location": {"uri": uri, "range": {"start": {"line": 0, "character": 0}, "end": {"line": 8, "character": 1}}}},
                  {"name": "resolveSymbol", "kind": 12, "location": {"uri": uri, "range": {"start": {"line": 2, "character": 0}, "end": {"line": 4, "character": 1}}}}
              ]
          })
      elif method == "shutdown":
          send_msg({"jsonrpc": "2.0", "id": req_id, "result": None})
      elif method == "exit":
          break
  """

  @tag :tmp_dir
  test "lsp_query tool delegates definition, references, hover, and document_symbols with strict WorkspacePath containment",
       %{tmp_dir: tmp_dir} do
    python_bin = System.find_executable("python3")
    assert is_binary(python_bin), "python3 is required for deterministic mock stdio LSP tests"

    File.mkdir_p!(Path.join(tmp_dir, "src"))

    ts_path = Path.join(tmp_dir, "src/registry.ts")

    File.write!(ts_path, """
    export class SymbolRegistry {
      resolveSymbol(name: string): string {
        return name.trim();
      }
      lookup(name: string): string {
        return this.resolveSymbol(name);
      }
    }
    """)

    mock_script = Path.join(tmp_dir, "mock_lsp_tool.py")
    File.write!(mock_script, @mock_lsp_server_py)
    server_cmd = [python_bin, mock_script]

    # 1. definition
    assert {:ok, def_out} =
             Tools.execute(
               "lsp_query",
               %{
                 "action" => "definition",
                 "file" => "src/registry.ts",
                 "line" => 5,
                 "character" => 16,
                 "server_cmd" => server_cmd
               },
               tmp_dir
             )

    assert def_out =~ "Found 1 definition(s):"
    assert def_out =~ "src/registry.ts:2:9"

    # 2. references
    assert {:ok, refs_out} =
             Tools.execute(
               "lsp_query",
               %{
                 "action" => "references",
                 "file" => "src/registry.ts",
                 "line" => 2,
                 "character" => 9,
                 "server_cmd" => server_cmd
               },
               tmp_dir
             )

    assert refs_out =~ "Found 2 reference(s):"
    assert refs_out =~ "src/registry.ts:2:9"
    assert refs_out =~ "src/registry.ts:6:9"

    # 3. hover (also verifying atom-keyed args + string server_cmd)
    assert {:ok, hover_out} =
             Tools.execute(
               "lsp_query",
               %{
                 action: "hover",
                 file: "src/registry.ts",
                 line: 2,
                 character: 9,
                 server_cmd: "#{python_bin} #{mock_script}"
               },
               tmp_dir
             )

    assert hover_out =~ "function resolveSymbol(name: string): string"

    # 4. document_symbols
    assert {:ok, syms_out} =
             Tools.execute(
               "lsp_query",
               %{
                 "action" => "document_symbols",
                 "file" => "src/registry.ts",
                 "server_cmd" => server_cmd
               },
               tmp_dir
             )

    assert syms_out =~ "Found 2 document symbol(s):"
    assert syms_out =~ "[class] SymbolRegistry (src/registry.ts:0:0)"
    assert syms_out =~ "[function] resolveSymbol (src/registry.ts:2:0)"

    # 5. WorkspacePath containment on relative traversal, file:// URI, and escaping symlinks
    outside_file =
      Path.join(
        System.tmp_dir!(),
        "outside_lsp_tool_#{System.unique_integer([:positive])}.ts"
      )

    File.write!(outside_file, "export const secret = 42;\n")
    on_exit(fn -> File.rm(outside_file) end)

    symlink_escape = Path.join(tmp_dir, "src/escape_link.ts")
    File.ln_s!(outside_file, symlink_escape)

    for escaping <- ["../outside.ts", "file:///etc/passwd", "src/escape_link.ts"] do
      assert {:error, err_msg} =
               Tools.execute(
                 "lsp_query",
                 %{
                   "action" => "hover",
                   "file" => escaping,
                   "line" => 0,
                   "character" => 0,
                   "server_cmd" => server_cmd
                 },
                 tmp_dir
               )

      assert err_msg =~ "Path escapes the workspace"
    end

    # 6. Escaping server response URI is rejected fail-closed
    assert {:error, resp_escape_msg} =
             Tools.execute(
               "lsp_query",
               %{
                 "action" => "definition",
                 "file" => "src/registry.ts",
                 "line" => 0,
                 "character" => 0,
                 "server_cmd" => [python_bin, mock_script, "escape_response"]
               },
               tmp_dir
             )

    assert resp_escape_msg =~ "Path escapes the workspace"

    # 7. Missing file & unsupported action validation
    assert {:error, missing_msg} =
             Tools.execute(
               "lsp_query",
               %{
                 "action" => "hover",
                 "file" => "src/missing.ts",
                 "server_cmd" => server_cmd
               },
               tmp_dir
             )

    assert missing_msg =~ "File does not exist"

    assert {:error, bad_action_msg} =
             Tools.execute(
               "lsp_query",
               %{
                 "action" => "rename",
                 "file" => "src/registry.ts",
                 "server_cmd" => server_cmd
               },
               tmp_dir
             )

    assert bad_action_msg =~ "unsupported action"
  end
end
