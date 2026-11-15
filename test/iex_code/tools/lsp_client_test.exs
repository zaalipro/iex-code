defmodule IexCode.Tools.LSPClientTest do
  use ExUnit.Case, async: true

  alias IexCode.Tools.LSPClient

  @mock_lsp_py """
  import json
  import os
  import socket
  import sys
  import time

  mode = sys.argv[1] if len(sys.argv) > 1 else "normal"
  notify_port = int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] != "0" else None

  sock = None
  if notify_port:
      sock = socket.create_connection(("127.0.0.1", notify_port), timeout=2.0)

  def write_raw(data: bytes):
      os.write(1, data)

  def frame(obj: dict) -> bytes:
      body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
      return f"Content-Length: {len(body)}\\r\\n\\r\\n".encode("ascii") + body

  def send_msg(obj: dict):
      write_raw(frame(obj))

  def read_msg():
      buf = b""
      while b"\\r\\n\\r\\n" not in buf:
          chunk = os.read(0, 4096)
          if not chunk:
              return None
          buf += chunk
      header_end = buf.index(b"\\r\\n\\r\\n")
      headers = buf[:header_end].decode("ascii", errors="replace")
      rest = buf[header_end + 4:]
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
      return json.loads(payload.decode("utf-8"))

  # Simple stateful loop storing any extra buffered bytes across reads
  extra = b""

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

  opened_uris = []
  initialized_seen = False

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
          initialized_seen = True
      elif method == "textDocument/didOpen":
          opened_uris.append(params.get("textDocument", {}).get("uri"))
      elif method == "textDocument/definition":
          if mode == "escape_response":
              send_msg({
                  "jsonrpc": "2.0",
                  "id": req_id,
                  "result": {"uri": "file:///etc/passwd", "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 1}}}
              })
          elif mode == "mixed_list":
              uri = params["textDocument"]["uri"]
              send_msg({
                  "jsonrpc": "2.0",
                  "id": req_id,
                  "result": [
                      {"uri": "file:///etc/passwd", "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 1}}},
                      {"uri": uri, "range": {"start": {"line": 2, "character": 4}, "end": {"line": 2, "character": 10}}}
                  ]
              })
          else:
              uri = params["textDocument"]["uri"]
              send_msg({
                  "jsonrpc": "2.0",
                  "id": req_id,
                  "result": [{"uri": uri, "range": {"start": {"line": 1, "character": 2}, "end": {"line": 1, "character": 8}}}]
              })
      elif method == "textDocument/references":
          if mode == "fragmented_coalesced":
              # Send server->client request first, then two coalesced responses split across UTF-8 byte boundary
              uri = params["textDocument"]["uri"]
              srv_req = frame({"jsonrpc": "2.0", "id": "srv-1", "method": "window/workDoneProgress/create", "params": {"token": "tok"}})
              write_raw(srv_req)
              _ack = read_next()
              res = frame({
                  "jsonrpc": "2.0",
                  "id": req_id,
                  "result": [{"uri": uri, "range": {"start": {"line": 3, "character": 0}, "end": {"line": 3, "character": 5}}}]
              })
              # Split response mid-header and mid-body
              write_raw(res[:10])
              write_raw(res[10:28])
              write_raw(res[28:])
          else:
              uri = params["textDocument"]["uri"]
              send_msg({
                  "jsonrpc": "2.0",
                  "id": req_id,
                  "result": [{"uri": uri, "range": {"start": {"line": 4, "character": 1}, "end": {"line": 4, "character": 6}}}]
              })
      elif method == "textDocument/hover":
          if mode == "overflow":
              write_raw(b"Content-Length: 4096\\r\\n\\r\\n" + (b"x" * 256))
          elif mode == "error":
              send_msg({"jsonrpc": "2.0", "id": req_id, "error": {"code": -32601, "message": "Method not found"}})
          elif mode == "utf8_coalesced":
              exotic_key = os.environ.get("LSP_EXOTIC_KEY", "exotic_default_key")
              f1 = frame({"jsonrpc": "2.0", "method": "window/logMessage", "params": {"type": 3, "message": "héllo 🚀 日本語"}})
              f2 = frame({"jsonrpc": "2.0", "id": req_id, "result": {"contents": {"kind": "markdown", "value": "héllo 🚀 日本語"}, exotic_key: len(opened_uris), "initialized": initialized_seen}})
              # Write both frames coalesced in a single write
              write_raw(f1 + f2)
          else:
              send_msg({
                  "jsonrpc": "2.0",
                  "id": req_id,
                  "result": {"contents": {"kind": "markdown", "value": "fn resolve(name: string)"}}
              })
      elif method == "textDocument/documentSymbol":
          uri = params["textDocument"]["uri"]
          send_msg({
              "jsonrpc": "2.0",
              "id": req_id,
              "result": [
                  {"name": "SymbolTable", "kind": 5, "location": {"uri": uri, "range": {"start": {"line": 0, "character": 0}, "end": {"line": 5, "character": 1}}}}
              ]
          })
      elif method == "shutdown":
          send_msg({"jsonrpc": "2.0", "id": req_id, "result": None})
      elif method == "exit":
          break
  """

  defp setup_mock_workspace(tmp_dir) do
    src_dir = Path.join(tmp_dir, "src")
    File.mkdir_p!(src_dir)

    ts_file = Path.join(src_dir, "sample.ts")
    File.write!(ts_file, "export function greet(name: string): string {\n  return name;\n}\n")

    server_script = Path.join(tmp_dir, "mock_lsp.py")
    File.write!(server_script, @mock_lsp_py)

    python_bin = System.find_executable("python3")
    assert is_binary(python_bin), "python3 is required for deterministic mock stdio LSP tests"

    %{root: tmp_dir, ts_file: ts_file, server_script: server_script, python: python_bin}
  end

  @tag :tmp_dir
  test "full LSP stdio lifecycle: initialize, didOpen, definition, references, hover, documentSymbol, shutdown, and clean OS exit",
       %{tmp_dir: tmp_dir} do
    env = setup_mock_workspace(tmp_dir)

    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: true, ip: {127, 0, 0, 1}])
    {:ok, tcp_port} = :inet.port(listen)
    on_exit(fn -> :gen_tcp.close(listen) end)

    {:ok, client} =
      LSPClient.start_link(
        command: env.python,
        args: [env.server_script, "normal", Integer.to_string(tcp_port)],
        root_path: env.root
      )

    assert {:ok, server_sock} = :gen_tcp.accept(listen, 2_000)

    assert {:ok, %{"capabilities" => %{"hoverProvider" => true}}} = LSPClient.initialize(client)
    assert :ok = LSPClient.did_open(client, "src/sample.ts")

    assert {:ok, [%{"uri" => def_uri, "range" => _}]} =
             LSPClient.definition(client, "src/sample.ts", 0, 16)

    assert def_uri == LSPClient.path_to_uri(Path.join(env.root, "src/sample.ts"))

    assert {:ok, [%{"range" => %{"start" => %{"line" => 4}}}]} =
             LSPClient.references(client, "src/sample.ts", 0, 16)

    assert {:ok, %{"contents" => %{"value" => "fn resolve(name: string)"}}} =
             LSPClient.hover(client, "src/sample.ts", 0, 16)

    assert {:ok, [%{"name" => "SymbolTable", "kind" => 5}]} =
             LSPClient.document_symbols(client, "src/sample.ts")

    ref = Process.monitor(client)
    assert :ok = LSPClient.stop(client)
    assert_receive {:DOWN, ^ref, :process, ^client, :normal}, 2_000
    assert_receive {:tcp_closed, ^server_sock}, 2_000
  end

  @tag :tmp_dir
  test "handles coalesced frames, split UTF-8 chunks, server requests, and never interns external JSON keys as atoms",
       %{tmp_dir: tmp_dir} do
    env = setup_mock_workspace(tmp_dir)
    exotic_key = "never_atomized_lsp_key_#{System.unique_integer([:positive])}"

    {:ok, client} =
      LSPClient.start_link(
        command: env.python,
        args: [env.server_script, "utf8_coalesced"],
        env: %{"LSP_EXOTIC_KEY" => exotic_key},
        root_path: env.root,
        notify_parent: self()
      )

    on_exit(fn -> LSPClient.stop(client) end)

    assert {:ok, _} = LSPClient.initialize(client)
    assert :ok = LSPClient.did_open(client, "src/sample.ts")
    assert {:ok, hover_res} = LSPClient.hover(client, "src/sample.ts", 0, 0)

    assert hover_res["contents"]["value"] == "héllo 🚀 日本語"
    assert hover_res[exotic_key] == 1
    assert hover_res["initialized"] == true

    assert_receive {:lsp_notification, ^client, %{"method" => "window/logMessage"}}, 1_000

    assert_raise ArgumentError, fn ->
      String.to_existing_atom(exotic_key)
    end
  end

  @tag :tmp_dir
  test "handles fragmented headers/bodies and mid-flight server->client requests", %{
    tmp_dir: tmp_dir
  } do
    env = setup_mock_workspace(tmp_dir)

    {:ok, client} =
      LSPClient.start_link(
        command: env.python,
        args: [env.server_script, "fragmented_coalesced"],
        root_path: env.root
      )

    on_exit(fn -> LSPClient.stop(client) end)

    assert {:ok, _} = LSPClient.initialize(client)

    assert {:ok, [%{"range" => %{"start" => %{"line" => 3}}}]} =
             LSPClient.references(client, "src/sample.ts", 0, 0)
  end

  @tag :tmp_dir
  test "enforces max_buffer_bytes overflow guard and propagates JSON-RPC errors", %{
    tmp_dir: tmp_dir
  } do
    env = setup_mock_workspace(tmp_dir)

    {:ok, overflow_client} =
      LSPClient.start_link(
        command: env.python,
        args: [env.server_script, "overflow"],
        root_path: env.root,
        max_buffer_bytes: 128
      )

    on_exit(fn -> LSPClient.stop(overflow_client) end)

    assert {:ok, _} = LSPClient.initialize(overflow_client)

    assert {:error, :lsp_buffer_overflow} =
             LSPClient.hover(overflow_client, "src/sample.ts", 0, 0)

    {:ok, err_client} =
      LSPClient.start_link(
        command: env.python,
        args: [env.server_script, "error"],
        root_path: env.root
      )

    on_exit(fn -> LSPClient.stop(err_client) end)

    assert {:ok, _} = LSPClient.initialize(err_client)

    assert {:error, {:lsp_error, -32601, "Method not found"}} =
             LSPClient.hover(err_client, "src/sample.ts", 0, 0)
  end

  @tag :tmp_dir
  test "enforces WorkspacePath containment on input paths, file:// URIs, symlinks, and server response URIs",
       %{tmp_dir: tmp_dir} do
    env = setup_mock_workspace(tmp_dir)

    outside_dir =
      Path.join(System.tmp_dir!(), "lsp-outside-#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside_dir)
    on_exit(fn -> File.rm_rf(outside_dir) end)

    outside_file = Path.join(outside_dir, "secret.ts")
    File.write!(outside_file, "export const secret = 1;\n")
    symlink_path = Path.join(env.root, "src/escape.ts")
    File.ln_s!(outside_file, symlink_path)

    {:ok, client} =
      LSPClient.start_link(
        command: env.python,
        args: [env.server_script, "escape_response"],
        root_path: env.root
      )

    on_exit(fn -> LSPClient.stop(client) end)
    assert {:ok, _} = LSPClient.initialize(client)

    assert {:error, :outside_workspace} = LSPClient.did_open(client, "../etc/passwd")
    assert {:error, :outside_workspace} = LSPClient.definition(client, "file:///etc/passwd", 0, 0)
    assert {:error, :outside_workspace} = LSPClient.hover(client, "src/escape.ts", 0, 0)

    assert {:error, :unsupported_uri_scheme} =
             LSPClient.hover(client, "http://example.com/a.ts", 0, 0)

    # Single escaping Location returned by server is rejected
    assert {:error, :outside_workspace} = LSPClient.definition(client, "src/sample.ts", 0, 0)

    # List containing mixed URIs filters out escaping URI while keeping workspace URI
    {:ok, mixed_client} =
      LSPClient.start_link(
        command: env.python,
        args: [env.server_script, "mixed_list"],
        root_path: env.root
      )

    on_exit(fn -> LSPClient.stop(mixed_client) end)
    assert {:ok, _} = LSPClient.initialize(mixed_client)

    assert {:ok, [kept]} = LSPClient.definition(mixed_client, "src/sample.ts", 0, 0)
    assert kept["uri"] == LSPClient.path_to_uri(env.ts_file)
  end

  @tag :tmp_dir
  test "one-shot query/3 executes full lifecycle and enforces containment", %{tmp_dir: tmp_dir} do
    env = setup_mock_workspace(tmp_dir)

    assert {:ok, %{"contents" => %{"value" => "fn resolve(name: string)"}}} =
             LSPClient.query(env.root, %{
               "action" => "hover",
               "file" => "src/sample.ts",
               "line" => 0,
               "character" => 5,
               "server_cmd" => [env.python, env.server_script]
             })

    assert {:ok, [%{"name" => "SymbolTable"}]} =
             LSPClient.query(env.root, :document_symbols,
               file: "src/sample.ts",
               command: env.python,
               args: [env.server_script]
             )

    assert {:error, :outside_workspace} =
             LSPClient.query(env.root, %{
               "action" => "definition",
               "file" => "file:///etc/passwd",
               "line" => 0,
               "character" => 0,
               "server_cmd" => [env.python, env.server_script]
             })

    assert {:error, {:unsupported_lsp_action, "bogus"}} =
             LSPClient.query(env.root, %{"action" => "bogus", "file" => "src/sample.ts"})
  end
end
