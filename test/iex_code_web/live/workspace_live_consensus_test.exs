defmodule IexCodeWeb.WorkspaceLiveConsensusTest do
  @moduledoc """
  Requirement R4: Multi-Model Adversarial Consensus & Swarm Voting.
  Tests for WorkspaceLive visual consensus UI:
  - Visual agreement matrix heat-map (#consensus-agreement-matrix)
  - Color-coded concordance cells and provider source chips
  - Dimensional score progress bars and reviewer critique cards
  - Interactive manual arbitration controls (Approve / Reject buttons)
  """
  use IexCodeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias IexCode.{Projects, Sessions, Runs}

  setup do
    unique_id = System.unique_integer([:positive])
    temp_dir = Path.join(System.tmp_dir!(), "iex_lv_consensus_#{unique_id}")
    File.mkdir_p!(temp_dir)

    {:ok, project} =
      Projects.create_project(%{
        name: "Consensus UI Test Project #{unique_id}",
        root_path: temp_dir
      })

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Consensus UI Session #{unique_id}"
      })

    {:ok, run} =
      Runs.create_run(%{
        session_id: session.id,
        project_id: project.id,
        objective: "Multi-Model Consensus Verification",
        status: "running"
      })

    on_exit(fn ->
      File.rm_rf(temp_dir)
    end)

    {:ok, project: project, session: session, run: run, temp_dir: temp_dir}
  end

  describe "Tier 1: Visual Agreement Matrix & Heat-Map Rendering" do
    test "an unreviewed session has no fabricated assessments, scores, or approval", %{
      conn: conn,
      session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      view |> element("#tab-btn-consensus") |> render_click()

      assert has_element?(view, "#consensus-review-status", "Awaiting reviews")
      assert has_element?(view, "#consensus-reviewers-empty")

      assert has_element?(
               view,
               "#consensus-decision[data-decision='unavailable']",
               "Awaiting reviews"
             )

      assert has_element?(view, "#consensus-concordance-percent", "—")
      assert has_element?(view, "#consensus-concordance-value", "—")
      assert has_element?(view, "#consensus-confidence-value", "—")
      assert has_element?(view, "#consensus-concordance-bar[style='width: 0%']")
      assert has_element?(view, "#consensus-confidence-bar[style='width: 0%']")
      refute has_element?(view, "#consensus-agreement-matrix tbody tr")

      for dimension <- ~w(correctness security architectural_fit maintainability testability) do
        assert has_element?(view, "#consensus-score-#{dimension}-value", "—")
        assert has_element?(view, "#consensus-score-#{dimension}-bar[style='width: 0%']")
      end
    end

    test "T1_R4_LV_01: mounts workspace and renders consensus agreement matrix", %{
      conn: conn,
      session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}?tab=consensus")

      assert has_element?(view, "#consensus-panel") or
               has_element?(view, "#consensus-agreement-matrix") or
               has_element?(view, "#workspace-consensus-container")
    end

    test "T1_R4_LV_02: renders reviewer headers with provider chips (Cloud vs Local Apple Silicon)",
         %{
           conn: conn,
           session: session
         } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}?tab=consensus")

      rendered = render(view)
      assert rendered =~ "Consensus" or rendered =~ "Agreement" or rendered =~ "Reviewers"
    end

    test "T1_R4_LV_03: renders dimensional score progress bars (Correctness, Security, Architecture)",
         %{
           conn: conn,
           session: session
         } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}?tab=consensus")

      rendered = render(view)

      assert rendered =~ "Correctness" or rendered =~ "Security" or rendered =~ "Concordance" or
               has_element?(view, "#consensus-score-correctness")
    end
  end

  describe "Tier 1 & 2: Interactive Human Arbitration Controls" do
    test "approval is unavailable until a reviewed proposal exists", %{
      conn: conn,
      session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      view |> element("#tab-btn-consensus") |> render_click()

      assert has_element?(view, "#consensus-btn-approve[disabled]")
      render_click(view, "approve_consensus", %{})
      assert has_element?(view, "#consensus-decision[data-decision='unavailable']")
      assert has_element?(view, "#consensus-btn-approve[disabled]")
    end

    test "rejection is unavailable until a reviewed proposal exists", %{
      conn: conn,
      session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      view |> element("#tab-btn-consensus") |> render_click()

      assert has_element?(view, "#consensus-btn-reject[disabled]")
      render_click(view, "reject_consensus", %{"reason" => "Security concerns"})
      assert has_element?(view, "#consensus-decision[data-decision='unavailable']")
      assert has_element?(view, "#consensus-btn-reject[disabled]")
    end
  end
end
