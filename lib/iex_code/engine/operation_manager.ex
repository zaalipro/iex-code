defmodule IexCode.Engine.OperationManager do
  @moduledoc """
  Manages asynchronous execution of operations (tools, file IO, commands, subagent tasks).
  Each operation is spawned in a dedicated Elixir process, monitored via OTP Process.monitor/1,
  and emits real-time progress and telemetry events.
  """
  require Logger
  alias IexCode.Sessions
  alias IexCode.Sessions.Operation
  alias Phoenix.PubSub

  @doc """
  Runs an operation in a dedicated asynchronous Elixir task process with crash monitoring.
  Returns `{:ok, task_pid, op_record}`.
  """
  def run_async_operation(session_id, parent_op_id, agent_name, op_type, title, params, fun) do
    op =
      create_or_fallback_operation(session_id, parent_op_id, agent_name, op_type, title, params)

    op_id = op.id
    parent_caller = self()
    start_time = System.monotonic_time(:millisecond)

    emit_telemetry(:start, session_id, op_id, 0, nil, nil, op)

    {:ok, task_pid} =
      Task.Supervisor.start_child(IexCode.TaskSupervisor, fn ->
        pid_str = inspect(self())

        started_op =
          safe_update_operation(op_id, %{pid_str: pid_str}, %{op | pid_str: pid_str})

        broadcast(session_id, {:operation_started, started_op})

        progress_fn = fn percent, message ->
          safe_update_operation(op_id, %{progress: percent, result: message}, op)
          broadcast(session_id, {:operation_progress, op_id, percent, message})
          emit_telemetry(:progress, session_id, op_id, percent, nil, message, op)
        end

        result =
          try do
            case fun.(progress_fn) do
              {:ok, res} ->
                duration = System.monotonic_time(:millisecond) - start_time
                res_str = if is_binary(res), do: res, else: inspect(res)

                final_op =
                  safe_update_operation(
                    op_id,
                    %{
                      status: "completed",
                      progress: 100,
                      result: res_str,
                      completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
                      duration_ms: duration
                    },
                    %{
                      op
                      | status: "completed",
                        progress: 100,
                        result: res_str,
                        duration_ms: duration
                    }
                  )

                broadcast(session_id, {:operation_completed, final_op})
                emit_telemetry(:stop, session_id, op_id, duration, nil, nil, final_op)
                {:ok, res}

              {:error, reason} ->
                duration = System.monotonic_time(:millisecond) - start_time
                err_str = format_crash_reason(reason)

                final_op =
                  safe_update_operation(
                    op_id,
                    %{
                      status: "failed",
                      error_message: err_str,
                      completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
                      duration_ms: duration
                    },
                    %{op | status: "failed", error_message: err_str, duration_ms: duration}
                  )

                broadcast(session_id, {:operation_failed, final_op})
                emit_telemetry(:crash, session_id, op_id, duration, reason, err_str, final_op)
                {:error, reason}
            end
          catch
            kind, err ->
              duration = System.monotonic_time(:millisecond) - start_time
              err_str = "#{kind}: #{format_crash_reason(err)}"

              final_op =
                safe_update_operation(
                  op_id,
                  %{
                    status: "failed",
                    error_message: err_str,
                    completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
                    duration_ms: duration
                  },
                  %{op | status: "failed", error_message: err_str, duration_ms: duration}
                )

              broadcast(session_id, {:operation_failed, final_op})
              emit_telemetry(:crash, session_id, op_id, duration, {kind, err}, err_str, final_op)
              {:error, err_str}
          end

        send(parent_caller, {:operation_task_done, op_id, result})
        result
      end)

    # Spawn crash watcher process under TaskSupervisor to guarantee zero dangling operations on abnormal exits
    Task.Supervisor.start_child(IexCode.TaskSupervisor, fn ->
      ref = Process.monitor(task_pid)

      receive do
        {:DOWN, ^ref, :process, ^task_pid, :normal} ->
          :ok

        {:DOWN, ^ref, :process, ^task_pid, :noproc} ->
          :ok

        {:DOWN, ^ref, :process, ^task_pid, reason} ->
          should_handle =
            try do
              case Sessions.get_operation(op_id) do
                %Sessions.Operation{status: status} when status in ["completed", "failed"] ->
                  false

                _ ->
                  true
              end
            rescue
              _ -> false
            catch
              _, _ -> false
            end

          if should_handle do
            duration = System.monotonic_time(:millisecond) - start_time
            err_str = format_crash_reason(reason)

            final_op =
              safe_update_operation(
                op_id,
                %{
                  status: "failed",
                  error_message: err_str,
                  completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
                  duration_ms: duration
                },
                %{op | status: "failed", error_message: err_str, duration_ms: duration}
              )

            broadcast(session_id, {:operation_failed, final_op})
            emit_telemetry(:crash, session_id, op_id, duration, reason, err_str, final_op)
            send(parent_caller, {:operation_task_done, op_id, {:error, err_str}})
          end
      end
    end)

    {:ok, task_pid, op}
  end

  @doc """
  Synchronous wrapper that monitors the task process with Process.monitor/1 and awaits completion.
  Returns immediately upon completion or process crash without blocking on timeouts.
  """
  def run_sync_operation(
        session_id,
        parent_op_id,
        agent_name,
        op_type,
        title,
        params,
        fun,
        timeout \\ 60_000
      ) do
    {:ok, task_pid, op} =
      run_async_operation(session_id, parent_op_id, agent_name, op_type, title, params, fun)

    op_id = op.id
    ref = Process.monitor(task_pid)

    receive do
      {:operation_task_done, ^op_id, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^task_pid, :normal} ->
        # Process completed normally; flush and wait briefly for task_done message
        receive do
          {:operation_task_done, ^op_id, result} ->
            Process.demonitor(ref, [:flush])
            result
        after
          100 ->
            Process.demonitor(ref, [:flush])
            {:ok, :completed}
        end

      {:DOWN, ^ref, :process, ^task_pid, reason} ->
        Process.demonitor(ref, [:flush])
        err_msg = format_crash_reason(reason)
        {:error, err_msg}
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        {:error, "Operation timed out after #{timeout}ms"}
    end
  end

  # ============================================================================
  # Operation Tree Hierarchy Helpers
  # ============================================================================

  @doc """
  Builds a nested operation tree from a flat list of operations.
  Each operation has a `:children` list containing its direct descendants.
  """
  def build_tree(operations) when is_list(operations) do
    by_parent = Enum.group_by(operations, & &1.parent_op_id)
    all_ids = MapSet.new(Enum.map(operations, & &1.id))

    root_ops =
      Enum.filter(operations, fn op ->
        is_nil(op.parent_op_id) or op.parent_op_id == "" or
          not MapSet.member?(all_ids, op.parent_op_id)
      end)

    root_ops =
      if root_ops == [] and operations != [] do
        [hd(operations)]
      else
        root_ops
      end

    Enum.map(root_ops, &nest_children(&1, by_parent, MapSet.new([&1.id])))
  end

  defp nest_children(op, by_parent, visited) do
    children =
      Map.get(by_parent, op.id, [])
      |> Enum.reject(&MapSet.member?(visited, &1.id))

    nested_children =
      Enum.map(children, fn child ->
        nest_children(child, by_parent, MapSet.put(visited, child.id))
      end)

    Map.put(op, :children, nested_children)
  end

  @doc """
  Returns all direct child operations for a given parent_op_id.
  """
  def get_children(parent_op_id, operations) when is_list(operations) do
    Enum.filter(operations, &(&1.parent_op_id == parent_op_id))
  end

  @doc """
  Returns all root operations (parent_op_id is nil or empty or not found).
  """
  def get_root_operations(operations) when is_list(operations) do
    all_ids = MapSet.new(Enum.map(operations, & &1.id))

    roots =
      Enum.filter(operations, fn op ->
        is_nil(op.parent_op_id) or op.parent_op_id == "" or
          not MapSet.member?(all_ids, op.parent_op_id)
      end)

    if roots == [] and operations != [] do
      [hd(operations)]
    else
      roots
    end
  end

  @doc """
  Returns summary statistics for the operation tree.
  """
  def tree_stats(operations) when is_list(operations) do
    all_ids = MapSet.new(Enum.map(operations, & &1.id))

    roots_count =
      Enum.count(operations, fn op ->
        is_nil(op.parent_op_id) or op.parent_op_id == "" or
          not MapSet.member?(all_ids, op.parent_op_id)
      end)

    roots_count = if roots_count == 0 and operations != [], do: 1, else: roots_count

    %{
      total: length(operations),
      roots: roots_count,
      running: Enum.count(operations, &(&1.status == "running")),
      completed: Enum.count(operations, &(&1.status == "completed")),
      failed: Enum.count(operations, &(&1.status == "failed")),
      total_duration_ms: Enum.sum(Enum.map(operations, &(&1.duration_ms || 0)))
    }
  end

  # ============================================================================
  # Crash Formatting & Telemetry Helpers
  # ============================================================================

  @doc """
  Formats any Erlang/Elixir crash or exit reason into a sanitized UTF-8 string.
  """
  def format_crash_reason(:normal), do: "Process exited normally"
  def format_crash_reason(:noproc), do: "Process does not exist or died before monitor"
  def format_crash_reason(:killed), do: "Process was killed (:killed)"

  def format_crash_reason({:shutdown, reason}),
    do: "Process shut down: #{format_crash_reason(reason)}"

  def format_crash_reason(:shutdown), do: "Process shut down"
  def format_crash_reason(%{__struct__: _, message: msg}) when is_binary(msg), do: msg
  def format_crash_reason({%{__struct__: _, message: msg}, _stack}) when is_binary(msg), do: msg

  def format_crash_reason({exception, _stack}) when is_exception(exception),
    do: Exception.message(exception)

  def format_crash_reason(exception) when is_exception(exception),
    do: Exception.message(exception)

  def format_crash_reason(term) when is_binary(term), do: Sessions.sanitize_utf8(term)
  def format_crash_reason(term) when is_atom(term), do: Atom.to_string(term)
  def format_crash_reason({kind, term}) when is_atom(kind), do: "#{kind}: #{inspect(term)}"
  def format_crash_reason(term), do: inspect(term)

  defp create_or_fallback_operation(session_id, parent_op_id, agent_name, op_type, title, params) do
    try do
      case Sessions.create_operation(%{
             session_id: session_id,
             parent_op_id: parent_op_id,
             agent_name: agent_name,
             op_type: to_string(op_type),
             title: title,
             status: "running",
             progress: 0,
             params: params,
             started_at: DateTime.utc_now() |> DateTime.truncate(:second)
           }) do
        {:ok, created} -> created
        _ -> fallback_op(session_id, parent_op_id, agent_name, op_type, title, params)
      end
    rescue
      _ -> fallback_op(session_id, parent_op_id, agent_name, op_type, title, params)
    end
  end

  defp fallback_op(session_id, parent_op_id, agent_name, op_type, title, params) do
    %Operation{
      id: Ecto.UUID.generate(),
      session_id: session_id,
      parent_op_id: parent_op_id,
      agent_name: agent_name,
      op_type: to_string(op_type),
      title: title,
      status: "running",
      progress: 0,
      params: params,
      started_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end

  defp broadcast(session_id, event) do
    PubSub.broadcast(IexCode.PubSub, "session:#{session_id}", event)
  rescue
    _ -> :ok
  end

  defp emit_telemetry(event, session_id, op_id, value, reason, message, op) do
    measurements =
      case event do
        :start -> %{system_time: System.system_time()}
        :progress -> %{progress: value, system_time: System.system_time()}
        :stop -> %{duration_ms: value, system_time: System.system_time()}
        :crash -> %{duration_ms: value, system_time: System.system_time()}
      end

    metadata = %{
      session_id: session_id,
      operation_id: op_id,
      agent_name: op.agent_name,
      op_type: op.op_type,
      parent_op_id: op.parent_op_id,
      reason: reason,
      message: message
    }

    :telemetry.execute([:iex_code, :operation, event], measurements, metadata)
  rescue
    _ -> :ok
  end

  defp safe_update_operation(op_id, attrs, fallback_struct) do
    try do
      case Sessions.update_operation(op_id, attrs) do
        {:ok, updated} -> updated
        _ -> fallback_struct
      end
    rescue
      _ -> fallback_struct
    catch
      _, _ -> fallback_struct
    end
  end
end
