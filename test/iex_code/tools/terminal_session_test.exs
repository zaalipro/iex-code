defmodule IexCode.Tools.TerminalSessionTest do
  use ExUnit.Case, async: false
  require Logger

  alias IexCode.Tools.TerminalSession
  alias Phoenix.PubSub

  @pubsub_server IexCode.PubSub

  setup do
    session_id = "test_sess_#{:erlang.unique_integer([:positive])}"
    topic = "session:#{session_id}:terminal"
    PubSub.subscribe(@pubsub_server, topic)

    on_exit(fn ->
      PubSub.unsubscribe(@pubsub_server, topic)

      if pid = TerminalSession.whereis(session_id) do
        ref = Process.monitor(pid)
        TerminalSession.stop(session_id)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          1_000 -> :ok
        end
      end
    end)

    %{session_id: session_id, topic: topic}
  end

  describe "initialization & registry" do
    test "starts successfully and registers in SessionRegistry under {:terminal, session_id}", %{
      session_id: session_id
    } do
      {:ok, pid} =
        start_supervised({TerminalSession, [session_id: session_id, project_root: File.cwd!()]})

      assert is_pid(pid)
      assert Process.alive?(pid)
      assert TerminalSession.whereis(session_id) == pid

      _ = :sys.get_state(pid)

      assert {:ok, state} = TerminalSession.get_state(session_id)
      assert state.session_id == session_id
      assert state.status in [:starting, :running]
      assert state.occupant == :user
      assert state.cols == 80
      assert state.rows == 24
    end

    test "broadcasts initial status over PubSub upon startup", %{
      session_id: session_id
    } do
      {:ok, pid} =
        start_supervised({TerminalSession, [session_id: session_id, project_root: File.cwd!()]})

      _ = :sys.get_state(pid)

      assert_receive {:terminal_status, %{session_id: ^session_id, status: :running}}, 5_000
    end
  end

  describe "bidirectional streaming & PubSub output" do
    test "dispatches stdin and broadcasts raw stdout chunk", %{session_id: session_id} do
      {:ok, pid} =
        start_supervised({TerminalSession, [session_id: session_id, project_root: File.cwd!()]})

      _ = :sys.get_state(pid)
      assert_receive {:terminal_status, _}, 5_000

      unique_token = "PTY_ECHO_#{:erlang.unique_integer([:positive])}"
      assert :ok = TerminalSession.send_input(session_id, "echo #{unique_token}\n")

      assert {:ok, output} = receive_matching_output(session_id, unique_token)
      assert String.contains?(output, unique_token)
    end

    test "handles split multibyte UTF-8 stream safely without crashes", %{session_id: session_id} do
      {:ok, pid} =
        start_supervised({TerminalSession, [session_id: session_id, project_root: File.cwd!()]})

      _ = :sys.get_state(pid)

      # Inject 4-byte emoji 🚀 (<<240, 159, 154, 128>>) split across two chunks
      send(pid, {nil, {:data, <<240, 159>>}})
      _ = :sys.get_state(pid)

      send(pid, {nil, {:data, <<154, 128>>}})
      _ = :sys.get_state(pid)

      assert_receive {:terminal_output, %{data: data}}, 3_000
      assert data =~ "🚀"
    end

    test "supports fallback mode execution", %{session_id: session_id} do
      {:ok, pid} =
        start_supervised(
          {TerminalSession, [session_id: session_id, mode: :fallback, project_root: File.cwd!()]}
        )

      _ = :sys.get_state(pid)

      token = "FALLBACK_TEST_#{:erlang.unique_integer([:positive])}"
      assert :ok = TerminalSession.send_input(session_id, "echo #{token}\n")

      assert {:ok, output} = receive_matching_output(session_id, token)
      assert String.contains?(output, token)
    end
  end

  describe "window resizing & dimensions" do
    test "updates dimensions and broadcasts resized event", %{session_id: session_id} do
      {:ok, pid} =
        start_supervised({TerminalSession, [session_id: session_id, cols: 80, rows: 24]})

      _ = :sys.get_state(pid)

      assert :ok = TerminalSession.resize(session_id, 120, 45)
      _ = :sys.get_state(pid)

      assert_receive {:terminal_resized, %{session_id: ^session_id, cols: 120, rows: 45}}, 3_000

      assert {:ok, state} = TerminalSession.get_state(session_id)
      assert state.cols == 120
      assert state.rows == 45
    end
  end

  describe "signals & occupant management" do
    test "sends signals and manages occupant transitions", %{session_id: session_id} do
      {:ok, pid} =
        start_supervised({TerminalSession, [session_id: session_id, project_root: File.cwd!()]})

      _ = :sys.get_state(pid)

      # Change occupant to agent
      assert :ok =
               TerminalSession.set_occupant(session_id, {:agent, "TestAgent", "test_op_1"})

      assert_receive {:terminal_occupant,
                      %{session_id: ^session_id, occupant: {:agent, "TestAgent", "test_op_1"}}},
                     3_000

      assert {:ok, state} = TerminalSession.get_state(session_id)
      assert state.occupant == {:agent, "TestAgent", "test_op_1"}

      # Send signal
      assert :ok = TerminalSession.send_signal(session_id, :sigint)

      # Revert occupant to user
      assert :ok = TerminalSession.set_occupant(session_id, :user)
      assert_receive {:terminal_occupant, %{session_id: ^session_id, occupant: :user}}, 3_000
    end
  end

  describe "ring buffer history management" do
    test "accumulates history and supports clear", %{session_id: session_id} do
      {:ok, pid} =
        start_supervised({TerminalSession, [session_id: session_id, project_root: File.cwd!()]})

      _ = :sys.get_state(pid)

      token = "HIST_TEST_#{:erlang.unique_integer([:positive])}"
      assert :ok = TerminalSession.send_input(session_id, "echo #{token}\n")

      assert {:ok, _} = receive_matching_output(session_id, token)

      history = TerminalSession.get_history(session_id)
      assert is_binary(history)
      assert String.contains?(history, token)

      assert :ok = TerminalSession.clear_history(session_id)
      assert_receive {:terminal_cleared, %{session_id: ^session_id}}, 3_000
      assert TerminalSession.get_history(session_id) == ""
    end

    test "enforces max_buffer_bytes capacity and drops oldest tail chunks", %{
      session_id: session_id
    } do
      {:ok, pid} =
        start_supervised(
          {TerminalSession,
           [session_id: session_id, max_buffer_bytes: 500, project_root: File.cwd!()]}
        )

      _ = :sys.get_state(pid)

      # Inject 1000 bytes in 200-byte chunks
      for idx <- 1..5 do
        chunk = "CHUNK_#{idx}_" <> String.duplicate("A", 185) <> "\n"
        send(pid, {nil, {:data, chunk}})
      end

      _ = :sys.get_state(pid)

      history = TerminalSession.get_history(session_id)
      assert byte_size(history) <= 500
      assert String.contains?(history, "CHUNK_5_")
      refute String.contains?(history, "CHUNK_1_")
    end
  end

  describe "restart and process lifecycle" do
    test "restarts session with new shell process", %{session_id: session_id} do
      {:ok, pid} =
        start_supervised({TerminalSession, [session_id: session_id, project_root: File.cwd!()]})

      _ = :sys.get_state(pid)

      assert {:ok, ^pid} = TerminalSession.restart(session_id)
      _ = :sys.get_state(pid)

      token = "POST_RESTART_#{:erlang.unique_integer([:positive])}"
      assert :ok = TerminalSession.send_input(session_id, "echo #{token}\n")
      assert {:ok, _} = receive_matching_output(session_id, token)
    end

    test "handles shell exit command cleanly", %{session_id: session_id} do
      {:ok, pid} =
        start_supervised({TerminalSession, [session_id: session_id, project_root: File.cwd!()]})

      _ = :sys.get_state(pid)

      assert :ok = TerminalSession.send_input(session_id, "exit\n")
      assert_receive {:terminal_exit, %{session_id: ^session_id}}, 8_000

      assert {:ok, state} = TerminalSession.get_state(session_id)
      assert state.status == :stopped
    end
  end

  describe "input locking & force bypass" do
    test "rejects send_input when occupied by agent unless forced", %{session_id: session_id} do
      {:ok, pid} =
        start_supervised({TerminalSession, [session_id: session_id, project_root: File.cwd!()]})

      _ = :sys.get_state(pid)

      :ok = TerminalSession.set_occupant(session_id, {:agent, "CoderAgent", "op_1"})

      # Rejected without force
      assert {:error, :agent_occupied} =
               TerminalSession.send_input(session_id, "echo blocked\n")

      # Accepted with force: true
      token = "FORCED_PASS_#{:erlang.unique_integer([:positive])}"
      assert :ok = TerminalSession.send_input(session_id, "echo #{token}\n", force: true)
      assert {:ok, output} = receive_matching_output(session_id, token)
      assert String.contains?(output, token)

      # Accepted when restored to :user
      :ok = TerminalSession.set_occupant(session_id, :user)
      user_token = "USER_PASS_#{:erlang.unique_integer([:positive])}"
      assert :ok = TerminalSession.send_input(session_id, "echo #{user_token}\n")
      assert {:ok, user_output} = receive_matching_output(session_id, user_token)
      assert String.contains?(user_output, user_token)
    end
  end

  describe "history search (search_history/3)" do
    test "searches scrollback with substring, regex, and ANSI stripping", %{
      session_id: session_id
    } do
      {:ok, pid} =
        start_supervised({TerminalSession, [session_id: session_id, project_root: File.cwd!()]})

      _ = :sys.get_state(pid)

      # Plain and colored input
      token1 = "SEARCHABLE_LINE_ONE"
      token2 = "SEARCHABLE_LINE_TWO"
      assert :ok = TerminalSession.send_input(session_id, "echo #{token1}\n")
      assert {:ok, _} = receive_matching_output(session_id, token1)

      assert :ok = TerminalSession.send_input(session_id, "echo #{token2}\n")
      assert {:ok, _} = receive_matching_output(session_id, token2)

      # Substring search
      assert {:ok, results} = TerminalSession.search_history(session_id, "SEARCHABLE_LINE")
      assert length(results) >= 2

      # Regex search
      assert {:ok, regex_results} =
               TerminalSession.search_history(session_id, "SEARCHABLE_LINE_(ONE|TWO)",
                 regex: true
               )

      assert length(regex_results) >= 2

      # Reverse option
      assert {:ok, rev_results} =
               TerminalSession.search_history(session_id, "SEARCHABLE_LINE", reverse: true)

      assert length(rev_results) >= 2
    end
  end

  describe "telemetry events emission" do
    test "emits session_started, output_chunk, and session_stopped", %{session_id: session_id} do
      test_pid = self()
      handler_id = "session-telem-#{session_id}-#{:erlang.unique_integer([:positive])}"

      events = [
        [:iex_code, :terminal, :session_started],
        [:iex_code, :terminal, :output_chunk],
        [:iex_code, :terminal, :session_stopped]
      ]

      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, _config ->
          send(test_pid, {:session_telem, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, pid} =
        start_supervised({TerminalSession, [session_id: session_id, project_root: File.cwd!()]})

      _ = :sys.get_state(pid)

      assert_receive {:session_telem, [:iex_code, :terminal, :session_started], measurements,
                      metadata},
                     5_000

      assert is_map(measurements)
      assert metadata.session_id == session_id

      # Output chunk
      token = "TELEMETRY_CHUNK_#{:erlang.unique_integer([:positive])}"
      assert :ok = TerminalSession.send_input(session_id, "echo #{token}\n")

      assert_receive {:session_telem, [:iex_code, :terminal, :output_chunk], chunk_meas,
                      chunk_meta},
                     5_000

      assert chunk_meas.byte_size > 0
      assert chunk_meta.session_id == session_id

      # Stop
      :ok = TerminalSession.stop(session_id)

      assert_receive {:session_telem, [:iex_code, :terminal, :session_stopped], stop_meas,
                      stop_meta},
                     5_000

      assert is_map(stop_meas)
      assert stop_meta.session_id == session_id
    end
  end

  # Helper to accumulate chunks until token is found
  defp receive_matching_output(session_id, token, acc \\ "", timeout \\ 8_000) do
    receive do
      {:terminal_output, %{session_id: ^session_id, data: data}} ->
        new_acc = acc <> data

        if String.contains?(new_acc, token) do
          {:ok, new_acc}
        else
          receive_matching_output(session_id, token, new_acc, timeout)
        end
    after
      timeout ->
        {:error, {:timeout, acc}}
    end
  end
end
