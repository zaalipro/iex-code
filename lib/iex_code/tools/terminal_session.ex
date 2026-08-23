defmodule IexCode.Tools.TerminalSession do
  @moduledoc """
  GenServer representing an active, supervised PTY terminal session.
  Maintains PTY Port lifecycle, binary ring buffer history, UTF-8 chunk alignment,
  and Phoenix PubSub event broadcasts.
  """
  use GenServer, restart: :temporary
  require Logger

  alias IexCode.LLM.UTF8Buffer
  alias IexCode.Tools.PTYAdapter

  @default_cols 80
  @default_rows 24
  @default_max_buffer_bytes 512 * 1024
  @pubsub_server IexCode.PubSub

  defstruct [
    :session_id,
    :project_root,
    :adapter,
    :shell,
    :cols,
    :rows,
    :status,
    :history_buffer,
    :buffer_bytes,
    :max_buffer_bytes,
    :utf8_acc,
    :active_occupant,
    :env,
    :mode,
    :started_at,
    :exit_code,
    :exit_reason,
    :cleared
  ]

  # --- Client API ---

  @doc """
  Starts a supervised `TerminalSession` GenServer registered under `IexCode.SessionRegistry`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(session_id))
  end

  @doc """
  Returns the Registry `{:via, ...}` tuple for the given `session_id`.
  """
  @spec via_tuple(session_id :: String.t()) :: {:via, Registry, {atom(), {atom(), String.t()}}}
  def via_tuple(session_id) when is_binary(session_id) do
    {:via, Registry, {IexCode.SessionRegistry, {:terminal, session_id}}}
  end

  @doc """
  Looks up the PID for `session_id`.
  """
  @spec whereis(session_id :: String.t()) :: pid() | nil
  def whereis(session_id) when is_binary(session_id) do
    case Registry.lookup(IexCode.SessionRegistry, {:terminal, session_id}) do
      [{pid, _}] ->
        if Process.alive?(pid) do
          pid
        else
          nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Sends raw binary input to the active PTY port.
  Enforces lock mode when occupied by an agent unless `force: true` is provided.
  """
  @spec send_input(session_id :: String.t(), data :: binary(), opts :: keyword()) ::
          :ok | {:error, term()}
  def send_input(session_id, data, opts \\ [])
      when is_binary(session_id) and is_binary(data) do
    try do
      GenServer.call(via_tuple(session_id), {:send_input, data, opts})
    catch
      :exit, _ -> {:error, :not_found}
    end
  end

  @doc """
  Searches accumulated scrollback history buffer.

  ## Options
    * `:case_sensitive` - boolean (default: `false`)
    * `:regex` / `:is_regex` - boolean (default: `false`)
    * `:strip_ansi` - boolean (default: `true`)
    * `:limit` / `:max_results` - integer or :infinity (default: `100`)
    * `:reverse` - boolean (default: `false`)
  """
  @spec search_history(
          session_id :: String.t(),
          query :: String.t() | Regex.t(),
          opts :: keyword()
        ) ::
          {:ok,
           [
             %{
               line_number: integer(),
               text: String.t(),
               match_range: {integer(), integer()}
             }
           ]}
          | {:error, term()}
  def search_history(session_id, query, opts \\ []) when is_binary(session_id) do
    try do
      GenServer.call(via_tuple(session_id), {:search_history, query, opts})
    catch
      :exit, _ -> {:error, :not_found}
    end
  end

  @doc """
  Resizes the terminal window dimensions.
  """
  @spec resize(session_id :: String.t(), cols :: integer(), rows :: integer()) ::
          :ok | {:error, term()}
  def resize(session_id, cols, rows)
      when is_binary(session_id) and is_integer(cols) and is_integer(rows) do
    try do
      GenServer.call(via_tuple(session_id), {:resize, cols, rows})
    catch
      :exit, _ -> {:error, :not_found}
    end
  end

  @doc """
  Sends an OS signal to the child shell process.
  """
  @spec send_signal(session_id :: String.t(), signal :: atom() | binary()) ::
          :ok | {:error, term()}
  def send_signal(session_id, signal) when is_binary(session_id) do
    try do
      GenServer.call(via_tuple(session_id), {:send_signal, signal})
    catch
      :exit, _ -> {:error, :not_found}
    end
  end

  @doc """
  Returns all accumulated scrollback history as a continuous UTF-8 binary.
  """
  @spec get_history(session_id :: String.t()) :: binary()
  def get_history(session_id) when is_binary(session_id) do
    try do
      GenServer.call(via_tuple(session_id), :get_history)
    catch
      :exit, _ -> ""
    end
  end

  @doc """
  Clears in-memory scrollback history buffer.
  """
  @spec clear_history(session_id :: String.t()) :: :ok
  def clear_history(session_id) when is_binary(session_id) do
    try do
      GenServer.call(via_tuple(session_id), :clear_history)
    catch
      :exit, _ -> :ok
    end
  end

  @doc """
  Updates the active occupant state (:user | {:agent, name, op_id}).
  """
  @spec set_occupant(
          session_id :: String.t(),
          occupant :: :user | {:agent, String.t(), String.t() | nil}
        ) :: :ok
  def set_occupant(session_id, occupant) when is_binary(session_id) do
    try do
      GenServer.call(via_tuple(session_id), {:set_occupant, occupant})
    catch
      :exit, _ -> {:error, :not_found}
    end
  end

  @doc """
  Restarts the shell process within the existing session.
  """
  @spec restart(session_id :: String.t(), opts :: keyword()) ::
          {:ok, pid()} | {:error, term()}
  def restart(session_id, opts \\ []) when is_binary(session_id) do
    try do
      GenServer.call(via_tuple(session_id), {:restart, opts})
    catch
      :exit, _ -> {:error, :not_found}
    end
  end

  @doc """
  Returns a snapshot map of the terminal session state.
  """
  @spec get_state(session_id :: String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_state(session_id) when is_binary(session_id) do
    try do
      GenServer.call(via_tuple(session_id), :get_state)
    catch
      :exit, _ -> {:error, :not_found}
    end
  end

  @doc """
  Stops the terminal session GenServer.
  """
  @spec stop(session_id :: String.t(), reason :: term(), timeout :: timeout()) :: :ok
  def stop(session_id, reason \\ :normal, timeout \\ 5000) when is_binary(session_id) do
    case whereis(session_id) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid, reason, timeout)
        catch
          :exit, _ -> :ok
        end
    end
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    session_id = Keyword.fetch!(opts, :session_id)

    project_root =
      Keyword.get(opts, :workspace_path) ||
        Keyword.get(opts, :project_root) ||
        Keyword.get(opts, :cwd, File.cwd!())

    cols = max(1, Keyword.get(opts, :cols, @default_cols))
    rows = max(1, Keyword.get(opts, :rows, @default_rows))
    shell = Keyword.get(opts, :shell)
    max_buffer_bytes = Keyword.get(opts, :max_buffer_bytes, @default_max_buffer_bytes)
    env = Keyword.get(opts, :env, default_env(project_root))
    mode = Keyword.get(opts, :mode)

    state = %__MODULE__{
      session_id: session_id,
      project_root: project_root,
      adapter: nil,
      shell: shell,
      cols: cols,
      rows: rows,
      status: :starting,
      history_buffer: [],
      buffer_bytes: 0,
      max_buffer_bytes: max_buffer_bytes,
      utf8_acc: UTF8Buffer.new(),
      active_occupant: :user,
      env: env,
      mode: mode,
      started_at: DateTime.utc_now(),
      exit_code: nil,
      exit_reason: nil,
      cleared: false
    }

    {:ok, state, {:continue, :spawn_shell}}
  end

  @impl true
  def handle_continue(:spawn_shell, state) do
    case spawn_adapter(state) do
      {:ok, adapter} ->
        running_state = %{
          state
          | adapter: adapter,
            shell: adapter.shell || state.shell,
            status: :running
        }

        :telemetry.execute(
          [:iex_code, :terminal, :session_started],
          %{system_time: System.system_time()},
          %{
            session_id: running_state.session_id,
            shell: running_state.shell,
            project_root: running_state.project_root,
            workspace_path: running_state.project_root,
            cols: running_state.cols,
            rows: running_state.rows,
            os_pid: adapter && adapter.os_pid
          }
        )

        broadcast_status(running_state)
        {:noreply, running_state}

      {:error, reason} ->
        Logger.error("[TerminalSession] Failed to spawn shell: #{inspect(reason)}")
        err_state = %{state | status: :error, exit_reason: reason}
        broadcast_status(err_state)
        {:noreply, err_state}
    end
  end

  # --- Calls ---

  @impl true
  def handle_call(
        {:send_input, data, opts},
        _from,
        %{status: :running, adapter: %PTYAdapter{} = adapter} = state
      ) do
    force? = Keyword.get(opts, :force, false)

    cond do
      state.active_occupant != :user and not force? ->
        {:reply, {:error, :agent_occupied}, state}

      true ->
        case PTYAdapter.send_input(adapter, data) do
          :ok -> {:reply, :ok, %{state | cleared: false}}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:send_input, _data, _opts}, _from, state) do
    {:reply, {:error, :not_running}, state}
  end

  def handle_call({:send_input, data}, from, state) do
    handle_call({:send_input, data, []}, from, state)
  end

  @impl true
  def handle_call({:search_history, query, opts}, _from, state) do
    result = do_search_history(state, query, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:resize, cols, rows}, _from, state) do
    new_cols = max(1, cols)
    new_rows = max(1, rows)

    new_adapter =
      if state.adapter && state.status == :running do
        case PTYAdapter.resize(state.adapter, new_cols, new_rows) do
          {:ok, updated_adapter} -> updated_adapter
          _ -> state.adapter
        end
      else
        state.adapter
      end

    new_state = %{state | adapter: new_adapter, cols: new_cols, rows: new_rows}

    broadcast_event(state.session_id, {
      :terminal_resized,
      %{session_id: state.session_id, cols: new_cols, rows: new_rows}
    })

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:send_signal, signal}, _from, state) do
    if state.adapter do
      case signal do
        sig when sig in [:eof, :ctrl_d, "EOF"] ->
          PTYAdapter.send_input(state.adapter, <<4>>)

        other ->
          PTYAdapter.send_signal(state.adapter, other)
      end

      {:reply, :ok, state}
    else
      {:reply, {:error, :not_running}, state}
    end
  end

  @impl true
  def handle_call(:get_history, _from, %{cleared: true} = state) do
    {:reply, "", state}
  end

  @impl true
  def handle_call(:get_history, _from, %{history_buffer: []} = state) do
    state = drain_pending_port_output(state, 150)

    history_str =
      state.history_buffer
      |> Enum.reverse()
      |> IO.iodata_to_binary()

    {:reply, history_str, state}
  end

  @impl true
  def handle_call(:get_history, _from, state) do
    history_str =
      state.history_buffer
      |> Enum.reverse()
      |> IO.iodata_to_binary()

    {:reply, history_str, state}
  end

  @impl true
  def handle_call(:clear_history, _from, state) do
    new_state = %{
      state
      | history_buffer: [],
        buffer_bytes: 0,
        cleared: true,
        utf8_acc: UTF8Buffer.new()
    }

    broadcast_event(state.session_id, {:terminal_cleared, %{session_id: state.session_id}})
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:set_occupant, occupant}, _from, state) do
    new_state = %{state | active_occupant: occupant}

    broadcast_event(state.session_id, {
      :terminal_occupant,
      %{session_id: state.session_id, occupant: occupant}
    })

    broadcast_status(new_state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:restart, opts}, _from, state) do
    if state.adapter, do: PTYAdapter.close(state.adapter)

    updated_shell = Keyword.get(opts, :shell, state.shell)

    updated_root =
      Keyword.get(opts, :workspace_path) ||
        Keyword.get(opts, :project_root) ||
        Keyword.get(opts, :cwd, state.project_root)

    updated_cols = max(1, Keyword.get(opts, :cols, state.cols))
    updated_rows = max(1, Keyword.get(opts, :rows, state.rows))
    updated_env = Keyword.get(opts, :env, state.env)
    updated_mode = Keyword.get(opts, :mode, state.mode)

    reset_state = %{
      state
      | adapter: nil,
        shell: updated_shell,
        project_root: updated_root,
        cols: updated_cols,
        rows: updated_rows,
        env: updated_env,
        mode: updated_mode,
        status: :restarting,
        exit_code: nil,
        exit_reason: nil,
        cleared: false
    }

    broadcast_status(reset_state)

    case spawn_adapter(reset_state) do
      {:ok, new_adapter} ->
        running_state = %{
          reset_state
          | adapter: new_adapter,
            shell: new_adapter.shell || updated_shell,
            status: :running,
            started_at: DateTime.utc_now()
        }

        :telemetry.execute(
          [:iex_code, :terminal, :session_started],
          %{system_time: System.system_time()},
          %{
            session_id: running_state.session_id,
            shell: running_state.shell,
            project_root: running_state.project_root,
            workspace_path: running_state.project_root,
            cols: running_state.cols,
            rows: running_state.rows,
            os_pid: new_adapter && new_adapter.os_pid
          }
        )

        broadcast_status(running_state)
        {:reply, {:ok, self()}, running_state}

      {:error, reason} ->
        err_state = %{reset_state | status: :error, exit_reason: reason}
        broadcast_status(err_state)
        {:reply, {:error, reason}, err_state}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    summary = %{
      session_id: state.session_id,
      project_root: state.project_root,
      workspace_path: state.project_root,
      status: state.status,
      shell: (state.adapter && state.adapter.shell) || state.shell,
      cols: state.cols,
      rows: state.rows,
      occupant: state.active_occupant,
      active_occupant: state.active_occupant,
      buffer_bytes: state.buffer_bytes,
      os_pid: state.adapter && state.adapter.os_pid,
      mode: state.adapter && state.adapter.mode,
      started_at: state.started_at,
      exit_code: state.exit_code
    }

    {:reply, {:ok, summary}, state}
  end

  # --- Port & System Info Messages ---

  @impl true
  def handle_info(
        {port, {:data, raw_bytes}} = msg,
        %{adapter: %PTYAdapter{port: port} = adapter} = state
      ) do
    case PTYAdapter.handle_port_message(adapter, msg) do
      {:output, data, new_adapter} ->
        process_output_bytes(%{state | adapter: new_adapter}, data)

      {:exit, exit_code, new_adapter} ->
        process_exit(%{state | adapter: new_adapter}, exit_code, :normal)

      {:ready, os_pid, new_adapter} ->
        {:noreply, %{state | adapter: %{new_adapter | os_pid: os_pid}}}

      {:noop, new_adapter} ->
        {:noreply, %{state | adapter: new_adapter}}

      :unknown ->
        process_output_bytes(state, raw_bytes)
    end
  end

  # Handle direct data message injection (for unit tests / mock streams)
  @impl true
  def handle_info({_port, {:data, raw_bytes}}, state) do
    process_output_bytes(state, raw_bytes)
  end

  @impl true
  def handle_info(
        {port, {:exit_status, status}},
        %{adapter: %PTYAdapter{port: port}} = state
      ) do
    process_exit(state, status, :exit_status)
  end

  @impl true
  def handle_info({:EXIT, port, reason}, %{adapter: %PTYAdapter{port: port}} = state) do
    Logger.warning(
      "[TerminalSession] Port trapped exit: #{inspect(reason)} (session: #{state.session_id})"
    )

    process_exit(state, -1, reason)
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(_other, state) do
    {:noreply, state}
  end

  # --- Termination Callback ---

  @impl true
  def terminate(reason, state) do
    Logger.debug("[TerminalSession] Terminating #{state.session_id}: #{inspect(reason)}")
    if state.adapter, do: PTYAdapter.close(state.adapter)

    if state.status != :stopped do
      duration_ms =
        if state.started_at do
          DateTime.diff(DateTime.utc_now(), state.started_at, :millisecond)
        else
          0
        end

      code = state.exit_code || 0

      :telemetry.execute(
        [:iex_code, :terminal, :session_stopped],
        %{
          duration_ms: duration_ms,
          exit_code: code,
          system_time: System.system_time()
        },
        %{
          session_id: state.session_id,
          exit_code: code,
          reason: reason
        }
      )
    end

    :ok
  end

  # --- Internal Helpers ---

  defp spawn_adapter(state) do
    PTYAdapter.open(
      cwd: state.project_root,
      shell: state.shell,
      cols: state.cols,
      rows: state.rows,
      env: state.env,
      mode: state.mode
    )
  end

  defp process_output_bytes(state, raw_bytes) when is_binary(raw_bytes) do
    {valid_text, new_acc} = UTF8Buffer.process_bytes(state.utf8_acc, raw_bytes)

    new_state =
      if valid_text != "" do
        :telemetry.execute(
          [:iex_code, :terminal, :output_chunk],
          %{
            byte_size: byte_size(valid_text),
            system_time: System.system_time()
          },
          %{
            session_id: state.session_id,
            occupant: state.active_occupant,
            data: valid_text
          }
        )

        payload = %{
          session_id: state.session_id,
          data: valid_text,
          timestamp: DateTime.utc_now()
        }

        broadcast_event(state.session_id, {:terminal_output, payload})
        append_to_history(state, valid_text)
      else
        state
      end

    {:noreply, %{new_state | utf8_acc: new_acc}}
  end

  defp process_exit(state, code, reason) do
    Logger.info(
      "[TerminalSession] Shell exited with code #{code} (reason: #{inspect(reason)}, session: #{state.session_id})"
    )

    if state.adapter, do: PTYAdapter.close(state.adapter)

    {remaining, _} = UTF8Buffer.flush(state.utf8_acc)

    flushed_state =
      if remaining != "" do
        :telemetry.execute(
          [:iex_code, :terminal, :output_chunk],
          %{
            byte_size: byte_size(remaining),
            system_time: System.system_time()
          },
          %{
            session_id: state.session_id,
            occupant: state.active_occupant,
            data: remaining
          }
        )

        payload = %{
          session_id: state.session_id,
          data: remaining,
          timestamp: DateTime.utc_now()
        }

        broadcast_event(state.session_id, {:terminal_output, payload})
        append_to_history(state, remaining)
      else
        state
      end

    duration_ms =
      if state.started_at do
        DateTime.diff(DateTime.utc_now(), state.started_at, :millisecond)
      else
        0
      end

    :telemetry.execute(
      [:iex_code, :terminal, :session_stopped],
      %{
        duration_ms: duration_ms,
        exit_code: code,
        system_time: System.system_time()
      },
      %{
        session_id: state.session_id,
        exit_code: code,
        reason: reason
      }
    )

    stopped_state = %{
      flushed_state
      | adapter: nil,
        status: :stopped,
        exit_code: code,
        exit_reason: reason,
        utf8_acc: UTF8Buffer.new()
    }

    broadcast_event(state.session_id, {
      :terminal_exit,
      %{session_id: state.session_id, exit_code: code, reason: reason}
    })

    broadcast_status(stopped_state)
    {:noreply, stopped_state}
  end

  defp append_to_history(state, chunk) do
    chunk_size = byte_size(chunk)
    new_chunks = [chunk | state.history_buffer]
    new_total_bytes = state.buffer_bytes + chunk_size

    {trimmed_chunks, final_bytes} =
      prune_history(new_chunks, new_total_bytes, state.max_buffer_bytes)

    %{state | history_buffer: trimmed_chunks, buffer_bytes: final_bytes, cleared: false}
  end

  defp prune_history(chunks, total_bytes, max_bytes) when total_bytes <= max_bytes do
    {chunks, total_bytes}
  end

  defp prune_history(chunks, total_bytes, max_bytes) do
    case List.pop_at(chunks, -1) do
      {nil, []} ->
        {[], 0}

      {oldest, remaining} ->
        prune_history(remaining, total_bytes - byte_size(oldest), max_bytes)
    end
  end

  defp default_env(project_root) do
    %{
      "TERM" => "xterm-256color",
      "COLORTERM" => "truecolor",
      "LANG" => "en_US.UTF-8",
      "WORKSPACE_ROOT" => project_root
    }
  end

  defp broadcast_event(session_id, payload) do
    Phoenix.PubSub.broadcast(@pubsub_server, "session:#{session_id}:terminal", payload)
  end

  defp broadcast_status(state) do
    payload = %{
      session_id: state.session_id,
      status: state.status,
      shell: (state.adapter && state.adapter.shell) || state.shell,
      occupant: state.active_occupant
    }

    broadcast_event(state.session_id, {:terminal_status, payload})
  end

  defp drain_pending_port_output(%{adapter: %PTYAdapter{port: port}} = state, timeout_ms)
       when is_port(port) do
    receive do
      {^port, {:data, _raw_bytes}} = msg ->
        case PTYAdapter.handle_port_message(state.adapter, msg) do
          {:output, data, new_adapter} ->
            new_state = process_output_bytes_sync(%{state | adapter: new_adapter}, data)
            drain_pending_port_output(new_state, 30)

          {:ready, os_pid, new_adapter} ->
            drain_pending_port_output(
              %{state | adapter: %{new_adapter | os_pid: os_pid}},
              timeout_ms
            )

          _ ->
            state
        end
    after
      timeout_ms ->
        state
    end
  end

  defp drain_pending_port_output(state, _timeout_ms), do: state

  defp process_output_bytes_sync(state, raw_bytes) when is_binary(raw_bytes) do
    {valid_text, new_acc} = UTF8Buffer.process_bytes(state.utf8_acc, raw_bytes)

    new_state =
      if valid_text != "" do
        :telemetry.execute(
          [:iex_code, :terminal, :output_chunk],
          %{
            byte_size: byte_size(valid_text),
            system_time: System.system_time()
          },
          %{
            session_id: state.session_id,
            occupant: state.active_occupant,
            data: valid_text
          }
        )

        payload = %{
          session_id: state.session_id,
          data: valid_text,
          timestamp: DateTime.utc_now()
        }

        broadcast_event(state.session_id, {:terminal_output, payload})
        append_to_history(state, valid_text)
      else
        state
      end

    %{new_state | utf8_acc: new_acc}
  end

  defp do_search_history(state, query, opts) do
    raw_history =
      if state.cleared do
        ""
      else
        state.history_buffer
        |> Enum.reverse()
        |> IO.iodata_to_binary()
      end

    if raw_history == "" or query == "" do
      {:ok, []}
    else
      case compile_search_matcher(query, opts) do
        {:ok, matcher_fn} ->
          strip_ansi? = Keyword.get(opts, :strip_ansi, true)
          limit = Keyword.get(opts, :limit, Keyword.get(opts, :max_results, 100))
          reverse? = Keyword.get(opts, :reverse, false)

          lines =
            raw_history
            |> String.split(~r/\r?\n/)
            |> Enum.with_index(1)

          lines_to_search = if reverse?, do: Enum.reverse(lines), else: lines

          matches =
            lines_to_search
            |> Enum.reduce_while([], fn {line, line_num}, acc ->
              processed_line = if strip_ansi?, do: strip_ansi(line), else: line

              case matcher_fn.(processed_line) do
                {:match, match_range} ->
                  item = %{
                    line_number: line_num,
                    text: processed_line,
                    match_range: match_range
                  }

                  new_acc = [item | acc]

                  if limit != :infinity and length(new_acc) >= limit do
                    {:halt, new_acc}
                  else
                    {:cont, new_acc}
                  end

                :nomatch ->
                  {:cont, acc}
              end
            end)
            |> Enum.reverse()

          {:ok, matches}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp compile_search_matcher(%Regex{} = regex, _opts) do
    matcher = fn line ->
      case Regex.run(regex, line, return: :index) do
        [{start_idx, length} | _] -> {:match, {start_idx, start_idx + length}}
        nil -> :nomatch
      end
    end

    {:ok, matcher}
  end

  defp compile_search_matcher(query, opts) when is_binary(query) do
    case_sensitive? = Keyword.get(opts, :case_sensitive, false)
    is_regex? = Keyword.get(opts, :regex, false) || Keyword.get(opts, :is_regex, false)
    modifiers = if case_sensitive?, do: "", else: "i"

    if is_regex? do
      case Regex.compile(query, modifiers) do
        {:ok, regex} ->
          matcher = fn line ->
            case Regex.run(regex, line, return: :index) do
              [{start_idx, length} | _] -> {:match, {start_idx, start_idx + length}}
              nil -> :nomatch
            end
          end

          {:ok, matcher}

        {:error, {reason, _pos}} ->
          {:error, {:invalid_regex, reason}}

        {:error, reason} ->
          {:error, {:invalid_regex, reason}}
      end
    else
      pattern = Regex.escape(query)

      case Regex.compile(pattern, modifiers) do
        {:ok, regex} ->
          matcher = fn line ->
            case Regex.run(regex, line, return: :index) do
              [{start_idx, length} | _] -> {:match, {start_idx, start_idx + length}}
              nil -> :nomatch
            end
          end

          {:ok, matcher}

        {:error, {reason, _pos}} ->
          {:error, {:invalid_regex, reason}}

        {:error, reason} ->
          {:error, {:invalid_regex, reason}}
      end
    end
  end

  defp strip_ansi(text) when is_binary(text) do
    text
    |> String.replace(~r/\x1b\[[0-9;]*[a-zA-Z]/, "")
    |> String.replace(~r/\x1b\([a-zA-Z]/, "")
    |> String.replace(~r/\e\[[0-9;]*[mK]/, "")
  end
end
