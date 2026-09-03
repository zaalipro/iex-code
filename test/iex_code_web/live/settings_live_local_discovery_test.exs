defmodule IexCodeWeb.SettingsLiveLocalDiscoveryTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true
  @moduletag timeout: 60_000

  alias IexCode.Settings
  alias Phoenix.PubSub

  describe "SettingsLive Local LLM Auto-Discovery" do
    test "renders local LLM section with servers and handles rescan", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      # 1. Verify Local LLM Auto-Discovery section and controls
      assert has_element?(view, "#settings-local-llm-section")

      assert has_element?(
               view,
               "#settings-rescan-local-models-btn[phx-click='rescan_local_models']"
             )

      # Verify server cards exist for all 3 engines
      assert has_element?(view, "#settings-server-card-ollama")
      assert has_element?(view, "#settings-server-card-lm_studio")
      assert has_element?(view, "#settings-server-card-llama_cpp")

      # Verify ports are displayed
      html = render(view)
      assert html =~ ":11434"
      assert html =~ ":1234"
      assert html =~ ":8080"

      # Verify select options include local providers
      assert has_element?(view, "#settings-default-model-provider option[value='ollama']")
      assert has_element?(view, "#settings-default-model-provider option[value='lm_studio']")
      assert has_element?(view, "#settings-default-model-provider option[value='llama_cpp']")

      # 2. Trigger rescan via click
      render_click(view, "rescan_local_models")
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#settings-local-llm-section")

      # 3. Test 1-click 'use_local_model' action
      render_click(view, "use_local_model", %{
        "provider" => "ollama",
        "model" => "llama3.2:latest"
      })

      settings = Settings.get_settings()
      assert settings.default_model_provider == "ollama"
      assert settings.default_model == "llama3.2:latest"

      # 4. Test PubSub broadcast update
      PubSub.broadcast(
        IexCode.PubSub,
        "llm:discovery",
        {:local_models_discovered, []}
      )

      _ = :sys.get_state(view.pid)
      assert has_element?(view, "#settings-server-card-ollama")
    end
  end
end
