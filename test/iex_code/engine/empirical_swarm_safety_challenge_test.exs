defmodule IexCode.Engine.EmpiricalSwarmSafetyChallengeTest do
  use IexCode.E2E.Case, async: false

  alias IexCode.Engine.SessionServer
  alias IexCode.Execution.{ModelRoute, Policy}
  alias IexCode.Settings.AppSettings
  alias Phoenix.PubSub

  # ---------------------------------------------------------------------------
  # Common Setup for Session Tests
  # ---------------------------------------------------------------------------
  setup %{workspace_path: path} do
    project = create_project_fixture(%{root_path: path, name: "Challenge Swarm Safety Project"})
    session = create_session_fixture(project, %{title: "Challenge Swarm Safety Session"})
    {:ok, pid} = SessionServer.ensure_started(session.id)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    end)

    %{project: project, session: session, session_pid: pid}
  end

  # ===========================================================================
  # 1. Stress test SessionServer.authorize_tool/6: Timeout Fallback
  # ===========================================================================
  describe "SessionServer.authorize_tool/6: Approval Timeout Fallback" do
    test "approval timeout fails closed with {:error, {:user_denied, reason}} without deadlock or crash",
         %{session: session} do
      settings = %AppSettings{
        __meta__: %{state: :loaded},
        tool_approval_mode: "prompt_dangerous",
        tool_category_overrides: %{}
      }

      PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")

      # Execute mutating tool in a Task with a 100ms timeout, without sending approval
      start_time = System.monotonic_time(:millisecond)

      task =
        Task.async(fn ->
          SessionServer.authorize_tool(
            session.id,
            "run_command",
            %{"command" => "rm -rf /tmp/test_danger"},
            settings,
            %{},
            100
          )
        end)

      # PubSub request broadcast must arrive
      assert_receive {:tool_approval_requested, sid, req}, 1_000
      assert sid == session.id
      assert req.tool_name == "run_command"
      assert req.category == "shell_execution"

      # Await task: must fail closed on timeout without crashing or hanging
      result = Task.await(task, 2_000)
      elapsed = System.monotonic_time(:millisecond) - start_time

      assert {:error, {:user_denied, reason}} = result
      assert is_binary(reason)
      assert reason =~ "Tool execution was denied by user"
      assert elapsed >= 90 and elapsed < 1_500
    end

    test "timeout fail-closed behavior across all mutating tool categories", %{session: session} do
      settings = %AppSettings{
        __meta__: %{state: :loaded},
        tool_approval_mode: "prompt_dangerous",
        tool_category_overrides: %{}
      }

      mutating_calls = [
        {"run_command", %{"command" => "git push origin main"}, "shell_execution"},
        {"write_file", %{"path" => "lib/danger.ex", "content" => "evil"}, "file_mutations"},
        {"git_commit", %{"message" => "unreviewed commit"}, "git_push"},
        {"patch_file", %{"path" => "config/config.exs", "patch" => "diff"}, "file_mutations"}
      ]

      for {tool, args, _expected_cat} <- mutating_calls do
        task =
          Task.async(fn ->
            SessionServer.authorize_tool(
              session.id,
              tool,
              args,
              settings,
              %{},
              60
            )
          end)

        assert {:error, {:user_denied, reason}} = Task.await(task, 1_000)
        assert reason =~ "denied by user"
      end
    end

    test "concurrent stress: 25 simultaneous approval timeouts fail closed cleanly", %{
      session: session,
      session_pid: pid
    } do
      settings = %AppSettings{
        __meta__: %{state: :loaded},
        tool_approval_mode: "prompt_dangerous",
        tool_category_overrides: %{}
      }

      tasks =
        for i <- 1..25 do
          timeout = 40 + rem(i * 7, 60)

          Task.async(fn ->
            SessionServer.authorize_tool(
              session.id,
              "run_command",
              %{"command" => "worker_job_#{i}"},
              settings,
              %{},
              timeout
            )
          end)
        end

      results = Task.await_many(tasks, 5_000)

      assert length(results) == 25

      Enum.each(results, fn result ->
        assert {:error, {:user_denied, reason}} = result
        assert reason =~ "Tool execution was denied by user"
      end)

      # Verify SessionServer GenServer survived 25 concurrent timeouts without crashing
      assert Process.alive?(pid)
      assert SessionServer.get_session_overrides(session.id) == %{}
    end

    test "late approval decision arriving after timeout does not crash or corrupt state", %{
      session: session,
      session_pid: pid
    } do
      settings = %AppSettings{
        __meta__: %{state: :loaded},
        tool_approval_mode: "prompt_dangerous",
        tool_category_overrides: %{}
      }

      PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")

      task =
        Task.async(fn ->
          SessionServer.authorize_tool(
            session.id,
            "run_command",
            %{"command" => "late_decision_test"},
            settings,
            %{},
            50
          )
        end)

      assert_receive {:tool_approval_requested, sid, req}, 500
      assert sid == session.id

      # Wait for timeout to elapse and task to exit
      assert {:error, {:user_denied, _}} = Task.await(task, 1_000)

      # Late decision sent after timeout has already triggered
      SessionServer.decide_tool_approval(session.id, req.id, :approve_once)

      # Verify SessionServer remains healthy and responsive to calls
      assert Process.alive?(pid)
      assert is_map(SessionServer.get_session_overrides(session.id))
    end
  end

  # ===========================================================================
  # 2. Stress test SessionServer.authorize_tool/6: read_only Safety Mode
  # ===========================================================================
  describe "SessionServer.authorize_tool/6: read_only Safety Mode" do
    test "mutating tools (write_file, run_command, git_commit) are unconditionally denied without prompting",
         %{session: session} do
      settings = %AppSettings{
        __meta__: %{state: :loaded},
        tool_approval_mode: "read_only",
        tool_category_overrides: %{}
      }

      PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")

      mutating_tools = [
        {"write_file", %{"path" => "lib/test.ex", "content" => "mod"}},
        {"run_command", %{"command" => "mix test"}},
        {"git_commit", %{"message" => "feat: test"}},
        {"patch_file", %{"path" => "lib/app.ex", "diff" => "..."}},
        {"multi_patch", %{"patches" => []}},
        {"git_stage", %{"files" => ["mix.exs"]}}
      ]

      for {tool, args} <- mutating_tools do
        result =
          SessionServer.authorize_tool(
            session.id,
            tool,
            args,
            settings,
            %{},
            1_000
          )

        assert {:deny, reason} = result
        assert reason =~ "prohibited in read_only mode"
        assert reason =~ tool
      end

      # Strictly assert NO PubSub approval requests were ever broadcast
      refute_receive {:tool_approval_requested, _, _}, 100
    end

    test "read-only inspect tools are permitted immediately in read_only mode without prompting",
         %{session: session} do
      settings = %AppSettings{
        __meta__: %{state: :loaded},
        tool_approval_mode: "read_only",
        tool_category_overrides: %{}
      }

      PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")

      inspect_tools = [
        {"read_file", %{"path" => "mix.exs"}},
        {"list_dir", %{"path" => "lib"}},
        {"grep_search", %{"query" => "defmodule"}},
        {"ast_search", %{"pattern" => "def"}},
        {"git_status", %{}},
        {"git_diff", %{}},
        {"run_tests", %{}}
      ]

      for {tool, args} <- inspect_tools do
        assert {:ok, :allowed, _overrides} =
                 SessionServer.authorize_tool(
                   session.id,
                   tool,
                   args,
                   settings,
                   %{},
                   1_000
                 )
      end

      # Zero prompts broadcast for read-only tools
      refute_receive {:tool_approval_requested, _, _}, 100
    end

    test "read_only tier strictly rejects mutating actions even if session overrides attempt auto approval",
         %{session: session} do
      settings = %AppSettings{
        __meta__: %{state: :loaded},
        tool_approval_mode: "read_only",
        tool_category_overrides: %{}
      }

      overrides = %{
        "shell_execution" => "auto",
        "file_mutations" => "auto",
        "git_push" => "auto"
      }

      # Safety invariant: read_only tier takes precedence over category auto overrides
      assert {:deny, reason} =
               SessionServer.authorize_tool(
                 session.id,
                 "run_command",
                 %{"command" => "rm -rf /"},
                 settings,
                 overrides,
                 1_000
               )

      assert reason =~ "prohibited in read_only mode"

      assert {:deny, reason2} =
               SessionServer.authorize_tool(
                 session.id,
                 "write_file",
                 %{"path" => "secret.txt", "content" => "leak"},
                 settings,
                 overrides,
                 1_000
               )

      assert reason2 =~ "prohibited in read_only mode"
    end
  end

  # ===========================================================================
  # 3. Stress test SessionServer.authorize_tool/6: full_auto Mode
  # ===========================================================================
  describe "SessionServer.authorize_tool/6: full_auto Safety Mode" do
    test "allowed tools run immediately without waiting for user approval", %{session: session} do
      settings = %AppSettings{
        __meta__: %{state: :loaded},
        tool_approval_mode: "full_auto",
        tool_category_overrides: %{}
      }

      PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")

      tools_to_run = [
        {"run_command", %{"command" => "mix compile"}},
        {"write_file", %{"path" => "lib/auto.ex", "content" => "defmodule Auto do end"}},
        {"git_commit", %{"message" => "auto commit"}},
        {"read_file", %{"path" => "mix.exs"}},
        {"patch_file", %{"path" => "lib/auto.ex", "diff" => "---"}}
      ]

      for {tool, args} <- tools_to_run do
        assert {:ok, :allowed, _overrides} =
                 SessionServer.authorize_tool(
                   session.id,
                   tool,
                   args,
                   settings,
                   %{},
                   100
                 )
      end

      # Under full_auto, no user prompts should ever be generated
      refute_receive {:tool_approval_requested, _, _}, 100
    end

    test "high-concurrency bursts under full_auto execute with zero blocking or prompts", %{
      session: session
    } do
      settings = %AppSettings{
        __meta__: %{state: :loaded},
        tool_approval_mode: "full_auto",
        tool_category_overrides: %{}
      }

      tasks =
        for i <- 1..30 do
          Task.async(fn ->
            SessionServer.authorize_tool(
              session.id,
              "run_command",
              %{"command" => "echo #{i}"},
              settings,
              %{},
              500
            )
          end)
        end

      results = Task.await_many(tasks, 2_000)
      assert length(results) == 30

      Enum.each(results, fn result ->
        assert {:ok, :allowed, _} = result
      end)
    end

    test "full_auto tier respects explicit category deny override", %{session: session} do
      settings = %AppSettings{
        __meta__: %{state: :loaded},
        tool_approval_mode: "full_auto",
        tool_category_overrides: %{"shell_execution" => "deny"}
      }

      # shell_execution is explicitly denied
      assert {:deny, reason} =
               SessionServer.authorize_tool(
                 session.id,
                 "run_command",
                 %{"command" => "ls"},
                 settings,
                 %{},
                 500
               )

      assert reason =~ "disabled by policy override"

      # file_mutations is not denied, so it remains auto-allowed
      assert {:ok, :allowed, _} =
               SessionServer.authorize_tool(
                 session.id,
                 "write_file",
                 %{"path" => "test.ex", "content" => "ok"},
                 settings,
                 %{},
                 500
               )
    end
  end

  # ===========================================================================
  # 4. Stress test SessionServer.authorize_tool/6: Session Override Persistence
  # ===========================================================================
  describe "SessionServer.authorize_tool/6: Session Override Persistence Across Multiple Turns" do
    test "persists category override across multiple sequential tool turns in the same session",
         %{session: session} do
      settings = %AppSettings{
        __meta__: %{state: :loaded},
        tool_approval_mode: "prompt_dangerous",
        tool_category_overrides: %{}
      }

      PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")

      # -----------------------------------------------------------------------
      # Turn 1: write_file (file_mutations) -> Prompts -> User grants :allow_session
      # -----------------------------------------------------------------------
      task1 =
        Task.async(fn ->
          SessionServer.authorize_tool(
            session.id,
            "write_file",
            %{"path" => "lib/mod1.ex", "content" => "mod1"},
            settings,
            %{},
            3_000
          )
        end)

      assert_receive {:tool_approval_requested, sid, req1}, 2_000
      assert sid == session.id
      assert req1.tool_name == "write_file"
      assert req1.category == "file_mutations"

      # User submits allow_session for file_mutations category
      SessionServer.decide_tool_approval(session.id, req1.id, :allow_session)
      assert {:ok, :allowed, overrides1} = Task.await(task1, 1_000)
      assert overrides1["file_mutations"] == "auto"

      # Verify persisted in SessionServer state
      server_overrides = SessionServer.get_session_overrides(session.id)
      assert server_overrides["file_mutations"] == "auto"

      # -----------------------------------------------------------------------
      # Turn 2: patch_file (same category: file_mutations) -> Executes immediately!
      # -----------------------------------------------------------------------
      assert {:ok, :allowed, overrides2} =
               SessionServer.authorize_tool(
                 session.id,
                 "patch_file",
                 %{"path" => "lib/mod1.ex", "diff" => "patch"},
                 settings,
                 %{},
                 1_000
               )

      assert overrides2["file_mutations"] == "auto"
      # Must not prompt!
      refute_receive {:tool_approval_requested, _, _}, 100

      # -----------------------------------------------------------------------
      # Turn 3: multi_patch (same category: file_mutations) -> Executes immediately!
      # -----------------------------------------------------------------------
      assert {:ok, :allowed, _} =
               SessionServer.authorize_tool(
                 session.id,
                 "multi_patch",
                 %{"patches" => []},
                 settings,
                 %{},
                 1_000
               )

      refute_receive {:tool_approval_requested, _, _}, 100

      # -----------------------------------------------------------------------
      # Turn 4: run_command (different category: shell_execution) -> Prompts!
      # -----------------------------------------------------------------------
      task4 =
        Task.async(fn ->
          SessionServer.authorize_tool(
            session.id,
            "run_command",
            %{"command" => "mix compile"},
            settings,
            %{},
            3_000
          )
        end)

      assert_receive {:tool_approval_requested, ^sid, req4}, 2_000
      assert req4.category == "shell_execution"

      # User approves once only
      SessionServer.decide_tool_approval(session.id, req4.id, :approve_once)
      assert {:ok, :allowed, _} = Task.await(task4, 1_000)

      # shell_execution must NOT be in session overrides
      assert SessionServer.get_session_overrides(session.id)["shell_execution"] == nil

      # -----------------------------------------------------------------------
      # Turn 5: run_command again -> Prompts again! User grants allow_session
      # -----------------------------------------------------------------------
      task5 =
        Task.async(fn ->
          SessionServer.authorize_tool(
            session.id,
            "run_command",
            %{"command" => "mix test"},
            settings,
            %{},
            3_000
          )
        end)

      assert_receive {:tool_approval_requested, ^sid, req5}, 2_000
      SessionServer.decide_tool_approval(session.id, req5.id, :allow_session)
      assert {:ok, :allowed, overrides5} = Task.await(task5, 1_000)

      # Both categories now auto-allowed
      assert overrides5["file_mutations"] == "auto"
      assert overrides5["shell_execution"] == "auto"

      # -----------------------------------------------------------------------
      # Turn 6: run_command again -> Executes immediately without prompt!
      # -----------------------------------------------------------------------
      assert {:ok, :allowed, _} =
               SessionServer.authorize_tool(
                 session.id,
                 "run_command",
                 %{"command" => "echo 'hello'"},
                 settings,
                 %{},
                 1_000
               )

      refute_receive {:tool_approval_requested, _, _}, 100

      # -----------------------------------------------------------------------
      # Turn 7: git_commit (category: git_push) -> Unapproved category -> Prompts!
      # -----------------------------------------------------------------------
      task7 =
        Task.async(fn ->
          SessionServer.authorize_tool(
            session.id,
            "git_commit",
            %{"message" => "wip"},
            settings,
            %{},
            1_000
          )
        end)

      assert_receive {:tool_approval_requested, ^sid, req7}, 2_000
      assert req7.category == "git_push"
      SessionServer.decide_tool_approval(session.id, req7.id, :deny)
      assert {:error, {:user_denied, _}} = Task.await(task7, 1_000)
    end

    test "session isolation: category overrides granted in Session A do not leak into Session B",
         %{project: project, session: session_a} do
      session_b = create_session_fixture(project, %{title: "Isolated Session B"})
      {:ok, pid_b} = SessionServer.ensure_started(session_b.id)

      on_exit(fn ->
        if Process.alive?(pid_b), do: GenServer.stop(pid_b, :normal, 1_000)
      end)

      settings = %AppSettings{
        __meta__: %{state: :loaded},
        tool_approval_mode: "prompt_dangerous",
        tool_category_overrides: %{}
      }

      # In Session A: update overrides with file_mutations => auto
      SessionServer.update_session_overrides(session_a.id, %{"file_mutations" => "auto"})
      assert SessionServer.get_session_overrides(session_a.id)["file_mutations"] == "auto"

      # In Session B: verify session overrides are clean
      assert SessionServer.get_session_overrides(session_b.id) == %{}

      # Session B must prompt for write_file
      PubSub.subscribe(IexCode.PubSub, "session:#{session_b.id}")

      task_b =
        Task.async(fn ->
          SessionServer.authorize_tool(
            session_b.id,
            "write_file",
            %{"path" => "b.txt", "content" => "b"},
            settings,
            %{},
            2_000
          )
        end)

      assert_receive {:tool_approval_requested, sid_b, req_b}, 1_000
      assert sid_b == session_b.id

      SessionServer.decide_tool_approval(session_b.id, req_b.id, :deny)
      assert {:error, {:user_denied, _}} = Task.await(task_b, 1_000)
    end
  end

  # ===========================================================================
  # 5. Stress test ModelRoute.resolve/2: OpenAI Reasoning Models (o1, o3, o3-mini, o4)
  # ===========================================================================
  describe "ModelRoute.resolve/2: OpenAI Reasoning Variants (o1, o3, o3-mini, o4)" do
    test "all OpenAI reasoning models strictly omit temperature (nil) and enforce reasoning_effort" do
      openai_reasoning_models = [
        "o1",
        "o1-mini",
        "o1-preview",
        "o3",
        "o3-mini",
        "o4",
        "o4-mini"
      ]

      settings = %AppSettings{
        __meta__: %{state: :loaded},
        openai_api_key: "sk-openai-test-key",
        openai_base_url: "https://api.openai.com/v1",
        default_reasoning_effort: "high",
        temperature: 0.7,
        max_tokens: 4096
      }

      for model <- openai_reasoning_models do
        # Test 1: with policy passing explicit temperature override (which must be stripped)
        {:ok, policy} =
          Policy.from_settings(settings, nil, %{
            "model_provider" => "openai",
            "model_name" => model,
            "temperature" => 0.85
          })

        assert {:ok, route} = ModelRoute.resolve(policy, settings),
               "Failed to resolve route for #{model}"

        assert route["provider"] == "openai"
        assert route[:provider] == "openai"
        assert route["model"] == model
        assert route[:model] == model
        assert route["api_key"] == "sk-openai-test-key"

        # INVARIANT 1: Temperature must strictly be nil in both string and atom keys
        assert route["temperature"] == nil,
               "Model #{model} route['temperature'] must be nil, got: #{inspect(route["temperature"])}"

        assert route[:temperature] == nil,
               "Model #{model} route[:temperature] must be nil, got: #{inspect(route[:temperature])}"

        # INVARIANT 2: reasoning_effort must be present and match settings default
        assert route["reasoning_effort"] == "high",
               "Model #{model} route['reasoning_effort'] must be 'high', got: #{inspect(route["reasoning_effort"])}"

        assert route[:reasoning_effort] == "high",
               "Model #{model} route[:reasoning_effort] must be 'high', got: #{inspect(route[:reasoning_effort])}"

        # INVARIANT 3: thinking_budget should be nil for OpenAI models
        assert route["thinking_budget"] == nil
        assert route[:thinking_budget] == nil
      end
    end

    test "OpenAI reasoning models honor granular reasoning_effort overrides (low, medium, high)" do
      settings = %AppSettings{
        __meta__: %{state: :loaded},
        openai_api_key: "sk-openai-test-key",
        openai_base_url: "https://api.openai.com/v1",
        default_reasoning_effort: "medium",
        temperature: 0.2
      }

      for effort <- ["low", "medium", "high"] do
        {:ok, policy} =
          Policy.from_settings(settings, nil, %{
            "model_provider" => "openai",
            "model_name" => "o3-mini"
          })

        # Inject reasoning_effort into policy
        policy_with_effort = Map.put(policy, "reasoning_effort", effort)

        assert {:ok, route} = ModelRoute.resolve(policy_with_effort, settings)
        assert route["temperature"] == nil
        assert route[:temperature] == nil
        assert route["reasoning_effort"] == effort
        assert route[:reasoning_effort] == effort
      end
    end

    test "OpenAI reasoning models strip temperature even if 0.0 is explicitly passed" do
      settings = %AppSettings{
        __meta__: %{state: :loaded},
        openai_api_key: "sk-openai-test-key",
        openai_base_url: "https://api.openai.com/v1"
      }

      {:ok, policy} =
        Policy.from_settings(settings, nil, %{
          "model_provider" => "openai",
          "model_name" => "o1",
          "temperature" => 0.0
        })

      assert {:ok, route} = ModelRoute.resolve(policy, settings)
      assert route["temperature"] == nil
      assert route[:temperature] == nil
      assert route["reasoning_effort"] != nil
    end
  end

  # ===========================================================================
  # 6. Stress test ModelRoute.resolve/2: Anthropic Thinking Variants
  # ===========================================================================
  describe "ModelRoute.resolve/2: Anthropic Thinking Variants (claude-3-7-sonnet-20250219)" do
    test "Anthropic thinking models: temperature strictly 1.0, thinking budget present, max_tokens > budget" do
      anthropic_models = [
        "claude-3-7-sonnet-20250219",
        "claude-3-7-sonnet",
        "claude-3.7-sonnet"
      ]

      settings = %AppSettings{
        __meta__: %{state: :loaded},
        anthropic_api_key: "sk-ant-test-key",
        anthropic_base_url: "https://api.anthropic.com",
        default_thinking_budget: 4096,
        temperature: 0.2,
        max_tokens: 8192
      }

      for model <- anthropic_models do
        # Test with custom policy temperature (e.g. 0.35) which MUST be clamped to 1.0
        {:ok, policy} =
          Policy.from_settings(settings, nil, %{
            "model_provider" => "anthropic",
            "model_name" => model,
            "temperature" => 0.35
          })

        assert {:ok, route} = ModelRoute.resolve(policy, settings)

        assert route["provider"] == "anthropic"
        assert route[:provider] == "anthropic"
        assert route["model"] == model
        assert route[:model] == model
        assert route["api_key"] == "sk-ant-test-key"

        # INVARIANT 1: Temperature must strictly be 1.0 per Anthropic API spec
        assert route["temperature"] == 1.0,
               "Model #{model} route['temperature'] must be 1.0, got: #{inspect(route["temperature"])}"

        assert route[:temperature] == 1.0,
               "Model #{model} route[:temperature] must be 1.0, got: #{inspect(route[:temperature])}"

        # INVARIANT 2: thinking_budget / budget_tokens must be present and >= 1024
        assert is_integer(route["thinking_budget"])
        assert route["thinking_budget"] >= 1024
        assert route[:thinking_budget] == route["thinking_budget"]
        assert route["budget_tokens"] == route["thinking_budget"]
        assert route[:budget_tokens] == route["thinking_budget"]

        # INVARIANT 3: max_tokens must be strictly greater than thinking_budget
        assert route["max_tokens"] > route["thinking_budget"],
               "Model #{model} max_tokens (#{route["max_tokens"]}) must exceed thinking_budget (#{route["thinking_budget"]})"

        assert route[:max_tokens] > route[:thinking_budget]
      end
    end

    test "Anthropic thinking automatically clamps max_tokens when configured max_tokens <= budget" do
      settings = %AppSettings{
        __meta__: %{state: :loaded},
        anthropic_api_key: "sk-ant-test-key",
        anthropic_base_url: "https://api.anthropic.com",
        default_thinking_budget: 8192,
        max_tokens: 4096
      }

      {:ok, policy} =
        Policy.from_settings(settings, nil, %{
          "model_provider" => "anthropic",
          "model_name" => "claude-3-7-sonnet-20250219"
        })

      assert {:ok, route} = ModelRoute.resolve(policy, settings)

      budget = route["thinking_budget"]
      max_tok = route["max_tokens"]

      assert budget == 8192
      # max_tokens was clamped to budget + 1024 = 9216
      assert max_tok >= budget + 1024
      assert max_tok > budget
      assert route["temperature"] == 1.0
    end

    test "Anthropic thinking clamps budget below minimum 1024 up to at least 1024" do
      settings = %AppSettings{
        __meta__: %{state: :loaded},
        anthropic_api_key: "sk-ant-test-key",
        anthropic_base_url: "https://api.anthropic.com",
        default_thinking_budget: 512,
        max_tokens: 4096
      }

      {:ok, policy} =
        Policy.from_settings(settings, nil, %{
          "model_provider" => "anthropic",
          "model_name" => "claude-3-7-sonnet-20250219"
        })

      assert {:ok, route} = ModelRoute.resolve(policy, settings)

      assert route["thinking_budget"] >= 1024
      assert route["max_tokens"] > route["thinking_budget"]
      assert route["temperature"] == 1.0
    end
  end

  # ===========================================================================
  # 7. Stress test ModelRoute.resolve/2: Non-Reasoning Models
  # ===========================================================================
  describe "ModelRoute.resolve/2: Non-Reasoning Models (gpt-4o, claude-3-5-sonnet)" do
    test "standard models preserve custom temperature and have nil reasoning fields" do
      standard_cases = [
        {"openai", "gpt-4o", 0.65},
        {"openai", "gpt-4o-mini", 0.15},
        {"anthropic", "claude-3-5-sonnet-20241022", 0.42},
        {"anthropic", "claude-3-5-haiku-20241022", 0.88}
      ]

      settings = %AppSettings{
        __meta__: %{state: :loaded},
        openai_api_key: "sk-openai-std",
        openai_base_url: "https://api.openai.com/v1",
        anthropic_api_key: "sk-ant-std",
        anthropic_base_url: "https://api.anthropic.com",
        temperature: 0.2,
        max_tokens: 4096
      }

      for {provider, model, custom_temp} <- standard_cases do
        {:ok, policy} =
          Policy.from_settings(settings, nil, %{
            "model_provider" => provider,
            "model_name" => model,
            "temperature" => custom_temp
          })

        assert {:ok, route} = ModelRoute.resolve(policy, settings)

        assert route["provider"] == provider
        assert route[:provider] == provider
        assert route["model"] == model
        assert route[:model] == model

        # INVARIANT 1: Custom temperature is accurately preserved
        assert_in_delta route["temperature"],
                        custom_temp,
                        0.001,
                        "Model #{model} route['temperature'] expected #{custom_temp}, got #{inspect(route["temperature"])}"

        assert_in_delta route[:temperature], custom_temp, 0.001

        # INVARIANT 2: reasoning_effort is nil for standard non-reasoning models
        assert route["reasoning_effort"] == nil,
               "Model #{model} route['reasoning_effort'] must be nil, got #{inspect(route["reasoning_effort"])}"

        assert route[:reasoning_effort] == nil

        # INVARIANT 3: thinking_budget and budget_tokens are nil
        assert route["thinking_budget"] == nil
        assert route[:thinking_budget] == nil
        assert route["budget_tokens"] == nil
        assert route[:budget_tokens] == nil
      end
    end

    test "standard models preserve extreme temperature boundaries (0.0 and 1.5)" do
      settings = %AppSettings{
        __meta__: %{state: :loaded},
        openai_api_key: "sk-openai-std",
        openai_base_url: "https://api.openai.com/v1"
      }

      for temp <- [0.0, 1.5] do
        {:ok, policy} =
          Policy.from_settings(settings, nil, %{
            "model_provider" => "openai",
            "model_name" => "gpt-4o",
            "temperature" => temp
          })

        assert {:ok, route} = ModelRoute.resolve(policy, settings)
        assert route["temperature"] == temp
        assert route[:temperature] == temp
        assert route["reasoning_effort"] == nil
      end
    end
  end
end
