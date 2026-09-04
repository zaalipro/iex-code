defmodule IexCode.Engine.SwarmReasoningIntegrationTest do
  use IexCode.E2E.Case, async: false

  alias IexCode.Engine.SessionServer
  alias IexCode.Execution.{ModelRoute, Policy}
  alias IexCode.LLM.ContextCompactor
  alias IexCode.Settings.AppSettings
  alias Phoenix.PubSub

  describe "ModelRoute.resolve/2 reasoning profile injection" do
    test "OpenAI o3-mini: omits temperature, injects reasoning_effort high" do
      settings = %AppSettings{
        __meta__: %{state: :loaded},
        openai_api_key: "sk-test-key",
        openai_base_url: "https://api.openai.com/v1",
        default_reasoning_effort: "high",
        temperature: 0.7,
        max_tokens: 4096
      }

      {:ok, policy} =
        Policy.from_settings(settings, nil, %{
          "model_provider" => "openai",
          "model_name" => "o3-mini"
        })

      assert {:ok, route} = ModelRoute.resolve(policy, settings)
      assert route["provider"] == "openai"
      assert route["model"] == "o3-mini"
      assert route["base_url"] == "https://api.openai.com/v1"
      assert route["api_key"] == "sk-test-key"

      # OpenAI reasoning models MUST omit temperature (nil)
      assert route["temperature"] == nil
      assert route[:temperature] == nil

      # reasoning_effort injected in both string and atom keys
      assert route["reasoning_effort"] == "high"
      assert route[:reasoning_effort] == "high"
      assert route["max_tokens"] == 4096
      assert route[:max_tokens] == 4096
    end

    test "Anthropic Claude 3.7: clamps temperature to 1.0, injects thinking budget 8192" do
      settings = %AppSettings{
        __meta__: %{state: :loaded},
        anthropic_api_key: "sk-ant-test-key",
        anthropic_base_url: "https://api.anthropic.com",
        default_thinking_budget: 8192,
        temperature: 0.2,
        max_tokens: 16384
      }

      {:ok, policy} =
        Policy.from_settings(settings, nil, %{
          "model_provider" => "anthropic",
          "model_name" => "claude-3-7-sonnet-20250219"
        })

      assert {:ok, route} = ModelRoute.resolve(policy, settings)
      assert route["provider"] == "anthropic"
      assert route["model"] == "claude-3-7-sonnet-20250219"
      assert route["base_url"] == "https://api.anthropic.com"
      assert route["api_key"] == "sk-ant-test-key"

      # Anthropic extended thinking MUST clamp temperature to 1.0 per API spec
      assert route["temperature"] == 1.0
      assert route[:temperature] == 1.0

      # thinking_budget injected in both string and atom keys
      assert route["thinking_budget"] == 8192
      assert route[:thinking_budget] == 8192
      assert route["budget_tokens"] == 8192

      # max_tokens must strictly exceed thinking budget
      assert route["max_tokens"] > 8192
      assert route[:max_tokens] > 8192
    end

    test "Standard model (gpt-4o): retains temperature, reasoning_effort is nil" do
      settings = %AppSettings{
        __meta__: %{state: :loaded},
        openai_api_key: "sk-standard-key",
        openai_base_url: "https://api.openai.com/v1",
        temperature: 0.3,
        max_tokens: 4096
      }

      {:ok, policy} =
        Policy.from_settings(settings, nil, %{
          "model_provider" => "openai",
          "model_name" => "gpt-4o",
          "temperature" => 0.6
        })

      assert {:ok, route} = ModelRoute.resolve(policy, settings)
      assert route["provider"] == "openai"
      assert route["model"] == "gpt-4o"
      assert route["temperature"] == 0.6
      assert route[:temperature] == 0.6
      assert route["reasoning_effort"] == nil
      assert route[:reasoning_effort] == nil
    end
  end

  describe "SafetyPolicy interception in session tool execution pipeline" do
    setup %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path, name: "Swarm Safety Project"})
      session = create_session_fixture(project, %{title: "Swarm Safety Session"})
      {:ok, pid} = SessionServer.ensure_started(session.id)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
      end)

      %{project: project, session: session}
    end

    test "full_auto mode: allowed mutating tools execute immediately without prompting", %{
      session: session
    } do
      settings = %AppSettings{
        __meta__: %{state: :loaded},
        tool_approval_mode: "full_auto",
        tool_category_overrides: %{}
      }

      assert {:ok, :allowed, _overrides} =
               SessionServer.authorize_tool(
                 session.id,
                 "run_command",
                 %{"command" => "mix compile"},
                 settings,
                 %{},
                 500
               )

      assert {:ok, :allowed, _overrides} =
               SessionServer.authorize_tool(
                 session.id,
                 "write_file",
                 %{"path" => "lib/sample.ex", "content" => "defmodule Sample do end"},
                 settings,
                 %{},
                 500
               )
    end

    test "read_only mode: strictly denies all mutating tools without prompting, allows inspect tools",
         %{
           session: session
         } do
      settings = %AppSettings{
        __meta__: %{state: :loaded},
        tool_approval_mode: "read_only",
        tool_category_overrides: %{}
      }

      # Mutating shell command denied
      assert {:deny, reason} =
               SessionServer.authorize_tool(
                 session.id,
                 "run_command",
                 %{"command" => "npm install"},
                 settings,
                 %{},
                 500
               )

      assert reason =~ "prohibited in read_only mode"

      # Mutating file write denied
      assert {:deny, reason} =
               SessionServer.authorize_tool(
                 session.id,
                 "write_file",
                 %{"path" => "foo.txt"},
                 settings,
                 %{},
                 500
               )

      assert reason =~ "prohibited in read_only mode"

      # Non-mutating inspect tool allowed
      assert {:ok, :allowed, _overrides} =
               SessionServer.authorize_tool(
                 session.id,
                 "read_file",
                 %{"path" => "mix.exs"},
                 settings,
                 %{},
                 500
               )

      assert {:ok, :allowed, _overrides} =
               SessionServer.authorize_tool(
                 session.id,
                 "grep_search",
                 %{"query" => "defmodule"},
                 settings,
                 %{},
                 500
               )
    end

    test "prompt_dangerous mode: intercepts mutating tools, broadcasts approval request, handles approve_once",
         %{
           session: session
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
            %{"command" => "rm -rf priv/build"},
            settings,
            %{},
            3_000
          )
        end)

      # Should broadcast tool approval request
      assert_receive {:tool_approval_requested, sid, req}, 2_000
      assert sid == session.id
      assert req.tool_name == "run_command"
      assert req.category == "shell_execution"

      # User submits approve_once decision
      SessionServer.decide_tool_approval(session.id, req.id, :approve_once)

      # Task should complete with allowed
      assert {:ok, :allowed, _overrides} = Task.await(task, 2_000)
    end

    test "prompt_dangerous mode: handles deny decision, returns user_denied error", %{
      session: session
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
            "git_commit",
            %{"message" => "unreviewed commit"},
            settings,
            %{},
            3_000
          )
        end)

      assert_receive {:tool_approval_requested, _sid, req}, 2_000

      # Deny execution
      SessionServer.decide_tool_approval(session.id, req.id, :deny)

      # Task should fail closed with user_denied
      assert {:error, {:user_denied, reason}} = Task.await(task, 2_000)
      assert reason =~ "denied by user"
    end

    test "prompt_dangerous mode: allow_session persists category override and bypasses subsequent prompts",
         %{
           session: session
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
            "write_file",
            %{"path" => "lib/new_module.ex"},
            settings,
            %{},
            3_000
          )
        end)

      assert_receive {:tool_approval_requested, _sid, req}, 2_000
      assert req.category == "file_mutations"

      # Allow for session
      SessionServer.decide_tool_approval(session.id, req.id, :allow_session)

      assert {:ok, :allowed, next_overrides} = Task.await(task, 2_000)
      assert next_overrides["file_mutations"] == "auto"

      # Subsequent calls to file_mutations tools bypass prompting immediately
      assert {:ok, :allowed, _} =
               SessionServer.authorize_tool(
                 session.id,
                 "patch_file",
                 %{"path" => "lib/new_module.ex"},
                 settings,
                 next_overrides,
                 200
               )

      assert {:ok, :allowed, _} =
               SessionServer.authorize_tool(
                 session.id,
                 "multi_patch",
                 %{"patches" => []},
                 settings,
                 next_overrides,
                 200
               )
    end
  end

  describe "ContextCompactor integration" do
    test "compacts oversized message history exceeding prune threshold before LLM dispatch" do
      settings = %AppSettings{
        context_window_tokens: 1_000,
        context_prune_threshold_percent: 50,
        context_compaction_strategy: "token_compaction"
      }

      bulky_output =
        1..400
        |> Enum.map(&"Line #{&1}: [DEBUG] Processing AST node for module #{&1}")
        |> Enum.join("\n")

      messages = [
        %{role: "user", content: "Please run tests and grep for errors"},
        %{role: "tool", content: bulky_output}
      ]

      initial_tokens = ContextCompactor.estimate_tokens(messages)
      assert initial_tokens > 500

      compacted = ContextCompactor.compact(messages, settings, "gpt-4o")
      compacted_tokens = ContextCompactor.estimate_tokens(compacted)

      assert compacted_tokens < initial_tokens
      tool_msg = List.last(compacted)
      assert tool_msg.content =~ "compacted"
    end

    test "sliding_window strategy retains root user prompt and recent turns" do
      settings = %AppSettings{
        context_window_tokens: 500,
        context_prune_threshold_percent: 40,
        context_compaction_strategy: "sliding_window",
        keep_recent_turns: 2
      }

      root = %{role: "user", content: "Root project objective"}

      history =
        1..10
        |> Enum.map(fn idx ->
          %{
            role: "assistant",
            content: "Intermediate turn #{idx}: completed subtask #{idx} with extra details"
          }
        end)

      messages = [root | history]
      compacted = ContextCompactor.compact(messages, settings, "claude-3-7-sonnet")

      assert length(compacted) <= 3
      assert List.first(compacted).content == "Root project objective"
      assert List.last(compacted).content =~ "Intermediate turn 10"
    end
  end
end
