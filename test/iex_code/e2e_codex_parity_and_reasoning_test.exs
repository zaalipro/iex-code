defmodule IexCode.E2ECodexParityAndReasoningTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true

  alias IexCode.Settings
  alias IexCode.Settings.AppSettings
  alias IexCode.LLM.{Discovery, Reasoning, SystemPromptBuilder}
  alias IexCode.Tools.{SafetyPolicy, SecretMasker}
  alias IexCode.Engine.SessionServer
  alias IexCode.Desktop.Sound
  alias Phoenix.PubSub

  # Mock Plug for deterministic HTTP ping diagnostics in E2E tests
  defmodule MockPingPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      case {conn.method, conn.request_path} do
        {"GET", "/api/tags"} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            200,
            Jason.encode!(%{
              "models" => [
                %{"name" => "deepseek-r1:14b", "model" => "deepseek-r1:14b"},
                %{"name" => "llama3.2:latest", "model" => "llama3.2:latest"}
              ]
            })
          )

        {"GET", "/v1/models"} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            200,
            Jason.encode!(%{
              "object" => "list",
              "data" => [
                %{"id" => "o3-mini", "object" => "model"},
                %{"id" => "gpt-4o", "object" => "model"}
              ]
            })
          )

        _ ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(%{"status" => "ok"}))
      end
    end
  end

  setup %{workspace_path: path} do
    project =
      create_project_fixture(%{
        name: "E2E Master Parity Project",
        root_path: path
      })

    session =
      create_session_fixture(project, %{
        title: "E2E Codex Parity Session",
        model_provider: "openai",
        model_name: "o3-mini"
      })

    {:ok, session_server_pid} = SessionServer.ensure_started(session.id)

    on_exit(fn ->
      if Process.alive?(session_server_pid) do
        GenServer.stop(session_server_pid, :normal, 1_000)
      end
    end)

    %{project: project, session: session, session_pid: session_server_pid}
  end

  # ============================================================================
  # MASTER E2E SCENARIO: Complete Full-Flow Execution (Steps A through I)
  # ============================================================================
  describe "Tier 4 Master E2E Scenario: Codex CLI Parity & Reasoning Engine" do
    test "full flow scenario executing steps (a) through (i)", %{
      conn: conn,
      workspace_path: workspace_path,
      session: session
    } do
      # ------------------------------------------------------------------------
      # Step (a): Configure AppSettings with all required custom parameters
      # ------------------------------------------------------------------------
      custom_settings_attrs = %{
        workspace_persona: "architect",
        custom_system_prompt:
          "Design scalable, resilient distributed systems with OTP fault-tolerance.",
        coding_style_rules:
          "Enforce strict typespecs and immutability across all public modules.",
        model_overrides: %{
          "o3-mini" => %{
            "reasoning_effort" => "high"
          },
          "claude-3-7-sonnet-20250219" => %{
            "budget_tokens" => 8192,
            "thinking_budget" => 8192
          }
        },
        tool_approval_mode: "prompt_dangerous",
        tool_category_overrides: %{
          "shell_execution" => "prompt",
          "file_mutations" => "prompt",
          "git_push" => "prompt",
          "web_search" => "auto"
        },
        sandbox_mode: "inherit_filtered",
        custom_env_vars: %{
          "CODEX_PARITY_TEST_VAR" => "active_parity_verified",
          "INTERNAL_SERVICE_SECRET" => "super_classified_system_token_999"
        },
        sound_enabled: true,
        sound_volume: 70,
        completion_chime: "hero",
        error_alert_chime: "basso",
        approval_prompt_chime: "ping"
      }

      assert {:ok, configured_settings} = Settings.update_settings(custom_settings_attrs)
      assert configured_settings.workspace_persona == "architect"
      assert configured_settings.sound_volume == 70
      assert configured_settings.sandbox_mode == "inherit_filtered"
      assert configured_settings.tool_approval_mode == "prompt_dangerous"
      assert configured_settings.tool_category_overrides["web_search"] == "auto"
      assert configured_settings.model_overrides["o3-mini"]["reasoning_effort"] == "high"

      # ------------------------------------------------------------------------
      # Step (b): Verify reasoning profile resolution across models
      # (o3-mini, claude-3-7-sonnet-20250219, gemini-2.5-pro, deepseek-r1)
      # ------------------------------------------------------------------------

      # 1. OpenAI o3-mini: reasoning_effort 'high', temperature strictly omitted
      profile_o3 = Reasoning.resolve_profile("openai", "o3-mini", configured_settings)
      assert profile_o3.reasoning_effort == "high"
      assert is_nil(profile_o3.temperature)
      assert profile_o3.capabilities.type == :openai

      # 2. Anthropic Claude 3.7 Sonnet: budget 8192, temperature clamped to 1.0, max_tokens > budget
      profile_claude =
        Reasoning.resolve_profile("anthropic", "claude-3-7-sonnet-20250219", configured_settings)

      assert profile_claude.temperature == 1.0
      assert profile_claude.thinking_budget == 8192
      assert profile_claude.budget_tokens == 8192
      assert profile_claude.max_tokens > 8192
      assert profile_claude.capabilities.type == :anthropic

      # 3. Gemini models: bounds clamping & non-reasoning parameter handling
      # Gemini 2.5 Pro (standard multimodal model): retains temperature, no reasoning effort
      profile_gemini_pro =
        Reasoning.resolve_profile("google", "gemini-2.5-pro", configured_settings)

      assert profile_gemini_pro.capabilities.type == :none
      assert profile_gemini_pro.temperature == configured_settings.temperature
      assert is_nil(profile_gemini_pro.reasoning_effort)

      # Gemini thinking model (gemini-2.5-flash-thinking): thinking budget clamped >= 1024
      profile_gemini_thinking =
        Reasoning.resolve_profile(
          "google",
          "gemini-2.5-flash-thinking",
          configured_settings,
          thinking_budget: 512
        )

      assert profile_gemini_thinking.capabilities.type == :gemini
      assert profile_gemini_thinking.thinking_budget >= 1024
      assert profile_gemini_thinking.max_tokens > profile_gemini_thinking.thinking_budget

      # 4. DeepSeek R1 (local): temperature defaults to 0.6, thinking budget >= 2048
      profile_deepseek =
        Reasoning.resolve_profile("ollama", "deepseek-r1:14b", configured_settings)

      assert profile_deepseek.capabilities.type == :local
      assert profile_deepseek.temperature == 0.6
      assert profile_deepseek.thinking_budget >= 2048

      # ------------------------------------------------------------------------
      # Step (c): Dynamic system prompt building synthesizing base prompt + persona
      # + custom instructions + coding style + discovered AGENTS.md
      # ------------------------------------------------------------------------
      agents_md_path = Path.join(workspace_path, "AGENTS.md")

      File.write!(
        agents_md_path,
        """
        # Workspace Specific Protocols
        - Strictly avoid premature optimization.
        - Validate all inputs at domain boundaries.
        """
      )

      base_prompt = "You are the primary assistant for iex-code."

      built_system_prompt =
        SystemPromptBuilder.build(base_prompt, workspace_path, configured_settings)

      assert built_system_prompt =~ "You are the primary assistant for iex-code."
      assert built_system_prompt =~ "## Persona"
      assert built_system_prompt =~ "expert systems architect"
      assert built_system_prompt =~ "## Custom Instructions"

      assert built_system_prompt =~
               "Design scalable, resilient distributed systems with OTP fault-tolerance."

      assert built_system_prompt =~ "## Coding Style Guidelines"

      assert built_system_prompt =~
               "Enforce strict typespecs and immutability across all public modules."

      assert built_system_prompt =~ "## Project Workspace Rules (AGENTS.md)"
      assert built_system_prompt =~ "Strictly avoid premature optimization."
      assert built_system_prompt =~ "Validate all inputs at domain boundaries."

      # ------------------------------------------------------------------------
      # Step (d): Safety policy evaluation: mutating tools prompt, read_only tools
      # auto-allow, web search auto-allows, mutating tools denied in read_only tier
      # ------------------------------------------------------------------------

      # Mutating tools must return {:prompt, _} in prompt_dangerous mode
      assert {:prompt, reason_shell} = SafetyPolicy.evaluate("run_command", configured_settings)
      assert reason_shell =~ "approval" and reason_shell =~ "shell_execution"

      assert {:prompt, reason_file} = SafetyPolicy.evaluate("write_file", configured_settings)
      assert reason_file =~ "approval" and reason_file =~ "file_mutations"

      assert {:prompt, reason_git} = SafetyPolicy.evaluate("git_commit", configured_settings)
      assert reason_git =~ "approval" and reason_git =~ "git_push"

      # Verify prompt without category overrides uses global tier reason
      tier_only_settings = %AppSettings{configured_settings | tool_category_overrides: %{}}
      assert {:prompt, tier_reason} = SafetyPolicy.evaluate("run_command", tier_only_settings)
      assert tier_reason =~ "modifies files or executes commands"

      # Read-only tools auto-allow
      assert SafetyPolicy.evaluate("read_file", configured_settings) == :allow
      assert SafetyPolicy.evaluate("grep_search", configured_settings) == :allow
      assert SafetyPolicy.evaluate("list_dir", configured_settings) == :allow

      # Web search auto-allows due to configured override in step (a)
      assert SafetyPolicy.evaluate("web_search", configured_settings) == :allow
      assert SafetyPolicy.evaluate("fetch_url", configured_settings) == :allow

      # In read_only tier, mutating tools are strictly denied
      read_only_settings = %AppSettings{
        configured_settings
        | tool_approval_mode: "read_only"
      }

      assert {:deny, deny_shell} = SafetyPolicy.evaluate("run_command", read_only_settings)
      assert deny_shell =~ "prohibited in read_only mode"

      assert {:deny, deny_file} = SafetyPolicy.evaluate("write_file", read_only_settings)
      assert deny_file =~ "prohibited in read_only mode"

      assert {:deny, deny_git} = SafetyPolicy.evaluate("git_commit", read_only_settings)
      assert deny_git =~ "prohibited in read_only mode"

      assert SafetyPolicy.evaluate("read_file", read_only_settings) == :allow

      # ------------------------------------------------------------------------
      # Step (e): Verify secret masking on sensitive strings
      # (bearer tokens, OpenAI keys, AWS credentials, known custom secrets)
      # ------------------------------------------------------------------------
      sensitive_sample = """
      Diagnostic dump:
      Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.token123
      OpenAI: sk-proj-ab12cd34ef56gh78ij90kl12mn34op56
      AWS: AKIAIOSFODNN7EXAMPLE
      Custom Secret: super_classified_system_token_999
      """

      scrubbed =
        SecretMasker.scrub(
          sensitive_sample,
          Map.values(configured_settings.custom_env_vars)
        )

      # All sensitive tokens must be redacted
      assert scrubbed =~ "Authorization: Bearer [REDACTED_SECRET]"
      assert scrubbed =~ "OpenAI: [REDACTED_SECRET]"
      assert scrubbed =~ "AWS: [REDACTED_SECRET]"
      assert scrubbed =~ "Custom Secret: [REDACTED_SECRET]"

      refute scrubbed =~ "eyJhbGciOiJIUzI1Ni"
      refute scrubbed =~ "sk-proj-ab12cd34ef56gh78ij90kl12mn34op56"
      refute scrubbed =~ "AKIAIOSFODNN7EXAMPLE"
      refute scrubbed =~ "super_classified_system_token_999"

      # ------------------------------------------------------------------------
      # Step (f): Verify LiveView Settings studio renders across all 6 tabs
      # (providers, reasoning, safety, context, environment, appearance)
      # and live payload previewer serializes genuine JSON
      # ------------------------------------------------------------------------
      {:ok, studio_view, _html} = live(conn, ~p"/settings")
      assert has_element?(studio_view, "#settings-studio-tabs")

      # Tab 1: Providers
      assert has_element?(studio_view, "#tab-link-providers")
      assert has_element?(studio_view, "#tab-panel-providers:not(.hidden)")

      # Tab 2: Reasoning (and payload previewer)
      render_patch(studio_view, ~p"/settings/reasoning")
      assert has_element?(studio_view, "#tab-panel-reasoning:not(.hidden)")
      assert has_element?(studio_view, "#tab-panel-providers.hidden")
      assert has_element?(studio_view, "#live-reasoning-payload-previewer")
      assert has_element?(studio_view, "#preview-payload-code")

      # Extract payload JSON and verify genuine JSON encoding
      preview_code_text =
        studio_view
        |> element("#preview-payload-code")
        |> render()
        |> Floki.parse_fragment!()
        |> Floki.text()

      assert {:ok, parsed_payload} = Jason.decode(preview_code_text)
      assert is_map(parsed_payload)
      assert Map.has_key?(parsed_payload, "model")
      assert Map.has_key?(parsed_payload, "messages")

      # Tab 3: Safety (Tool Approvals)
      render_patch(studio_view, ~p"/settings/safety")
      assert has_element?(studio_view, "#tab-panel-safety:not(.hidden)")
      assert has_element?(studio_view, "#tab-panel-reasoning.hidden")
      assert has_element?(studio_view, "#safety-policy-card")
      assert has_element?(studio_view, "#settings-tool-approval-mode")

      # Tab 4: Context (Personas & Window Compaction)
      render_patch(studio_view, ~p"/settings/context")
      assert has_element?(studio_view, "#tab-panel-context:not(.hidden)")
      assert has_element?(studio_view, "#tab-panel-safety.hidden")
      assert has_element?(studio_view, "#context-compaction-card")
      assert has_element?(studio_view, "#settings-workspace-persona")

      # Tab 5: Environment (Sandbox & Custom Variables)
      render_patch(studio_view, ~p"/settings/environment")
      assert has_element?(studio_view, "#tab-panel-environment:not(.hidden)")
      assert has_element?(studio_view, "#tab-panel-context.hidden")
      assert has_element?(studio_view, "#environment-vars-card")

      # Tab 6: Appearance (Sound & Theme Accent)
      render_patch(studio_view, ~p"/settings/appearance")
      assert has_element?(studio_view, "#tab-panel-appearance:not(.hidden)")
      assert has_element?(studio_view, "#tab-panel-environment.hidden")
      assert has_element?(studio_view, "#audio-ergonomics-card")
      assert has_element?(studio_view, "#settings-sound-volume")

      # ------------------------------------------------------------------------
      # Step (g): Verify 1-click provider ping executes and returns latency/status
      # ------------------------------------------------------------------------
      # Direct diagnostic ping test using MockPingPlug
      assert {:ok, %{latency_ms: latency, model_count: model_count, status: :online}} =
               Discovery.ping("ollama", configured_settings,
                 plug: MockPingPlug,
                 probe_url: "http://localhost:11434/api/tags"
               )

      assert is_integer(latency) and latency >= 0
      assert model_count == 2

      # LiveView interactive 1-click ping event
      render_patch(studio_view, ~p"/settings/providers")
      assert has_element?(studio_view, "#ping-btn-ollama[phx-click='ping_provider']")

      render_click(studio_view, "ping_provider", %{"provider" => "ollama"})
      _ = :sys.get_state(studio_view.pid)

      provider_html = render(studio_view)
      assert provider_html =~ "ollama" or has_element?(studio_view, "#provider-latency-ollama")

      # ------------------------------------------------------------------------
      # Step (h): Verify LiveView tool approval modal interactive flow:
      # - Intercepts dangerous call
      # - Renders #tool-approval-modal
      # - Clicking #approve-tool-once-btn executes once
      # - Clicking #allow-tool-session-btn permits session
      # - Clicking #deny-tool-btn returns user-denied error
      # ------------------------------------------------------------------------
      PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")
      {:ok, workspace_view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Modal is initially not rendered
      refute has_element?(workspace_view, "#tool-approval-modal")

      # 1. Flow: Approve Once
      request_once = %{
        id: "req-e2e-once-#{System.unique_integer([:positive])}",
        session_id: session.id,
        tool_name: "write_file",
        category: "file_mutations",
        arguments: %{"path" => "lib/core.ex", "content" => "defmodule Core do end"},
        reason: "Tool 'write_file' modifies files or executes commands",
        tier: "prompt_dangerous"
      }

      # Authorize tool in background task simulating swarm agent
      task_once =
        Task.async(fn ->
          SessionServer.authorize_tool(
            session.id,
            request_once.tool_name,
            request_once.arguments,
            configured_settings,
            %{},
            3_000
          )
        end)

      # PubSub request broadcast should trigger modal render in WorkspaceLive
      assert_receive {:tool_approval_requested, _sid, received_req_once}, 2_000
      assert String.starts_with?(received_req_once.id, "approval-")
      assert received_req_once.tool_name == "write_file"
      assert received_req_once.category == "file_mutations"

      # Verify modal is now visible with action buttons
      assert has_element?(workspace_view, "#tool-approval-modal")
      assert has_element?(workspace_view, "#tool-approval-name", "write_file")
      assert has_element?(workspace_view, "#approve-tool-once-btn")
      assert has_element?(workspace_view, "#allow-tool-session-btn")
      assert has_element?(workspace_view, "#deny-tool-btn")

      # Click Approve Once
      workspace_view
      |> element("#approve-tool-once-btn")
      |> render_click()

      # Modal dismissed
      refute has_element?(workspace_view, "#tool-approval-modal")

      # Task successfully receives approval
      assert {:ok, :allowed, _overrides} = Task.await(task_once, 2_000)

      # 2. Flow: Allow for Session
      request_session = %{
        id: "req-e2e-session-#{System.unique_integer([:positive])}",
        session_id: session.id,
        tool_name: "run_command",
        category: "shell_execution",
        arguments: %{"command" => "mix compile"},
        reason: "Tool 'run_command' modifies files or executes commands",
        tier: "prompt_dangerous"
      }

      task_session =
        Task.async(fn ->
          SessionServer.authorize_tool(
            session.id,
            request_session.tool_name,
            request_session.arguments,
            configured_settings,
            %{},
            3_000
          )
        end)

      assert_receive {:tool_approval_requested, _sid, received_req_session}, 2_000
      assert String.starts_with?(received_req_session.id, "approval-")
      assert received_req_session.tool_name == "run_command"
      assert received_req_session.category == "shell_execution"

      assert has_element?(workspace_view, "#tool-approval-modal")

      # Click Allow for Session
      workspace_view
      |> element("#allow-tool-session-btn")
      |> render_click()

      refute has_element?(workspace_view, "#tool-approval-modal")

      # Task allowed and returns updated category overrides
      assert {:ok, :allowed, session_overrides} = Task.await(task_session, 2_000)
      assert session_overrides["shell_execution"] == "auto"

      # Subsequent calls to shell_execution are immediately allowed without prompting
      assert {:ok, :allowed, _} =
               SessionServer.authorize_tool(
                 session.id,
                 "run_command",
                 %{"command" => "git status"},
                 configured_settings,
                 session_overrides,
                 500
               )

      # 3. Flow: Deny Tool
      request_deny = %{
        id: "req-e2e-deny-#{System.unique_integer([:positive])}",
        session_id: session.id,
        tool_name: "git_commit",
        category: "git_push",
        arguments: %{"message" => "Force push experimental branch"},
        reason: "Tool 'git_commit' modifies repository history",
        tier: "prompt_dangerous"
      }

      task_deny =
        Task.async(fn ->
          SessionServer.authorize_tool(
            session.id,
            request_deny.tool_name,
            request_deny.arguments,
            configured_settings,
            %{},
            3_000
          )
        end)

      assert_receive {:tool_approval_requested, _sid, received_req_deny}, 2_000
      assert String.starts_with?(received_req_deny.id, "approval-")
      assert received_req_deny.tool_name == "git_commit"
      assert received_req_deny.category == "git_push"

      assert has_element?(workspace_view, "#tool-approval-modal")

      # Click Deny
      workspace_view
      |> element("#deny-tool-btn")
      |> render_click()

      refute has_element?(workspace_view, "#tool-approval-modal")

      # Task completes with user-denied error
      assert {:error, {:user_denied, deny_reason}} = Task.await(task_deny, 2_000)
      assert deny_reason =~ "denied by user"

      # ------------------------------------------------------------------------
      # Step (i): Verify desktop sound broadcast on desktop:sound
      # ------------------------------------------------------------------------
      PubSub.subscribe(IexCode.PubSub, "desktop:sound")

      assert :ok == Sound.play(:hero, volume: configured_settings.sound_volume)
      assert_receive {:play_sound, "hero", 70}, 2_000

      assert :ok == Sound.play(:ping, volume: 50)
      assert_receive {:play_sound, "ping", 50}, 2_000

      assert :ok == Sound.play(:basso, volume: 80)
      assert_receive {:play_sound, "basso", 80}, 2_000
    end
  end

  # ============================================================================
  # TARGETED SUBSYSTEM VERIFICATION SUITES
  # ============================================================================
  describe "Reasoning profile resolution and parameter clamping matrix" do
    test "OpenAI reasoning models strictly omit temperature and honor reasoning_effort overrides" do
      settings = %AppSettings{
        default_reasoning_effort: "low",
        model_overrides: %{
          "o3-mini" => %{"reasoning_effort" => "high"}
        }
      }

      profile = Reasoning.resolve_profile("openai", "o3-mini", settings)
      assert profile.reasoning_effort == "high"
      assert is_nil(profile.temperature)
      assert profile.capabilities.type == :openai
    end

    test "Anthropic models clamp temperature to 1.0 when thinking is active and enforce max_tokens > budget" do
      settings = %AppSettings{
        default_thinking_budget: 4096,
        temperature: 0.2,
        max_tokens: 4096
      }

      profile =
        Reasoning.resolve_profile(
          "anthropic",
          "claude-3-7-sonnet-20250219",
          settings,
          thinking_budget: 8192
        )

      assert profile.temperature == 1.0
      assert profile.thinking_budget == 8192
      assert profile.max_tokens > 8192
    end

    test "Anthropic models with reasoning_effort 'none' restore temperature and omit thinking block" do
      settings = %AppSettings{
        temperature: 0.4,
        max_tokens: 4096
      }

      profile =
        Reasoning.resolve_profile(
          "anthropic",
          "claude-3-7-sonnet-20250219",
          settings,
          reasoning_effort: "none"
        )

      assert profile.temperature == 0.4
      assert is_nil(profile.thinking_budget)
      assert profile.reasoning_effort == "none"
    end

    test "Local models (DeepSeek R1) enforce temperature 0.6 and minimum budget allocation" do
      settings = %AppSettings{
        temperature: 0.2,
        max_tokens: 4096
      }

      profile = Reasoning.resolve_profile("ollama", "deepseek-r1:14b", settings)
      assert profile.temperature == 0.6
      assert profile.thinking_budget >= 2048
      assert profile.capabilities.type == :local
    end

    test "Gemini models clamp thinking_budget >= 1024" do
      settings = %AppSettings{
        temperature: 0.2,
        max_tokens: 4096
      }

      profile =
        Reasoning.resolve_profile(
          "google",
          "gemini-2.0-flash-thinking",
          settings,
          thinking_budget: 256
        )

      assert profile.thinking_budget >= 1024
      assert profile.capabilities.type == :gemini
    end
  end

  describe "Dynamic system prompt building and instruction composition" do
    test "SystemPromptBuilder composes base role, persona, instructions, style, and project AGENTS.md",
         %{workspace_path: path} do
      agents_path = Path.join(path, "AGENTS.md")
      File.write!(agents_path, "# Team Instructions\n- Write declarative elixir code.")

      settings = %AppSettings{
        workspace_persona: "architect",
        custom_system_prompt: "Follow clean architecture principles.",
        coding_style_rules: "Prefer pattern matching over conditional branches."
      }

      prompt = SystemPromptBuilder.build("Base developer role", path, settings)
      assert prompt =~ "Base developer role"
      assert prompt =~ "expert systems architect"
      assert prompt =~ "Follow clean architecture principles."
      assert prompt =~ "Prefer pattern matching over conditional branches."
      assert prompt =~ "Write declarative elixir code."
    end

    test "SystemPromptBuilder falls back to CODEX.md when AGENTS.md is absent", %{
      workspace_path: path
    } do
      # Remove any existing AGENTS.md in temp workspace
      File.rm(Path.join(path, "AGENTS.md"))

      codex_path = Path.join(path, "CODEX.md")
      File.write!(codex_path, "# Codex Instructions\n- Adhere to test-driven design.")

      prompt = SystemPromptBuilder.build("Base role", path, %AppSettings{})
      assert prompt =~ "## Project Workspace Rules (CODEX.md)"
      assert prompt =~ "Adhere to test-driven design."
    end
  end

  describe "SafetyPolicy tiers, category overrides, and session override mechanics" do
    test "read_only mode unconditionally blocks mutating tools regardless of category overrides" do
      settings = %AppSettings{
        tool_approval_mode: "read_only",
        tool_category_overrides: %{
          "file_mutations" => "auto",
          "shell_execution" => "prompt"
        }
      }

      assert {:deny, reason_write} = SafetyPolicy.evaluate("write_file", settings)
      assert reason_write =~ "prohibited in read_only mode"

      assert {:deny, reason_cmd} = SafetyPolicy.evaluate("run_command", settings)
      assert reason_cmd =~ "prohibited in read_only mode"

      # Read-only inspection tools still permitted
      assert SafetyPolicy.evaluate("read_file", settings) == :allow
      assert SafetyPolicy.evaluate("list_dir", settings) == :allow
    end

    test "full_auto mode permits execution without prompting" do
      settings = %AppSettings{
        tool_approval_mode: "full_auto",
        tool_category_overrides: %{}
      }

      assert SafetyPolicy.evaluate("run_command", settings) == :allow
      assert SafetyPolicy.evaluate("write_file", settings) == :allow
      assert SafetyPolicy.evaluate("git_commit", settings) == :allow
      assert SafetyPolicy.evaluate("read_file", settings) == :allow
    end

    test "session category override bypasses prompt for permitted category", %{session: session} do
      settings = %AppSettings{
        tool_approval_mode: "prompt_dangerous",
        tool_category_overrides: %{}
      }

      session_overrides = %{"shell_execution" => "auto"}

      assert {:ok, :allowed, _} =
               SessionServer.authorize_tool(
                 session.id,
                 "run_command",
                 %{"command" => "git status"},
                 settings,
                 session_overrides,
                 500
               )
    end
  end

  describe "SecretMasker output redaction and sandbox environment sanitization" do
    test "scrubs bearer tokens, API keys, AWS credentials, and arbitrary known secrets" do
      sample =
        "Auth: Bearer secret_bearer_token_123, Key: sk-proj-123456789012345678901234, AWS: AKIAIOSFODNN7EXAMPLE, Token: custom_secret_pass"

      scrubbed = SecretMasker.scrub(sample, ["custom_secret_pass"])
      assert scrubbed =~ "Auth: Bearer [REDACTED_SECRET]"
      assert scrubbed =~ "Key: [REDACTED_SECRET]"
      assert scrubbed =~ "AWS: [REDACTED_SECRET]"
      assert scrubbed =~ "Token: [REDACTED_SECRET]"
      refute scrubbed =~ "secret_bearer_token_123"
      refute scrubbed =~ "sk-proj-123456789012345678901234"
      refute scrubbed =~ "custom_secret_pass"
    end

    test "builds filtered environment stripping sensitive host variables" do
      System.put_env("E2E_SECRET_TOKEN_VAR", "leaked_secret")
      System.put_env("E2E_SAFE_PUBLIC_VAR", "public_safe_val")

      on_exit(fn ->
        System.delete_env("E2E_SECRET_TOKEN_VAR")
        System.delete_env("E2E_SAFE_PUBLIC_VAR")
      end)

      env = SecretMasker.build_sandbox_env("inherit_filtered", %{}, "/test/path")
      assert env["E2E_SAFE_PUBLIC_VAR"] == "public_safe_val"
      refute Map.has_key?(env, "E2E_SECRET_TOKEN_VAR")
    end
  end

  describe "Settings Studio 6-tab navigation and Live Payload Previewer JSON integrity" do
    test "direct navigation to each of the 6 settings tabs renders active panel", %{conn: conn} do
      tabs = [
        {"providers", "#tab-panel-providers"},
        {"reasoning", "#tab-panel-reasoning"},
        {"safety", "#tab-panel-safety"},
        {"context", "#tab-panel-context"},
        {"environment", "#tab-panel-environment"},
        {"appearance", "#tab-panel-appearance"}
      ]

      for {tab_name, panel_id} <- tabs do
        {:ok, view, _html} = live(conn, "/settings/#{tab_name}")
        assert has_element?(view, "#{panel_id}:not(.hidden)")
        assert has_element?(view, "#tab-link-#{tab_name}")
      end
    end

    test "live reasoning previewer updates serialized JSON payload when switching models", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/settings/reasoning")

      assert has_element?(view, "#live-reasoning-payload-previewer")
      assert has_element?(view, "#preview-payload-code")

      # Update model to Anthropic Claude 3.7 Sonnet with extended thinking
      render_click(view, "update_preview_model", %{
        "provider" => "anthropic",
        "model" => "claude-3-7-sonnet",
        "thinking_budget" => 8192
      })

      _ = :sys.get_state(view.pid)

      code_text =
        view
        |> element("#preview-payload-code")
        |> render()
        |> Floki.parse_fragment!()
        |> Floki.text()

      assert {:ok, json} = Jason.decode(code_text)
      assert json["model"] == "claude-3-7-sonnet"
      assert json["thinking"]["budget_tokens"] == 8192
      assert json["temperature"] == 1.0
    end
  end
end
