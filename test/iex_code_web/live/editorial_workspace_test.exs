defmodule IexCodeWeb.EditorialWorkspaceTest do
  @moduledoc """
  Direction B stage B3: editorial workspace surfaces (display heroes, broken
  grid, feature plates, settings index) render only under the editorial theme
  and leave every workflow/settings interaction functional.
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
            description: "Stages the B3 broken grid.",
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

  test "workflows gallery renders hero, note, and live counts", %{
    conn: conn,
    project: project,
    session: session
  } do
    use_editorial_theme()
    workflow = create_workflow_fixture(project)

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/workflows")

    assert has_element?(view, "#workflows-editorial-hero")
    assert has_element?(view, "#workflows-editorial-hero-title", "Every pipeline")
    assert has_element?(view, "#workflows-editorial-hero .ed-hero-kicker", "Execution library")

    assert view
           |> element("#workflows-editorial-hero .ed-hero-meta")
           |> render() =~ "pipelines"

    assert has_element?(view, "#workflows-editorial-note")
    assert has_element?(view, "#workflows-editorial-note .ed-pullquote", "speaks once")

    # Existing gallery functionality stays rendered around the new surfaces.
    assert has_element?(view, "#workflows-gallery-header")
    assert has_element?(view, "#workflows-overview")
    assert has_element?(view, "#workflows-search-form")
    assert has_element?(view, "#workflow-card-#{workflow.id}")
    assert has_element?(view, "#btn-launch-#{workflow.id}")
  end

  test "workflows search still morphs the card list under the broken grid", %{
    conn: conn,
    project: project,
    session: session
  } do
    use_editorial_theme()
    workflow = create_workflow_fixture(project)

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/workflows")

    view
    |> form("#workflows-search-form", %{"query" => "no-matching-pipeline"})
    |> render_change()

    assert has_element?(view, "#workflows-empty-state")
    refute has_element?(view, "#workflow-card-#{workflow.id}")
    assert has_element?(view, "#workflows-editorial-hero")

    view
    |> form("#workflows-search-form", %{"query" => "Editorial"})
    |> render_change()

    assert has_element?(view, "#workflow-card-#{workflow.id}")
    refute has_element?(view, "#workflows-empty-state")
  end

  test "settings renders hero and chapter index with working tab patches", %{
    conn: conn,
    session: session
  } do
    use_editorial_theme()

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/settings/providers")

    assert has_element?(view, "#settings-editorial-hero")
    assert has_element?(view, "#settings-editorial-hero-title", "Tune the")
    assert has_element?(view, "#settings-editorial-hero .ed-hero-kicker", "Studio index")

    for {tab_id, hint} <- [
          {"providers", "live ping"},
          {"reasoning", "budgets"},
          {"safety", "tiers"},
          {"context", "compaction"},
          {"environment", "sandbox"},
          {"appearance", "density"}
        ] do
      assert view
             |> element("#tab-link-#{tab_id} .ed-chapter-hint")
             |> render() =~ hint
    end

    # The index rows stay working patch links.
    view |> element("#tab-link-reasoning") |> render_click()

    assert_patch(view, "/sessions/#{session.id}/settings/reasoning")
    assert has_element?(view, "#tab-panel-reasoning:not(.hidden)")
    assert has_element?(view, "#tab-link-reasoning[aria-current='page']")
    assert has_element?(view, "#settings-editorial-hero")
  end

  test "non-editorial themes render no hero, note, or chapter hints", %{
    conn: conn,
    project: project,
    session: session
  } do
    create_workflow_fixture(project)

    {:ok, workflows_view, _html} = live(conn, ~p"/sessions/#{session.id}/workflows")

    refute has_element?(workflows_view, "#workflows-editorial-hero")
    refute has_element?(workflows_view, "#workflows-editorial-note")
    assert has_element?(workflows_view, "#workflows-gallery-header")

    {:ok, settings_view, _html} = live(conn, ~p"/sessions/#{session.id}/settings/providers")

    refute has_element?(settings_view, "#settings-editorial-hero")
    refute has_element?(settings_view, ".ed-chapter-hint")
    assert has_element?(settings_view, "#tab-link-providers")
  end
end
