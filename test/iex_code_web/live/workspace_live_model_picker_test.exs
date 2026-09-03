defmodule IexCodeWeb.WorkspaceLiveModelPickerTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true
  @moduletag timeout: 60_000

  alias IexCode.Sessions
  alias Phoenix.PubSub

  describe "WorkspaceLive Model Picker Local LLM Integration" do
    test "displays discovered local models and updates session upon selection", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # 1. Open model picker dropdown
      render_click(view, "toggle_dropdown", %{"name" => "model"})
      assert has_element?(view, "#model-picker-listbox")

      # Initially only cloud models exist
      assert has_element?(view, "#model-picker-option-gemini-3\\.7-flash-high")
      assert has_element?(view, "#model-picker-option-gpt-5\\.4-turbo")
      assert has_element?(view, "#model-picker-option-claude-3\\.7-sonnet")

      # 2. Broadcast discovered local models over PubSub topic "llm:discovery"
      local_models = [
        %{
          id: "llama3.2:latest",
          name: "llama3.2:latest",
          provider: "ollama",
          server_name: "Ollama",
          port: 11434,
          base_url: "http://localhost:11434/v1",
          parameter_size: "3.2B",
          quantization: "Q4_K_M",
          size_bytes: 2_019_393_189,
          format: "gguf"
        },
        %{
          id: "qwen2.5-coder-7b",
          name: "qwen2.5-coder-7b",
          provider: "lm_studio",
          server_name: "LM Studio",
          port: 1234,
          base_url: "http://localhost:1234/v1",
          parameter_size: "7.6B",
          quantization: "Q4_K_M",
          size_bytes: nil,
          format: "gguf"
        }
      ]

      PubSub.broadcast(
        IexCode.PubSub,
        "llm:discovery",
        {:local_models_discovered, local_models}
      )

      _ = :sys.get_state(view.pid)

      # 3. Verify local models are rendered in model picker
      html = render(view)
      assert html =~ "Local Offline Models"
      assert html =~ "llama3.2:latest"
      assert html =~ "qwen2.5-coder-7b"
      assert html =~ "Ollama (:11434)"
      assert html =~ "LM Studio (:1234)"
      assert has_element?(view, "#model-picker-rescan-btn")

      # 4. 1-click select local model (llama3.2:latest)
      render_click(view, "change_model", %{
        "provider" => "ollama",
        "model" => "llama3.2:latest"
      })

      # Verify session updated in database
      updated_session = Sessions.get_session!(session.id)
      assert updated_session.model_name == "llama3.2:latest"
      assert updated_session.model_provider == "ollama"

      # 5. Select second local model (qwen2.5-coder-7b)
      render_click(view, "change_model", %{
        "provider" => "lm_studio",
        "model" => "qwen2.5-coder-7b"
      })

      updated_session2 = Sessions.get_session!(session.id)
      assert updated_session2.model_name == "qwen2.5-coder-7b"
      assert updated_session2.model_provider == "lm_studio"

      # 6. Test rescan button trigger
      render_click(view, "rescan_local_models")
      _ = :sys.get_state(view.pid)
    end
  end
end
