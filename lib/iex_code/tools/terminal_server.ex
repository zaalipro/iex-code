defmodule IexCode.Tools.TerminalServer do
  @moduledoc """
  Public client facade for interactive PTY terminal sessions.
  Provides high-level, fail-safe APIs for LiveViews, autonomous agents, and test suites.
  """
  require Logger

  alias IexCode.Tools.TerminalSession
  alias IexCode.Tools.TerminalSupervisor

  @pubsub_server IexCode.PubSub

  # --- Session Lifecycle ---

  @doc """
  Ensures a terminal session is running for the given `session_id`.
  If already running, returns `{:ok, pid}`. Otherwise, spawns a new session under `TerminalSupervisor`.
  """
  @spec ensure_started(session_id :: String.t(), opts :: keyword()) ::
          {:ok, pid()} | {:error, term()}
  def ensure_started(session_id, opts \\ []) when is_binary(session_id) do
    case whereis(session_id) do
      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          {:ok, pid}
        else
          TerminalSupervisor.start_session(session_id, opts)
        end

      nil ->
        TerminalSupervisor.start_session(session_id, opts)
    end
  end

  @doc """
  Looks up the PID of the active terminal session for `session_id`.
  Returns `pid` if alive, or `nil` if not running.
  """
  @spec whereis(session_id :: String.t()) :: pid() | nil
  def whereis(session_id) when is_binary(session_id) do
    TerminalSession.whereis(session_id)
  end

  @doc """
  Returns true if the terminal session is currently running.
  """
  @spec running?(session_id :: String.t()) :: boolean()
  def running?(session_id) when is_binary(session_id) do
    case whereis(session_id) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end

  # --- Input & Commands ---

  @doc """
  Sends raw input bytes (keystrokes, escape sequences, control chars) to the shell process.
  Returns `{:error, :agent_occupied}` if terminal is occupied by an agent unless `force: true` is passed.
  Returns `{:error, :not_found}` if the session is not started.
  """
  @spec send_input(session_id :: String.t(), data :: binary(), opts :: keyword()) ::
          :ok | {:error, term()}
  def send_input(session_id, data, opts \\ [])
      when is_binary(session_id) and is_binary(data) do
    case whereis(session_id) do
      nil ->
        {:error, :not_found}

      _pid ->
        TerminalSession.send_input(session_id, data, opts)
    end
  end

  @doc """
  Queues a complete command for correlated, serialized execution.

  This compatibility API returns `:ok`; use `run_command_with_id/2` when the
  caller needs the generated command ID.
  """
  @spec run_command(session_id :: String.t(), command :: String.t()) :: :ok | {:error, term()}
  def run_command(session_id, command) when is_binary(session_id) and is_binary(command) do
    case run_command_with_id(session_id, command) do
      {:ok, _command_id} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Queues a command and returns the opaque ID used by command lifecycle PubSub events.
  """
  @spec run_command_with_id(session_id :: String.t(), command :: String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def run_command_with_id(session_id, command)
      when is_binary(session_id) and is_binary(command) do
    case whereis(session_id) do
      nil -> {:error, :not_found}
      _pid -> TerminalSession.run_command(session_id, command)
    end
  end

  @doc """
  Executes a command synchronously on behalf of an autonomous agent, capturing output until completion.
  Emits telemetry events `[:iex_code, :terminal, :command_dispatched]` and `[:iex_code, :terminal, :command_completed]`.
  Guarantees occupant cleanup back to `:user`.
  """
  @spec run_agent_command(
          session_id :: String.t(),
          command :: String.t(),
          agent_name :: String.t(),
          opts :: keyword()
        ) ::
          {:ok, %{output: String.t(), exit_code: integer(), duration_ms: integer()}}
          | {:error, term()}
  def run_agent_command(session_id, command, agent_name, opts \\ [])
      when is_binary(session_id) and is_binary(command) and is_binary(agent_name) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)
    op_id = Keyword.get(opts, :op_id)
    occupant = {:agent, agent_name, op_id}

    workspace_lock_identity =
      opts
      |> Keyword.get(:workspace_lock_identity, [])
      |> Keyword.put(:terminal_mutation_kind, :agent)

    lock_started_at = System.monotonic_time(:millisecond)

    with {:ok, _pid} <- ensure_started(session_id, opts),
         {:ok, command_timeout_ms} <-
           begin_workspace_mutation_with_retry(
             session_id,
             workspace_lock_identity,
             lock_started_at,
             timeout_ms
           ) do
      result =
        case TerminalSession.set_occupant(session_id, occupant) do
          :ok ->
            run_locked_agent_command(
              session_id,
              command,
              agent_name,
              occupant,
              op_id,
              command_timeout_ms
            )

          {:error, _reason} = error ->
            error
        end

      _ = TerminalSession.set_occupant(session_id, :user)
      _ = TerminalSession.end_workspace_mutation(session_id)
      result
    end
  end

  defp begin_workspace_mutation_with_retry(session_id, identity, started_at, timeout_ms) do
    elapsed = System.monotonic_time(:millisecond) - started_at
    remaining = timeout_ms - elapsed

    if remaining <= 0 do
      {:error, :timeout}
    else
      case TerminalSession.begin_workspace_mutation(session_id, identity) do
        :ok ->
          {:ok, remaining}

        {:error, reason} = error ->
          if retryable_workspace_lock_conflict?(reason) do
            receive do
            after
              min(40, remaining) -> :ok
            end

            begin_workspace_mutation_with_retry(session_id, identity, started_at, timeout_ms)
          else
            error
          end
      end
    end
  end

  defp retryable_workspace_lock_conflict?(:terminal_mutation_busy), do: true
  defp retryable_workspace_lock_conflict?({:workspace_lock_waiting, _locks}), do: true
  defp retryable_workspace_lock_conflict?({:conflict, _locks}), do: true
  defp retryable_workspace_lock_conflict?(_reason), do: false

  defp run_locked_agent_command(session_id, command, agent_name, occupant, op_id, timeout_ms) do
    token = "CMD_FIN_#{:erlang.unique_integer([:positive])}"
    wrapped_cmd = "#{command}; echo '__AGENT_EXIT:'$?':TOKEN:#{token}__'\n"

    # Execute collector in an isolated task to preserve caller's PubSub subscriptions
    collector_task =
      Task.async(fn ->
        topic = "session:#{session_id}:terminal"
        Phoenix.PubSub.subscribe(@pubsub_server, topic)
        start_time = System.monotonic_time(:millisecond)

        try do
          collect_agent_output(session_id, token, "", start_time, timeout_ms)
        after
          Phoenix.PubSub.unsubscribe(@pubsub_server, topic)
        end
      end)

    start_monotonic = System.monotonic_time(:millisecond)

    :telemetry.execute(
      [:iex_code, :terminal, :command_dispatched],
      %{system_time: System.system_time()},
      %{
        session_id: session_id,
        command: command,
        occupant: occupant,
        agent_name: agent_name,
        op_id: op_id
      }
    )

    try do
      case TerminalSession.send_input(session_id, wrapped_cmd, force: true) do
        :ok ->
          case Task.await(collector_task, timeout_ms + 1_000) do
            {:ok, res} ->
              :telemetry.execute(
                [:iex_code, :terminal, :command_completed],
                %{
                  duration_ms: res.duration_ms,
                  exit_code: res.exit_code,
                  system_time: System.system_time()
                },
                %{
                  session_id: session_id,
                  command: command,
                  agent_name: agent_name,
                  op_id: op_id,
                  exit_code: res.exit_code,
                  status: if(res.exit_code == 0, do: :ok, else: :error)
                }
              )

              {:ok, res}

            {:error, _reason} = err ->
              duration = System.monotonic_time(:millisecond) - start_monotonic

              :telemetry.execute(
                [:iex_code, :terminal, :command_completed],
                %{
                  duration_ms: duration,
                  exit_code: -1,
                  system_time: System.system_time()
                },
                %{
                  session_id: session_id,
                  command: command,
                  agent_name: agent_name,
                  op_id: op_id,
                  exit_code: -1,
                  status: :error
                }
              )

              err
          end

        {:error, reason} ->
          Task.shutdown(collector_task, :brutal_kill)

          emit_command_completed(
            session_id,
            command,
            agent_name,
            op_id,
            start_monotonic,
            :error
          )

          {:error, reason}
      end
    rescue
      e ->
        Task.shutdown(collector_task, :brutal_kill)

        emit_command_completed(
          session_id,
          command,
          agent_name,
          op_id,
          start_monotonic,
          :error
        )

        {:error, e}
    catch
      :exit, {:timeout, _} ->
        Task.shutdown(collector_task, :brutal_kill)
        duration = System.monotonic_time(:millisecond) - start_monotonic

        :telemetry.execute(
          [:iex_code, :terminal, :command_completed],
          %{
            duration_ms: duration,
            exit_code: -1,
            system_time: System.system_time()
          },
          %{
            session_id: session_id,
            command: command,
            agent_name: agent_name,
            op_id: op_id,
            exit_code: -1,
            status: :error
          }
        )

        {:error, :timeout}

      :exit, reason ->
        Task.shutdown(collector_task, :brutal_kill)

        emit_command_completed(
          session_id,
          command,
          agent_name,
          op_id,
          start_monotonic,
          :error
        )

        {:error, {:exit, reason}}
    end
  end

  defp emit_command_completed(
         session_id,
         command,
         agent_name,
         op_id,
         start_monotonic,
         status
       ) do
    :telemetry.execute(
      [:iex_code, :terminal, :command_completed],
      %{
        duration_ms: max(System.monotonic_time(:millisecond) - start_monotonic, 0),
        exit_code: -1,
        system_time: System.system_time()
      },
      %{
        session_id: session_id,
        command: command,
        agent_name: agent_name,
        op_id: op_id,
        exit_code: -1,
        status: status
      }
    )

    :ok
  end

  defp collect_agent_output(session_id, token, acc, start_time, timeout_ms) do
    elapsed = System.monotonic_time(:millisecond) - start_time
    remaining = max(timeout_ms - elapsed, 0)
    regex = ~r/\r?\n?__AGENT_EXIT:(\d+):TOKEN:#{token}__\r?\n?/

    receive do
      {:terminal_output, %{session_id: ^session_id, data: chunk}} ->
        new_acc = acc <> chunk

        case Regex.run(regex, new_acc) do
          [match, code_str] ->
            duration = System.monotonic_time(:millisecond) - start_time

            clean_output =
              new_acc
              |> String.split(match, parts: 2)
              |> List.first()
              |> strip_agent_command_echo(token)
              |> String.trim_trailing()

            {:ok,
             %{
               output: clean_output,
               exit_code: String.to_integer(code_str),
               duration_ms: duration
             }}

          nil ->
            collect_agent_output(session_id, token, new_acc, start_time, timeout_ms)
        end

      {:terminal_exit, %{session_id: ^session_id, exit_code: code}} ->
        duration = System.monotonic_time(:millisecond) - start_time
        {:ok, %{output: acc, exit_code: code || 0, duration_ms: duration}}
    after
      remaining ->
        {:error, :timeout}
    end
  end

  defp strip_agent_command_echo(output, token) do
    output
    |> String.replace(~r/;?\s*echo\s+['"]__AGENT_EXIT:[^'"]*['"]/, "")
    |> String.replace(token, "")
  end

  # --- Terminal Window & Signals ---

  @doc """
  Resizes the terminal dimensions (cols x rows) and triggers SIGWINCH.
  """
  @spec resize(session_id :: String.t(), cols :: integer(), rows :: integer()) ::
          :ok | {:error, term()}
  def resize(session_id, cols, rows)
      when is_binary(session_id) and is_integer(cols) and is_integer(rows) do
    if cols <= 0 or rows <= 0 do
      {:error, :invalid_dimensions}
    else
      case whereis(session_id) do
        nil -> {:error, :not_found}
        _pid -> TerminalSession.resize(session_id, cols, rows)
      end
    end
  end

  @doc """
  Dispatches an OS signal or control sequence (`:sigint`, `:sigterm`, `:sigkill`, `:sigtstp`, `:eof`) to the shell.
  """
  @spec send_signal(session_id :: String.t(), signal :: atom() | binary()) ::
          :ok | {:error, term()}
  def send_signal(session_id, signal) when is_binary(session_id) do
    case whereis(session_id) do
      nil ->
        {:error, :not_found}

      _pid ->
        with :ok <- TerminalSession.begin_workspace_mutation(session_id) do
          try do
            case TerminalSession.send_signal(session_id, signal) do
              {:error, :not_running} -> :ok
              result -> result
            end
          after
            _ = TerminalSession.end_workspace_mutation(session_id)
          end
        end
    end
  end

  # --- History & Inspection ---

  @doc """
  Searches the terminal session scrollback history for matching lines.

  ## Options
    * `:regex` / `:is_regex` - boolean, treat query as regex (default: `false`).
    * `:case_sensitive` - boolean, case sensitive search (default: `false`).
    * `:strip_ansi` - boolean, strip ANSI sequences before search (default: `true`).
    * `:limit` / `:max_results` - pos_integer() | :infinity, max results (default: `100`).
    * `:reverse` - boolean, return newest matches first (default: `false`).
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
  def search_history(session_id, query, opts \\ [])
      when is_binary(session_id) and (is_binary(query) or is_struct(query, Regex)) do
    case whereis(session_id) do
      nil -> {:error, :not_found}
      _pid -> TerminalSession.search_history(session_id, query, opts)
    end
  end

  @doc """
  Retrieves accumulated UTF-8 scrollback history from the ring buffer.
  Returns empty string if session is not running.
  """
  @spec get_history(session_id :: String.t()) :: binary()
  def get_history(session_id) when is_binary(session_id) do
    case whereis(session_id) do
      nil -> ""
      _pid -> TerminalSession.get_history(session_id)
    end
  end

  @doc """
  Clears the in-memory ring buffer and broadcasts `{:terminal_cleared, ...}` over PubSub.
  """
  @spec clear(session_id :: String.t()) :: :ok
  def clear(session_id) when is_binary(session_id) do
    case whereis(session_id) do
      nil -> :ok
      _pid -> TerminalSession.clear_history(session_id)
    end
  end

  @doc """
  Retrieves a full state inspection map from the running terminal session.
  """
  @spec get_state(session_id :: String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_state(session_id) when is_binary(session_id) do
    case whereis(session_id) do
      nil -> {:error, :not_found}
      _pid -> TerminalSession.get_state(session_id)
    end
  end

  # --- Restart & Termination ---

  @doc """
  Restarts the shell process within the terminal session by stopping the existing child
  and spawning a fresh supervised session.
  """
  @spec restart(session_id :: String.t(), opts :: keyword()) :: {:ok, pid()} | {:error, term()}
  def restart(session_id, opts \\ []) when is_binary(session_id) do
    saved_opts =
      case get_state(session_id) do
        {:ok, state} ->
          [
            workspace_path: state.workspace_path,
            cols: state.cols,
            rows: state.rows,
            shell: state.shell
          ]

        _ ->
          []
      end

    merged_opts = Keyword.merge(saved_opts, opts)

    with :ok <- kill(session_id) do
      TerminalSupervisor.start_session(session_id, merged_opts)
    end
  end

  @doc """
  Stops and terminates the terminal session, sending SIGKILL and stopping the child process under supervision.
  """
  @spec kill(session_id :: String.t()) :: :ok | {:error, term()}
  def kill(session_id) when is_binary(session_id) do
    case whereis(session_id) do
      nil ->
        :ok

      pid ->
        with :ok <- TerminalSession.begin_workspace_mutation(session_id) do
          ref = Process.monitor(pid)
          _ = TerminalSession.send_signal(session_id, :sigkill)
          _ = TerminalSupervisor.stop_session(session_id)
          _ = TerminalSession.stop(session_id)

          receive do
            {:DOWN, ^ref, :process, ^pid, _} -> :ok
          after
            1_000 -> :ok
          end
        end
    end
  end
end
