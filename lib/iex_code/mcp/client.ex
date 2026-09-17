defmodule IexCode.MCP.Client do
  @moduledoc """
  Minimal MCP (Model Context Protocol) stdio client over JSON-RPC 2.0.

  Spawns `command` with `args`, speaks newline-delimited JSON-RPC on its
  stdio, and correlates responses by request id. Supports `initialize`,
  `tools/list`, and `tools/call` — enough to bridge MCP servers as agent
  tools (see `IexCode.MCP.ToolBridge`).
  """

  use GenServer
  require Logger

  @protocol_version "2024-11-05"
  @default_timeout_ms 30_000
  @max_line_bytes 8_000_000

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Runs MCP initialize + initialized notification."
  @spec initialize(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def initialize(server, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    case request(server, "initialize", initialize_params(), timeout) do
      {:ok, info} ->
        :ok = GenServer.call(server, :notify_initialized)
        {:ok, info}

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Lists tools exposed by the server."
  @spec list_tools(GenServer.server(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_tools(server, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    case request(server, "tools/list", %{}, timeout) do
      {:ok, %{"tools" => tools}} when is_list(tools) -> {:ok, tools}
      {:ok, _other} -> {:error, :mcp_bad_tools_list}
      {:error, _reason} = error -> error
    end
  end

  @doc "Calls a tool by name with a JSON-encodable arguments map."
  @spec call_tool(GenServer.server(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def call_tool(server, name, args, opts \\ [])
      when is_binary(name) and is_map(args) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    request(server, "tools/call", %{"name" => name, "arguments" => args}, timeout)
  end

  @doc false
  @spec request(GenServer.server(), String.t(), map(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def request(server, method, params, timeout) do
    GenServer.call(server, {:request, method, params}, timeout + 5_000)
  catch
    :exit, {:timeout, _} -> {:error, :mcp_request_timeout}
  end

  @impl true
  def init(opts) do
    command = Keyword.fetch!(opts, :command)
    args = Keyword.get(opts, :args, [])
    env = Keyword.get(opts, :env, %{})
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    with {:ok, executable} <- resolve_executable(command) do
      port =
        Port.open({:spawn_executable, executable}, [
          :binary,
          :exit_status,
          :use_stdio,
          args: Enum.map(args, &to_string/1),
          env: Enum.map(env, fn {k, v} -> {to_string(k), to_string(v)} end)
        ])

      {:ok,
       %{
         port: port,
         buffer: "",
         next_id: 1,
         pending: %{},
         exited: nil,
         timeout_ms: timeout
       }}
    end
  end

  @impl true
  def handle_call({:request, _method, _params}, _from, %{exited: status} = state)
      when not is_nil(status) do
    {:reply, {:error, {:mcp_server_exited, status}}, state}
  end

  def handle_call({:request, method, params}, from, state) do
    id = state.next_id
    payload = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

    with {:ok, line} <- Jason.encode(payload) do
      Port.command(state.port, line <> "\n")
      timer = Process.send_after(self(), {:request_timeout, id}, state.timeout_ms)
      pending = Map.put(state.pending, id, %{from: from, timer: timer})
      {:noreply, %{state | next_id: id + 1, pending: pending}}
    else
      {:error, reason} -> {:reply, {:error, {:mcp_encode, reason}}, state}
    end
  end

  def handle_call(:notify_initialized, _from, %{exited: nil} = state) do
    with {:ok, line} <-
           Jason.encode(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"}) do
      Port.command(state.port, line <> "\n")
      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, {:mcp_encode, reason}}, state}
    end
  end

  def handle_call(:notify_initialized, _from, state) do
    {:reply, {:error, {:mcp_server_exited, state.exited}}, state}
  end

  @impl true
  def handle_info({port, {:data, bytes}}, %{port: port} = state) do
    buffer = state.buffer <> bytes

    if byte_size(buffer) > @max_line_bytes and not String.contains?(buffer, "\n") do
      {:noreply, fail_all(state, :mcp_line_too_long)}
    else
      {:noreply, drain_lines(state, buffer)}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {:noreply, fail_all(%{state | exited: status}, {:mcp_server_exited, status})}
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

  defp drain_lines(state, buffer) do
    case :binary.split(buffer, "\n") do
      [line, rest] ->
        state |> handle_line(line) |> drain_lines(rest)

      [_incomplete] ->
        %{state | buffer: buffer}
    end
  end

  defp handle_line(state, "") do
    state
  end

  defp handle_line(state, line) do
    case Jason.decode(line) do
      {:ok, %{"id" => id} = message} when not is_nil(id) ->
        deliver_response(state, id, message)

      {:ok, _notification} ->
        state

      {:error, _reason} ->
        Logger.warning("mcp: dropping undecodable server line")
        state
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
      "capabilities" => %{"tools" => %{}},
      "clientInfo" => %{"name" => "iex-code", "version" => "0.1.0"}
    }
  end
end
