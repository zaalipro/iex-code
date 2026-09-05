defmodule IexCode.Desktop.Lifecycle do
  @moduledoc """
  Coordinates process lifecycle, clean teardown, and resource cleanup for
  the IexCode native desktop application.

  Ensures zero zombie PTY processes, invalidation of workspace locks,
  flushing of SQLite WAL journal frames to disk, and safe BEAM termination.
  """
  require Logger

  @quit_coordinator __MODULE__.QuitCoordinator
  @default_cleanup_timeout_ms 2_000
  @default_force_halt_after_ms 7_000

  @doc """
  Starts the bounded desktop quit sequence without blocking a native menu callback.

  The first caller owns shutdown. Later Dock or keyboard quit events are
  idempotent. Cleanup gets a short grace period, graceful OTP shutdown is then
  requested, and an independent watchdog hard-halts the runtime if the whole
  sequence does not complete within seven seconds by default.
  """
  @spec request_quit(keyword()) :: :ok
  def request_quit(opts \\ []) do
    coordinator =
      spawn(fn ->
        # Application masters kill all processes belonging to their group
        # leader during shutdown, even unlinked ones. Detach before starting
        # quit so this coordinator and its watchdog survive application cleanup.
        Process.group_leader(self(), Process.whereis(:init))

        receive do
          {:begin_quit, quit_opts} -> coordinate_quit(quit_opts)
        end
      end)

    try do
      true = Process.register(coordinator, @quit_coordinator)
      send(coordinator, {:begin_quit, opts})
    rescue
      ArgumentError -> Process.exit(coordinator, :kill)
    end

    :ok
  end

  @doc """
  Runs the teardown pipeline.

  Accepts options:
    * `:kill_terminals` - whether to terminate active terminal sessions (default: `true`)
    * `:release_locks` - whether to release/expire active workspace locks (default: `true`)
    * `:flush_wal` - whether to checkpoint SQLite WAL (default: `true`)
    * `:halt` - whether to halt the BEAM runtime / desktop OS after teardown (default: `true` in prod/dev, `false` in test)
    * `:halt_fn` - custom 0-arity function to invoke when `:halt` is true (defaults to `Desktop.OS.shutdown/0` or `System.stop(0)`)

  Returns `{:ok, results}` summarizing each stage's outcome.
  """
  @spec teardown(keyword()) :: {:ok, map()} | {:error, term()}
  def teardown(opts \\ []) do
    default_opts = [
      kill_terminals: true,
      release_locks: true,
      flush_wal: true,
      halt: default_halt?()
    ]

    opts = Keyword.merge(default_opts, opts)
    Logger.info("IexCode.Desktop.Lifecycle: Starting teardown pipeline...")

    # Stage 1: Terminal process cleanup
    terminals_result =
      if Keyword.get(opts, :kill_terminals, true) do
        cleanup_terminals()
      else
        :skipped
      end

    # Stage 2: Workspace lock cleanup
    locks_result =
      if Keyword.get(opts, :release_locks, true) do
        cleanup_workspace_locks()
      else
        :skipped
      end

    # Stage 3: SQLite WAL flushing
    wal_result =
      if Keyword.get(opts, :flush_wal, true) do
        checkpoint_wal()
      else
        :skipped
      end

    results = %{
      terminals: terminals_result,
      workspace_locks: locks_result,
      wal: wal_result
    }

    Logger.info("IexCode.Desktop.Lifecycle: Teardown stages completed: #{inspect(results)}")

    # Stage 4: Shutdown
    if Keyword.get(opts, :halt, false) do
      halt_runtime(opts[:halt_fn])
    end

    {:ok, results}
  end

  @doc """
  Cleanly terminates all running terminal sessions managed by TerminalSupervisor.
  """
  @spec cleanup_terminals() :: {:ok, list()} | {:error, term()}
  def cleanup_terminals do
    if Code.ensure_loaded?(IexCode.Tools.TerminalSupervisor) and
         Process.whereis(IexCode.Tools.TerminalSupervisor) do
      try do
        sessions = IexCode.Tools.TerminalSupervisor.list_sessions()

        stopped =
          Enum.map(sessions, fn {session_id, _pid} ->
            case IexCode.Tools.TerminalSupervisor.stop_session(session_id) do
              :ok -> {session_id, :ok}
              {:error, reason} -> {session_id, {:error, reason}}
            end
          end)

        # Catch any additional supervised children not registered under session keys
        children =
          try do
            DynamicSupervisor.which_children(IexCode.Tools.TerminalSupervisor)
          rescue
            _ -> []
          end

        for {_, child_pid, _, _} <- children, is_pid(child_pid) and Process.alive?(child_pid) do
          try do
            DynamicSupervisor.terminate_child(IexCode.Tools.TerminalSupervisor, child_pid)
          rescue
            _ -> :ok
          end
        end

        {:ok, stopped}
      rescue
        e ->
          Logger.warning("IexCode.Desktop.Lifecycle: Error cleaning up terminals: #{inspect(e)}")
          {:error, e}
      catch
        kind, reason ->
          Logger.warning(
            "IexCode.Desktop.Lifecycle: Catch cleaning up terminals: #{inspect({kind, reason})}"
          )

          {:error, {kind, reason}}
      end
    else
      {:ok, []}
    end
  end

  @doc """
  Releases active and expired workspace locks in SQLite.
  """
  @spec cleanup_workspace_locks(DateTime.t() | nil) :: {:ok, term()} | {:error, term()}
  def cleanup_workspace_locks(before \\ nil) do
    if Code.ensure_loaded?(IexCode.Runs) and
         Code.ensure_loaded?(IexCode.Repo) and
         Process.whereis(IexCode.Repo) do
      try do
        cutoff = before || DateTime.utc_now()

        case IexCode.Runs.release_expired_workspace_locks(cutoff) do
          {:ok, count} when is_integer(count) -> {:ok, count}
          {:error, reason} -> {:error, reason}
          other -> {:ok, other}
        end
      rescue
        _ in [DBConnection.OwnershipError] ->
          {:ok, :sandbox_unowned}

        e ->
          Logger.warning(
            "IexCode.Desktop.Lifecycle: Error releasing workspace locks: #{inspect(e)}"
          )

          {:error, e}
      catch
        kind, reason ->
          Logger.warning(
            "IexCode.Desktop.Lifecycle: Catch releasing workspace locks: #{inspect({kind, reason})}"
          )

          {:error, {kind, reason}}
      end
    else
      {:ok, 0}
    end
  end

  @doc """
  Flushes SQLite write-ahead logging (WAL) frames to disk.
  """
  @spec checkpoint_wal() :: {:ok, term()} | {:error, term()}
  def checkpoint_wal do
    if Code.ensure_loaded?(IexCode.Repo) and Process.whereis(IexCode.Repo) do
      try do
        IexCode.Repo.checkpoint_wal()
      rescue
        _ in [DBConnection.OwnershipError] ->
          {:ok, :sandbox_unowned}

        e ->
          Logger.warning("IexCode.Desktop.Lifecycle: Error checkpointing WAL: #{inspect(e)}")
          {:error, e}
      catch
        kind, reason ->
          Logger.warning(
            "IexCode.Desktop.Lifecycle: Catch checkpointing WAL: #{inspect({kind, reason})}"
          )

          {:error, {kind, reason}}
      end
    else
      {:ok, :repo_not_running}
    end
  end

  @doc """
  Shuts down the BEAM runtime or desktop OS process.
  """
  @spec halt_runtime((-> any()) | nil) :: any()
  def halt_runtime(custom_halt_fn \\ nil) do
    cond do
      is_function(custom_halt_fn, 0) ->
        custom_halt_fn.()

      Code.ensure_loaded?(Desktop.OS) and function_exported?(Desktop.OS, :shutdown, 0) ->
        Desktop.OS.shutdown()

      true ->
        System.stop(0)
    end
  end

  defp coordinate_quit(opts) do
    cleanup_timeout_ms =
      non_negative_timeout(opts[:cleanup_timeout_ms], @default_cleanup_timeout_ms)

    force_halt_after_ms =
      non_negative_timeout(opts[:force_halt_after_ms], @default_force_halt_after_ms)

    cleanup_fn = opts[:cleanup_fn] || default_cleanup_fn()
    stop_fn = opts[:stop_fn] || default_stop_fn()
    halt_fn = opts[:halt_fn] || default_force_halt_fn()

    watchdog? = Keyword.has_key?(opts, :halt_fn) or default_halt?()
    coordinator = self()

    if watchdog? do
      spawn(fn ->
        receive do
        after
          force_halt_after_ms ->
            safely_invoke(halt_fn, :hard_halt)
            send(coordinator, :hard_halt_returned)
        end
      end)
    end

    run_bounded_cleanup(cleanup_fn, cleanup_timeout_ms)
    safely_invoke(stop_fn, :graceful_stop)

    if Keyword.get(opts, :linger, default_halt?()) and watchdog? do
      receive do
        :hard_halt_returned -> :ok
      end
    end
  end

  defp run_bounded_cleanup(cleanup_fn, timeout_ms) when is_function(cleanup_fn, 0) do
    {cleanup_pid, cleanup_ref} =
      spawn_monitor(fn ->
        safely_invoke(cleanup_fn, :cleanup)
      end)

    receive do
      {:DOWN, ^cleanup_ref, :process, ^cleanup_pid, _reason} -> :ok
    after
      timeout_ms ->
        Logger.warning("IexCode.Desktop.Lifecycle: Cleanup timed out; continuing shutdown")
        Process.exit(cleanup_pid, :kill)
        Process.demonitor(cleanup_ref, [:flush])
    end
  end

  defp safely_invoke(fun, stage) when is_function(fun, 0) do
    fun.()
  rescue
    error ->
      Logger.warning(
        "IexCode.Desktop.Lifecycle: #{stage} failed during quit: #{Exception.message(error)}"
      )

      :ok
  catch
    kind, reason ->
      Logger.warning(
        "IexCode.Desktop.Lifecycle: #{stage} failed during quit: #{inspect({kind, reason})}"
      )

      :ok
  end

  defp non_negative_timeout(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_negative_timeout(_value, default), do: default

  defp default_stop_fn do
    if default_halt?(), do: fn -> System.stop(0) end, else: fn -> :ok end
  end

  defp default_cleanup_fn do
    if default_halt?(), do: fn -> teardown(halt: false) end, else: fn -> :ok end
  end

  defp default_force_halt_fn do
    if default_halt?(), do: fn -> System.halt(0) end, else: fn -> :ok end
  end

  @doc """
  Registers an exit hook with System.at_exit/1 to guarantee teardown runs before VM exit.
  """
  @spec register_shutdown_hook() :: :ok
  def register_shutdown_hook do
    System.at_exit(fn _status ->
      teardown(halt: false)
    end)
  end

  @doc """
  Alias for register_shutdown_hook/0.
  """
  @spec at_exit() :: :ok
  def at_exit do
    register_shutdown_hook()
  end

  @doc """
  Cleans up orphaned locks and stale background state on application startup.
  """
  @spec cleanup_orphans() :: {:ok, term()} | {:error, term()}
  def cleanup_orphans do
    cleanup_workspace_locks()
  end

  defp default_halt? do
    case Application.get_env(:iex_code, :desktop_lifecycle_halt) do
      val when is_boolean(val) ->
        val

      _ ->
        if Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) do
          Mix.env() != :test
        else
          true
        end
    end
  end
end
