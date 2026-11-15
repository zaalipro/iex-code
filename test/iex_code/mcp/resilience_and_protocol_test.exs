defmodule IexCode.MCP.ResilienceAndProtocolTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias IexCode.MCP.{Client, Manager, ToolBridge}

  setup_all do
    elixir = System.find_executable("elixir")
    tmp_dir = Path.join(System.tmp_dir!(), "mcp_resilience_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    script_path = Path.join(tmp_dir, "resilient_mcp_server.exs")
    File.write!(script_path, server_script_source())

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    %{elixir: elixir, script: script_path, tmp_dir: tmp_dir}
  end

  describe "Client.terminate/2 port cleanup and in-flight caller cancellation" do
    test "replies {:error, :client_stopping} to pending callers and terminates child OS process",
         %{elixir: elixir, script: script} do
      {:ok, life_listen} = open_loopback_listener()
      {:ok, gate_listen} = open_loopback_listener()

      on_exit(fn ->
        :gen_tcp.close(life_listen)
        :gen_tcp.close(gate_listen)
      end)

      life_port = listener_port(life_listen)
      gate_port = listener_port(gate_listen)

      {:ok, client} =
        Client.start(
          command: elixir,
          args: [script],
          env: %{
            "LIFE_PORT" => Integer.to_string(life_port),
            "GATE_PORT" => Integer.to_string(gate_port)
          },
          timeout_ms: 30_000
        )

      {:ok, life_conn} = :gen_tcp.accept(life_listen, 5_000)
      assert {:ok, "booted\n"} = :gen_tcp.recv(life_conn, 0, 5_000)

      assert {:ok, _info} = Client.initialize(client, timeout_ms: 15_000)

      in_flight =
        Task.async(fn ->
          Client.call_tool(client, "gated_tool", %{}, timeout_ms: 30_000)
        end)

      {:ok, gate_conn} = :gen_tcp.accept(gate_listen, 5_000)
      assert {:ok, "entered\n"} = :gen_tcp.recv(gate_conn, 0, 5_000)

      state = :sys.get_state(client)
      assert map_size(state.pending) == 1

      :ok = GenServer.stop(client, :normal)

      assert {:error, :client_stopping} = Task.await(in_flight, 5_000)

      # Kernel closes the child's TCP socket immediately when the child OS process exits
      assert {:error, :closed} = :gen_tcp.recv(life_conn, 0, 5_000)
      :gen_tcp.close(gate_conn)
    end
  end

  describe "Client buffer bounds (@max_buffer_bytes)" do
    test "aborts stream without newline exceeding @max_buffer_bytes (8 MiB) without OOM", %{
      elixir: elixir,
      script: script
    } do
      {:ok, life_listen} = open_loopback_listener()
      on_exit(fn -> :gen_tcp.close(life_listen) end)
      life_port = listener_port(life_listen)

      client =
        start_supervised!(
          {Client,
           command: elixir,
           args: [script],
           env: %{"LIFE_PORT" => Integer.to_string(life_port)},
           timeout_ms: 15_000}
        )

      {:ok, life_conn} = :gen_tcp.accept(life_listen, 5_000)
      assert {:ok, "booted\n"} = :gen_tcp.recv(life_conn, 0, 5_000)
      assert {:ok, _info} = Client.initialize(client, timeout_ms: 15_000)

      overflow_bytes = Client.max_buffer_bytes() + 131_072

      assert {:error, :mcp_buffer_overflow} =
               Client.call_tool(
                 client,
                 "flood_no_newline",
                 %{"bytes" => overflow_bytes},
                 timeout_ms: 15_000
               )

      post_state = :sys.get_state(client)
      assert post_state.buffer == ""
      assert post_state.exited == :mcp_buffer_overflow
      assert {:error, :closed} = :gen_tcp.recv(life_conn, 0, 5_000)
    end

    test "enforces custom max_buffer_bytes option on oversized single line", %{
      elixir: elixir,
      script: script
    } do
      client =
        start_supervised!(
          {Client, command: elixir, args: [script], max_buffer_bytes: 4_096, timeout_ms: 15_000}
        )

      assert {:ok, _info} = Client.initialize(client, timeout_ms: 15_000)

      assert {:error, :mcp_buffer_overflow} =
               Client.call_tool(
                 client,
                 "huge_output",
                 %{"repeat" => 1_000},
                 timeout_ms: 15_000
               )

      assert :sys.get_state(client).buffer == ""
    end
  end

  describe "MCP protocol completeness (resources & prompts on Client and Manager)" do
    test "Client supports list_resources, read_resource, list_prompts, and get_prompt", %{
      elixir: elixir,
      script: script
    } do
      {:ok, gate_listen} = open_loopback_listener()
      on_exit(fn -> :gen_tcp.close(gate_listen) end)
      gate_port = listener_port(gate_listen)

      client =
        start_supervised!(
          {Client,
           command: elixir,
           args: [script],
           env: %{"GATE_PORT" => Integer.to_string(gate_port)},
           timeout_ms: 15_000}
        )

      assert {:ok, _info} = Client.initialize(client, timeout_ms: 15_000)

      # resources/list
      assert {:ok, resources} = Client.list_resources(client)
      assert length(resources) == 2
      assert Enum.any?(resources, &(&1["uri"] == "file:///workspace/README.md"))

      # resources/read
      assert {:ok, %{"contents" => [%{"uri" => "file:///workspace/README.md", "text" => text}]}} =
               Client.read_resource(client, "file:///workspace/README.md")

      assert text =~ "Hello MCP resources!"

      assert {:error, {:mcp_error, -32002, "Resource not found"}} =
               Client.read_resource(client, "file:///workspace/missing.txt", 5_000)

      # prompts/list
      assert {:ok, prompts} = Client.list_prompts(client)
      assert Enum.map(prompts, & &1["name"]) == ["code_review", "summarize"]

      # prompts/get with default and explicit arguments
      assert {:ok, %{"description" => "Code review prompt", "messages" => [msg]}} =
               Client.get_prompt(client, "code_review", %{"language" => "elixir"}, 5_000)

      assert msg["role"] == "user"
      assert msg["content"]["text"] == "Please review this elixir code."

      assert {:ok, %{"messages" => [default_msg]}} = Client.get_prompt(client, "code_review")
      assert default_msg["content"]["text"] == "Please review this unknown code."

      assert {:error, {:mcp_error, -32602, "Unknown prompt"}} =
               Client.get_prompt(client, "nonexistent_prompt", %{})

      # Per-call custom timeout enforcement without sleep
      timeout_task =
        Task.async(fn ->
          Client.read_resource(client, "gated://resource", 80)
        end)

      {:ok, gate_conn} = :gen_tcp.accept(gate_listen, 5_000)
      assert {:ok, "entered\n"} = :gen_tcp.recv(gate_conn, 0, 5_000)
      assert {:error, :mcp_request_timeout} = Task.await(timeout_task, 5_000)
      :ok = :gen_tcp.send(gate_conn, "release\n")
      :gen_tcp.close(gate_conn)
    end

    test "Manager wraps resources and prompts methods cleanly", %{elixir: elixir, script: script} do
      manager =
        start_supervised!(
          {Manager,
           name: :"mcp_proto_mgr_#{System.unique_integer([:positive])}",
           servers: %{"docs" => %{command: elixir, args: [script], env: %{}}},
           timeout_ms: 15_000}
        )

      assert {:ok, [_, _]} = Manager.list_resources(manager, "docs")
      assert {:ok, [_, _]} = Manager.list_resources("docs", manager)

      assert {:ok, %{"contents" => [%{"text" => text}]}} =
               Manager.read_resource(manager, "docs", "file:///workspace/README.md")

      assert text =~ "Hello MCP resources!"

      assert {:ok, %{"contents" => [_]}} =
               Manager.read_resource("docs", "file:///workspace/README.md", manager)

      assert {:ok, [%{"name" => "code_review"}, %{"name" => "summarize"}]} =
               Manager.list_prompts(manager, "docs")

      assert {:ok, %{"messages" => [%{"content" => %{"text" => prompt_text}}]}} =
               Manager.get_prompt(manager, "docs", "code_review", %{"language" => "otp"})

      assert prompt_text == "Please review this otp code."

      assert {:ok, %{"messages" => [_]}} =
               Manager.get_prompt("docs", "code_review", %{"language" => "beam"}, manager)

      assert {:error, :mcp_server_unknown} = Manager.list_resources(manager, "missing")
      assert {:error, :mcp_server_unknown} = Manager.read_resource(manager, "missing", "x://y")
      assert {:error, :mcp_server_unknown} = Manager.list_prompts(manager, "missing")
      assert {:error, :mcp_server_unknown} = Manager.get_prompt(manager, "missing", "p", %{})
    end
  end

  describe "Manager crash isolation, lazy reconnect, and explicit reconnect" do
    test "killing one MCP Client never crashes Manager or sibling servers, and lazy reconnect recovers",
         %{elixir: elixir, script: script} do
      manager =
        start_supervised!(
          {Manager,
           name: :"mcp_isolation_mgr_#{System.unique_integer([:positive])}",
           servers: %{
             "alpha" => %{command: elixir, args: [script], env: %{}},
             "beta" => %{command: elixir, args: [script], env: %{}}
           },
           timeout_ms: 15_000}
        )

      assert Manager.list_servers(manager) == ["alpha", "beta"]
      assert {:ok, alpha_initial} = Manager.server_status("alpha", manager)
      assert {:ok, beta_initial} = Manager.server_status("beta", manager)

      alpha_pid = alpha_initial.pid
      beta_pid = beta_initial.pid
      assert is_pid(alpha_pid)
      assert is_pid(beta_pid)

      # Brutally kill alpha's Client process
      alpha_ref = Process.monitor(alpha_pid)
      Process.exit(alpha_pid, :kill)
      assert_receive {:DOWN, ^alpha_ref, :process, ^alpha_pid, :killed}, 5_000

      # Synchronize Manager mailbox deterministically without sleeping
      _ = :sys.get_state(manager)

      # Sibling beta and Manager remain completely healthy with identical pid
      assert Manager.list_servers(manager) == ["beta"]
      assert {:ok, beta_after} = Manager.server_status("beta", manager)
      assert beta_after.pid == beta_pid
      assert beta_after.status == :connected
      assert beta_after.crash_count == 0

      assert {:ok, %{"content" => [%{"text" => "echo:beta_alive"}]}} =
               Manager.call_tool(manager, "beta", "echo", %{"text" => "beta_alive"})

      # Alpha reflects crashed metadata
      assert {:ok, alpha_crashed} = Manager.server_status("alpha", manager)
      assert alpha_crashed.pid == nil
      assert alpha_crashed.status == :crashed
      assert alpha_crashed.crash_count == 1
      assert alpha_crashed.last_error == :killed

      # Lazy reconnect on next call_tool using stored config!
      assert {:ok, %{"content" => [%{"text" => "echo:lazily_reconnected"}]}} =
               Manager.call_tool(manager, "alpha", "echo", %{"text" => "lazily_reconnected"})

      assert {:ok, alpha_recovered} = Manager.server_status("alpha", manager)
      assert is_pid(alpha_recovered.pid)
      assert alpha_recovered.pid != alpha_pid
      assert alpha_recovered.status == :connected
      assert alpha_recovered.crash_count == 1
      assert alpha_recovered.last_error == nil
      assert Manager.list_servers(manager) == ["alpha", "beta"]
    end

    test "OS subprocess crash isolates cleanly, increments crash_count, and supports explicit reconnect",
         %{elixir: elixir, script: script} do
      manager =
        start_supervised!(
          {Manager,
           name: :"mcp_subproc_mgr_#{System.unique_integer([:positive])}",
           servers: %{
             "crasher" => %{command: elixir, args: [script], env: %{}},
             "survivor" => %{command: elixir, args: [script], env: %{}}
           },
           timeout_ms: 15_000}
        )

      {:ok, before_status} = Manager.server_status("crasher", manager)
      {:ok, survivor_before} = Manager.server_status("survivor", manager)

      assert {:error, {:mcp_server_exited, 2}} =
               Manager.call_tool(manager, "crasher", "crash_subprocess", %{})

      _ = :sys.get_state(manager)

      {:ok, crashed_status} = Manager.server_status("crasher", manager)
      assert crashed_status.status == :crashed
      assert crashed_status.crash_count == 1
      assert crashed_status.last_error == {:mcp_server_exited, 2}

      # Survivor is completely unaffected
      {:ok, survivor_after} = Manager.server_status("survivor", manager)
      assert survivor_after.pid == survivor_before.pid

      assert {:ok, %{"content" => [%{"text" => "echo:still_here"}]}} =
               Manager.call_tool(manager, "survivor", "echo", %{"text" => "still_here"})

      # Explicit reconnect/2 restores crasher
      assert {:ok, reconnected_status} = Manager.reconnect("crasher", manager)
      assert is_pid(reconnected_status.pid)
      assert reconnected_status.pid != before_status.pid
      assert reconnected_status.status == :connected
      assert reconnected_status.crash_count == 1
      assert reconnected_status.last_error == nil

      assert {:ok, %{"content" => [%{"text" => "echo:back"}]}} =
               Manager.call_tool(manager, "crasher", "echo", %{"text" => "back"})
    end

    test "dynamic start_server, stop_server, and single-attempt failed lazy reconnect", %{
      elixir: elixir,
      script: script,
      tmp_dir: tmp_dir
    } do
      ephemeral_bin = Path.join(tmp_dir, "ephemeral_runner.sh")
      File.write!(ephemeral_bin, "#!/bin/sh\nexec \"#{elixir}\" \"#{script}\"\n")
      File.chmod!(ephemeral_bin, 0o755)

      manager =
        start_supervised!(
          {Manager,
           name: :"mcp_dyn_mgr_#{System.unique_integer([:positive])}",
           servers: %{},
           timeout_ms: 15_000}
        )

      assert Manager.list_servers(manager) == []

      assert {:ok, started} =
               Manager.start_server(manager, "dyn", %{command: ephemeral_bin, args: [], env: %{}})

      assert started.status == :connected
      assert Manager.list_servers(manager) == ["dyn"]

      # Remove binary and crash client so lazy reconnect fails cleanly once
      File.rm!(ephemeral_bin)
      dyn_ref = Process.monitor(started.pid)
      Process.exit(started.pid, :kill)
      assert_receive {:DOWN, ^dyn_ref, :process, _, :killed}, 5_000
      _ = :sys.get_state(manager)

      assert {:error, {:mcp_no_command, ^ephemeral_bin}} =
               Manager.call_tool(manager, "dyn", "echo", %{"text" => "x"})

      assert :ok = Manager.stop_server(manager, "dyn")
      assert {:error, :mcp_server_unknown} = Manager.server_status("dyn", manager)
    end
  end

  describe "Non-blocking concurrent Manager.call_tool across servers" do
    test "slow gated tool call on Server A never blocks list_servers, list_tools, or fast calls on Server B",
         %{elixir: elixir, script: script} do
      {:ok, gate_listen} = open_loopback_listener()
      on_exit(fn -> :gen_tcp.close(gate_listen) end)
      gate_port = listener_port(gate_listen)

      manager =
        start_supervised!(
          {Manager,
           name: :"mcp_concurrent_mgr_#{System.unique_integer([:positive])}",
           servers: %{
             "server_a" => %{
               command: elixir,
               args: [script],
               env: %{"GATE_PORT" => Integer.to_string(gate_port)}
             },
             "server_b" => %{command: elixir, args: [script], env: %{}}
           },
           timeout_ms: 30_000}
        )

      slow_task =
        Task.async(fn ->
          Manager.call_tool(manager, "server_a", "gated_tool", %{}, timeout_ms: 30_000)
        end)

      # Deterministically wait until Server A has entered the blocking tool handler
      {:ok, gate_conn} = :gen_tcp.accept(gate_listen, 5_000)
      assert {:ok, "entered\n"} = :gen_tcp.recv(gate_conn, 0, 5_000)

      # While Server A is completely blocked, Manager queries and Server B calls succeed immediately!
      assert Manager.list_servers(manager) == ["server_a", "server_b"]
      assert {:ok, [_ | _]} = Manager.list_tools(manager, "server_a")
      assert {:ok, [_ | _]} = Manager.list_tools(manager, "server_b")
      assert {:ok, %{status: :connected}} = Manager.server_status("server_a", manager)

      fast_results =
        1..5
        |> Task.async_stream(
          fn idx ->
            Manager.call_tool(manager, "server_b", "echo", %{"text" => "fast_#{idx}"})
          end,
          timeout: 5_000
        )
        |> Enum.to_list()

      assert Enum.all?(fast_results, fn
               {:ok, {:ok, %{"content" => [%{"text" => "echo:fast_" <> _}]}}} -> true
               _ -> false
             end)

      # Confirm Server A is still blocked right up until we release the TCP gate
      assert Task.yield(slow_task, 0) == nil

      :ok = :gen_tcp.send(gate_conn, "release\n")
      assert {:ok, %{"content" => [%{"text" => "gate_released"}]}} = Task.await(slow_task, 5_000)
      :gen_tcp.close(gate_conn)
    end
  end

  describe "ToolBridge isError propagation and UTF-8 output truncation" do
    test "returns {:error, {:mcp_tool_error, text}} for both string and atom isError: true", %{
      elixir: elixir,
      script: script
    } do
      manager =
        start_supervised!(
          {Manager,
           name: :"mcp_bridge_mgr_#{System.unique_integer([:positive])}",
           servers: %{"srv" => %{command: elixir, args: [script], env: %{}}},
           timeout_ms: 15_000}
        )

      assert {:error, {:mcp_tool_error, "tool failed: permission denied"}} =
               ToolBridge.execute(manager, "mcp__srv__fail_tool", %{
                 "reason" => "permission denied"
               })

      assert {:ok, "all good"} =
               ToolBridge.execute(manager, "mcp__srv__ok_false_error_tool", %{})

      # Verify atom-key :isError => true handling via lightweight OTP process stub
      fake_client =
        spawn_link(fn ->
          receive do
            {:"$gen_call", from, {:managed_request, "tools/call", _params, _timeout}} ->
              GenServer.reply(
                from,
                {:ok, %{isError: true, content: [%{type: "text", text: "atom isError boom"}]}}
              )
          end
        end)

      fake_manager =
        spawn_link(fn ->
          receive do
            {:"$gen_call", from, {:resolve_client, "atom_srv", _}} ->
              GenServer.reply(from, {:ok, fake_client, false})
          end
        end)

      assert {:error, {:mcp_tool_error, "atom isError boom"}} =
               ToolBridge.execute(fake_manager, "mcp__atom_srv__boom", %{})
    end

    test "bounds oversized multi-byte UTF-8 tool outputs to @max_output_bytes cleanly", %{
      elixir: elixir,
      script: script
    } do
      manager =
        start_supervised!(
          {Manager,
           name: :"mcp_trunc_mgr_#{System.unique_integer([:positive])}",
           servers: %{"srv" => %{command: elixir, args: [script], env: %{}}},
           timeout_ms: 15_000}
        )

      # 25_000 * 16 bytes ("🚀é€-chunk-") = 400_000 bytes > 256_000 (@max_output_bytes)
      assert {:ok, truncated} =
               ToolBridge.execute(manager, "mcp__srv__huge_output", %{"repeat" => 25_000})

      assert is_binary(truncated)
      assert byte_size(truncated) <= ToolBridge.max_output_bytes()
      assert String.valid?(truncated)
      assert truncated =~ "[truncated MCP output at 256000 bytes; original 400000 bytes]"

      # Also bounds oversized error outputs cleanly
      assert {:error, {:mcp_tool_error, truncated_err}} =
               ToolBridge.execute(manager, "mcp__srv__huge_output", %{
                 "repeat" => 25_000,
                 "as_error" => true
               })

      assert byte_size(truncated_err) <= ToolBridge.max_output_bytes()
      assert String.valid?(truncated_err)
      assert truncated_err =~ "[truncated MCP output at 256000 bytes; original 400000 bytes]"
    end

    test "preserves exact max_output_bytes boundary and never splits 4-byte UTF-8 codepoints" do
      max = ToolBridge.max_output_bytes()
      exact = :binary.copy("a", max)
      assert ToolBridge.truncate_output(exact, max) == exact

      # Test all 4 byte alignments of a 4-byte UTF-8 emoji ("🚀") across cut boundary
      for pad <- 0..3 do
        text = :binary.copy("a", pad) <> String.duplicate("🚀", div(max, 4) + 10)
        out = ToolBridge.truncate_output(text, max)
        assert byte_size(out) <= max
        assert String.valid?(out)
        assert out =~ "[truncated MCP output"
      end
    end

    test "coalesces concurrent lazy reconnect callers after sudden Client crash", %{
      elixir: elixir,
      script: script
    } do
      manager =
        start_supervised!(
          {Manager,
           name: :"mcp_coalesce_mgr_#{System.unique_integer([:positive])}",
           servers: %{"shared" => %{command: elixir, args: [script], env: %{}}},
           timeout_ms: 15_000}
        )

      {:ok, initial} = Manager.server_status("shared", manager)
      Process.exit(initial.pid, :kill)

      # Immediately fire 5 concurrent tool calls with zero synchronization delay
      results =
        1..5
        |> Task.async_stream(
          fn idx ->
            Manager.call_tool(manager, "shared", "echo", %{"text" => "c_#{idx}"})
          end,
          timeout: 15_000
        )
        |> Enum.to_list()

      assert Enum.all?(results, fn
               {:ok, {:ok, %{"content" => [%{"text" => "echo:c_" <> _}]}}} -> true
               _ -> false
             end)

      {:ok, after_status} = Manager.server_status("shared", manager)
      assert after_status.status == :connected
      assert is_pid(after_status.pid)
      assert after_status.pid != initial.pid
      assert after_status.crash_count == 1
    end
  end

  defp open_loopback_listener do
    :gen_tcp.listen(0, [
      :binary,
      ip: {127, 0, 0, 1},
      packet: :line,
      active: false,
      reuseaddr: true
    ])
  end

  defp listener_port(socket) do
    {:ok, port} = :inet.port(socket)
    port
  end

  defp server_script_source do
    ~S"""
    life_sock =
      case System.get_env("LIFE_PORT") do
        port_str when is_binary(port_str) and port_str != "" ->
          {:ok, sock} =
            :gen_tcp.connect({127, 0, 0, 1}, String.to_integer(port_str), [
              :binary,
              packet: :line,
              active: false
            ])

          :ok = :gen_tcp.send(sock, "booted\n")
          sock

        _ ->
          nil
      end

    _keep_alive_ref = life_sock

    extract = fn line, regex ->
      case Regex.run(regex, line) do
        [_, val] -> String.trim(val)
        _ -> nil
      end
    end

    wait_gate = fn ->
      gate_port = String.to_integer(System.fetch_env!("GATE_PORT"))

      {:ok, sock} =
        :gen_tcp.connect({127, 0, 0, 1}, gate_port, [:binary, packet: :line, active: false])

      :ok = :gen_tcp.send(sock, "entered\n")
      _ = :gen_tcp.recv(sock, 0)
      :gen_tcp.close(sock)
    end

    respond = fn id, body ->
      IO.write(:stdio, ~s({"jsonrpc":"2.0","id":#{id},"result":{#{body}}}\n))
    end

    respond_error = fn id, code, message ->
      IO.write(:stdio, ~s({"jsonrpc":"2.0","id":#{id},"error":{"code":#{code},"message":"#{message}"}}\n))
    end

    loop = fn loop_fn ->
      case IO.read(:stdio, :line) do
        :eof ->
          :ok

        {:error, _} ->
          :ok

        line when is_binary(line) ->
          id = extract.(line, ~r/"id"\s*:\s*([0-9]+)/)
          method = extract.(line, ~r/"method"\s*:\s*"([^"]+)"/)

          case {id, method} do
            {nil, _} ->
              :ok

            {_id, "notifications/initialized"} ->
              :ok

            {id, "initialize"} ->
              respond.(
                id,
                ~s("protocolVersion":"2024-11-05","capabilities":{"tools":{},"resources":{},"prompts":{}},"serverInfo":{"name":"resilient","version":"1.0"})
              )

            {id, "tools/list"} ->
              respond.(
                id,
                ~s("tools":[{"name":"echo","description":"Echo text","inputSchema":{"type":"object"}},{"name":"gated_tool","description":"Blocks on TCP gate","inputSchema":{"type":"object"}},{"name":"fail_tool","description":"Returns isError true","inputSchema":{"type":"object"}},{"name":"ok_false_error_tool","description":"Returns isError false","inputSchema":{"type":"object"}},{"name":"huge_output","description":"Returns UTF-8 payload","inputSchema":{"type":"object"}},{"name":"flood_no_newline","description":"Streams raw bytes without newline","inputSchema":{"type":"object"}},{"name":"crash_subprocess","description":"Halts process","inputSchema":{"type":"object"}}])
              )

            {id, "tools/call"} ->
              name = extract.(line, ~r/"name"\s*:\s*"([^"]+)"/)

              case name do
                "echo" ->
                  text = extract.(line, ~r/"text"\s*:\s*"((?:[^"\\]|\\.)*)"/) || ""
                  respond.(id, ~s("content":[{"type":"text","text":"echo:#{text}"}]))

                "gated_tool" ->
                  wait_gate.()
                  respond.(id, ~s("content":[{"type":"text","text":"gate_released"}]))

                "fail_tool" ->
                  reason = extract.(line, ~r/"reason"\s*:\s*"((?:[^"\\]|\\.)*)"/) || "error"
                  respond.(id, ~s("isError":true,"content":[{"type":"text","text":"tool failed: #{reason}"}]))

                "ok_false_error_tool" ->
                  respond.(id, ~s("isError":false,"content":[{"type":"text","text":"all good"}]))

                "huge_output" ->
                  repeat =
                    case extract.(line, ~r/"repeat"\s*:\s*([0-9]+)/) do
                      nil -> 25_000
                      n -> String.to_integer(n)
                    end

                  as_error = String.contains?(line, ~s("as_error":true))
                  chunk = "🚀é€-chunk-"
                  payload = String.duplicate(chunk, repeat)
                  err_flag = if as_error, do: ~s("isError":true,), else: ""
                  respond.(id, ~s(#{err_flag}"content":[{"type":"text","text":"#{payload}"}]))

                "flood_no_newline" ->
                  bytes =
                    case extract.(line, ~r/"bytes"\s*:\s*([0-9]+)/) do
                      nil -> 8_500_000
                      n -> String.to_integer(n)
                    end

                  block = :binary.copy("x", 65_536)
                  full_blocks = div(bytes, 65_536)
                  rem_bytes = rem(bytes, 65_536)

                  Enum.each(1..full_blocks, fn _ -> IO.binwrite(:stdio, block) end)
                  if rem_bytes > 0, do: IO.binwrite(:stdio, :binary.copy("x", rem_bytes))

                "crash_subprocess" ->
                  System.halt(2)

                _ ->
                  respond_error.(id, -32602, "unknown tool")
              end

            {id, "resources/list"} ->
              respond.(
                id,
                ~s("resources":[{"uri":"file:///workspace/README.md","name":"README.md","mimeType":"text/markdown"},{"uri":"file:///workspace/config.json","name":"config.json","mimeType":"application/json"}])
              )

            {id, "resources/read"} ->
              uri = extract.(line, ~r/"uri"\s*:\s*"([^"]+)"/)

              case uri do
                "file:///workspace/README.md" ->
                  respond.(
                    id,
                    ~s("contents":[{"uri":"file:///workspace/README.md","mimeType":"text/markdown","text":"# Project Readme\\nHello MCP resources!"}])
                  )

                "gated://resource" ->
                  wait_gate.()
                  respond.(id, ~s("contents":[{"uri":"gated://resource","text":"done"}]))

                _ ->
                  respond_error.(id, -32002, "Resource not found")
              end

            {id, "prompts/list"} ->
              respond.(
                id,
                ~s("prompts":[{"name":"code_review","description":"Review source code"},{"name":"summarize","description":"Summarize module"}])
              )

            {id, "prompts/get"} ->
              pname = extract.(line, ~r/"name"\s*:\s*"([^"]+)"/)

              case pname do
                "code_review" ->
                  lang = extract.(line, ~r/"language"\s*:\s*"([^"]+)"/) || "unknown"

                  respond.(
                    id,
                    ~s("description":"Code review prompt","messages":[{"role":"user","content":{"type":"text","text":"Please review this #{lang} code."}}])
                  )

                _ ->
                  respond_error.(id, -32602, "Unknown prompt")
              end

            {id, _other} ->
              respond_error.(id, -32601, "method not found")
          end

          loop_fn.(loop_fn)
      end
    end

    loop.(loop)
    """
  end
end
