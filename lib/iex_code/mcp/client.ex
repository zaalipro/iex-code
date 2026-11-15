defmodule IexCode.MCP.Client do
  @moduledoc """
  Stdio MCP (Model Context Protocol) client over newline-delimited JSON-RPC 2.0.

  Spawns `command` with `args`, speaks newline-delimited JSON-RPC on its stdio,
  correlates responses by request id, enforces bounded read buffers, and cleans
  up child ports and in-flight callers on shutdown.

  Supports `initialize`, `tools/list`, `tools/call`, `resources/list`,
  `resources/read`, `prompts/list`, and `prompts/get`.
  """

  use GenServer
  require Logger

  @protocol_version "2024-11-05"
  @default_timeout_ms 30_000
  @default_list_resources_timeout_ms 10_000
  @default_read_resource_timeout_ms 15_000
  @default_list_prompts_timeout_ms 10_000
  @default_get_prompt_timeout_ms 15_000
  @max_buffer_bytes 8_388_608

  @doc "Maximum buffered stdout bytes allowed before failing a stream without a newline."
  @spec max_buffer_bytes() :: pos_integer()
  def max_buffer_bytes, do: @max_buffer_bytes

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec start(keyword()) :: GenServer.on_start()
  def start(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start(__MODULE__, opts, name: name)
  end

  @doc "Runs MCP initialize + initialized notification."
  @spec initialize(GenServer.server(), keyword() | pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def initialize(server, opts \\ []) do
    timeout = resolve_timeout(opts, @default_timeout_ms)

    case dispatch_request(server, "initialize", initialize_params(), timeout, opts) do
      {:ok, info} ->
        case notify_initialized(server, timeout) do
          :ok -> {:ok, info}
          {:error, _reason} = error -> error
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Lists tools exposed by the server."
  @spec list_tools(GenServer.server(), keyword() | pos_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def list_tools(server, opts \\ []) do
    timeout = resolve_timeout(opts, @default_timeout_ms)

    case dispatch_request(server, "tools/list", cursor_params(opts), timeout, opts) do
      {:ok, %{"tools" => tools}} when is_list(tools) -> {:ok, tools}
      {:ok, _other} -> {:error, :mcp_bad_tools_list}
      {:error, _reason} = error -> error
    end
  end

  @doc "Calls a tool by name with a JSON-encodable arguments map."
  @spec call_tool(GenServer.server(), String.t(), map(), keyword() | pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def call_tool(server, name, args, opts \\ [])
      when is_binary(name) and is_map(args) do
    timeout = resolve_timeout(opts, @default_timeout_ms)

    dispatch_request(
      server,
      "tools/call",
      %{"name" => name, "arguments" => args},
      timeout,
      opts
    )
  end

  @doc "Lists resources exposed by the server (`resources/list`)."
  @spec list_resources(GenServer.server(), pos_integer() | keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def list_resources(client, timeout \\ @default_list_resources_timeout_ms) do
    timeout_ms = resolve_timeout(timeout, @default_list_resources_timeout_ms)

    case dispatch_request(client, "resources/list", cursor_params(timeout), timeout_ms, timeout) do
      {:ok, %{"resources" => resources}} when is_list(resources) -> {:ok, resources}
      {:ok, _other} -> {:error, :mcp_bad_resources_list}
      {:error, _reason} = error -> error
    end
  end

  @doc "Reads a resource by URI (`resources/read`)."
  @spec read_resource(GenServer.server(), String.t(), pos_integer() | keyword()) ::
          {:ok, map()} | {:error, term()}
  def read_resource(client, uri, timeout \\ @default_read_resource_timeout_ms)
      when is_binary(uri) do
    timeout_ms = resolve_timeout(timeout, @default_read_resource_timeout_ms)
    dispatch_request(client, "resources/read", %{"uri" => uri}, timeout_ms, timeout)
  end

  @doc "Lists prompt templates exposed by the server (`prompts/list`)."
  @spec list_prompts(GenServer.server(), pos_integer() | keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def list_prompts(client, timeout \\ @default_list_prompts_timeout_ms) do
    timeout_ms = resolve_timeout(timeout, @default_list_prompts_timeout_ms)

    case dispatch_request(client, "prompts/list", cursor_params(timeout), timeout_ms, timeout) do
      {:ok, %{"prompts" => prompts}} when is_list(prompts) -> {:ok, prompts}
      {:ok, _other} -> {:error, :mcp_bad_prompts_list}
      {:error, _reason} = error -> error
    end
  end

  @doc "Fetches a prompt by name with optional arguments (`prompts/get`)."
  @spec get_prompt(GenServer.server(), String.t(), map(), pos_integer() | keyword()) ::
          {:ok, map()} | {:error, term()}
  def get_prompt(client, name, arguments \\ %{}, timeout \\ @default_get_prompt_timeout_ms)
      when is_binary(name) and is_map(arguments) do
    timeout_ms = resolve_timeout(timeout, @default_get_prompt_timeout_ms)

    dispatch_request(
      client,
      "prompts/get",
      %{"name" => name, "arguments" => arguments},
      timeout_ms,
      timeout
    )
  end

  @doc false
  @spec request(GenServer.server(), String.t(), map(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def request(server, method, params, timeout) do
    dispatch_request(server, method, params, timeout, [])
  end

  defp dispatch_request(server, method, params, timeout, opts) do
    tag =
      if is_list(opts) and Keyword.get(opts, :managed, false),
        do: :managed_request,
        else: :request

    GenServer.call(server, {tag, method, params, timeout}, timeout + 5_000)
  catch
    :exit, {:timeout, _} -> {:error, :mcp_request_timeout}
    :exit, {:normal, _} -> {:error, :client_stopping}
    :exit, {:shutdown, _} -> {:error, :client_stopping}
    :exit, {{:shutdown, _}, _} -> {:error, :client_stopping}
    :exit, {:noproc, _} -> {:error, :client_stopped}
    :exit, {reason, _} -> {:error, {:mcp_client_exit, reason}}
  end

  defp notify_initialized(server, timeout) do
    GenServer.call(server, :notify_initialized, timeout + 5_000)
  catch
    :exit, {:timeout, _} -> {:error, :mcp_request_timeout}
    :exit, {:normal, _} -> {:error, :client_stopping}
    :exit, {:shutdown, _} -> {:error, :client_stopping}
    :exit, {{:shutdown, _}, _} -> {:error, :client_stopping}
    :exit, {:noproc, _} -> {:error, :client_stopped}
    :exit, {reason, _} -> {:error, {:mcp_client_exit, reason}}
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    command = Keyword.fetch!(opts, :command)
    args = Keyword.get(opts, :args, [])
    env = Keyword.get(opts, :env, %{})
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    max_buffer = normalize_max_buffer(Keyword.get(opts, :max_buffer_bytes, @max_buffer_bytes))
    notify_parent = Keyword.get(opts, :notify_parent)

    with {:ok, executable} <- resolve_executable(command),
         {:ok, port} <- open_stdio_port(executable, args, env) do
      {:ok,
       %{
         port: port,
         os_pid: port_os_pid(port),
         buffer: "",
         next_id: 1,
         pending: %{},
         exited: nil,
         timeout_ms: timeout,
         max_buffer_bytes: max_buffer,
         notify_parent: notify_parent
       }}
    end
  end

  @impl true
  def handle_call(
        {:managed_request, _method, _params, _timeout},
        _from,
        %{exited: status} = state
      )
      when not is_nil(status) do
    {:reply, {:error, {:mcp_already_exited, status}}, state}
  end

  def handle_call({:managed_request, method, params, timeout}, from, state) do
    enqueue_request(method, params, timeout, from, state)
  end

  def handle_call({:request, _method, _params, _timeout}, _from, %{exited: status} = state)
      when not is_nil(status) do
    {:reply, {:error, {:mcp_server_exited, status}}, state}
  end

  def handle_call({:request, method, params, timeout}, from, state) do
    enqueue_request(method, params, timeout, from, state)
  end

  def handle_call({:request, method, params}, from, %{exited: nil} = state) do
    enqueue_request(method, params, state.timeout_ms, from, state)
  end

  def handle_call({:request, _method, _params}, _from, %{exited: status} = state) do
    {:reply, {:error, {:mcp_server_exited, status}}, state}
  end

  def handle_call(:notify_initialized, _from, %{exited: nil} = state) do
    with {:ok, line} <-
           Jason.encode(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"}),
         :ok <- safe_port_command(state.port, line <> "\n") do
      {:reply, :ok, state}
    else
      {:error, :port_closed} ->
        state = mark_port_exited(state, :epipe)
        {:reply, {:error, {:mcp_server_exited, :epipe}}, state}

      {:error, reason} ->
        {:reply, {:error, {:mcp_encode, reason}}, state}
    end
  end

  def handle_call(:notify_initialized, _from, state) do
    {:reply, {:error, {:mcp_server_exited, state.exited}}, state}
  end

  @impl true
  def handle_info({port, {:data, _bytes}}, %{port: port, exited: exited} = state)
      when not is_nil(exited) do
    {:noreply, state}
  end

  def handle_info({port, {:data, bytes}}, %{port: port} = state) when is_binary(bytes) do
    {:noreply, consume_data(state, bytes)}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    if is_nil(state.exited) do
      notify_parent_exit(state.notify_parent, {:mcp_server_exited, status})
      {:noreply, fail_all(%{state | exited: status}, {:mcp_server_exited, status})}
    else
      {:noreply, state}
    end
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    if is_nil(state.exited) do
      notify_parent_exit(state.notify_parent, {:mcp_server_exited, reason})
      {:noreply, fail_all(%{state | exited: reason}, {:mcp_server_exited, reason})}
    else
      {:noreply, state}
    end
  end

  def handle_info({:EXIT, parent, reason}, %{notify_parent: parent} = state)
      when is_pid(parent) do
    {:stop, reason, state}
  end

  def handle_info({:request_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {%{from: from}, pending} ->
        GenServer.reply(from, {:error, :mcp_request_timeout})
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _state = fail_all(state, :client_stopping)
    close_port(state.port, state.os_pid, state.exited)
    :ok
  end

  defp enqueue_request(method, params, timeout, from, state) do
    id = state.next_id
    payload = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

    with {:ok, line} <- Jason.encode(payload),
         :ok <- safe_port_command(state.port, line <> "\n") do
      timer = Process.send_after(self(), {:request_timeout, id}, timeout)
      pending = Map.put(state.pending, id, %{from: from, timer: timer})
      {:noreply, %{state | next_id: id + 1, pending: pending}}
    else
      {:error, :port_closed} ->
        state = mark_port_exited(state, :epipe)
        {:reply, {:error, {:mcp_server_exited, :epipe}}, state}

      {:error, reason} ->
        {:reply, {:error, {:mcp_encode, reason}}, state}
    end
  end

  defp safe_port_command(port, iodata) do
    if Port.info(port) != nil do
      true = Port.command(port, iodata)
      :ok
    else
      {:error, :port_closed}
    end
  rescue
    ArgumentError -> {:error, :port_closed}
  end

  defp mark_port_exited(%{exited: nil} = state, reason) do
    notify_parent_exit(state.notify_parent, {:mcp_server_exited, reason})
    fail_all(%{state | exited: reason}, {:mcp_server_exited, reason})
  end

  defp mark_port_exited(state, _reason), do: state

  defp consume_data(state, <<>>), do: state

  defp consume_data(state, bytes) do
    case :binary.match(bytes, "\n") do
      :nomatch ->
        if byte_size(state.buffer) + byte_size(bytes) > state.max_buffer_bytes do
          overflow_buffer(state)
        else
          %{state | buffer: state.buffer <> bytes}
        end

      {pos, 1} ->
        if byte_size(state.buffer) + pos > state.max_buffer_bytes do
          overflow_buffer(state)
        else
          <<head::binary-size(pos), "\n", tail::binary>> = bytes
          line = state.buffer <> head
          next_state = %{state | buffer: ""} |> handle_line(line)

          if tail == "" or not is_nil(next_state.exited) do
            next_state
          else
            consume_data(next_state, tail)
          end
        end
    end
  end

  defp overflow_buffer(state) do
    Logger.warning(
      "mcp: buffer exceeded #{state.max_buffer_bytes} bytes without newline; closing port"
    )

    close_port(state.port, state.os_pid, state.exited)
    notify_parent_exit(state.notify_parent, :mcp_buffer_overflow)
    fail_all(%{state | exited: :mcp_buffer_overflow}, :mcp_buffer_overflow)
  end

  defp handle_line(state, line) do
    trimmed = String.trim_trailing(line, "\r")

    if trimmed == "" do
      state
    else
      case Jason.decode(trimmed) do
        {:ok, %{"id" => id} = message} when not is_nil(id) ->
          deliver_response(state, id, message)

        {:ok, _notification} ->
          state

        {:error, _reason} ->
          Logger.warning("mcp: dropping undecodable server line")
          state
      end
    end
  end

  defp deliver_response(state, id, message) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        state

      {%{from: from, timer: timer}, pending} ->
        _ = Process.cancel_timer(timer)
        GenServer.reply(from, response_result(message))
        %{state | pending: pending}
    end
  end

  defp response_result(%{"result" => result}), do: {:ok, result}

  defp response_result(%{"error" => %{"code" => code, "message" => message}}),
    do: {:error, {:mcp_error, code, message}}

  defp response_result(%{"error" => error}), do: {:error, {:mcp_error, error}}
  defp response_result(_message), do: {:error, :mcp_bad_response}

  defp fail_all(state, reason) do
    Enum.each(state.pending, fn {_id, %{from: from, timer: timer}} ->
      _ = Process.cancel_timer(timer)
      GenServer.reply(from, {:error, reason})
    end)

    %{state | pending: %{}, buffer: ""}
  end

  defp close_port(port, os_pid, exited) do
    live_os_pid = port_os_pid(port) || if(is_nil(exited), do: os_pid, else: nil)

    if is_port(port) and Port.info(port) != nil do
      try do
        Port.close(port)
      catch
        _, _ -> :ok
      end
    end

    if is_integer(live_os_pid) and live_os_pid > 0 and match?({:unix, _}, :os.type()) do
      kill_bin = System.find_executable("kill") || "/bin/kill"

      try do
        _ =
          System.cmd(kill_bin, ["-TERM", Integer.to_string(live_os_pid)], stderr_to_stdout: true)
      rescue
        _ -> :ok
      end
    end

    :ok
  end

  defp port_os_pid(port) when is_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) -> pid
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp port_os_pid(_other), do: nil

  defp notify_parent_exit(pid, reason) when is_pid(pid) do
    send(pid, {:mcp_client_exited, self(), reason})
  end

  defp notify_parent_exit(_other, _reason), do: :ok

  defp resolve_timeout(timeout, _default) when is_integer(timeout) and timeout > 0, do: timeout

  defp resolve_timeout(opts, default) when is_list(opts) do
    case Keyword.get(opts, :timeout_ms) || Keyword.get(opts, :timeout) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> default
    end
  end

  defp resolve_timeout(_other, default), do: default

  defp cursor_params(opts) when is_list(opts) do
    case Keyword.get(opts, :cursor) do
      cursor when is_binary(cursor) and cursor != "" -> %{"cursor" => cursor}
      _ -> %{}
    end
  end

  defp cursor_params(_other), do: %{}

  defp normalize_max_buffer(bytes) when is_integer(bytes) and bytes > 0, do: bytes
  defp normalize_max_buffer(bytes) when is_integer(bytes) and bytes <= 0, do: 1
  defp normalize_max_buffer(_other), do: @max_buffer_bytes

  defp open_stdio_port(executable, args, env) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :use_stdio,
        args: Enum.map(args, &to_string/1),
        env: format_port_env(env)
      ])

    {:ok, port}
  rescue
    error in ArgumentError -> {:error, {:mcp_port_open, Exception.message(error)}}
  end

  defp format_port_env(env) when is_map(env) or is_list(env) do
    Enum.map(env, fn
      {k, nil} -> {String.to_charlist(to_string(k)), false}
      {k, false} -> {String.to_charlist(to_string(k)), false}
      {k, v} -> {String.to_charlist(to_string(k)), String.to_charlist(to_string(v))}
    end)
  end

  defp format_port_env(_other), do: []

  defp resolve_executable(command) when is_binary(command) do
    if String.contains?(command, "/") do
      if File.exists?(command), do: {:ok, command}, else: {:error, {:mcp_no_command, command}}
    else
      case System.find_executable(command) do
        nil -> {:error, {:mcp_no_command, command}}
        path -> {:ok, path}
      end
    end
  end

  defp resolve_executable(_command), do: {:error, :mcp_bad_command}

  defp initialize_params do
    %{
      "protocolVersion" => @protocol_version,
      "capabilities" => %{"tools" => %{}, "resources" => %{}, "prompts" => %{}},
      "clientInfo" => %{"name" => "iex-code", "version" => "0.1.0"}
    }
  end
end
