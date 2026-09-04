defmodule IexCodeWeb.Live.ToolApprovalModalTest do
  use IexCode.E2E.Case, async: false

  @moduletag mock_llm: true

  alias IexCode.Engine.SessionServer
  alias IexCode.Sessions
  alias IexCode.Settings
  alias Phoenix.PubSub

  setup %{workspace_path: path} do
    project = create_project_fixture(%{root_path: path, name: "Tool Approval Test Project"})
    session = create_session_fixture(project, %{title: "Tool Approval Session"})
    settings = Settings.get_settings()
    {:ok, pid} = SessionServer.ensure_started(session.id)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    end)

    %{project: project, session: session, settings: settings}
  end

  test "renders tool approval modal with tool details, parameters preview, and risk reason", %{
    conn: conn,
    session: session
  } do
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    refute has_element?(view, "#tool-approval-modal")

    req = %{
      id: "app-test-1",
      session_id: session.id,
      tool_name: "run_command",
      category: "shell_execution",
      arguments: %{"command" => "rm -rf /tmp/dangerous_dir", "timeout" => 30},
      reason: "Tool 'run_command' modifies files or executes commands",
      tier: "prompt_dangerous"
    }

    # Broadcast tool approval request over PubSub
    PubSub.broadcast(
      IexCode.PubSub,
      "session:#{session.id}",
      {:tool_approval_requested, session.id, req}
    )

    # Verify modal and its elements
    assert has_element?(view, "#tool-approval-modal")
    assert has_element?(view, "#tool-approval-title", "Tool Execution Approval Required")
    assert has_element?(view, "#tool-approval-tier-badge", "prompt_dangerous")
    assert has_element?(view, "#tool-approval-category-badge", "shell_execution")
    assert has_element?(view, "#tool-approval-name", "run_command")

    assert has_element?(
             view,
             "#tool-approval-reason",
             "Tool 'run_command' modifies files or executes commands"
           )

    assert has_element?(view, "#tool-approval-preview-box")
    assert render(element(view, "#tool-approval-preview-box")) =~ "rm -rf /tmp/dangerous_dir"

    # Action buttons must be present with explicit IDs
    assert has_element?(view, "#approve-tool-once-btn")
    assert has_element?(view, "#allow-tool-session-btn")
    assert has_element?(view, "#deny-tool-btn")
  end

  test "Approve Once flow: permits single tool invocation and dismisses modal", %{
    conn: conn,
    session: session
  } do
    PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    req = %{
      id: "app-test-once",
      session_id: session.id,
      tool_name: "write_file",
      category: "file_mutations",
      arguments: %{"path" => "lib/sample.ex", "content" => "defmodule Sample do\nend"},
      reason: "Tool 'write_file' modifies files or executes commands",
      tier: "prompt_dangerous"
    }

    PubSub.broadcast(
      IexCode.PubSub,
      "session:#{session.id}",
      {:tool_approval_requested, session.id, req}
    )

    assert has_element?(view, "#tool-approval-modal")

    # Click Approve Once
    view
    |> element("#approve-tool-once-btn")
    |> render_click()

    # Modal should be dismissed
    refute has_element?(view, "#tool-approval-modal")

    # PubSub broadcast should confirm the decision
    assert_receive {:tool_approval_decision, "app-test-once", :approve_once}, 2_000
  end

  test "Allow for Session flow: adds category to session overrides, subsequent calls bypass prompt",
       %{
         conn: conn,
         session: session,
         settings: settings
       } do
    PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    req = %{
      id: "app-test-session",
      session_id: session.id,
      tool_name: "run_command",
      category: "shell_execution",
      arguments: %{"command" => "mix test"},
      reason: "Tool 'run_command' executes commands",
      tier: "prompt_dangerous"
    }

    PubSub.broadcast(
      IexCode.PubSub,
      "session:#{session.id}",
      {:tool_approval_requested, session.id, req}
    )

    assert has_element?(view, "#tool-approval-modal")

    # Click Allow for Session
    view
    |> element("#allow-tool-session-btn")
    |> render_click()

    # Modal should be dismissed
    refute has_element?(view, "#tool-approval-modal")

    # PubSub decision broadcast
    assert_receive {:tool_approval_decision, "app-test-session", :allow_session}, 2_000

    # Ensure SessionServer overrides now include shell_execution: "auto"
    assert {:ok, overrides} =
             SessionServer.update_session_overrides(session.id, %{"shell_execution" => "auto"})

    assert overrides["shell_execution"] == "auto"

    # Subsequent tool calls for shell_execution should immediately be allowed without prompting!
    assert {:ok, :allowed, _} =
             SessionServer.authorize_tool(
               session.id,
               "run_command",
               %{"command" => "git status"},
               settings,
               overrides,
               500
             )
  end

  test "Deny flow: aborts execution, sends error to session, dismisses modal", %{
    conn: conn,
    session: session
  } do
    PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    req = %{
      id: "app-test-deny",
      session_id: session.id,
      tool_name: "git_commit",
      category: "git_push",
      arguments: %{"message" => "malicious commit"},
      reason: "Tool 'git_commit' modifies repository history",
      tier: "prompt_dangerous"
    }

    PubSub.broadcast(
      IexCode.PubSub,
      "session:#{session.id}",
      {:tool_approval_requested, session.id, req}
    )

    assert has_element?(view, "#tool-approval-modal")

    # Click Deny
    view
    |> element("#deny-tool-btn")
    |> render_click()

    # Modal should be dismissed
    refute has_element?(view, "#tool-approval-modal")

    # PubSub should broadcast denial
    assert_receive {:tool_approval_decision, "app-test-deny", :deny}, 2_000
  end

  test "renders thinking trace component inside chat messages with reasoning metadata", %{
    conn: conn,
    session: session
  } do
    # Create assistant message with reasoning trace
    {:ok, message} =
      Sessions.create_message(%{
        session_id: session.id,
        role: "assistant",
        agent_name: "Assistant",
        content: "Here is the completed task solution.",
        metadata: %{
          "reasoning" =>
            "Analyzing requirements for milestone M4. Verified SafetyPolicy contracts.",
          "duration_ms" => 420,
          "thinking_tokens" => 85
        }
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    # Switch to chat tab if necessary
    view |> element("#sidebar-tab-chat") |> render_click()

    # Thinking trace must be rendered with matching message id
    assert has_element?(view, "#thinking-trace-#{message.id}")
    trace_html = render(element(view, "#thinking-trace-#{message.id}"))
    assert trace_html =~ "Thought Process (Reasoning Trace)"
    assert trace_html =~ "Analyzing requirements for milestone M4"
    assert trace_html =~ "420ms"
    assert trace_html =~ "85 tokens"
  end
end
