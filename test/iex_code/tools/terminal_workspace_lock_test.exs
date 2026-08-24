defmodule IexCode.Tools.TerminalWorkspaceLockTest do
  use IexCode.DataCase, async: false

  alias IexCode.{Projects, Runs, WorkspaceLocks}
  alias IexCode.Tools.TerminalServer

  @pubsub_server IexCode.PubSub

  setup do
    root = Path.join(System.tmp_dir!(), "terminal-lock-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    {:ok, project} =
      Projects.create_project(%{name: "Terminal lock project", root_path: root})

    session_id = "terminal-lock-#{System.unique_integer([:positive])}"
    :ok = Phoenix.PubSub.subscribe(@pubsub_server, "session:#{session_id}:terminal")
    {:ok, _pid} = TerminalServer.ensure_started(session_id, workspace_path: root)

    on_exit(fn ->
      Phoenix.PubSub.unsubscribe(@pubsub_server, "session:#{session_id}:terminal")
      _ = TerminalServer.kill(session_id)
      File.rm_rf!(root)
    end)

    %{project: project, root: root, session_id: session_id}
  end

  test "foreign project lock rejects raw input, correlated commands, and controls", context do
    {:ok, blocker} =
      WorkspaceLocks.acquire(context.project, [:project], owner_id: "foreign-run")

    assert {:error, {:workspace_lock_waiting, _locks}} =
             TerminalServer.send_input(context.session_id, "echo blocked\n")

    assert {:error, {:workspace_lock_waiting, _locks}} =
             TerminalServer.run_command_with_id(context.session_id, "echo blocked")

    assert {:error, {:workspace_lock_waiting, _locks}} =
             TerminalServer.send_signal(context.session_id, :sigint)

    assert {:error, {:workspace_lock_waiting, _locks}} =
             TerminalServer.restart(context.session_id)

    :ok = WorkspaceLocks.release(blocker)
    assert {:ok, _command_id} = TerminalServer.run_command_with_id(context.session_id, "true")
    assert_receive {:terminal_command_completed, %{session_id: sid, exit_code: 0}}, 5_000
    assert sid == context.session_id
  end

  test "correlated command releases at marker completion while raw input retains the lease",
       context do
    assert {:ok, _command_id} = TerminalServer.run_command_with_id(context.session_id, "true")
    assert_receive {:terminal_command_completed, %{session_id: sid, exit_code: 0}}, 5_000
    assert sid == context.session_id
    assert {:ok, _state} = TerminalServer.get_state(context.session_id)
    assert Runs.list_workspace_locks(project_id: context.project.id, active: true) == []

    assert :ok = TerminalServer.send_input(context.session_id, "\n")

    assert [%{status: "held", owner_id: owner}] =
             Runs.list_workspace_locks(project_id: context.project.id, active: true)

    assert owner == "terminal-session:#{context.session_id}"

    assert {:error, {:workspace_lock_waiting, _locks}} =
             WorkspaceLocks.acquire(context.project, [:project], owner_id: "competing-run")

    assert :ok = TerminalServer.kill(context.session_id)
    assert Runs.list_workspace_locks(project_id: context.project.id, active: true) == []
  end

  test "agent commands across sessions sharing a root wait for exclusive ownership", context do
    second_session_id = "terminal-lock-second-#{System.unique_integer([:positive])}"
    {:ok, _pid} = TerminalServer.ensure_started(second_session_id, workspace_path: context.root)
    on_exit(fn -> TerminalServer.kill(second_session_id) end)

    first =
      Task.async(fn ->
        TerminalServer.run_agent_command(
          context.session_id,
          "sleep 0.2; echo first",
          "FirstAgent",
          timeout_ms: 5_000
        )
      end)

    second =
      Task.async(fn ->
        TerminalServer.run_agent_command(
          second_session_id,
          "echo second",
          "SecondAgent",
          timeout_ms: 5_000
        )
      end)

    assert {:ok, %{exit_code: 0}} = Task.await(first, 6_000)
    assert {:ok, %{exit_code: 0}} = Task.await(second, 6_000)
  end
end
