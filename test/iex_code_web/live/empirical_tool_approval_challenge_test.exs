defmodule IexCodeWeb.Live.EmpiricalToolApprovalChallengeTest do
  use IexCode.E2E.Case, async: false

  @moduletag mock_llm: true

  alias IexCode.Engine.SessionServer
  alias IexCode.Settings
  alias IexCode.Tools.SafetyPolicy
  alias Phoenix.PubSub

  setup %{workspace_path: path} do
    project = create_project_fixture(%{root_path: path, name: "Tool Approval Challenge Project"})
    session = create_session_fixture(project, %{title: "Challenge Session"})
    settings = Settings.get_settings()
    {:ok, pid} = SessionServer.ensure_started(session.id)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    end)

    %{project: project, session: session, settings: settings}
  end

  describe "Edge Case 1: Rapid click sequences, duplicate clicks, and conflicting click ordering" do
    test "repeated clicks on approve-tool-once-btn and direct event replays are idempotent and safe",
         %{conn: conn, session: session} do
      PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      req = %{
        id: "req-rapid-1",
        session_id: session.id,
        tool_name: "run_command",
        category: "shell_execution",
        arguments: %{"command" => "echo 1"},
        reason: "Shell command execution",
        tier: "prompt_dangerous"
      }

      PubSub.broadcast(
        IexCode.PubSub,
        "session:#{session.id}",
        {:tool_approval_requested, session.id, req}
      )

      assert has_element?(view, "#tool-approval-modal")

      # First click dismisses modal and broadcasts approval
      view
      |> element("#approve-tool-once-btn")
      |> render_click()

      refute has_element?(view, "#tool-approval-modal")
      assert_receive {:tool_approval_decision, "req-rapid-1", :approve_once}, 1_000

      # Repeated rapid clicks on event directly (e.g. rapid network clicks) must be safe and idempotent
      for _i <- 1..5 do
        render_click(view, "approve_tool_once", %{"id" => req.id})
      end

      # Socket remains healthy and modal remains dismissed
      refute has_element?(view, "#tool-approval-modal")
    end

    test "conflicting click sequence (deny then approve then allow_session) honors first action cleanly",
         %{conn: conn, session: session} do
      PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      req = %{
        id: "req-conflict-1",
        session_id: session.id,
        tool_name: "write_file",
        category: "file_mutations",
        arguments: %{"path" => "critical.ex"},
        reason: "Mutates workspace files",
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

      refute has_element?(view, "#tool-approval-modal")
      assert_receive {:tool_approval_decision, "req-conflict-1", :deny}, 1_000

      # Conflicting events dispatched immediately afterwards do not revive modal or crash socket
      render_click(view, "approve_tool_once", %{"id" => req.id})
      render_click(view, "allow_tool_session", %{"id" => req.id})

      refute has_element?(view, "#tool-approval-modal")
    end

    test "event handlers tolerate malformed params (nil id, missing id, integer id, huge id)",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      malformed_payloads = [
        %{},
        %{"id" => nil},
        %{"id" => ""},
        %{"id" => 999_999},
        %{"id" => %{"nested" => "obj"}},
        %{"id" => String.duplicate("long_id_", 1_000)}
      ]

      for params <- malformed_payloads do
        assert render_click(view, "approve_tool_once", params)
        assert render_click(view, "allow_tool_session", params)
        assert render_click(view, "deny_tool", params)
      end

      refute has_element?(view, "#tool-approval-modal")
    end
  end

  describe "Edge Case 2: Concurrent approval requests and multi-process contention" do
    test "rapid burst of PubSub approval requests leaves LiveView stable on the latest request",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Send 20 approval requests in rapid burst
      for i <- 1..20 do
        req = %{
          id: "req-burst-#{i}",
          session_id: session.id,
          tool_name: "tool_burst_#{i}",
          category: if(rem(i, 2) == 0, do: "shell_execution", else: "file_mutations"),
          arguments: %{"seq" => i, "cmd" => "echo burst #{i}"},
          reason: "Rapid burst test #{i}",
          tier: "prompt_dangerous"
        }

        PubSub.broadcast(
          IexCode.PubSub,
          "session:#{session.id}",
          {:tool_approval_requested, session.id, req}
        )
      end

      # LiveView must survive and render the final request in the burst
      assert has_element?(view, "#tool-approval-modal")
      assert has_element?(view, "#tool-approval-name", "tool_burst_20")
      assert has_element?(view, "#tool-approval-reason", "Rapid burst test 20")

      # Dismiss the active request
      view
      |> element("#approve-tool-once-btn")
      |> render_click()

      refute has_element?(view, "#tool-approval-modal")
    end

    test "multiple concurrent processes contending on authorize_tool receive accurate isolated decisions",
         %{session: session, settings: settings} do
      PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")

      # Start 4 concurrent tasks calling authorize_tool with recognized mutating tools
      task1 =
        Task.async(fn ->
          SessionServer.authorize_tool(
            session.id,
            "run_command",
            %{"command" => "task 1"},
            settings,
            %{},
            5_000
          )
        end)

      task2 =
        Task.async(fn ->
          SessionServer.authorize_tool(
            session.id,
            "write_file",
            %{"path" => "task2.ex"},
            settings,
            %{},
            5_000
          )
        end)

      task3 =
        Task.async(fn ->
          SessionServer.authorize_tool(
            session.id,
            "git_commit",
            %{"message" => "task 3 commit"},
            settings,
            %{},
            5_000
          )
        end)

      task4 =
        Task.async(fn ->
          SessionServer.authorize_tool(
            session.id,
            "run_command",
            %{"command" => "task 4 cmd"},
            settings,
            %{},
            5_000
          )
        end)

      # Collect all 4 requests
      reqs =
        for _ <- 1..4 do
          assert_receive {:tool_approval_requested, _sid, req}, 2_000
          req
        end

      # Match each request by its unique command/path/message arguments
      task1_req =
        Enum.find(reqs, fn r ->
          r.tool_name == "run_command" and r.arguments["command"] == "task 1"
        end)

      task2_req =
        Enum.find(reqs, fn r ->
          r.tool_name == "write_file" and r.arguments["path"] == "task2.ex"
        end)

      task3_req =
        Enum.find(reqs, fn r ->
          r.tool_name == "git_commit" and r.arguments["message"] == "task 3 commit"
        end)

      task4_req =
        Enum.find(reqs, fn r ->
          r.tool_name == "run_command" and r.arguments["command"] == "task 4 cmd"
        end)

      assert is_binary(task1_req.id)
      assert is_binary(task2_req.id)
      assert is_binary(task3_req.id)
      assert is_binary(task4_req.id)

      # Decide each individually:
      # task1 (run_command) -> approve_once
      SessionServer.decide_tool_approval(session.id, task1_req.id, :approve_once)

      # task2 (write_file) -> deny
      SessionServer.decide_tool_approval(session.id, task2_req.id, :deny)

      # task3 (git_commit) -> approve_once
      SessionServer.decide_tool_approval(session.id, task3_req.id, :approve_once)

      # task4 (run_command, category shell_execution) -> allow_session
      SessionServer.decide_tool_approval(session.id, task4_req.id, :allow_session)

      # Await all tasks and verify isolated return values
      res1 = Task.await(task1, 3_000)
      res2 = Task.await(task2, 3_000)
      res3 = Task.await(task3, 3_000)
      res4 = Task.await(task4, 3_000)

      assert {:ok, :allowed, _} = res1
      assert {:error, {:user_denied, _}} = res2
      assert {:ok, :allowed, _} = res3
      assert {:ok, :allowed, next_overrides} = res4
      assert next_overrides["shell_execution"] == "auto"

      # A 5th task requesting shell_execution tool now immediately succeeds without prompting!
      task5 =
        Task.async(fn ->
          SessionServer.authorize_tool(
            session.id,
            "run_command",
            %{"command" => "task 5 auto"},
            settings,
            %{},
            1_000
          )
        end)

      assert {:ok, :allowed, _} = Task.await(task5, 1_000)
      refute_receive {:tool_approval_requested, _sid, _req}
    end
  end

  describe "Edge Case 3: Massive command payloads, un-serializable terms, and XSS/curly injection" do
    test "handles massive 200KB command payload without crashing or truncating action buttons",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      massive_cmd = "echo '" <> String.duplicate("CHUNK_DATA_1234567890_", 10_000) <> "'"

      req = %{
        id: "req-massive-payload",
        session_id: session.id,
        tool_name: "run_command",
        category: "shell_execution",
        arguments: %{"command" => massive_cmd},
        reason: "Massive payload execution test",
        tier: "prompt_dangerous"
      }

      PubSub.broadcast(
        IexCode.PubSub,
        "session:#{session.id}",
        {:tool_approval_requested, session.id, req}
      )

      assert has_element?(view, "#tool-approval-modal")
      assert has_element?(view, "#tool-approval-preview-box")
      assert has_element?(view, "#deny-tool-btn")
      assert has_element?(view, "#allow-tool-session-btn")
      assert has_element?(view, "#approve-tool-once-btn")

      # Click Deny on the massive payload
      view
      |> element("#deny-tool-btn")
      |> render_click()

      refute has_element?(view, "#tool-approval-modal")
    end

    test "handles non-JSON-serializable terms (PIDs, refs, nested tuples) by falling back to inspect",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      non_json_args = %{
        pid: self(),
        ref: make_ref(),
        tuple: {:error, :unsupported_term, [1, 2, 3]},
        func: fn x -> x + 1 end
      }

      req = %{
        id: "req-non-json",
        session_id: session.id,
        tool_name: "custom_runtime_tool",
        category: "system_info",
        arguments: non_json_args,
        reason: "Tool passing non-serializable BEAM data",
        tier: "prompt_dangerous"
      }

      PubSub.broadcast(
        IexCode.PubSub,
        "session:#{session.id}",
        {:tool_approval_requested, session.id, req}
      )

      assert has_element?(view, "#tool-approval-modal")
      preview_text = render(element(view, "#tool-approval-preview-box"))
      assert preview_text =~ "#PID&lt;"
      assert preview_text =~ "#Reference&lt;"
      assert preview_text =~ ":unsupported_term"

      view
      |> element("#approve-tool-once-btn")
      |> render_click()

      refute has_element?(view, "#tool-approval-modal")
    end

    test "renders XSS payloads, HTML tags, and HEEx curly brace injection without crashing or leaking",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      xss_tool = "<script>alert('xss_tool')</script>"

      xss_reason =
        "Malicious reason: {interpolation} and {{double_curly}} & <img src=x onerror=alert(1)>"

      xss_args = %{
        "template" => "{{foo}} {bar} <%= 1 + 2 %>",
        "script" => "<script>document.cookie='stolen'</script>",
        "null_byte" => "safe\0data",
        "unicode" => "🚀 Unicode: ⚡ \u202Ereversed\u202C"
      }

      req = %{
        id: "req-xss",
        session_id: session.id,
        tool_name: xss_tool,
        category: "shell_execution",
        arguments: xss_args,
        reason: xss_reason,
        tier: "prompt_dangerous"
      }

      PubSub.broadcast(
        IexCode.PubSub,
        "session:#{session.id}",
        {:tool_approval_requested, session.id, req}
      )

      assert has_element?(view, "#tool-approval-modal")
      modal_html = render(element(view, "#tool-approval-modal"))

      # Ensure HTML entities are properly escaped in HEEx output
      assert modal_html =~ "&lt;script&gt;alert(&#39;xss_tool&#39;)&lt;/script&gt;"
      assert modal_html =~ "{interpolation}"
      assert modal_html =~ "{{double_curly}}"
      assert modal_html =~ "Unicode"

      # Buttons remain functional
      view
      |> element("#deny-tool-btn")
      |> render_click()

      refute has_element?(view, "#tool-approval-modal")
    end
  end

  describe "Edge Case 4: Category-scoped :allow_session isolation and modal suppression" do
    test "allowing shell_execution suppresses modal for subsequent shell calls, but keeps file_mutations protected",
         %{conn: conn, session: session, settings: settings} do
      PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # 1. Start shell_execution task
      shell_task =
        Task.async(fn ->
          SessionServer.authorize_tool(
            session.id,
            "run_command",
            %{"command" => "git status"},
            settings,
            %{},
            3_000
          )
        end)

      assert_receive {:tool_approval_requested, _sid, req}, 2_000
      assert req.category == "shell_execution"
      assert has_element?(view, "#tool-approval-modal")

      # 2. Click Allow for Session
      view
      |> element("#allow-tool-session-btn")
      |> render_click()

      refute has_element?(view, "#tool-approval-modal")
      assert {:ok, :allowed, overrides} = Task.await(shell_task, 2_000)
      assert overrides["shell_execution"] == "auto"

      # 3. Subsequent shell_execution tool calls must immediately pass without prompting or modal
      assert {:ok, :allowed, _} =
               SessionServer.authorize_tool(
                 session.id,
                 "run_command",
                 %{"command" => "ls -la"},
                 settings,
                 %{},
                 500
               )

      assert {:ok, :allowed, _} =
               SessionServer.authorize_tool(
                 session.id,
                 "run_command",
                 %{"command" => "pwd"},
                 settings,
                 %{},
                 500
               )

      refute_receive {:tool_approval_requested, _sid, _req}
      refute has_element?(view, "#tool-approval-modal")

      # 4. A DIFFERENT category (file_mutations) MUST STILL PROMPT!
      file_task =
        Task.async(fn ->
          SessionServer.authorize_tool(
            session.id,
            "write_file",
            %{"path" => "secret.txt", "content" => "123"},
            settings,
            %{},
            3_000
          )
        end)

      assert_receive {:tool_approval_requested, _sid, file_req}, 2_000
      assert file_req.category == "file_mutations"
      assert has_element?(view, "#tool-approval-modal")
      assert has_element?(view, "#tool-approval-category-badge", "file_mutations")

      # 5. Deny the file mutation
      view
      |> element("#deny-tool-btn")
      |> render_click()

      refute has_element?(view, "#tool-approval-modal")
      assert {:error, {:user_denied, _}} = Task.await(file_task, 2_000)

      # 6. Verify shell_execution remains auto-allowed while file_mutations remains restricted
      assert {:ok, :allowed, _} =
               SessionServer.authorize_tool(
                 session.id,
                 "run_command",
                 %{"command" => "whoami"},
                 settings,
                 %{},
                 500
               )
    end
  end

  describe "Edge Case 5: :deny flow rejection and state isolation" do
    test "denying a tool rejects calling process, dismisses modal, and does not whitelist category",
         %{conn: conn, session: session, settings: settings} do
      PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      git_task =
        Task.async(fn ->
          SessionServer.authorize_tool(
            session.id,
            "git_commit",
            %{"message" => "dangerous commit"},
            settings,
            %{},
            3_000
          )
        end)

      assert_receive {:tool_approval_requested, _sid, req}, 2_000
      assert req.tool_name == "git_commit"
      assert has_element?(view, "#tool-approval-modal")

      # Click Deny
      view
      |> element("#deny-tool-btn")
      |> render_click()

      refute has_element?(view, "#tool-approval-modal")
      assert {:error, {:user_denied, reason}} = Task.await(git_task, 2_000)
      assert reason =~ "denied by user"

      # Verify session overrides do NOT contain git_commit or git_push
      overrides = SessionServer.get_session_overrides(session.id)
      refute Map.get(overrides, "git_commit") == "auto"
      refute Map.get(overrides, "git_push") == "auto"

      # Subsequent git_commit still prompts again
      git_task2 =
        Task.async(fn ->
          SessionServer.authorize_tool(
            session.id,
            "git_commit",
            %{"message" => "another commit"},
            settings,
            %{},
            1_000
          )
        end)

      assert_receive {:tool_approval_requested, _sid, _req2}, 2_000
      assert has_element?(view, "#tool-approval-modal")

      # Clean up second task by denying
      view |> element("#deny-tool-btn") |> render_click()
      assert {:error, {:user_denied, _}} = Task.await(git_task2, 1_000)
    end
  end

  describe "Edge Case 6: Cross-session request isolation" do
    test "LiveView ignores tool approval broadcasts belonging to other sessions",
         %{conn: conn, session: session, project: project} do
      foreign_session = create_session_fixture(project, %{title: "Foreign Session"})
      {:ok, _fpid} = SessionServer.ensure_started(foreign_session.id)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      refute has_element?(view, "#tool-approval-modal")

      foreign_req = %{
        id: "req-foreign-1",
        session_id: foreign_session.id,
        tool_name: "run_command",
        category: "shell_execution",
        arguments: %{"cmd" => "rm -rf /"},
        reason: "Foreign dangerous tool",
        tier: "prompt_dangerous"
      }

      # Broadcast foreign request to the session topic
      PubSub.broadcast(
        IexCode.PubSub,
        "session:#{session.id}",
        {:tool_approval_requested, foreign_session.id, foreign_req}
      )

      # Our view MUST ignore it
      refute has_element?(view, "#tool-approval-modal")

      # Now broadcast request belonging to our session
      my_req = %{
        id: "req-own-1",
        session_id: session.id,
        tool_name: "run_command",
        category: "shell_execution",
        arguments: %{"cmd" => "echo own"},
        reason: "Own dangerous tool",
        tier: "prompt_dangerous"
      }

      PubSub.broadcast(
        IexCode.PubSub,
        "session:#{session.id}",
        {:tool_approval_requested, session.id, my_req}
      )

      assert has_element?(view, "#tool-approval-modal")
      assert has_element?(view, "#tool-approval-name", "run_command")
    end
  end

  describe "Edge Case 7: Timeout fallback behavior" do
    test "authorize_tool fails closed with :user_denied on timeout without blocking indefinitely",
         %{session: session, settings: settings} do
      PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")

      start_time = System.monotonic_time(:millisecond)

      result =
        SessionServer.authorize_tool(
          session.id,
          "run_command",
          %{"command" => "sleep 10"},
          settings,
          %{},
          150
        )

      elapsed = System.monotonic_time(:millisecond) - start_time

      assert {:error, {:user_denied, reason}} = result
      assert reason =~ "denied by user"
      assert elapsed >= 140 and elapsed <= 500

      # Drain the requested broadcast
      assert_receive {:tool_approval_requested, _sid, _req}, 1_000
    end
  end

  describe "Edge Case 8: Tool category policy gap challenge" do
    test "empirically verifies which tool names fall into 'other' and bypass prompt_dangerous",
         %{settings: settings} do
      # Note: SafetyPolicy defines:
      # "shell_execution" => ~w(run_command)
      # "file_mutations" => ~w(write_file patch_file multi_patch)
      # "git_push" => ~w(git_stage git_commit)

      assert SafetyPolicy.category_for_tool("run_command") == "shell_execution"
      assert SafetyPolicy.category_for_tool("write_file") == "file_mutations"
      assert SafetyPolicy.category_for_tool("patch_file") == "file_mutations"
      assert SafetyPolicy.category_for_tool("multi_patch") == "file_mutations"
      assert SafetyPolicy.category_for_tool("git_stage") == "git_push"
      assert SafetyPolicy.category_for_tool("git_commit") == "git_push"

      # Notice: "git_push", "bash", "terminal_exec" are NOT in SafetyPolicy predefined categories!
      # They return "other", which is non-mutating, so evaluate returns :allow under prompt_dangerous!
      assert SafetyPolicy.category_for_tool("git_push") == "other"
      assert SafetyPolicy.category_for_tool("bash") == "other"
      assert SafetyPolicy.category_for_tool("terminal_exec") == "other"

      assert SafetyPolicy.evaluate("git_push", settings, %{}) == :allow
      assert SafetyPolicy.evaluate("bash", settings, %{}) == :allow
      assert SafetyPolicy.evaluate("terminal_exec", settings, %{}) == :allow
    end
  end
end
