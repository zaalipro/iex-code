defmodule IexCode.Desktop.Lifecycle do
  @moduledoc """
  Coordinates process lifecycle, clean teardown, and resource cleanup for
  the IexCode native desktop application.

  Ensures zero zombie PTY processes, invalidation of workspace locks,
  flushing of SQLite WAL journal frames to disk, and safe BEAM termination.
  """
  require Logger

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
