defmodule IexCodeWeb.Components.CommandPaletteComponentTest do
  use IexCodeWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias IexCodeWeb.WorkspaceComponents

  describe "WorkspaceComponents.command_palette/1 visibility and shell" do
    test "renders only controller container when show is false" do
      rendered =
        render_component(&WorkspaceComponents.command_palette/1, %{
          show: false,
          query: "",
          category: "all",
          results: [],
          selected_index: 0
        })

      assert rendered =~ ~s(id="command-palette-controller")
      assert rendered =~ ~s(phx-hook="CommandPalette")
      refute rendered =~ ~s(id="command-palette-modal")
      refute rendered =~ ~s(id="command-palette-dialog")
    end

    test "renders modal dialog with split pane layout and ARIA attributes when show is true" do
      rendered =
        render_component(&WorkspaceComponents.command_palette/1, %{
          show: true,
          query: "",
          category: "all",
          results: [],
          selected_index: 0
        })

      assert rendered =~ ~s(id="command-palette-modal")
      assert rendered =~ ~s(id="command-palette-dialog")
      assert rendered =~ ~s(role="dialog")
      assert rendered =~ ~s(aria-modal="true")
      assert rendered =~ ~s(aria-labelledby="command-palette-title")
      assert rendered =~ ~s(aria-describedby="command-palette-description")
      assert rendered =~ ~s(max-w-5xl)

      # ARIA Combobox input
      assert rendered =~ ~s(id="command-palette-input")
      assert rendered =~ ~s(role="combobox")
      assert rendered =~ ~s(aria-autocomplete="list")
      assert rendered =~ ~s(aria-expanded="true")
      assert rendered =~ ~s(aria-controls="command-palette-results")

      # Listbox and Preview Containers (Split Pane)
      assert rendered =~ ~s(id="command-palette-results")
      assert rendered =~ ~s(role="listbox")
      assert rendered =~ ~s(id="command-palette-preview")
      assert rendered =~ "w-7/12"
      assert rendered =~ "w-5/12"
    end

    test "renders all 9 category filter pills with correct aria-pressed status" do
      for active_cat <- [
            "all",
            "actions",
            "swarms",
            "files",
            "models",
            "branches",
            "terminal",
            "views",
            "sessions"
          ] do
        rendered =
          render_component(&WorkspaceComponents.command_palette/1, %{
            show: true,
            query: "",
            category: active_cat,
            results: [],
            selected_index: 0
          })

        # All 9 category values are present
        assert rendered =~ ~s(phx-value-category="all")
        assert rendered =~ ~s(phx-value-category="actions")
        assert rendered =~ ~s(phx-value-category="swarms")
        assert rendered =~ ~s(phx-value-category="files")
        assert rendered =~ ~s(phx-value-category="models")
        assert rendered =~ ~s(phx-value-category="branches")
        assert rendered =~ ~s(phx-value-category="terminal")
        assert rendered =~ ~s(phx-value-category="views")
        assert rendered =~ ~s(phx-value-category="sessions")

        # Active category has aria-pressed="true"
        assert rendered =~ ~s(phx-value-category="#{active_cat}" aria-pressed="true")
      end
    end

    test "renders empty search state and keyboard hints" do
      rendered =
        render_component(&WorkspaceComponents.command_palette/1, %{
          show: true,
          query: "unmatched_pattern",
          category: "all",
          results: [],
          selected_index: 0
        })

      assert rendered =~ ~s(No results found for "unmatched_pattern")
      assert rendered =~ "Try searching with prefixes:"
      assert rendered =~ "actions"
      assert rendered =~ "files"
      assert rendered =~ "swarms"
      assert rendered =~ "models"
      assert rendered =~ "branches"
      assert rendered =~ "terminal"

      # Footer navigation hint chips
      assert rendered =~ "Navigate"
      assert rendered =~ "Select"
      assert rendered =~ "Close"
      assert rendered =~ "Cmd+K"
      assert rendered =~ "Cmd+B"
      assert rendered =~ "Cmd+J"
    end
  end

  describe "WorkspaceComponents.command_palette/1 rich preview cards" do
    test "renders :file rich preview card with size, lines, syntax badge, and preview snippet" do
      file_item = %{
        id: "file_lib/foo.ex",
        category: :file,
        title: "foo.ex",
        subtitle: "lib/foo.ex",
        icon: "hero-code-bracket",
        path: "lib/foo.ex",
        preview: %{
          category: :file,
          path: "lib/foo.ex",
          filename: "foo.ex",
          ext: ".ex",
          size: 2048,
          lines: 42,
          syntax: "Elixir",
          preview_lines: [
            {1, "defmodule Foo do"},
            {2, "  def bar, do: :ok"},
            {3, "end"}
          ]
        }
      }

      rendered =
        render_component(&WorkspaceComponents.command_palette/1, %{
          show: true,
          query: "foo",
          category: "files",
          results: [file_item],
          selected_index: 0
        })

      assert rendered =~ ~s(id="palette-preview-file")
      assert rendered =~ "foo.ex"
      assert rendered =~ "lib/foo.ex"
      assert rendered =~ "Elixir"
      assert rendered =~ "2.0 KB"
      assert rendered =~ "42 lines"
      assert rendered =~ "Syntax Preview"
      assert rendered =~ "defmodule Foo do"
      assert rendered =~ "def bar, do: :ok"
    end

    test "renders :swarm rich preview card with status, mode, workers, tokens, and progress bar" do
      swarm_item = %{
        id: "swarm_run-123",
        category: :swarm,
        title: "Implement Parallel Parser",
        subtitle: "Status: running • Mode: swarm • 65% complete",
        icon: "hero-sparkles",
        run_id: "run-123",
        preview: %{
          category: :swarm,
          run_id: "run-123",
          status: "running",
          mode: "swarm",
          objective: "Implement Parallel Parser",
          progress: 65,
          tokens: 14250,
          active_agents: 4
        }
      }

      rendered =
        render_component(&WorkspaceComponents.command_palette/1, %{
          show: true,
          query: "parser",
          category: "swarms",
          results: [swarm_item],
          selected_index: 0
        })

      assert rendered =~ ~s(id="palette-preview-swarm")
      assert rendered =~ "Implement Parallel Parser"
      assert rendered =~ "running"
      assert rendered =~ "swarm"
      assert rendered =~ "4 Workers"
      assert rendered =~ "14250"
      assert rendered =~ "65%"
      assert rendered =~ ~s(style="width: 65%;")
      assert rendered =~ "Swarm Telemetry canvas"
    end

    test "renders :model rich preview card with provider, endpoint, local/cloud flag, and status" do
      local_model = %{
        id: "model_llama3",
        category: :model,
        title: "Llama 3 8B",
        subtitle: "ollama • Local Offline",
        icon: "hero-cpu-chip",
        model_id: "llama3",
        provider: "ollama",
        preview: %{
          category: :model,
          name: "Llama 3 8B",
          model_id: "llama3",
          provider: "ollama",
          endpoint: "http://localhost:11434",
          local?: true,
          status: :online
        }
      }

      cloud_model = %{
        id: "model_claude-3-7-sonnet",
        category: :model,
        title: "Claude 3.7 Sonnet",
        subtitle: "anthropic • Cloud API",
        icon: "hero-cpu-chip",
        model_id: "claude-3-7-sonnet",
        provider: "anthropic",
        preview: %{
          category: :model,
          name: "Claude 3.7 Sonnet",
          model_id: "claude-3-7-sonnet",
          provider: "anthropic",
          endpoint: "api.anthropic.com",
          local?: false,
          status: :online
        }
      }

      rendered_local =
        render_component(&WorkspaceComponents.command_palette/1, %{
          show: true,
          query: "llama",
          category: "models",
          results: [local_model],
          selected_index: 0
        })

      assert rendered_local =~ ~s(id="palette-preview-model")
      assert rendered_local =~ "Llama 3 8B"
      assert rendered_local =~ "Provider: ollama"
      assert rendered_local =~ "Local Offline"
      assert rendered_local =~ "http://localhost:11434"
      assert rendered_local =~ "Online"

      rendered_cloud =
        render_component(&WorkspaceComponents.command_palette/1, %{
          show: true,
          query: "claude",
          category: "models",
          results: [cloud_model],
          selected_index: 0
        })

      assert rendered_cloud =~ ~s(id="palette-preview-model")
      assert rendered_cloud =~ "Claude 3.7 Sonnet"
      assert rendered_cloud =~ "Provider: anthropic"
      assert rendered_cloud =~ "Cloud Endpoint"
      assert rendered_cloud =~ "api.anthropic.com"
    end

    test "renders :branch rich preview card with branch name, HEAD pointer, and upstream" do
      branch_item = %{
        id: "branch_feature/palette-v2",
        category: :branch,
        title: "feature/palette-v2",
        subtitle: "Current branch • origin/feature/palette-v2",
        icon: "hero-code-bracket",
        branch: "feature/palette-v2",
        preview: %{
          category: :branch,
          name: "feature/palette-v2",
          current?: true,
          upstream: "origin/feature/palette-v2",
          head_commit: "HEAD"
        }
      }

      rendered =
        render_component(&WorkspaceComponents.command_palette/1, %{
          show: true,
          query: "palette",
          category: "branches",
          results: [branch_item],
          selected_index: 0
        })

      assert rendered =~ ~s(id="palette-preview-branch")
      assert rendered =~ "feature/palette-v2"
      assert rendered =~ "Current HEAD"
      assert rendered =~ "origin/feature/palette-v2"
      assert rendered =~ "refs/heads/feature/palette-v2"
      assert rendered =~ "checkout and switch to this branch"
    end

    test "renders :terminal rich preview card with command, description, and cwd" do
      terminal_item = %{
        id: "terminal_mix precommit",
        category: :terminal,
        title: "mix precommit",
        subtitle: "Run format, compile, unlock, test verification",
        icon: "hero-command-line",
        command: "mix precommit",
        preview: %{
          category: :terminal,
          command: "mix precommit",
          description: "Run format, compile, unlock, test verification",
          directory: "/path/to/project"
        }
      }

      rendered =
        render_component(&WorkspaceComponents.command_palette/1, %{
          show: true,
          query: "precommit",
          category: "terminal",
          results: [terminal_item],
          selected_index: 0
        })

      assert rendered =~ ~s(id="palette-preview-terminal")
      assert rendered =~ "mix precommit"
      assert rendered =~ "Run format, compile, unlock, test verification"
      assert rendered =~ "/path/to/project"
      assert rendered =~ "execute command in terminal shell"
    end

    test "renders :action rich preview card with shortcut, description, and target tab" do
      action_item = %{
        id: "run_all_tests",
        category: :action,
        title: "Run All Tests",
        subtitle: "Execute full ExUnit suite with progress",
        icon: "hero-beaker",
        shortcut: "Cmd+T",
        event: "run_tests",
        preview: %{
          category: :action,
          shortcut: "Cmd+T",
          description: "Execute full ExUnit suite with live test progress and result streaming",
          target_tab: "tests",
          event: "run_tests"
        }
      }

      rendered =
        render_component(&WorkspaceComponents.command_palette/1, %{
          show: true,
          query: "tests",
          category: "actions",
          results: [action_item],
          selected_index: 0
        })

      assert rendered =~ ~s(id="palette-preview-action")
      assert rendered =~ "Run All Tests"
      assert rendered =~ "Shortcut: Cmd+T"
      assert rendered =~ "Target: tests"
      assert rendered =~ ~s[handle_event("run_tests")]
      assert rendered =~ "execute this action"
    end

    test "renders :view rich preview card with target workspace tab destination" do
      view_item = %{
        id: "view_swarm",
        category: :view,
        title: "Coach & Swarm Telemetry",
        subtitle: "Live agent cards, iteration progress & reasoning",
        icon: "hero-sparkles",
        tab: "swarm",
        shortcut: "",
        preview: %{
          category: :view,
          shortcut: "",
          description: "Live visual swarm canvas, supervisor steering, and agent telemetry feeds",
          target_tab: "swarm"
        }
      }

      rendered =
        render_component(&WorkspaceComponents.command_palette/1, %{
          show: true,
          query: "telemetry",
          category: "views",
          results: [view_item],
          selected_index: 0
        })

      assert rendered =~ ~s(id="palette-preview-view")
      assert rendered =~ "Coach" and rendered =~ "Swarm Telemetry"
      assert rendered =~ ~s(active_tab: "swarm")
      assert rendered =~ "switch directly to this workspace view"
    end

    test "renders :session rich preview card with assigned model, message count, and last activity" do
      session_item = %{
        id: "session_sess-123",
        category: :session,
        title: "Auth Module Redesign",
        subtitle: "Updated Sep 03, 14:00",
        icon: "hero-document-text",
        session_id: "sess-123",
        preview: %{
          category: :session,
          session_id: "sess-123",
          title: "Auth Module Redesign",
          subtitle: "Updated Sep 03, 14:00",
          message_count: 18,
          model: "claude-3-7-sonnet",
          updated_at: "Updated Sep 03, 14:00"
        }
      }

      rendered =
        render_component(&WorkspaceComponents.command_palette/1, %{
          show: true,
          query: "auth",
          category: "sessions",
          results: [session_item],
          selected_index: 0
        })

      assert rendered =~ ~s(id="palette-preview-session")
      assert rendered =~ "Auth Module Redesign"
      assert rendered =~ "Session ID: sess-123"
      assert rendered =~ "claude-3-7-sonnet"
      assert rendered =~ "18 items"
      assert rendered =~ "Updated Sep 03, 14:00"
      assert rendered =~ "load session dialogue"
    end
  end
end
