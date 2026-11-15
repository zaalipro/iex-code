defmodule IexCode.MCP.Manager do
  @moduledoc """
  Owns stdio MCP server clients with crash isolation, non-blocking tool
  execution, lazy/explicit reconnection, and MCP protocol wrappers.

  Started with `[servers: %{name => spec}]` (see `IexCode.MCP.Catalog`).
  Fetches each server's tool list at startup. Tool names bridge as
  `mcp__<server>__<tool>` via `IexCode.MCP.ToolBridge`.
  """

  use GenServer

  alias IexCode.MCP.Client

  @default_timeout_ms 30_000
  @default_resources_list_timeout_ms 10_000
  @default_resource_read_timeout_ms 15_000
  @default_prompts_list_timeout_ms 10_000
  @default_prompt_get_timeout_ms 15_000

  @type server_status_map :: %{
          pid: pid() | nil,
          config: map(),
          status: :connected | :crashed | :disconnected | :reconnecting,
          crash_count: non_neg_integer(),
          last_error: term()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if is_nil(name), do: [], else: [name: name]
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Dynamically registers and connects an MCP server."
  @spec start_server(
          GenServer.server() | String.t(),
          String.t() | map(),
          map() | GenServer.server()
        ) ::
          {:ok, server_status_map()} | {:error, term()}
  def start_server(server \\ __MODULE__, name, spec)

  def start_server(name, spec, server) when is_binary(name) and is_map(spec) do
    GenServer.call(server, {:start_server, name, spec}, 35_000)
  end

  def start_server(server, name, spec) when is_binary(name) and is_map(spec) do
    GenServer.call(server, {:start_server, name, spec}, 35_000)
  end

  @doc "Stops and unregisters a managed MCP server."
  @spec stop_server(GenServer.server() | String.t(), String.t() | GenServer.server()) ::
          :ok | {:error, :mcp_server_unknown}
  def stop_server(server \\ __MODULE__, name)

  def stop_server(name, server)
      when is_binary(name) and (is_pid(server) or is_atom(server) or is_tuple(server)) do
    GenServer.call(server, {:stop_server, name}, 15_000)
  end

  def stop_server(server, name) when is_binary(name) do
    GenServer.call(server, {:stop_server, name}, 15_000)
  end

  @doc "Lists connected server names."
  @spec list_servers(GenServer.server()) :: [String.t()]
  def list_servers(server \\ __MODULE__), do: GenServer.call(server, :list_servers)

  @doc "Lists a server's tools (from the cached server snapshot)."
  @spec list_tools(GenServer.server() | String.t(), String.t() | GenServer.server()) ::
          {:ok, [map()]} | {:error, term()}
  def list_tools(server \\ __MODULE__, name)

  def list_tools(name, server)
      when is_binary(name) and (is_pid(server) or is_atom(server) or is_tuple(server)) do
    GenServer.call(server, {:list_tools, name})
  end

  def list_tools(server, name), do: GenServer.call(server, {:list_tools, name})

  @doc "Returns metadata (`%{pid, config, status, crash_count, last_error}`) for `server_name`."
  @spec server_status(String.t() | GenServer.server(), GenServer.server() | String.t()) ::
          {:ok, server_status_map()} | {:error, :mcp_server_unknown}
  def server_status(server_name, manager \\ __MODULE__)

  def server_status(server_name, manager) when is_binary(server_name) do
    GenServer.call(manager, {:server_status, server_name})
  end

  def server_status(manager, server_name) when is_binary(server_name) do
    GenServer.call(manager, {:server_status, server_name})
  end

  @doc "Explicitly reconnects `server_name` using its stored configuration."
  @spec reconnect(String.t() | GenServer.server(), GenServer.server() | String.t()) ::
          {:ok, server_status_map()} | {:error, term()}
  def reconnect(server_name, manager \\ __MODULE__)

  def reconnect(server_name, manager) when is_binary(server_name) do
    GenServer.call(manager, {:reconnect, server_name}, 60_000)
  end

  def reconnect(manager, server_name) when is_binary(server_name) do
    GenServer.call(manager, {:reconnect, server_name}, 60_000)
  end

  @doc """
  Calls a tool on `name` without blocking `Manager` across servers.

  Resolves the `Client` pid (lazily reconnecting once if the server previously
  exited and has stored config) and executes `Client.call_tool/4` outside
  `Manager` serialization.
  """
  @spec call_tool(GenServer.server(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def call_tool(server \\ __MODULE__, name, tool, args, opts \\ []) do
    with_client(server, name, opts, fn client ->
      Client.call_tool(client, tool, args, put_managed_opt(opts))
    end)
  end

  @doc "Lists resources on a managed MCP server (`resources/list`)."
  def list_resources(server_or_name, name_or_manager \\ __MODULE__)

  def list_resources(server_name, timeout_or_opts)
      when is_binary(server_name) and (is_integer(timeout_or_opts) or is_list(timeout_or_opts)) do
    do_list_resources(__MODULE__, server_name, timeout_or_opts)
  end

  def list_resources(server_name, manager) when is_binary(server_name) do
    do_list_resources(manager, server_name, @default_resources_list_timeout_ms)
  end

  def list_resources(manager, server_name) when is_binary(server_name) do
    do_list_resources(manager, server_name, @default_resources_list_timeout_ms)
  end

  def list_resources(manager, server_name, timeout_or_opts)
      when not is_binary(manager) and is_binary(server_name) do
    do_list_resources(manager, server_name, timeout_or_opts)
  end

  def list_resources(server_name, manager, timeout_or_opts)
      when is_binary(server_name) and not is_binary(manager) do
    do_list_resources(manager, server_name, timeout_or_opts)
  end

  @doc "Reads a resource by URI from a managed MCP server (`resources/read`)."
  def read_resource(server_name, uri) when is_binary(server_name) and is_binary(uri) do
    do_read_resource(__MODULE__, server_name, uri, @default_resource_read_timeout_ms)
  end

  def read_resource(manager, server_name, uri)
      when not is_binary(manager) and is_binary(server_name) and is_binary(uri) do
    do_read_resource(manager, server_name, uri, @default_resource_read_timeout_ms)
  end

  def read_resource(server_name, uri, timeout_or_opts)
      when is_binary(server_name) and is_binary(uri) and
             (is_integer(timeout_or_opts) or is_list(timeout_or_opts)) do
    do_read_resource(__MODULE__, server_name, uri, timeout_or_opts)
  end

  def read_resource(server_name, uri, manager)
      when is_binary(server_name) and is_binary(uri) do
    do_read_resource(manager, server_name, uri, @default_resource_read_timeout_ms)
  end

  def read_resource(manager, server_name, uri, timeout_or_opts)
      when not is_binary(manager) and is_binary(server_name) and is_binary(uri) do
    do_read_resource(manager, server_name, uri, timeout_or_opts)
  end

  @doc "Lists prompts on a managed MCP server (`prompts/list`)."
  def list_prompts(server_or_name, name_or_manager \\ __MODULE__)

  def list_prompts(server_name, timeout_or_opts)
      when is_binary(server_name) and (is_integer(timeout_or_opts) or is_list(timeout_or_opts)) do
    do_list_prompts(__MODULE__, server_name, timeout_or_opts)
  end

  def list_prompts(server_name, manager) when is_binary(server_name) do
    do_list_prompts(manager, server_name, @default_prompts_list_timeout_ms)
  end

  def list_prompts(manager, server_name) when is_binary(server_name) do
    do_list_prompts(manager, server_name, @default_prompts_list_timeout_ms)
  end

  def list_prompts(manager, server_name, timeout_or_opts)
      when not is_binary(manager) and is_binary(server_name) do
    do_list_prompts(manager, server_name, timeout_or_opts)
  end

  def list_prompts(server_name, manager, timeout_or_opts)
      when is_binary(server_name) and not is_binary(manager) do
    do_list_prompts(manager, server_name, timeout_or_opts)
  end

  @doc "Fetches a prompt from a managed MCP server (`prompts/get`)."
  def get_prompt(server_name, prompt_name)
      when is_binary(server_name) and is_binary(prompt_name) do
    do_get_prompt(__MODULE__, server_name, prompt_name, %{}, @default_prompt_get_timeout_ms)
  end

  def get_prompt(manager, server_name, prompt_name)
      when not is_binary(manager) and is_binary(server_name) and is_binary(prompt_name) do
    do_get_prompt(manager, server_name, prompt_name, %{}, @default_prompt_get_timeout_ms)
  end

  def get_prompt(server_name, prompt_name, arguments)
      when is_binary(server_name) and is_binary(prompt_name) and is_map(arguments) do
    do_get_prompt(__MODULE__, server_name, prompt_name, arguments, @default_prompt_get_timeout_ms)
  end

  def get_prompt(server_name, prompt_name, manager)
      when is_binary(server_name) and is_binary(prompt_name) do
    do_get_prompt(manager, server_name, prompt_name, %{}, @default_prompt_get_timeout_ms)
  end

  def get_prompt(manager, server_name, prompt_name, arguments)
      when not is_binary(manager) and is_binary(server_name) and is_binary(prompt_name) and
             is_map(arguments) do
    do_get_prompt(manager, server_name, prompt_name, arguments, @default_prompt_get_timeout_ms)
  end

  def get_prompt(server_name, prompt_name, arguments, timeout_or_opts)
      when is_binary(server_name) and is_binary(prompt_name) and is_map(arguments) and
             (is_integer(timeout_or_opts) or is_list(timeout_or_opts)) do
    do_get_prompt(__MODULE__, server_name, prompt_name, arguments, timeout_or_opts)
  end

  def get_prompt(server_name, prompt_name, arguments, manager)
      when is_binary(server_name) and is_binary(prompt_name) and is_map(arguments) do
    do_get_prompt(manager, server_name, prompt_name, arguments, @default_prompt_get_timeout_ms)
  end

  def get_prompt(manager, server_name, prompt_name, arguments, timeout_or_opts)
      when not is_binary(manager) and is_binary(server_name) and is_binary(prompt_name) and
             is_map(arguments) do
    do_get_prompt(manager, server_name, prompt_name, arguments, timeout_or_opts)
  end

  # --- Private Non-Blocking Dispatch Helpers ---

  defp do_list_resources(manager, server_name, timeout_or_opts) do
    opts = to_managed_opts(timeout_or_opts, @default_resources_list_timeout_ms)
    with_client(manager, server_name, opts, &Client.list_resources(&1, opts))
  end

  defp do_read_resource(manager, server_name, uri, timeout_or_opts) do
    opts = to_managed_opts(timeout_or_opts, @default_resource_read_timeout_ms)
    with_client(manager, server_name, opts, &Client.read_resource(&1, uri, opts))
  end

  defp do_list_prompts(manager, server_name, timeout_or_opts) do
    opts = to_managed_opts(timeout_or_opts, @default_prompts_list_timeout_ms)
    with_client(manager, server_name, opts, &Client.list_prompts(&1, opts))
  end

  defp do_get_prompt(manager, server_name, prompt_name, arguments, timeout_or_opts) do
    opts = to_managed_opts(timeout_or_opts, @default_prompt_get_timeout_ms)
    with_client(manager, server_name, opts, &Client.get_prompt(&1, prompt_name, arguments, opts))
  end

  defp with_client(manager, server_name, _opts, fun) do
    case GenServer.call(manager, {:resolve_client, server_name, true}, 60_000) do
      {:ok, client, reconnected?} ->
        case fun.(client) do
          {:error, reason} = err ->
            if not reconnected? and stale_before_send?(reason) do
              retry_after_stale_client(manager, server_name, client, fun)
            else
              err
            end

          other ->
            other
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp retry_after_stale_client(manager, server_name, stale_pid, fun) do
    case GenServer.call(manager, {:reconnect_stale, server_name, stale_pid}, 60_000) do
      {:ok, fresh_client} ->
        case fun.(fresh_client) do
          {:error, {:mcp_already_exited, status}} -> {:error, {:mcp_server_exited, status}}
          other -> other
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp stale_before_send?(:client_stopped), do: true
  defp stale_before_send?(:client_stopping), do: true
  defp stale_before_send?({:mcp_already_exited, _status}), do: true
  defp stale_before_send?(_other), do: false

  defp put_managed_opt(opts) when is_list(opts), do: Keyword.put(opts, :managed, true)
  defp put_managed_opt(ms) when is_integer(ms) and ms > 0, do: [timeout_ms: ms, managed: true]
  defp put_managed_opt(_other), do: [managed: true]

  defp to_managed_opts(opts, _default) when is_list(opts), do: Keyword.put(opts, :managed, true)

  defp to_managed_opts(ms, _default) when is_integer(ms) and ms > 0,
    do: [timeout_ms: ms, managed: true]

  defp to_managed_opts(_other, default), do: [timeout_ms: default, managed: true]

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    servers = Keyword.get(opts, :servers, %{})
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    {:ok, %{servers: %{}, pending: servers, timeout: timeout}, {:continue, :connect_all}}
  end

  @impl true
  def handle_continue(:connect_all, state) do
    manager_pid = self()
    timeout = state.timeout

    connected =
      state.pending
      |> Task.async_stream(
        fn {name, spec} ->
          {name, spec, connect_unlinked(spec, timeout, manager_pid)}
        end,
        timeout: :infinity,
        ordered: false
      )
      |> Enum.reduce(%{}, fn
        {:ok, {name, spec, {:ok, client, tools}}}, acc ->
          entry = attach_connected_client(spec, client, tools, 0)
          Map.put(acc, name, entry)

        {:ok, {name, spec, {:error, reason}}}, acc ->
          entry = new_disconnected_entry(spec, reason)
          Map.put(acc, name, entry)

        {:exit, _reason}, acc ->
          acc
      end)

    {:noreply, %{state | servers: connected, pending: %{}}}
  end

  @impl true
  def handle_call(:list_servers, _from, state) do
    names =
      for {name, %{status: :connected, pid: pid}} <- state.servers, is_pid(pid) do
        name
      end
      |> Enum.sort()

    {:reply, names, state}
  end

  def handle_call({:list_tools, name}, _from, state) do
    case Map.get(state.servers, name) do
      %{tools: tools} when is_list(tools) ->
        {:reply, {:ok, tools}, state}

      %{last_error: reason} ->
        {:reply, {:error, reason || :mcp_disconnected}, state}

      nil ->
        {:reply, {:error, :mcp_server_unknown}, state}
    end
  end

  def handle_call({:server_status, name}, _from, state) do
    case Map.get(state.servers, name) do
      nil -> {:reply, {:error, :mcp_server_unknown}, state}
      entry -> {:reply, {:ok, public_status(entry)}, state}
    end
  end

  def handle_call({:start_server, name, spec}, from, state) do
    state = detach_and_stop_existing(state, name)

    entry = %{
      pid: nil,
      monitor_ref: nil,
      config: spec,
      tools: nil,
      status: :disconnected,
      crash_count: 0,
      last_error: nil,
      reconnect_ref: nil,
      waiters: []
    }

    {:noreply, begin_async_connect(state, name, entry, {from, :status})}
  end

  def handle_call({:stop_server, name}, _from, state) do
    case Map.get(state.servers, name) do
      nil ->
        {:reply, {:error, :mcp_server_unknown}, state}

      entry ->
        fail_waiters(entry.waiters, {:error, :mcp_server_stopped})
        detach_and_stop_entry(entry)
        {:reply, :ok, %{state | servers: Map.delete(state.servers, name)}}
    end
  end

  def handle_call({:reconnect, name}, from, state) do
    case Map.get(state.servers, name) do
      nil ->
        {:reply, {:error, :mcp_server_unknown}, state}

      %{status: :reconnecting} = entry ->
        updated = %{entry | waiters: [{from, :status} | entry.waiters]}
        {:noreply, put_entry(state, name, updated)}

      entry ->
        detach_and_stop_entry(entry)
        cleared = %{entry | pid: nil, monitor_ref: nil}
        {:noreply, begin_async_connect(state, name, cleared, {from, :status})}
    end
  end

  def handle_call({:resolve_client, name, allow_reconnect?}, from, state) do
    case Map.get(state.servers, name) do
      nil ->
        {:reply, {:error, :mcp_server_unknown}, state}

      %{status: :connected, pid: pid} = entry when is_pid(pid) ->
        if Process.alive?(pid) do
          {:reply, {:ok, pid, false}, state}
        else
          crashed = mark_entry_crashed(entry, :noproc)

          if allow_reconnect? do
            {:noreply, begin_async_connect(state, name, crashed, {from, :pid_reconnected})}
          else
            {:reply, {:error, :client_stopped}, put_entry(state, name, crashed)}
          end
        end

      %{status: :reconnecting} = entry ->
        if allow_reconnect? do
          updated = %{entry | waiters: [{from, :pid_reconnected} | entry.waiters]}
          {:noreply, put_entry(state, name, updated)}
        else
          {:reply, {:error, entry.last_error || :mcp_reconnecting}, state}
        end

      entry ->
        if allow_reconnect? and is_map(entry.config) do
          {:noreply, begin_async_connect(state, name, entry, {from, :pid_reconnected})}
        else
          {:reply, {:error, entry.last_error || :mcp_disconnected}, state}
        end
    end
  end

  def handle_call({:reconnect_stale, name, stale_pid}, from, state) do
    case Map.get(state.servers, name) do
      nil ->
        {:reply, {:error, :mcp_server_unknown}, state}

      %{status: :connected, pid: ^stale_pid} = entry ->
        crashed = mark_entry_crashed(entry, :stale_client)
        {:noreply, begin_async_connect(state, name, crashed, {from, :pid_only})}

      %{status: :connected, pid: fresh_pid} when is_pid(fresh_pid) ->
        {:reply, {:ok, fresh_pid}, state}

      %{status: :reconnecting} = entry ->
        updated = %{entry | waiters: [{from, :pid_only} | entry.waiters]}
        {:noreply, put_entry(state, name, updated)}

      entry ->
        {:noreply, begin_async_connect(state, name, entry, {from, :pid_only})}
    end
  end

  @impl true
  def handle_info({:reconnect_done, name, ref, result}, state) do
    case Map.get(state.servers, name) do
      %{reconnect_ref: ^ref} = entry ->
        _ = Process.demonitor(ref, [:flush])
        {:noreply, finish_async_connect(state, name, entry, result)}

      _other ->
        case result do
          {:ok, orphan_client, _tools} -> spawn_stop_client(orphan_client)
          _ -> :ok
        end

        {:noreply, state}
    end
  end

  def handle_info({:mcp_client_exited, pid, reason}, state) do
    case find_by_pid(state.servers, pid) do
      {name, entry} ->
        crashed = mark_entry_crashed(entry, reason)
        spawn_stop_client(pid)
        {:noreply, put_entry(state, name, crashed)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    cond do
      match?({_name, _entry}, find_by_reconnect_ref(state.servers, ref)) ->
        {name, entry} = find_by_reconnect_ref(state.servers, ref)

        {:noreply,
         finish_async_connect(state, name, entry, {:error, {:mcp_reconnect_crash, reason}})}

      match?({_name, _entry}, find_by_monitor_ref(state.servers, ref, pid)) ->
        {name, entry} = find_by_monitor_ref(state.servers, ref, pid)
        updated = apply_process_exit(entry, reason)
        {:noreply, put_entry(state, name, updated)}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, pid, reason}, state) do
    case find_by_pid(state.servers, pid) do
      {name, entry} ->
        updated = apply_process_exit(entry, reason)
        {:noreply, put_entry(state, name, updated)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.servers, fn {_name, entry} ->
      fail_waiters(entry.waiters, {:error, :client_stopping})
      detach_and_stop_entry_sync(entry)
    end)

    :ok
  end

  # --- Internal State & Connection Helpers ---

  defp begin_async_connect(state, name, entry, waiter) do
    manager_pid = self()
    spec = entry.config
    timeout = state.timeout

    {:ok, task_pid} =
      Task.start(fn ->
        receive do
          {:go, ref} ->
            result = connect_unlinked(spec, timeout, manager_pid)
            send(manager_pid, {:reconnect_done, name, ref, result})
        end
      end)

    ref = Process.monitor(task_pid)
    send(task_pid, {:go, ref})

    updated = %{
      entry
      | pid: nil,
        monitor_ref: nil,
        status: :reconnecting,
        reconnect_ref: ref,
        waiters: [waiter | entry.waiters]
    }

    put_entry(state, name, updated)
  end

  defp finish_async_connect(state, name, entry, {:ok, client, tools}) do
    if Process.alive?(client) do
      connected = attach_connected_client(entry.config, client, tools, entry.crash_count)

      Enum.each(Enum.reverse(entry.waiters), fn
        {from, :pid_reconnected} -> GenServer.reply(from, {:ok, client, true})
        {from, :pid_only} -> GenServer.reply(from, {:ok, client})
        {from, :status} -> GenServer.reply(from, {:ok, public_status(connected)})
      end)

      put_entry(state, name, connected)
    else
      finish_async_connect(state, name, entry, {:error, :client_stopped})
    end
  end

  defp finish_async_connect(state, name, entry, {:error, reason}) do
    status = if entry.crash_count > 0, do: :crashed, else: :disconnected

    failed = %{
      entry
      | pid: nil,
        monitor_ref: nil,
        status: status,
        last_error: reason,
        reconnect_ref: nil,
        waiters: []
    }

    fail_waiters(entry.waiters, {:error, reason})
    put_entry(state, name, failed)
  end

  defp attach_connected_client(spec, client, tools, crash_count) do
    Process.link(client)
    mon_ref = Process.monitor(client)

    %{
      pid: client,
      monitor_ref: mon_ref,
      config: spec,
      tools: tools,
      status: :connected,
      crash_count: crash_count,
      last_error: nil,
      reconnect_ref: nil,
      waiters: []
    }
  end

  defp new_disconnected_entry(spec, reason) do
    %{
      pid: nil,
      monitor_ref: nil,
      config: spec,
      tools: nil,
      status: :disconnected,
      crash_count: 0,
      last_error: reason,
      reconnect_ref: nil,
      waiters: []
    }
  end

  defp apply_process_exit(entry, reason) do
    if is_reference(entry.monitor_ref), do: Process.demonitor(entry.monitor_ref, [:flush])
    if is_pid(entry.pid), do: safe_unlink(entry.pid)

    if normal_exit?(reason) do
      %{
        entry
        | pid: nil,
          monitor_ref: nil,
          status: :disconnected,
          last_error: reason
      }
    else
      %{
        entry
        | pid: nil,
          monitor_ref: nil,
          status: :crashed,
          crash_count: entry.crash_count + 1,
          last_error: reason
      }
    end
  end

  defp mark_entry_crashed(entry, reason) do
    if is_reference(entry.monitor_ref), do: Process.demonitor(entry.monitor_ref, [:flush])
    if is_pid(entry.pid), do: safe_unlink(entry.pid)

    %{
      entry
      | pid: nil,
        monitor_ref: nil,
        status: :crashed,
        crash_count: entry.crash_count + 1,
        last_error: reason
    }
  end

  defp normal_exit?(:normal), do: true
  defp normal_exit?(:shutdown), do: true
  defp normal_exit?({:shutdown, _}), do: true
  defp normal_exit?(_reason), do: false

  defp detach_and_stop_existing(state, name) do
    case Map.get(state.servers, name) do
      nil ->
        state

      entry ->
        fail_waiters(entry.waiters, {:error, :mcp_server_replaced})
        detach_and_stop_entry(entry)
        %{state | servers: Map.delete(state.servers, name)}
    end
  end

  defp detach_and_stop_entry(entry) do
    if is_reference(entry.reconnect_ref), do: Process.demonitor(entry.reconnect_ref, [:flush])
    if is_reference(entry.monitor_ref), do: Process.demonitor(entry.monitor_ref, [:flush])

    if is_pid(entry.pid) do
      safe_unlink(entry.pid)
      spawn_stop_client(entry.pid)
    end
  end

  defp detach_and_stop_entry_sync(entry) do
    if is_reference(entry.reconnect_ref), do: Process.demonitor(entry.reconnect_ref, [:flush])
    if is_reference(entry.monitor_ref), do: Process.demonitor(entry.monitor_ref, [:flush])

    if is_pid(entry.pid) do
      safe_unlink(entry.pid)
      safe_stop_client(entry.pid)
    end
  end

  defp spawn_stop_client(pid) when is_pid(pid) do
    _ = Task.start(fn -> safe_stop_client(pid) end)
    :ok
  end

  defp safe_stop_client(pid) when is_pid(pid) do
    GenServer.stop(pid, :normal, 2_000)
  catch
    :exit, _ -> :ok
  end

  defp safe_unlink(pid) do
    Process.unlink(pid)
  rescue
    ArgumentError -> :ok
  end

  defp fail_waiters(waiters, error) do
    Enum.each(Enum.reverse(waiters), fn {from, _kind} ->
      GenServer.reply(from, error)
    end)
  end

  defp public_status(entry) do
    %{
      pid: entry.pid,
      config: entry.config,
      status: entry.status,
      crash_count: entry.crash_count,
      last_error: entry.last_error
    }
  end

  defp put_entry(state, name, entry) do
    %{state | servers: Map.put(state.servers, name, entry)}
  end

  defp find_by_pid(servers, pid) do
    Enum.find(servers, fn {_name, entry} -> entry.pid == pid end)
  end

  defp find_by_monitor_ref(servers, ref, pid) do
    Enum.find(servers, fn {_name, entry} ->
      entry.monitor_ref == ref or entry.pid == pid
    end)
  end

  defp find_by_reconnect_ref(servers, ref) do
    Enum.find(servers, fn {_name, entry} -> entry.reconnect_ref == ref end)
  end

  defp connect_unlinked(%{command: command} = spec, timeout, manager_pid)
       when is_binary(command) do
    args = Map.get(spec, :args) || Map.get(spec, "args") || []
    env = Map.get(spec, :env) || Map.get(spec, "env") || %{}

    with {:ok, client} <-
           Client.start(
             command: command,
             args: args,
             env: env,
             timeout_ms: timeout,
             notify_parent: manager_pid
           ) do
      case handshake_client(client, timeout) do
        {:ok, tools} ->
          {:ok, client, tools}

        {:error, reason} ->
          safe_stop_client(client)
          {:error, reason}
      end
    end
  end

  defp connect_unlinked(%{"command" => command} = spec, timeout, manager_pid)
       when is_binary(command) do
    normalized = %{
      command: command,
      args: Map.get(spec, "args", []),
      env: Map.get(spec, "env", %{})
    }

    connect_unlinked(normalized, timeout, manager_pid)
  end

  defp connect_unlinked(_spec, _timeout, _manager_pid), do: {:error, :mcp_bad_server_spec}

  defp handshake_client(client, timeout) do
    with {:ok, _info} <- Client.initialize(client, timeout_ms: timeout),
         {:ok, tools} <- Client.list_tools(client, timeout_ms: timeout) do
      {:ok, tools}
    end
  end
end
