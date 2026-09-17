defmodule IexCodeWeb.EditorialStatesTest do
  @moduledoc """
  Direction B stage B4: editorial states + motion (staggered entries, skeleton
  loaders, composed empty states, inline form errors) render only under the
  editorial theme and leave every workflow/settings/workspace interaction
  functional.
  """
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true

  alias IexCode.Settings
  alias IexCode.Workflows

  setup %{workspace_path: path} do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    %{project: project, session: session}
  end

  defp use_editorial_theme do
    {:ok, settings} = Settings.update_settings(%{ui_theme: "editorial"})
    assert settings.ui_theme == "editorial"
  end

  defp create_workflow_fixture(project, attrs \\ %{}) do
    {:ok, workflow} =
      Workflows.create_workflow(
        Map.merge(
          %{
            project_id: project.id,
            name: "Editorial Pipeline",
            slug: "editorial-pipeline-#{System.unique_integer([:positive])}",
            description: "Stages the B4 states layer.",
            tags: ["autonomous"],
            steps: [
              %{
                "key" => "research",
                "kind" => "deep_research",
                "title" => "Research the grid",
                "depends_on" => [],
                "params" => %{"query" => "broken grid"},
                "model_config" => %{"provider" => "openai", "model_id" => "gpt-4o"},
                "safety_policy" => "read_only"
              }
            ]
          },
          attrs
        )
      )

    workflow
  end

  test "gallery staggers entries and composes the empty shelf", %{
    conn: conn,
    project: project,
    session: session
  } do
    use_editorial_theme()
    workflow = create_workflow_fixture(project)
    {:ok, _run} = Workflows.create_run(workflow, %{status: "running", progress: 10})

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/workflows")

    assert has_element?(view, "#workflows-library-grid.ed-stagger")
    assert has_element?(view, "#workflows-recent-runs tbody.ed-stagger-fade")
    assert has_element?(view, "#workflow-card-#{workflow.id}")

    view
    |> form("#workflows-search-form", %{"query" => "no-matching-pipeline"})
    |> render_change()

    assert has_element?(view, "#workflows-empty-state.ed-empty")
    assert has_element?(view, "#workflows-empty-state .ed-empty-eyebrow", "empty shelf")
    assert has_element?(view, "#workflows-empty-state .ed-empty-title", "No matching workflows")
    refute has_element?(view, "#workflows-empty-state .workflow-observatory")

    assert view
           |> element("#workflows-empty-create")
           |> render() =~ "/workflows/new"

    view
    |> form("#workflows-search-form", %{"query" => "Editorial"})
    |> render_change()

    assert has_element?(view, "#workflows-library-grid.ed-stagger")
    assert has_element?(view, "#workflow-card-#{workflow.id}")
    refute has_element?(view, "#workflows-empty-state")
  end

  test "builder shows the synthesis skeleton and staggered steps", %{
    conn: conn,
    session: session
  } do
    use_editorial_theme()

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/workflows/new")

    assert has_element?(
             view,
             "#blueprint-steps-skeleton[data-ed-skeleton='steps'][role='status'][aria-busy='true']"
           )

    skeleton_html = view |> element("#blueprint-steps-skeleton") |> render()
    assert skeleton_html =~ "ed-skeleton-orb"
    assert skeleton_html =~ "Loading"

    # The default blueprint pre-populates staggered steps.
    assert has_element?(view, ".workflow-step-sequence.ed-stagger")
    assert has_element?(view, "#workflow-configured-step-0")

    # Synthesis still replaces the steps in place.
    view
    |> form("#blueprint-prompt-form", %{"prompt" => "Implement auth with rate limits"})
    |> render_submit()

    assert has_element?(view, "#workflow-configured-step-0", "deep_research")
    assert has_element?(view, "#workflow-configured-step-4", "git_commit")
  end

  test "invalid builder input surfaces inline error hooks", %{conn: conn, session: session} do
    use_editorial_theme()

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/workflows/new")

    view
    |> form("#workflow-config-form", %{
      "workflow" => %{"name" => "Bad Slug Pipeline", "slug" => "BAD SLUG!!!"}
    })
    |> render_change()

    assert has_element?(view, "#workflow-config-form input[aria-invalid='true']")
    assert has_element?(view, "#workflow-config-form .form-error", "has invalid format")
  end

  test "settings index and workspace boards carry stagger hooks", %{
    conn: conn,
    project: project,
    session: session
  } do
    use_editorial_theme()
    create_workflow_fixture(project)

    {:ok, settings_view, _html} = live(conn, ~p"/sessions/#{session.id}/settings/providers")
    assert has_element?(settings_view, "#settings-section-nav.ed-stagger")

    {:ok, workspace_view, _html} = live(conn, ~p"/sessions/#{session.id}")
    assert has_element?(workspace_view, "#kanban-board.ed-stagger")

    workspace_view |> element("#sidebar-tab-workflows") |> render_click()
    assert has_element?(workspace_view, "#workspace-workflows-grid.ed-stagger")
  end

  test "non-editorial themes render no B4 editorial markup", %{
    conn: conn,
    project: project,
    session: session
  } do
    create_workflow_fixture(project)

    {:ok, gallery_view, _html} = live(conn, ~p"/sessions/#{session.id}/workflows")

    gallery_view
    |> form("#workflows-search-form", %{"query" => "no-matching-pipeline"})
    |> render_change()

    assert has_element?(gallery_view, "#workflows-empty-state", "No matching workflows")
    assert has_element?(gallery_view, "#workflows-empty-state .workflow-observatory")
    refute has_element?(gallery_view, ".ed-empty-eyebrow")
    refute has_element?(gallery_view, "#workflows-empty-state.ed-empty")

    {:ok, builder_view, _html} = live(conn, ~p"/sessions/#{session.id}/workflows/new")

    refute has_element?(builder_view, ".ed-submit-shelf")
    refute has_element?(builder_view, "#blueprint-steps-skeleton")
    refute has_element?(builder_view, ".ed-empty")

    # Inline errors are shared behavior, independent of theme.
    builder_view
    |> form("#workflow-config-form", %{
      "workflow" => %{"name" => "Bad Slug Pipeline", "slug" => "BAD SLUG!!!"}
    })
    |> render_change()

    assert has_element?(builder_view, "#workflow-config-form input[aria-invalid='true']")
    assert has_element?(builder_view, "#workflow-config-form .form-error")
  end
end
