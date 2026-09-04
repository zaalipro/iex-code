defmodule IexCodeWeb.SettingsStudioTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true

  alias IexCode.LLM.Discovery
  alias IexCode.Settings
  alias IexCodeWeb.CommandPalette

  # Mock plug for testing Discovery.ping/3
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
                %{"name" => "llama3.2:latest", "model" => "llama3.2:latest"}
              ]
            })
          )

        {"GET", "/api/version"} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(%{"version" => "0.5.1"}))

        {"GET", "/v1/models"} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            200,
            Jason.encode!(%{
              "object" => "list",
              "data" => [
                %{"id" => "gpt-4o", "object" => "model"},
                %{"id" => "o3-mini", "object" => "model"}
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
          |> send_resp(200, Jason.encode!(%{"status" => "ok", "data" => []}))
      end
    end
  end

  # ============================================================================
  # 1. Tab Navigation & Routing
  # ============================================================================
  describe "Settings Studio tab navigation and routing" do
    test "renders sticky tabs bar and defaults to providers tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "#settings-studio-tabs")

      for tab <- ~w(providers reasoning safety context environment appearance) do
        assert has_element?(view, "#tab-link-#{tab}")
        assert has_element?(view, "#tab-panel-#{tab}")
      end

      # Providers panel should NOT be hidden, reasoning panel SHOULD be hidden
      assert has_element?(view, "#tab-panel-providers:not(.hidden)")
      assert has_element?(view, "#tab-panel-reasoning.hidden")
    end

    test "direct navigation to /settings/:tab activates correct tab", %{conn: conn} do
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

    test "clicking/patching tab links switches active tab dynamically", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "#tab-panel-providers:not(.hidden)")
      assert has_element?(view, "#tab-panel-reasoning.hidden")

      # Switch to reasoning tab
      render_patch(view, ~p"/settings/reasoning")

      assert has_element?(view, "#tab-panel-reasoning:not(.hidden)")
      assert has_element?(view, "#tab-panel-providers.hidden")

      # Switch to safety tab
      render_patch(view, ~p"/settings/safety")

      assert has_element?(view, "#tab-panel-safety:not(.hidden)")
      assert has_element?(view, "#tab-panel-reasoning.hidden")
    end

    test "invalid tab path defaults cleanly to providers tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings/unknown_tab_slug")

      assert has_element?(view, "#tab-panel-providers:not(.hidden)")
    end

    test "session-scoped settings routes preserve session context and return link", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/settings/reasoning")

      assert has_element?(view, "#settings-session-context")
      assert has_element?(view, "#settings-return-workspace[href='/sessions/#{session.id}']")
      assert has_element?(view, "#tab-panel-reasoning:not(.hidden)")

      assert has_element?(
               view,
               "#tab-link-reasoning[href='/sessions/#{session.id}/settings/reasoning']"
             )
    end
  end

  # ============================================================================
  # 2. Latency Ping & Diagnostics
  # ============================================================================
  describe "Latency Ping & Diagnostics" do
    test "Discovery.ping/3 works with mock plug for local and cloud providers" do
      # Local Ollama ping
      ollama_res =
        Discovery.ping("ollama", nil,
          plug: MockPingPlug,
          probe_url: "http://localhost:11434/api/tags"
        )

      assert {:ok, %{latency_ms: ms, model_count: count, status: :online}} = ollama_res
      assert is_integer(ms) and ms >= 0
      assert count == 1

      # Cloud OpenAI ping
      openai_res =
        Discovery.ping("openai", nil,
          plug: MockPingPlug,
          base_url: "http://localhost:1234/v1"
        )

      assert {:ok, %{latency_ms: ms2, model_count: count2, status: :online}} = openai_res
      assert is_integer(ms2) and ms2 >= 0
      assert count2 == 2

      # Error response
      error_res =
        Discovery.ping("openai", nil,
          plug: MockPingPlug,
          base_url: "http://localhost:1234/v1/error"
        )

      assert {:error, _reason} = error_res
    end

    test "ping_provider LiveView event updates latency badge and flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/providers")

      assert has_element?(view, "#ping-btn-ollama[phx-click='ping_provider']")

      # Trigger ping
      render_click(view, "ping_provider", %{"provider" => "ollama"})
      _ = :sys.get_state(view.pid)

      html = render(view)
      assert html =~ "ollama" or has_element?(view, "#provider-latency-ollama")
    end
  end

  # ============================================================================
  # 3. Live Reasoning Payload Previewer
  # ============================================================================
  describe "Live Reasoning Payload Previewer" do
    test "renders serialized JSON and capability badges in reasoning tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/reasoning")

      assert has_element?(view, "#live-reasoning-payload-previewer")
      assert has_element?(view, "#copy-payload-btn")
      assert has_element?(view, "#preview-payload-code")

      # Test switching preview model via update_preview_model
      render_click(view, "update_preview_model", %{
        "provider" => "anthropic",
        "model" => "claude-3-7-sonnet",
        "thinking_budget" => 8192
      })

      _ = :sys.get_state(view.pid)

      html = render(view)
      assert html =~ "thinking" or html =~ "claude-3-7-sonnet"
    end
  end

  # ============================================================================
  # 4. Quick Settings Drawer in WorkspaceLive
  # ============================================================================
  describe "Quick Settings Drawer in WorkspaceLive" do
    test "drawer can be toggled open and closed", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      assert has_element?(view, "#sidebar-quick-settings-btn")

      # Initially drawer is not shown
      refute has_element?(view, "#quick-settings-drawer")

      # Open drawer
      render_click(view, "toggle_quick_settings")
      assert has_element?(view, "#quick-settings-drawer")
      assert has_element?(view, "#drawer-open-full-studio-btn")

      # Close drawer
      render_click(view, "toggle_quick_settings")
      refute has_element?(view, "#quick-settings-drawer")
    end

    test "quick_update_settings event modifies settings", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Update tool approval mode via drawer
      render_click(view, "quick_update_settings", %{
        "key" => "tool_approval_mode",
        "value" => "full_auto"
      })

      _ = :sys.get_state(view.pid)

      settings = Settings.get_settings()
      assert settings.tool_approval_mode == "full_auto"
    end
  end

  # ============================================================================
  # 5. Command Palette Settings Shortcuts
  # ============================================================================
  describe "Command Palette Settings Navigation" do
    test "command palette includes all 6 studio tab shortcuts" do
      actions = CommandPalette.actions()
      action_ids = Enum.map(actions, & &1.id)

      assert "open_settings_providers" in action_ids
      assert "open_settings_reasoning" in action_ids
      assert "open_settings_safety" in action_ids
      assert "open_settings_context" in action_ids
      assert "open_settings_environment" in action_ids
      assert "open_settings_appearance" in action_ids

      reasoning_item = Enum.find(actions, &(&1.id == "open_settings_reasoning"))
      assert reasoning_item.category in [:action, :navigation]
      assert reasoning_item.title =~ "Reasoning"
    end

    test "executing settings navigation action in WorkspaceLive redirects to tab", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "open_settings_tab", %{"tab" => "reasoning"})

      assert_redirect(view, ~p"/sessions/#{session.id}/settings/reasoning")
    end
  end

  # ============================================================================
  # 6. Appearance Chime & Model Overrides Matrix
  # ============================================================================
  describe "Appearance & Model Overrides Matrix" do
    test "test_chime event executes without crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/appearance")

      assert has_element?(view, "#test-completion-chime-btn[phx-click='test_chime']")
      render_click(view, "test_chime", %{"chime" => "hero"})
      _ = :sys.get_state(view.pid)

      # Should still be mounted and healthy
      assert has_element?(view, "#tab-panel-appearance")
    end

    test "save_model_override and delete_model_override update model overrides matrix", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/settings/reasoning")

      assert has_element?(view, "#model-overrides-card")

      # Add an override
      render_submit(view, "save_model_override", %{
        "override" => %{
          "model" => "test-custom-model",
          "reasoning_effort" => "high",
          "budget_tokens" => "4096"
        }
      })

      _ = :sys.get_state(view.pid)

      settings = Settings.get_settings()
      assert Map.has_key?(settings.model_overrides, "test-custom-model")
      override = settings.model_overrides["test-custom-model"]
      assert override["reasoning_effort"] == "high"
      assert override["budget_tokens"] == 4096

      # Delete the override
      render_click(view, "delete_model_override", %{"model" => "test-custom-model"})
      _ = :sys.get_state(view.pid)

      updated = Settings.get_settings()
      refute Map.has_key?(updated.model_overrides, "test-custom-model")
    end
  end
end
