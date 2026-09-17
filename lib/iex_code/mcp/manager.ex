defmodule IexCode.MCP.Manager do
  @moduledoc """
  Owns stdio MCP server clients and exposes their tools.

  Started with `[servers: %{name => spec}]` (see `IexCode.MCP.Catalog`).
  Fetches each server's tool list at startup. Tool names bridge as
  `mcp__<server>__<tool>` via `IexCode.MCP.ToolBridge`.
  """

  use GenServer

  alias IexCode.MCP.Client

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Lists connected server names."
  @spec list_servers(GenServer.server()) :: [String.t()]
  def list_servers(server \\ __MODULE__), do: GenServer.call(server, :list_servers)

  @doc "Lists a server's tools (from the startup snapshot)."
  @spec list_tools(GenServer.server(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_tools(server \\ __MODULE__, name), do: GenServer.call(server, {:list_tools, name})

  @doc "Calls a tool on a server."
  @spec call_tool(GenServer.server(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def call_tool(server \\ __MODULE__, name, tool, args, opts \\ []) do
    GenServer.call(server, {:call_tool, name, tool, args, opts})
  end

  @impl true
  def init(opts) do
    servers = Keyword.get(opts, :servers, %{})
    timeout = Keyword.get(opts, :timeout_ms, 30_000)

    {:ok, %{servers: %{}, pending: servers, timeout: timeout}, {:continue, :connect_all}}
  end

  @impl true
  def handle_continue(:connect_all, state) do
    connected =
      Map.new(state.pending, fn {name, spec} ->
        {name, connect(spec, state.timeout)}
      end)

    {:noreply, %{state | servers: connected, pending: %{}}}
  end

  @impl true
  def handle_call(:list_servers, _from, state) do
    names =
      for {name, {:ok, _client, _tools}} <- state.servers do
        name
      end

    {:reply, names, state}
  end

  def handle_call({:list_tools, name}, _from, state) do
    case Map.get(state.servers, name) do
      {:ok, _client, tools} -> {:reply, {:ok, tools}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
      nil -> {:reply, {:error, :mcp_server_unknown}, state}
    end
  end

  def handle_call({:call_tool, name, tool, args, opts}, _from, state) do
    case Map.get(state.servers, name) do
      {:ok, client, _tools} -> {:reply, Client.call_tool(client, tool, args, opts), state}
      {:error, reason} -> {:reply, {:error, reason}, state}
      nil -> {:reply, {:error, :mcp_server_unknown}, state}
    end
  end

  defp connect(%{command: command, args: args, env: env}, timeout) do
    with {:ok, client} <- Client.start_link(command: command, args: args, env: env),
         {:ok, _info} <- Client.initialize(client, timeout_ms: timeout),
         {:ok, tools} <- Client.list_tools(client, timeout_ms: timeout) do
      {:ok, client, tools}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp connect(_spec, _timeout), do: {:error, :mcp_bad_server_spec}
end
