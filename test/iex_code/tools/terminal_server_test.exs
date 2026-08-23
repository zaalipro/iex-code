defmodule IexCode.Tools.TerminalServerTest do
  use ExUnit.Case, async: false
  require Logger

  alias IexCode.Tools.TerminalServer
  alias Phoenix.PubSub

  @pubsub_server IexCode.PubSub

  setup do
    session_id = "server_test_#{:erlang.unique_integer([:positive])}"
    topic = "session:#{session_id}:terminal"
    PubSub.subscribe(@pubsub_server, topic)

    on_exit(fn ->
      PubSub.unsubscribe(@pubsub_server, topic)

      if pid = TerminalServer.whereis(session_id) do
        ref = Process.monitor(pid)
        TerminalServer.kill(session_id)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          1_000 -> :ok
        end
      end
    end)

    %{session_id: session_id, topic: topic}
  end

  describe "ensure_started/2, whereis/1, and running?/1" do
    test "idempotently starts session under TerminalSupervisor", %{session_id: session_id} do
      refute TerminalServer.running?(session_id)
      assert TerminalServer.whereis(session_id) == nil

      assert {:ok, pid1} = TerminalServer.ensure_started(session_id)
      assert is_pid(pid1)
      assert Process.alive?(pid1)
      assert TerminalServer.running?(session_id)
      assert TerminalServer.whereis(session_id) == pid1

      # Second call returns existing PID
      assert {:ok, pid2} = TerminalServer.ensure_started(session_id)
      assert pid1 == pid2
    end
  end

  describe "send_input/2 and run_command/2" do
    test "returns error on nonexistent session", %{session_id: session_id} do
      assert {:error, :not_found} = TerminalServer.send_input(session_id, "echo hello\n")
    end

    test "executes command and streams output", %{session_id: session_id} do
      assert {:ok, _pid} = TerminalServer.ensure_started(session_id)

      token = "SERVER_CMD_#{:erlang.unique_integer([:positive])}"
      assert :ok = TerminalServer.run_command(session_id, "echo #{token}")

      assert {:ok, output} = receive_matching_output(session_id, token)
      assert String.contains?(output, token)
    end
  end

  describe "resize/3 and send_signal/2" do
    test "resizes running terminal dimensions", %{session_id: session_id} do
      {:ok, _pid} = TerminalServer.ensure_started(session_id)

      assert :ok = TerminalServer.resize(session_id, 140, 50)
      assert_receive {:terminal_resized, %{session_id: ^session_id, cols: 140, rows: 50}}, 3_000

      assert {:ok, state} = TerminalServer.get_state(session_id)
      assert state.cols == 140
      assert state.rows == 50
    end

    test "validates invalid dimensions", %{session_id: session_id} do
      {:ok, _pid} = TerminalServer.ensure_started(session_id)

      assert {:error, :invalid_dimensions} = TerminalServer.resize(session_id, 0, 10)
      assert {:error, :invalid_dimensions} = TerminalServer.resize(session_id, 80, -5)
    end

    test "send_signal interrupts active shell execution", %{session_id: session_id} do
      {:ok, _pid} = TerminalServer.ensure_started(session_id)

      # Send long running sleep
      :ok = TerminalServer.run_command(session_id, "sleep 30")

      # Send SIGINT (Ctrl+C)
      assert :ok = TerminalServer.send_signal(session_id, :sigint)

      # Verify shell is still responsive
      token = "ALIVE_AFTER_SIGINT_#{:erlang.unique_integer([:positive])}"
      :ok = TerminalServer.run_command(session_id, "echo #{token}")
      assert {:ok, _} = receive_matching_output(session_id, token)
    end

    test "send_signal supports sigcont and sigtstp", %{session_id: session_id} do
      {:ok, _pid} = TerminalServer.ensure_started(session_id)

      assert :ok = TerminalServer.send_signal(session_id, :sigtstp)
      assert :ok = TerminalServer.send_signal(session_id, :sigcont)
      assert :ok = TerminalServer.send_signal(session_id, "SIGCONT")

      token = "ALIVE_AFTER_SIGCONT_#{:erlang.unique_integer([:positive])}"
      :ok = TerminalServer.run_command(session_id, "echo #{token}")
      assert {:ok, _} = receive_matching_output(session_id, token)
    end
  end

  describe "run_agent_command/4" do
    test "synchronously executes agent command and captures clean output", %{
      session_id: session_id
    } do
      token = "AGENT_EXECUTION_SUCCESS_#{:erlang.unique_integer([:positive])}"

      {:ok, result} =
        TerminalServer.run_agent_command(
          session_id,
          "echo '#{token}'",
          "ExplorerAgent",
          timeout_ms: 8_000
        )

      assert is_map(result)
      assert String.contains?(result.output, token)
      assert result.exit_code == 0
      assert result.duration_ms >= 0

      # Verify occupant restored to :user
      assert {:ok, state} = TerminalServer.get_state(session_id)
      assert state.occupant == :user
    end

    test "captures non-zero exit codes from agent commands", %{session_id: session_id} do
      {:ok, result} =
        TerminalServer.run_agent_command(
          session_id,
          "sh -c 'exit 7'",
          "VerifierAgent",
          timeout_ms: 8_000
        )

      assert result.exit_code == 7
    end
  end

  describe "history, clear, restart, and kill" do
    test "retrieves history and clears correctly", %{session_id: session_id} do
      {:ok, _pid} = TerminalServer.ensure_started(session_id)
      token = "HIST_SERVER_#{:erlang.unique_integer([:positive])}"
      :ok = TerminalServer.run_command(session_id, "echo #{token}")

      assert {:ok, _} = receive_matching_output(session_id, token)
      assert String.contains?(TerminalServer.get_history(session_id), token)

      assert :ok = TerminalServer.clear(session_id)
      assert_receive {:terminal_cleared, %{session_id: ^session_id}}, 3_000
      assert TerminalServer.get_history(session_id) == ""
    end

    test "restarts session with a fresh process", %{session_id: session_id} do
      assert {:ok, pid1} = TerminalServer.ensure_started(session_id)

      assert {:ok, pid2} = TerminalServer.restart(session_id)
      assert is_pid(pid2)
      assert Process.alive?(pid2)
      assert pid2 != pid1

      token = "POST_RESTART_TOKEN_#{:erlang.unique_integer([:positive])}"
      :ok = TerminalServer.run_command(session_id, "echo #{token}")
      assert {:ok, _} = receive_matching_output(session_id, token)
    end

    test "kills session cleanly and unregisters from supervisor", %{session_id: session_id} do
      {:ok, pid} = TerminalServer.ensure_started(session_id)
      ref = Process.monitor(pid)

      assert :ok = TerminalServer.kill(session_id)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 3_000

      refute TerminalServer.running?(session_id)
      assert TerminalServer.whereis(session_id) == nil
      assert TerminalServer.get_state(session_id) == {:error, :not_found}
    end
  end

  describe "search_history/3 facade" do
    test "delegates history search to TerminalSession", %{session_id: session_id} do
      {:ok, _pid} = TerminalServer.ensure_started(session_id)

      token = "FACADE_SEARCH_TEST_#{:erlang.unique_integer([:positive])}"
      :ok = TerminalServer.run_command(session_id, "echo #{token}")
      assert {:ok, _} = receive_matching_output(session_id, token)

      assert {:ok, results} = TerminalServer.search_history(session_id, token)
      assert length(results) >= 1
      first_match = hd(results)
      assert String.contains?(first_match.text, token)
      assert first_match.line_number > 0
    end

    test "returns {:error, :not_found} for nonexistent session" do
      assert {:error, :not_found} =
               TerminalServer.search_history("missing_session_id", "query")
    end
  end

  defp receive_matching_output(session_id, token, timeout \\ 8_000) do
    do_receive_matching_output(session_id, token, "", timeout)
  end

  defp do_receive_matching_output(session_id, token, acc, timeout) do
    receive do
      {:terminal_output, %{session_id: ^session_id, data: data}} ->
        new_acc = acc <> data

        if String.contains?(new_acc, token) do
          {:ok, new_acc}
        else
          do_receive_matching_output(session_id, token, new_acc, timeout)
        end
    after
      timeout ->
        {:error, {:timeout, acc}}
    end
  end
end
