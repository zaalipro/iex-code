Code.require_file("lib/jsonrpc_framer.ex", __DIR__)

ExUnit.start(autorun: false)

defmodule JsonRpcFramerGradeTest do
  use ExUnit.Case

  test "encodes and decodes multi-byte UTF-8 payloads using exact byte lengths" do
    payload = ~s({"jsonrpc":"2.0","id":1,"result":{"msg":"héllo 🚀 日本語"}})
    encoded = JsonRpcFramer.encode(payload)

    assert String.starts_with?(encoded, "Content-Length: #{byte_size(payload)}\r\n\r\n")

    state = JsonRpcFramer.new()
    assert {:ok, [^payload], next_state} = JsonRpcFramer.feed(state, encoded)
    assert next_state.buffer == ""
  end

  test "parses case-insensitive Content-Length with extra headers and fragmented chunks" do
    p1 = ~s({"jsonrpc":"2.0","id":1,"method":"ping"})
    p2 = ~s({"jsonrpc":"2.0","id":2,"method":"tools/list","params":{"q":"café"}})

    raw =
      "content-type: application/vscode-jsonrpc; charset=utf-8\r\ncontent-length: #{byte_size(p1)}\r\n\r\n" <>
        p1 <>
        "CONTENT-LENGTH: #{byte_size(p2)}\r\nX-Trace: abc\r\n\r\n" <>
        p2

    # Split at arbitrary byte boundaries: mid-header, mid-second-header (after p1), and remainder
    chunk1 = binary_part(raw, 0, 35)
    chunk2 = binary_part(raw, 35, 90)
    chunk3 = binary_part(raw, 125, byte_size(raw) - 125)

    state = JsonRpcFramer.new()
    assert {:ok, [], state} = JsonRpcFramer.feed(state, chunk1)
    assert {:ok, [^p1], state} = JsonRpcFramer.feed(state, chunk2)
    assert {:ok, [^p2], state} = JsonRpcFramer.feed(state, chunk3)
    assert state.buffer == ""
  end

  test "extracts multiple concatenated frames in a single chunk" do
    p1 = ~s({"id":1})
    p2 = ~s({"id":2})
    p3 = ~s({"id":3})
    combined = JsonRpcFramer.encode(p1) <> JsonRpcFramer.encode(p2) <> JsonRpcFramer.encode(p3)

    state = JsonRpcFramer.new()
    assert {:ok, [^p1, ^p2, ^p3], next_state} = JsonRpcFramer.feed(state, combined)
    assert next_state.buffer == ""
  end

  test "returns structured errors for missing, invalid, negative, and oversized Content-Length" do
    state = JsonRpcFramer.new(max_content_length: 64)

    assert {:error, _reason, _} = JsonRpcFramer.feed(state, "Content-Type: json\r\n\r\n{}")
    assert {:error, _reason, _} = JsonRpcFramer.feed(state, "Content-Length: abc\r\n\r\n{}")
    assert {:error, _reason, _} = JsonRpcFramer.feed(state, "Content-Length: -5\r\n\r\n{}")
    assert {:error, _reason, _} = JsonRpcFramer.feed(state, "Content-Length: 1024\r\n\r\n{}")
  end
end

case ExUnit.run() do
  %{failures: 0} -> System.halt(0)
  _ -> System.halt(1)
end
