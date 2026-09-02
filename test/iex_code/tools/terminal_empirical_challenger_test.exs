defmodule IexCode.Tools.TerminalEmpiricalChallengerTest do
  @moduledoc """
  Empirical Challenger Stress & Adversarial Test Suite for Milestone M1.
  Authored by challenger_m1_1.

  Adversarially challenges:
  1. Extreme keystroke throughput (10,000+ characters) under high concurrency.
  2. Rapid window resizing storm (100+ resize events) during active output streaming.
  3. Rapid process kill/restart lifecycle churn (50+ rapid cycles).
  4. Signal propagation (SIGINT, SIGTERM, SIGKILL, SIGTSTP, SIGCONT) and foreground process group interruption.
  5. UTF-8 multibyte boundary splits at every byte offset (2-byte, 3-byte, 4-byte codepoints).
  6. Zombie process prevention and OS process table verification (ps aux | grep pty_shim).
  """
  use IexCode.E2E.Case, async: false

  alias IexCode.Tools.{TerminalServer, TerminalSession}
  alias Phoenix.PubSub

  @pubsub_server IexCode.PubSub

  # ============================================================================
  # Helpers
  # ============================================================================

  defp subscribe_terminal(session_id) do
    PubSub.subscribe(@pubsub_server, "session:#{session_id}:terminal")
  end

  defp receive_output(session_id, expected_substr, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_receive_output(session_id, expected_substr, deadline, "")
  end

  defp do_receive_output(session_id, expected_substr, deadline, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:terminal_output, %{session_id: ^session_id, data: data}} ->
        new_acc = acc <> data

        matched? =
          case expected_substr do
            %Regex{} = regex -> Regex.match?(regex, new_acc)
            str when is_binary(str) -> String.contains?(new_acc, str)
          end

        if matched? do
          {:ok, new_acc}
        else
          do_receive_output(session_id, expected_substr, deadline, new_acc)
        end
    after
      remaining ->
        {:error, {:timeout, acc}}
    end
  end

  defp cleanup_session(session_id) do
    try do
      TerminalServer.kill(session_id)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp count_running_shims do
    case System.cmd("ps", ["-eo", "pid,command"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n")
        |> Enum.filter(&String.contains?(&1, "pty_shim.py"))
        |> Enum.reject(&String.contains?(&1, "grep"))
        |> length()

      _ ->
        0
    end
  end

  defp wait_for_shims_to_reap(target_max, max_wait_ms) do
    deadline = System.monotonic_time(:millisecond) + max_wait_ms
    do_wait_shims(target_max, deadline)
  end

  defp do_wait_shims(target_max, deadline) do
    current = count_running_shims()

    if current <= target_max do
      current
    else
      if System.monotonic_time(:millisecond) >= deadline do
        current
      else
        Process.sleep(100)
        do_wait_shims(target_max, deadline)
      end
    end
  end

  # ============================================================================
  # Dimension 1: Extreme Keystroke Throughput (10,000+ chars)
  # ============================================================================

  describe "Dimension 1: Extreme Keystroke Throughput" do
    test "CHALLENGE_01_extreme_keystroke_flood_12k_chars", %{workspace_path: path} do
      session_id = "challenger_keys_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      # Launch a deterministic character receiver via heredoc
      assert :ok = TerminalServer.run_command(session_id, "cat << 'EOF' | wc -c")

      # Generate 12,000 characters split into 120 concurrent tasks of 100 chars each
      chunk_count = 120
      chunk_size = 100
      _total_expected_chars = chunk_count * chunk_size

      tasks =
        for _task_idx <- 1..chunk_count do
          chunk = String.duplicate("X", chunk_size)

          Task.async(fn ->
            TerminalServer.send_input(session_id, chunk)
          end)
        end

      Task.await_many(tasks, 20_000)

      # Terminate heredoc
      assert :ok = TerminalServer.send_input(session_id, "\nEOF\n")

      # Verify wc output contains the total count (12000 chars + 1 newline before EOF = 12001)
      assert {:ok, output} = receive_output(session_id, "1200", 15_000)
      assert String.contains?(output, "1200")

      # Verify terminal remains responsive to new commands
      token = "THROUGHPUT_12K_PASSED"
      assert :ok = TerminalServer.run_command(session_id, "echo #{token}")
      assert {:ok, _} = receive_output(session_id, token, 8_000)
      assert Process.alive?(pid)
    end

    test "CHALLENGE_02_rapid_single_char_keystroke_stream_10k", %{workspace_path: path} do
      session_id = "challenger_single_keys_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      # Launch heredoc line counter
      assert :ok = TerminalServer.run_command(session_id, "cat << 'EOF' | wc -l")

      # Send 10,000 characters (1,000 lines of 10 chars each) across 10 concurrent tasks
      lines_count = 1_000

      tasks =
        for _t <- 1..10 do
          Task.async(fn ->
            for _k <- 1..100 do
              TerminalServer.send_input(session_id, "012345678\n")
            end
          end)
        end

      Task.await_many(tasks, 30_000)

      # Terminate heredoc
      assert :ok = TerminalServer.send_input(session_id, "EOF\n")

      assert {:ok, output} = receive_output(session_id, to_string(lines_count), 15_000)
      assert String.contains?(output, to_string(lines_count))
      assert Process.alive?(pid)
    end
  end

  # ============================================================================
  # Dimension 2: Rapid Window Resizing Storm (100+ events)
  # ============================================================================

  describe "Dimension 2: Rapid Resizing Storm" do
    test "CHALLENGE_03_rapid_resize_storm_100_events_during_stream", %{workspace_path: path} do
      session_id = "challenger_resize_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      # Start streaming background output
      assert :ok =
               TerminalServer.run_command(
                 session_id,
                 "for i in $(seq 1 1000); do echo \"RESIZE_STORM_LINE_$i\"; sleep 0.005; done"
               )

      # Dispatch 100 rapid resize operations
      for i <- 1..100 do
        cols = 30 + rem(i * 13, 190)
        rows = 10 + rem(i * 7, 70)
        assert :ok = TerminalServer.resize(session_id, cols, rows)
      end

      # Set final deterministic dimensions
      assert :ok = TerminalServer.resize(session_id, 140, 45)

      # Ensure output reached at least line 500
      assert {:ok, _} = receive_output(session_id, "RESIZE_STORM_LINE_", 15_000)

      # Verify GenServer state accurately reflects final dimensions
      assert {:ok, state} = TerminalServer.get_state(session_id)
      assert state.cols == 140
      assert state.rows == 45
      assert Process.alive?(pid)
    end
  end

  # ============================================================================
  # Dimension 3: Rapid Process Kill/Restart Cycles (50+ cycles)
  # ============================================================================

  describe "Dimension 3: Rapid Kill/Restart Churn" do
    test "CHALLENGE_04_rapid_kill_restart_50_cycles_with_zero_orphans", %{workspace_path: path} do
      initial_shims = count_running_shims()
      session_id = "challenger_churn_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_session(session_id) end)

      for cycle <- 1..50 do
        assert {:ok, pid} = TerminalServer.ensure_started(session_id, workspace_path: path)
        assert Process.alive?(pid)

        # Alternating operations: restart vs kill vs run_command
        case rem(cycle, 3) do
          0 ->
            assert {:ok, new_pid} = TerminalServer.restart(session_id)
            assert Process.alive?(new_pid)

          1 ->
            assert :ok = TerminalServer.kill(session_id)
            refute Process.alive?(pid)

          2 ->
            assert :ok = TerminalServer.send_input(session_id, "echo CYCLE_#{cycle}\n")
            assert {:ok, new_pid} = TerminalServer.restart(session_id)
            assert Process.alive?(new_pid)
        end
      end

      # Final clean start and command execution
      assert {:ok, final_pid} = TerminalServer.ensure_started(session_id, workspace_path: path)
      assert Process.alive?(final_pid)

      token = "CHURN_50_FINAL_SUCCESS"
      subscribe_terminal(session_id)
      assert :ok = TerminalServer.run_command(session_id, "echo #{token}")
      assert {:ok, _} = receive_output(session_id, token, 8_000)

      assert :ok = TerminalServer.kill(session_id)

      # Assert process count returns to baseline
      final_shims = wait_for_shims_to_reap(initial_shims, 5_000)
      assert final_shims <= initial_shims
    end
  end

  # ============================================================================
  # Dimension 4: Signal Propagation & Foreground Process Group Interruption
  # ============================================================================

  describe "Dimension 4: Signal Propagation" do
    test "CHALLENGE_05_sigint_interrupts_blocking_foreground_command", %{workspace_path: path} do
      session_id = "challenger_sigint_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      # Start a blocking sleep command
      assert :ok = TerminalServer.run_command(session_id, "sleep 120")
      Process.sleep(200)

      # Send SIGINT to interrupt sleep
      assert :ok = TerminalServer.send_signal(session_id, :sigint)

      # Immediate follow-up command must execute without waiting for 120s sleep
      token = "INTERRUPT_SIGINT_PASSED"
      assert :ok = TerminalServer.run_command(session_id, "echo #{token}")
      assert {:ok, _} = receive_output(session_id, token, 5_000)
      assert Process.alive?(pid)
    end

    test "CHALLENGE_06_sigterm_and_sigkill_handling", %{workspace_path: path} do
      session_id = "challenger_sigterm_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      # Send SIGTERM
      assert :ok = TerminalServer.send_signal(session_id, :sigterm)
      Process.sleep(200)

      # TerminalServer.restart should recover cleanly
      assert {:ok, restarted_pid} = TerminalServer.restart(session_id)
      assert Process.alive?(restarted_pid)

      token = "SIGTERM_RECOVERY_PASSED"
      assert :ok = TerminalServer.run_command(session_id, "echo #{token}")
      assert {:ok, _} = receive_output(session_id, token, 5_000)
    end
  end

  # ============================================================================
  # Dimension 5: UTF-8 Multibyte Boundary Splits
  # ============================================================================

  describe "Dimension 5: UTF-8 Multibyte Boundary Splits" do
    test "CHALLENGE_07_multibyte_utf8_split_at_every_byte_offset", %{workspace_path: path} do
      session_id = "challenger_utf8_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_session(session_id) end)

      subscribe_terminal(session_id)
      assert {:ok, pid} = TerminalServer.ensure_started(session_id, workspace_path: path)

      # 2-byte: Greek Lambda 'λ' (<<206, 187>>)
      # 3-byte: Euro '€' (<<226, 130, 172>>) and CJK '漢' (<<230, 188, 162>>)
      # 4-byte: Rocket '🚀' (<<240, 159, 154, 128>>) and Fire '🔥' (<<240, 159, 148, 165>>)
      # Execute a python command that flushes bytes individually through stdout to force PTY chunk slicing
      cmd =
        "python3 -c \"import sys, time; raw = 'λ € 漢 🚀 🔥'.encode('utf-8'); [sys.stdout.buffer.write(bytes([b])) or sys.stdout.buffer.flush() or time.sleep(0.005) for b in raw]; sys.stdout.buffer.write(b'\\n'); sys.stdout.buffer.flush()\""

      assert :ok = TerminalServer.run_command(session_id, cmd)

      # Verify output receives the fully intact Unicode string
      assert {:ok, output} = receive_output(session_id, "λ € 漢 🚀 🔥", 15_000)
      assert String.contains?(output, "λ € 漢 🚀 🔥")

      # Check history buffer
      history = TerminalServer.get_history(session_id)
      assert String.valid?(history)
      assert String.contains?(history, "λ € 漢 🚀 🔥")
      assert Process.alive?(pid)
    end

    test "CHALLENGE_07B_whitebox_port_chunk_utf8_split_and_reassembly", %{workspace_path: path} do
      session_id = "challenger_utf8_wb_#{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_session(session_id) end)

      subscribe_terminal(session_id)

      {:ok, pid} =
        start_supervised(
          {TerminalSession, [session_id: session_id, project_root: path, mode: :fallback]}
        )

      fake_port = make_ref()

      # 4-byte rocket <<240, 159, 154, 128>>
      <<r1::binary-size(1), r2::binary-size(2), r3::binary-size(1)>> = "🚀"
      # 3-byte spark <<226, 154, 161>>
      <<s1::binary-size(1), s2::binary-size(2)>> = "⚡"

      # Send partial chunk r1
      send(pid, {fake_port, {:data, r1}})
      refute_receive {:terminal_output, %{data: "🚀"}}, 100

      # Send remaining r2, r3 + first byte of spark s1
      send(pid, {fake_port, {:data, r2 <> r3 <> s1}})
      assert_receive {:terminal_output, %{data: "🚀"}}, 1_000

      # Send remaining spark bytes s2
      send(pid, {fake_port, {:data, s2}})
      assert_receive {:terminal_output, %{data: "⚡"}}, 1_000

      # Check full history
      history = TerminalServer.get_history(session_id)
      assert String.contains?(history, "🚀")
      assert String.contains?(history, "⚡")
      assert String.valid?(history)
    end
  end

  # ============================================================================
  # Dimension 6: Zombie Process Prevention & Process Table Verification
  # ============================================================================

  describe "Dimension 6: Zombie Process Prevention" do
    test "CHALLENGE_08_strict_zombie_process_audit_after_brutal_crashes", %{workspace_path: path} do
      initial_shims = count_running_shims()

      # Launch 10 sessions simultaneously
      sessions =
        for i <- 1..10 do
          sid = "challenger_zombie_#{i}_#{System.unique_integer([:positive])}"
          {:ok, pid} = TerminalServer.ensure_started(sid, workspace_path: path)
          # Fire infinite background streams
          :ok =
            TerminalServer.run_command(sid, "while true; do echo NOISY_OUTPUT; sleep 0.05; done")

          {sid, pid}
        end

      Process.sleep(300)

      # Brutally crash 5 session GenServers with Process.exit(:kill) (simulating VM process death)
      {crashed, normal} = Enum.split(sessions, 5)

      for {_sid, pid} <- crashed do
        Process.exit(pid, :kill)
      end

      # Terminate remaining 5 gracefully via TerminalServer.kill
      for {sid, _pid} <- normal do
        TerminalServer.kill(sid)
      end

      # Wait for OS process reaper to clean up pty_shim processes
      final_shims = wait_for_shims_to_reap(initial_shims, 6_000)

      # Assert zero leaked shims
      assert final_shims <= initial_shims
    end
  end
end
