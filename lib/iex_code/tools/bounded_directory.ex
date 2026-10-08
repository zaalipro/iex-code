defmodule IexCode.Tools.BoundedDirectory do
  @moduledoc """
  Temporary, supervised owner of one isolated Python scandir Port per search.
  One name/ack is in flight, framed at 65,535 bytes (names at most 4,096).
  Listings share 10 seconds active time; each request and idle wait is bounded.
  Names from an unfinished directory are discarded, never sorted as a prefix.
  """
  @timeout 5_000
  @active_ms 10_000
  @wire_bytes 2_097_152
  @path_bytes 16_384

  def wire_bytes, do: @wire_bytes

  def open(opts \\ []) do
    owner = self()
    ref = make_ref()
    supervisor = Keyword.get(opts, :supervisor, IexCode.TaskSupervisor)

    with {:ok, pid} <-
           Task.Supervisor.start_child(supervisor, fn -> start(owner, ref, opts) end) do
      await(pid, ref)
    end
  end

  def list(pid, path, entries, wire) do
    if byte_size(path) > @path_bytes or :binary.match(path, <<0>>) != :nomatch do
      {:error, :path}
    else
      ref = make_ref()
      send(pid, {:list, self(), ref, path, entries, wire})
      await(pid, ref)
    end
  end

  def close(pid) do
    monitor = Process.monitor(pid)
    send(pid, {:close, self()})

    receive do
      {:DOWN, ^monitor, :process, ^pid, _} -> :ok
    after
      2_000 -> {:error, :shutdown_timeout}
    end
  end

  defp await(pid, ref) do
    monitor = Process.monitor(pid)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _} ->
        {:error, :helper_exit}
    after
      12_000 ->
        Process.demonitor(monitor, [:flush])
        send(pid, {:close, self()})
        {:error, :timeout}
    end
  end

  defp start(owner, ref, opts) do
    Process.flag(:trap_exit, true)
    owner_ref = Process.monitor(owner)
    python = Keyword.get(opts, :python, System.find_executable("python3"))

    helper =
      Keyword.get(opts, :helper, Path.join(:code.priv_dir(:iex_code), "bounded_directory.py"))

    if is_binary(python) and File.regular?(python) and File.regular?(helper) do
      port =
        Port.open({:spawn_executable, String.to_charlist(python)}, [
          :binary,
          :exit_status,
          {:packet, 2},
          {:args, ["-I", "-S", "-B", "-u", helper]}
        ])

      os_pid = Port.info(port, :os_pid) |> elem(1)
      send(owner, {ref, {:ok, self()}})

      try do
        loop(port, owner, owner_ref, Keyword.get(opts, :timeout_ms, @timeout), @active_ms)
      after
        shutdown(port, os_pid)
      end
    else
      send(owner, {ref, {:error, :helper_unavailable}})
    end
  end

  defp loop(port, owner, owner_ref, timeout, remaining) do
    receive do
      {:list, ^owner, ref, path, entries, wire} ->
        cond do
          remaining <= 0 ->
            send(owner, {ref, {:error, :timeout}})

          entries <= 0 or wire < 16 ->
            reason = if entries <= 0, do: :entries, else: :wire

            send(
              owner,
              {ref, {:incomplete, reason, %{entries: 0, wire_bytes: 0, helper_peak_rss_bytes: 0}}}
            )

            loop(port, owner, owner_ref, timeout, remaining)

          true ->
            started = System.monotonic_time(:millisecond)
            deadline = started + min(timeout, remaining)

            Port.command(
              port,
              <<?L, min(entries, 5_000)::32, min(wire, @wire_bytes)::32, path::binary>>
            )

            result = collect(port, owner, owner_ref, deadline, entries, wire, [], 0)
            send(owner, {ref, result})

            if elem(result, 0) != :error do
              elapsed = System.monotonic_time(:millisecond) - started
              loop(port, owner, owner_ref, timeout, remaining - elapsed)
            end
        end

      {:close, ^owner} ->
        :ok

      {:DOWN, ^owner_ref, :process, ^owner, _} ->
        :ok

      {^port, {:exit_status, _}} ->
        :ok

      {:EXIT, _pid, _reason} ->
        :ok
    after
      10_000 -> :ok
    end
  end

  defp collect(port, owner, owner_ref, deadline, allowance, wire, names, used) do
    receive do
      {^port, {:data, <<?N, name::binary>>}} ->
        bytes = byte_size(name) + 3

        if valid_name?(name) and length(names) < allowance and used + bytes + 16 <= wire do
          Port.command(port, "A")
          collect(port, owner, owner_ref, deadline, allowance, wire, [name | names], used + bytes)
        else
          {:error, :protocol}
        end

      {^port, {:data, <<kind, count::32, rss::64, reason>>}}
      when kind in [?C, ?I, ?E] ->
        stats = %{entries: count, wire_bytes: used + 16, helper_peak_rss_bytes: rss}

        cond do
          count > allowance or count < length(names) or used + 16 > wire ->
            {:error, :protocol}

          kind == ?C and count == length(names) ->
            {:ok, names, stats}

          kind == ?I and reason in [1, 2, 3] ->
            {:incomplete, %{1 => :entries, 2 => :wire, 3 => :name}[reason], stats}

          kind == ?E ->
            {:skip, stats}

          true ->
            {:error, :protocol}
        end

      {:DOWN, ^owner_ref, :process, ^owner, _} ->
        {:error, :caller_down}

      {:close, ^owner} ->
        {:error, :closed}

      {^port, _} ->
        {:error, :helper_exit}

      {:EXIT, _pid, _reason} ->
        {:error, :helper_exit}
    after
      max(0, deadline - System.monotonic_time(:millisecond)) -> {:error, :timeout}
    end
  end

  defp valid_name?(name) do
    byte_size(name) in 1..4_096 and name not in [".", ".."] and
      :binary.match(name, ["/", <<0>>]) == :nomatch
  end

  defp shutdown(port, os_pid) do
    # Keep the Port attached until an actual child exit where possible. The
    # helper also has SIGALRM/EOF backstops, including a brutally killed owner.
    if Port.info(port) do
      Port.command(port, "Q")

      unless exited?(port, 250) do
        signal(os_pid, "-TERM")

        unless exited?(port, 250) do
          signal(os_pid, "-KILL")
          exited?(port, 250)
        end
      end

      if Port.info(port), do: Port.close(port)
    end
  rescue
    ArgumentError -> :ok
  end

  defp exited?(port, timeout) do
    receive do
      {^port, {:exit_status, _}} -> true
      {:EXIT, ^port, _} -> true
    after
      timeout -> false
    end
  end

  defp signal(pid, signal) do
    System.cmd("/bin/kill", [signal, Integer.to_string(pid)], stderr_to_stdout: true)
  end
end
