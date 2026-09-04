defmodule IexCodeWeb.EmpiricalSettingsStudioChallengeTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true
  @moduletag timeout: 60_000

  alias IexCode.LLM.Reasoning
  alias IexCode.Settings
  alias IexCodeWeb.CommandPalette

  # ============================================================================
  # Mock Plug for Local HTTP Server Ping Diagnostics
  # ============================================================================
  defmodule MockPingPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      case {conn.method, conn.request_path} do
        {"GET", "/v1/models"} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            200,
            Jason.encode!(%{
              "object" => "list",
              "data" => [
                %{"id" => "gpt-4o", "object" => "model"},
                %{"id" => "o3-mini", "object" => "model"},
                %{"id" => "o1", "object" => "model"}
              ]
            })
          )

        {"GET", "/v1/anthropic/models"} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            200,
            Jason.encode!(%{
              "data" => [
                %{"id" => "claude-3-7-sonnet-20250219"}
              ]
            })
          )

        {"GET", "/api/tags"} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            200,
            Jason.encode!(%{
              "models" => [
                %{"name" => "deepseek-r1:14b", "model" => "deepseek-r1:14b"}
              ]
            })
          )

        {"GET", "/v1/error/models"} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(500, Jason.encode!(%{"error" => "Internal server error"}))

        _ ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(404, Jason.encode!(%{"error" => "Not found"}))
      end
    end
  end

  # ============================================================================
  # Helper: Extract and Parse Rendered Payload from LiveView
  # ============================================================================
  defp parse_live_preview_payload(view) do
    code_html = render(element(view, "#preview-payload-code"))
    {:ok, fragment} = Floki.parse_fragment(code_html)
    raw_text = String.trim(Floki.text(fragment))

    case Jason.decode(raw_text) do
      {:ok, payload} ->
        {:ok, payload}

      {:error, decode_error} ->
        {:error, {decode_error, raw_text}}
    end
  end

  # ============================================================================
  # 1. Tab Navigation Across All 6 Tabs
  # ============================================================================
  describe "1. Tab Navigation Across All 6 Tabs" do
    @all_tabs ~w(providers reasoning safety context environment appearance)

    test "initial mount at /settings renders sticky tabs bar and defaults to providers tab", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "#settings-studio-tabs")

      # All 6 tabs must have a navigation link and a corresponding content panel
      for tab <- @all_tabs do
        assert has_element?(view, "#tab-link-#{tab}")
        assert has_element?(view, "#tab-panel-#{tab}")
      end

      # Providers tab should have active styling (cyan indicator) and its panel must NOT be hidden
      assert has_element?(view, "#tab-link-providers[class*='text-cyan-300']")
      assert has_element?(view, "#tab-panel-providers:not(.hidden)")

      # All other 5 tabs must have inactive styling and their panels MUST be hidden
      for inactive <- ~w(reasoning safety context environment appearance) do
        assert has_element?(view, "#tab-link-#{inactive}[class*='text-gray-400']")
        assert has_element?(view, "#tab-panel-#{inactive}.hidden")
      end
    end

    test "direct URL navigation activates the targeted tab and hides all others", %{conn: conn} do
      tabs = [
        {"providers", "Providers & Models"},
        {"reasoning", "Reasoning & Thinking"},
        {"safety", "Tool Safety & Approvals"},
        {"context", "Context & Personas"},
        {"environment", "Environment & Secrets"},
        {"appearance", "Sound & Appearance"}
      ]

      for {tab_id, expected_title_part} <- tabs do
        {:ok, view, _html} = live(conn, "/settings/#{tab_id}")

        # Active panel is visible
        assert has_element?(view, "#tab-panel-#{tab_id}:not(.hidden)")
        # Active tab link has highlighted cyan styling
        assert has_element?(view, "#tab-link-#{tab_id}[class*='text-cyan-300']")

        # All other panels are hidden
        for other <- @all_tabs, other != tab_id do
          assert has_element?(view, "#tab-panel-#{other}.hidden")
          assert has_element?(view, "#tab-link-#{other}[class*='text-gray-400']")
        end

        # Page title reflects the active tab
        assert page_title(view) =~ expected_title_part
      end
    end

    test "live patching between tabs smoothly switches visibility without full page reload", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/settings")

      # Start at providers
      assert has_element?(view, "#tab-panel-providers:not(.hidden)")
      assert has_element?(view, "#tab-panel-reasoning.hidden")

      # Patch to reasoning
      render_patch(view, ~p"/settings/reasoning")
      assert has_element?(view, "#tab-panel-reasoning:not(.hidden)")
      assert has_element?(view, "#tab-panel-providers.hidden")
      assert has_element?(view, "#tab-link-reasoning[class*='text-cyan-300']")

      # Patch to safety
      render_patch(view, ~p"/settings/safety")
      assert has_element?(view, "#tab-panel-safety:not(.hidden)")
      assert has_element?(view, "#tab-panel-reasoning.hidden")
      assert has_element?(view, "#tab-link-safety[class*='text-cyan-300']")

      # Patch to context
      render_patch(view, ~p"/settings/context")
      assert has_element?(view, "#tab-panel-context:not(.hidden)")
      assert has_element?(view, "#tab-panel-safety.hidden")
      assert has_element?(view, "#tab-link-context[class*='text-cyan-300']")

      # Patch to environment
      render_patch(view, ~p"/settings/environment")
      assert has_element?(view, "#tab-panel-environment:not(.hidden)")
      assert has_element?(view, "#tab-panel-context.hidden")
      assert has_element?(view, "#tab-link-environment[class*='text-cyan-300']")

      # Patch to appearance
      render_patch(view, ~p"/settings/appearance")
      assert has_element?(view, "#tab-panel-appearance:not(.hidden)")
      assert has_element?(view, "#tab-panel-environment.hidden")
      assert has_element?(view, "#tab-link-appearance[class*='text-cyan-300']")

      # Patch back to providers
      render_patch(view, ~p"/settings/providers")
      assert has_element?(view, "#tab-panel-providers:not(.hidden)")
      assert has_element?(view, "#tab-panel-appearance.hidden")
      assert has_element?(view, "#tab-link-providers[class*='text-cyan-300']")
    end

    test "session-scoped settings routes preserve session context, return link, and tab patch targets",
         %{
           conn: conn,
           workspace_path: path
         } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/settings/reasoning")

      # Preserves session context indicator and workspace return link
      assert has_element?(view, "#settings-session-context")
      assert has_element?(view, "#settings-return-workspace[href='/sessions/#{session.id}']")
      assert has_element?(view, "#tab-panel-reasoning:not(.hidden)")

      # Tab links preserve session prefix in their patch hrefs
      assert has_element?(
               view,
               "#tab-link-reasoning[href='/sessions/#{session.id}/settings/reasoning']"
             )

      assert has_element?(
               view,
               "#tab-link-providers[href='/sessions/#{session.id}/settings/providers']"
             )

      # Patching within session route preserves session context
      render_patch(view, ~p"/sessions/#{session.id}/settings/appearance")
      assert has_element?(view, "#tab-panel-appearance:not(.hidden)")
      assert has_element?(view, "#settings-session-context")
    end

    test "invalid or unknown tab fallback defaults cleanly to providers tab without crashing", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/settings/completely_bogus_tab_slug")

      assert has_element?(view, "#tab-panel-providers:not(.hidden)")
      assert has_element?(view, "#tab-link-providers[class*='text-cyan-300']")
    end
  end

  # ============================================================================
  # 2. Live Reasoning Payload Previewer Component & Serialization
  # ============================================================================
  describe "2. Live Reasoning Payload Previewer Component & Serialization" do
    test "Reasoning.serialize_payload unit oracle enforces provider-specific contracts", %{
      conn: _conn
    } do
      settings = Settings.get_settings()
      messages = [%{"role" => "user", "content" => "Hello world"}]
      system = "You are an assistant"

      # 1. OpenAI reasoning model: o3-mini
      openai_payload =
        Reasoning.serialize_payload("openai", "o3-mini", messages, system, settings,
          reasoning_effort: "high"
        )

      assert openai_payload["model"] == "o3-mini"
      assert openai_payload["reasoning_effort"] == "high"
      # Critical requirement: strictly omits temperature
      refute Map.has_key?(openai_payload, "temperature"),
             "OpenAI reasoning model payload must strictly omit temperature"

      assert Map.has_key?(openai_payload, "max_completion_tokens") or
               Map.has_key?(openai_payload, "max_tokens")

      # 2. Anthropic extended thinking model: claude-3-7-sonnet
      anthropic_payload =
        Reasoning.serialize_payload(
          "anthropic",
          "claude-3-7-sonnet-20250219",
          messages,
          system,
          settings,
          thinking_budget: 8192
        )

      assert anthropic_payload["model"] == "claude-3-7-sonnet-20250219"
      # Critical requirement: temperature clamped to 1.0
      assert anthropic_payload["temperature"] == 1.0,
             "Anthropic extended thinking payload must clamp temperature to 1.0"

      assert anthropic_payload["thinking"]["type"] == "enabled"
      assert anthropic_payload["thinking"]["budget_tokens"] == 8192
      assert anthropic_payload["max_tokens"] > 8192
    end

    test "renders previewer component with badges, clipboard button, and sample buttons in reasoning tab",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/reasoning")

      assert has_element?(view, "#live-reasoning-payload-previewer")
      assert has_element?(view, "#copy-payload-btn")
      assert has_element?(view, "#payload-preview-badges")
      assert has_element?(view, "#preview-payload-code")

      # Sample model buttons
      assert has_element?(view, "#preview-btn-o3-mini")
      assert has_element?(view, "#preview-btn-o1")
      assert has_element?(view, "#preview-btn-claude")
      assert has_element?(view, "#preview-btn-gemini")
      assert has_element?(view, "#preview-btn-deepseek")
    end

    test "UI badges reflect active model capability rules upon model switch", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/reasoning")

      # Switch to Anthropic
      render_click(view, "update_preview_model", %{
        "provider" => "anthropic",
        "model" => "claude-3-7-sonnet-20250219",
        "thinking_budget" => 8192
      })

      _ = :sys.get_state(view.pid)
      badges_html = render(element(view, "#payload-preview-badges"))
      assert badges_html =~ "Clamped temp: 1.0 (Anthropic Extended Thinking)"
      assert badges_html =~ "Thinking Budget: 8192"

      # Switch to OpenAI o1
      render_click(view, "update_preview_model", %{
        "provider" => "openai",
        "model" => "o1",
        "reasoning_effort" => "high"
      })

      _ = :sys.get_state(view.pid)
      badges_html = render(element(view, "#payload-preview-badges"))
      assert badges_html =~ "Omit Temperature (OpenAI reasoning)"
      assert badges_html =~ "Reasoning Effort: high"

      # Switch to local DeepSeek R1
      render_click(view, "update_preview_model", %{
        "provider" => "ollama",
        "model" => "deepseek-r1:14b"
      })

      _ = :sys.get_state(view.pid)
      badges_html = render(element(view, "#payload-preview-badges"))
      assert badges_html =~ "&lt;think&gt; tags parsed" or badges_html =~ "think"
    end

    test "live reasoning payload previewer: OpenAI reasoning model renders JSON omitting temperature",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/reasoning")

      render_click(view, "update_preview_model", %{
        "provider" => "openai",
        "model" => "o3-mini",
        "reasoning_effort" => "high"
      })

      _ = :sys.get_state(view.pid)

      case parse_live_preview_payload(view) do
        {:ok, payload} ->
          assert payload["model"] == "o3-mini"
          assert payload["reasoning_effort"] == "high"
          refute Map.has_key?(payload, "temperature")

        {:error, {_err, raw_text}} ->
          flunk("""
          EMPIRICAL BUG: Rendered #preview-payload-code contains literal #{inspect(raw_text)} instead of JSON.
          Root cause: In `lib/iex_code_web/components/payload_previewer.ex` line 119,
          `<code id="preview-payload-code" phx-no-curly-interpolation>{@payload_json}</code>`
          disables {...} interpolation. Must use `<%= @payload_json %>`.
          """)
      end
    end

    test "live reasoning payload previewer: Anthropic thinking model renders JSON clamping temperature to 1.0",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/reasoning")

      render_click(view, "update_preview_model", %{
        "provider" => "anthropic",
        "model" => "claude-3-7-sonnet-20250219",
        "thinking_budget" => 8192
      })

      _ = :sys.get_state(view.pid)

      case parse_live_preview_payload(view) do
        {:ok, payload} ->
          assert payload["model"] == "claude-3-7-sonnet-20250219"
          assert payload["temperature"] == 1.0
          assert payload["thinking"]["type"] == "enabled"
          assert payload["thinking"]["budget_tokens"] == 8192

        {:error, {_err, raw_text}} ->
          flunk("""
          EMPIRICAL BUG: Rendered #preview-payload-code contains literal #{inspect(raw_text)} instead of JSON.
          Root cause: In `lib/iex_code_web/components/payload_previewer.ex` line 119,
          `<code id="preview-payload-code" phx-no-curly-interpolation>{@payload_json}</code>`
          disables {...} interpolation. Must use `<%= @payload_json %>`.
          """)
      end
    end
  end

  # ============================================================================
  # 3. Live Provider Ping Event (ping_provider) & Latency Badges
  # ============================================================================
  describe "3. Live Provider Ping Event (ping_provider)" do
    test "live ping to active endpoint updates latency badge with online status, ms, and flash notification",
         %{conn: conn} do
      # Spin up an in-memory Bandit server running MockPingPlug on an ephemeral port
      server =
        start_supervised!(
          {Bandit, plug: MockPingPlug, port: 0, ip: :loopback, startup_log: false}
        )

      {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)

      # Update settings so openai_base_url points to our mock server
      {:ok, _} = Settings.update_settings(%{openai_base_url: "http://127.0.0.1:#{port}/v1"})

      {:ok, view, _html} = live(conn, ~p"/settings/providers")

      # Before pinging, the badge exists in 'Ready' state
      assert has_element?(view, "#ping-badge-openai")
      assert render(element(view, "#ping-badge-openai")) =~ "Ready"
      assert has_element?(view, "#ping-btn-openai")

      # Trigger live ping event
      render_click(view, "ping_provider", %{"provider" => "openai"})
      _ = :sys.get_state(view.pid)

      # Verify the badge rendered online status and latency ms
      badge_html = render(element(view, "#ping-badge-openai"))
      assert badge_html =~ "ms"
      assert has_element?(view, "#ping-badge-openai span.bg-emerald-400")

      # Verify flash notification displays online status and model count
      html = render(view)
      assert html =~ "Openai online"
      assert html =~ "latency"
      assert html =~ "models discovered"
    end

    test "live ping to unreachable provider gracefully transitions badge to offline without crash",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/providers")

      # Ping ollama which has no server listening on default port
      render_click(view, "ping_provider", %{"provider" => "ollama"})
      _ = :sys.get_state(view.pid)

      # Verify badge rendered offline status
      badge_html = render(element(view, "#ping-badge-ollama"))
      assert badge_html =~ "Offline"
      assert has_element?(view, "#ping-badge-ollama span.bg-rose-400")

      # Verify error flash message is set
      html = render(view)
      assert html =~ "unreachable"
    end
  end

  # ============================================================================
  # 4. Quick Settings Drawer in WorkspaceLive
  # ============================================================================
  describe "4. Quick Settings Drawer in WorkspaceLive" do
    test "drawer opens via toggle, renders controls and deep-link, and closes cleanly", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Sidebar quick settings button exists
      assert has_element?(view, "#sidebar-quick-settings-btn")

      # Drawer is initially not rendered in DOM
      refute has_element?(view, "#quick-settings-drawer")

      # 1. Open drawer
      render_click(view, "toggle_quick_settings")
      assert has_element?(view, "#quick-settings-drawer")
      assert has_element?(view, "#quick-settings-title")
      assert has_element?(view, "#close-quick-settings-btn")
      assert has_element?(view, "#drawer-sound-toggle-btn")

      # Assert deep-link navigates to session-scoped Settings studio
      assert has_element?(
               view,
               "#drawer-open-full-studio-btn[href='/sessions/#{session.id}/settings']"
             )

      # 2. Close drawer via close button
      render_click(view, "toggle_quick_settings")
      refute has_element?(view, "#quick-settings-drawer")

      # 3. Open again and close via backdrop click
      render_click(view, "toggle_quick_settings")
      assert has_element?(view, "#quick-settings-drawer")
      render_click(view, "toggle_quick_settings")
      refute has_element?(view, "#quick-settings-drawer")
    end

    test "quick_update_settings event updates tool approval mode in settings and UI", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      render_click(view, "toggle_quick_settings")

      for mode <- ~w(full_auto read_only prompt_dangerous) do
        render_click(view, "quick_update_settings", %{
          "key" => "tool_approval_mode",
          "value" => mode
        })

        _ = :sys.get_state(view.pid)

        # Database state updated
        settings = Settings.get_settings()
        assert settings.tool_approval_mode == mode

        # UI highlights the active mode button
        assert has_element?(
                 view,
                 "#quick-settings-drawer button[phx-value-value='#{mode}'][class*='border-emerald-500']"
               )
      end
    end

    test "quick_update_settings event updates reasoning effort and desktop audio settings", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      render_click(view, "toggle_quick_settings")

      # Update reasoning effort to 'high'
      render_click(view, "quick_update_settings", %{
        "key" => "default_reasoning_effort",
        "value" => "high"
      })

      _ = :sys.get_state(view.pid)
      assert Settings.get_settings().default_reasoning_effort == "high"

      # Update reasoning effort to 'low'
      render_click(view, "quick_update_settings", %{
        "key" => "default_reasoning_effort",
        "value" => "low"
      })

      _ = :sys.get_state(view.pid)
      assert Settings.get_settings().default_reasoning_effort == "low"

      # Toggle desktop audio sound_enabled
      render_click(view, "quick_update_settings", %{
        "key" => "sound_enabled",
        "value" => "false"
      })

      _ = :sys.get_state(view.pid)
      refute Settings.get_settings().sound_enabled

      render_click(view, "quick_update_settings", %{
        "key" => "sound_enabled",
        "value" => "true"
      })

      _ = :sys.get_state(view.pid)
      assert Settings.get_settings().sound_enabled

      # Update thinking budget
      render_click(view, "quick_update_settings", %{
        "key" => "default_thinking_budget",
        "value" => "8192"
      })

      _ = :sys.get_state(view.pid)
      assert Settings.get_settings().default_thinking_budget == 8192
    end
  end

  # ============================================================================
  # 5. Command Palette Tab Navigation Events
  # ============================================================================
  describe "5. Command Palette Tab Navigation Events" do
    test "CommandPalette index includes all 6 studio tab shortcut definitions" do
      actions = CommandPalette.actions()
      action_ids = Enum.map(actions, & &1.id)

      assert "open_settings_providers" in action_ids
      assert "open_settings_reasoning" in action_ids
      assert "open_settings_safety" in action_ids
      assert "open_settings_context" in action_ids
      assert "open_settings_environment" in action_ids
      assert "open_settings_appearance" in action_ids

      # Verify metadata
      providers_act = Enum.find(actions, &(&1.id == "open_settings_providers"))
      assert providers_act.shortcut == "Cmd+, P"
      assert providers_act.params["tab"] == "providers"

      reasoning_act = Enum.find(actions, &(&1.id == "open_settings_reasoning"))
      assert reasoning_act.shortcut == "Cmd+, R"
      assert reasoning_act.params["tab"] == "reasoning"

      safety_act = Enum.find(actions, &(&1.id == "open_settings_safety"))
      assert safety_act.shortcut == "Cmd+, S"
      assert safety_act.params["tab"] == "safety"
    end

    test "open_settings_tab event dispatches navigation to each individual tab from WorkspaceLive",
         %{
           conn: conn,
           workspace_path: path
         } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      for tab <- ~w(providers reasoning safety context environment appearance) do
        {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

        render_click(view, "open_settings_tab", %{"tab" => tab})
        assert_redirect(view, ~p"/sessions/#{session.id}/settings/#{tab}")
      end
    end

    test "named Command Palette action events redirect directly to designated settings tab", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      actions = [
        {"open_settings_providers", "providers"},
        {"open_settings_reasoning", "reasoning"},
        {"open_settings_safety", "safety"},
        {"open_settings_context", "context"},
        {"open_settings_environment", "environment"},
        {"open_settings_appearance", "appearance"}
      ]

      for {event_name, tab} <- actions do
        {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

        render_click(view, event_name, %{})
        assert_redirect(view, ~p"/sessions/#{session.id}/settings/#{tab}")
      end
    end
  end

  # ============================================================================
  # 6. Edge Cases & Concurrency Stress
  # ============================================================================
  describe "6. Edge Cases & Concurrency Stress" do
    test "rapid tab switching stress test maintains consistency without crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      # Cycle through tabs rapidly 18 times (3 full loops across all 6 tabs)
      for _round <- 1..3 do
        for tab <- ~w(providers reasoning safety context environment appearance) do
          render_patch(view, "/settings/#{tab}")
          assert has_element?(view, "#tab-panel-#{tab}:not(.hidden)")
        end
      end

      # Final check: view process still alive and healthy
      assert Process.alive?(view.pid)
      assert has_element?(view, "#tab-panel-appearance:not(.hidden)")
    end

    test "model overrides matrix persistence and boundary validation", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/reasoning")

      # 1. Add valid override with max boundary values (128,000 token limit)
      render_submit(view, "save_model_override", %{
        "override" => %{
          "model" => "o3-pro-custom",
          "reasoning_effort" => "high",
          "budget_tokens" => "65536",
          "max_tokens" => "128000",
          "temperature" => "1.0"
        }
      })

      _ = :sys.get_state(view.pid)

      settings = Settings.get_settings()
      assert Map.has_key?(settings.model_overrides, "o3-pro-custom")
      override = settings.model_overrides["o3-pro-custom"]
      assert override["reasoning_effort"] == "high"
      assert override["budget_tokens"] == 65_536
      assert override["max_tokens"] == 128_000

      # Verify it renders in the table
      assert has_element?(view, "#override-row-o3-pro-custom")

      # 2. Delete the override
      render_click(view, "delete_model_override", %{"model" => "o3-pro-custom"})
      _ = :sys.get_state(view.pid)

      updated = Settings.get_settings()
      refute Map.has_key?(updated.model_overrides, "o3-pro-custom")
      refute has_element?(view, "#override-row-o3-pro-custom")

      # 3. Adversarial boundary: exceeding 128,000 token ceiling fails validation gracefully
      render_submit(view, "save_model_override", %{
        "override" => %{
          "model" => "invalid-boundary-model",
          "max_tokens" => "131072"
        }
      })

      _ = :sys.get_state(view.pid)
      after_invalid = Settings.get_settings()
      refute Map.has_key?(after_invalid.model_overrides, "invalid-boundary-model")
    end

    test "desktop chime test event executes cleanly without crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/appearance")

      assert has_element?(view, "#test-completion-chime-btn")
      render_click(view, "test_chime", %{"chime" => "hero"})
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#tab-panel-appearance")
    end
  end
end
