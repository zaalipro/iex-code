defmodule IexCode.Tools.ProcessGroupRunner do
  @moduledoc """
  Isolated POSIX process-group command runner.

  Spawns shell commands through a lightweight `python3` wrapper using
  `start_new_session=True` (`os.setsid()`) so the command and all descendants run
  in a dedicated OS process group (`pgid`). On timeout or port close, sends
  `SIGTERM` followed by `SIGKILL` to `-pgid` so grandchild processes (`sleep`,
  background subshells, pipelines) are deterministically reaped with zero orphans.
  """

  alias IexCode.Tools.SecretMasker

  @default_timeout_ms 30_000
  @default_max_output_bytes 256_000
  @term_grace_ms 150
  @kill_wait_ms 200

  @python_wrapper ~S"""
  import os
  import selectors
  import signal
  import struct
  import subprocess
  import sys
  import time

  class _StopSignal(Exception):
    pass

  def _send_packet(tag, payload):
    frame = struct.pack(">I", 1 + len(payload)) + tag + payload
    try:
      out = sys.stdout.buffer
      view = memoryview(frame)
      written = 0
      while written < len(frame):
        n = out.write(view[written:])
        if n is None:
          break
        written += n
      out.flush()
      return True
    except (BrokenPipeError, OSError):
      return False

  def _kill_pg(pgid, sig):
    try:
      os.killpg(pgid, sig)
      return True
    except ProcessLookupError:
      return False
    except PermissionError:
      return False

  def _pg_alive(pgid, proc):
    try:
      os.killpg(pgid, 0)
      return True
    except (ProcessLookupError, PermissionError):
      return proc.poll() is None

  def _reap_pg(pgid, proc, grace_s=0.15):
    if _kill_pg(pgid, signal.SIGTERM):
      deadline = time.monotonic() + grace_s
      while time.monotonic() < deadline:
        proc.poll()
        if not _pg_alive(pgid, proc):
          break
        time.sleep(0.01)
      _kill_pg(pgid, signal.SIGKILL)
    if proc.poll() is None:
      try:
        proc.kill()
      except OSError:
        pass
    try:
      proc.wait(timeout=0.5)
    except Exception:
      pass

  def main():
    cmd = sys.argv[1]
    cwd = sys.argv[2]

    try:
      os.setsid()
    except OSError:
      pass

    try:
      proc = subprocess.Popen(
        ["/bin/sh", "-c", cmd],
        cwd=cwd,
        start_new_session=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
      )
    except OSError as exc:
      _send_packet(b"E", str(exc).encode("utf-8", "replace"))
      return 127

    pgid = proc.pid
    _send_packet(b"P", struct.pack(">I", pgid))

    reap_needed = False
    reaped = False

    def _on_signal(_signum, _frame):
      nonlocal reap_needed
      reap_needed = True
      raise _StopSignal()

    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
      try:
        signal.signal(sig, _on_signal)
      except (OSError, ValueError):
        pass

    stdout_fd = proc.stdout.fileno()
    stdin_fd = sys.stdin.fileno()
    os.set_blocking(stdout_fd, False)
    os.set_blocking(stdin_fd, False)

    sel = selectors.DefaultSelector()
    sel.register(stdout_fd, selectors.EVENT_READ, data="stdout")
    sel.register(stdin_fd, selectors.EVENT_READ, data="stdin")

    stdout_open = True

    try:
      while stdout_open and not reap_needed:
        events = sel.select()
        for key, _mask in events:
          if key.data == "stdout":
            while True:
              try:
                chunk = os.read(stdout_fd, 65536)
              except BlockingIOError:
                break
              except OSError:
                chunk = b""
              if not chunk:
                stdout_open = False
                try:
                  sel.unregister(stdout_fd)
                except Exception:
                  pass
                break
              if not _send_packet(b"O", chunk):
                reap_needed = True
                break
          elif key.data == "stdin":
            try:
              ctrl = os.read(stdin_fd, 4096)
            except BlockingIOError:
              ctrl = None
            except OSError:
              ctrl = b""
            if ctrl == b"" or (ctrl is not None and b"K" in ctrl):
              reap_needed = True
              try:
                sel.unregister(stdin_fd)
              except Exception:
                pass
              break

      if reap_needed:
        return 143

      rc = proc.wait()
      exit_code = 128 + (-rc) if rc < 0 else rc
      _send_packet(b"X", struct.pack(">i", exit_code))
      return 0
    except _StopSignal:
      reap_needed = True
      return 143
    finally:
      try:
        sel.close()
      except Exception:
        pass
      if proc.stdout:
        try:
          proc.stdout.close()
        except Exception:
          pass
      if (reap_needed or proc.poll() is None) and not reaped:
        reaped = True
        _reap_pg(pgid, proc)

  sys.exit(main())
  """

  @type run_result ::
          {:ok,
           %{
             exit_code: integer(),
             output: binary(),
             truncated?: boolean(),
             pgid: pos_integer() | nil
           }}
          | {:timeout, %{output: binary(), truncated?: boolean(), pgid: pos_integer() | nil}}
          | {:error, term()}

  @doc """
  Executes `command` via `/bin/sh -c` inside an isolated POSIX process group.

  Options:
    * `:cd` - working directory (default current directory)
    * `:env` - environment map passed to the command process (default `%{}`)
    * `:timeout_ms` - wall-clock execution budget in milliseconds (default `30_000`)
    * `:max_output_bytes` - maximum captured output bytes (default `256_000`)
  """
  @spec run(String.t(), keyword()) :: run_result()
  def run(command, opts \\ []) when is_binary(command) and is_list(opts) do
    cd = opts |> Keyword.get(:cd, File.cwd!()) |> Path.expand()
    env_map = Keyword.get(opts, :env, %{})
    timeout_ms = opts |> Keyword.get(:timeout_ms, @default_timeout_ms) |> max(1)
    max_output_bytes = opts |> Keyword.get(:max_output_bytes, @default_max_output_bytes) |> max(1)

    with :ok <- validate_cwd(cd),
         {:ok, python_path} <- find_python3() do
      port_env = SecretMasker.to_port_env(env_map)

      port =
        Port.open(
          {:spawn_executable, python_path},
          [
            :binary,
            {:packet, 4},
            :use_stdio,
            :exit_status,
            :hide,
            cd: cd,
            args: ["-u", "-c", @python_wrapper, command, cd],
            env: port_env
          ]
        )

      deadline = System.monotonic_time(:millisecond) + timeout_ms

      state = %{
        port: port,
        pgid: nil,
        output: "",
        truncated?: false,
        max_output_bytes: max_output_bytes,
        exit_code: nil,
        spawn_error: nil
      }

      try do
        collect_packets(state, deadline)
      after
        safe_close_port(port)
      end
    end
  end

  defp validate_cwd(cd) do
    if File.dir?(cd), do: :ok, else: {:error, {:invalid_cwd, cd}}
  end

  defp find_python3 do
    case System.find_executable("python3") do
      nil -> {:error, :python3_not_found}
      path -> {:ok, path}
    end
  end

  defp collect_packets(%{port: port} = state, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      handle_timeout(state)
    else
      receive do
        {^port, {:data, packet}} ->
          next_state = handle_packet(packet, state)

          if next_state.spawn_error != nil do
            wait_wrapper_exit(port, 50)
            {:error, next_state.spawn_error}
          else
            collect_packets(next_state, deadline)
          end

        {^port, {:exit_status, wrapper_status}} ->
          final_state = drain_packets(state)

          if final_state.spawn_error != nil do
            {:error, final_state.spawn_error}
          else
            exit_code = final_state.exit_code || wrapper_status

            {:ok,
             %{
               exit_code: exit_code,
               output: final_state.output,
               truncated?: final_state.truncated?,
               pgid: final_state.pgid
             }}
          end
      after
        remaining ->
          handle_timeout(state)
      end
    end
  end

  defp handle_packet(<<?P, pgid::unsigned-integer-32-big>>, state) when pgid > 0 do
    %{state | pgid: pgid}
  end

  defp handle_packet(<<?O, chunk::binary>>, state) do
    {next_output, next_truncated?} =
      append_capped(state.output, state.truncated?, chunk, state.max_output_bytes)

    %{state | output: next_output, truncated?: next_truncated?}
  end

  defp handle_packet(<<?X, code::signed-integer-32-big>>, state) do
    %{state | exit_code: code}
  end

  defp handle_packet(<<?E, reason::binary>>, state) do
    %{state | spawn_error: reason}
  end

  defp handle_packet(_unknown, state), do: state

  defp drain_packets(%{port: port} = state) do
    receive do
      {^port, {:data, packet}} ->
        state
        |> then(&handle_packet(packet, &1))
        |> drain_packets()
    after
      0 -> state
    end
  end

  defp handle_timeout(%{port: port, pgid: pgid} = state) do
    reap_process_group(port, pgid)
    final_state = drain_packets(state)

    {:timeout,
     %{
       output: final_state.output,
       truncated?: final_state.truncated?,
       pgid: final_state.pgid
     }}
  end

  defp reap_process_group(port, pgid) do
    send_stop_signal(port)
    signal_pgid(pgid, "TERM")

    case wait_wrapper_exit(port, @term_grace_ms) do
      :exited ->
        :ok

      :timeout ->
        signal_pgid(pgid, "KILL")
        _ = wait_wrapper_exit(port, @kill_wait_ms)
        :ok
    end

    safe_close_port(port)
  end

  defp send_stop_signal(port) do
    if Port.info(port) != nil do
      Port.command(port, "K")
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp signal_pgid(pgid, signal) when is_integer(pgid) and pgid > 0 do
    kill_bin = System.find_executable("kill") || "/bin/kill"
    System.cmd(kill_bin, ["-#{signal}", "-#{pgid}"], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp signal_pgid(_pgid, _signal), do: :ok

  defp wait_wrapper_exit(port, timeout_ms) do
    receive do
      {^port, {:exit_status, _code}} -> :exited
    after
      timeout_ms -> :timeout
    end
  end

  defp safe_close_port(port) do
    if Port.info(port) != nil do
      Port.close(port)
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp append_capped(acc, true, _chunk, _max_bytes), do: {acc, true}

  defp append_capped(acc, false, chunk, max_bytes) do
    if byte_size(acc) + byte_size(chunk) <= max_bytes do
      {acc <> chunk, false}
    else
      take = max(max_bytes - byte_size(acc), 0)
      {acc <> binary_part(chunk, 0, take), true}
    end
  end
end
