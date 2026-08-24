defmodule IexCodeWeb.WorkspaceLiveAsyncRunsTest do
  use IexCode.E2E.Case, async: false

  alias IexCode.Runs

  setup %{conn: conn} do
    {:ok, conn: %{conn | host: "localhost"}}
  end

  test "queues a durable background run and renders its replayable control plane", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    view |> element("#tab-btn-swarm") |> render_click()

    assert has_element?(view, "#async-run-control")
    assert has_element?(view, "#async-runs-empty")
    assert has_element?(view, "#dispatch-mode-background")
    assert render(view) =~ "Durable mode"

    view
    |> form("#prompt-form", %{"prompt" => "Audit concurrency and produce a safe patch"})
    |> render_submit()

    [run] = Runs.list_runs(session_id: session.id)
    assert run.status == "queued"
    assert run.kind == "coding_swarm"
    assert run.mode == "swarm"
    refute Map.has_key?(run.metadata, "research")
    assert run.event_sequence >= 3

    assert Enum.map(Runs.list_steps(run), &{&1.key, &1.status}) == [
             {"prepare", "ready"},
             {"execute", "pending"}
           ]

    assert has_element?(view, "#async-run-#{run.id}")
    assert has_element?(view, "#async-run-detail")
    assert has_element?(view, "#async-run-step-#{hd(Runs.list_steps(run)).id}")
    assert has_element?(view, "#run-event-#{Runs.latest_event(run).id}")
    refute has_element?(view, "#async-run-research-manifest")
  end

  test "interactive mode keeps the legacy live-session path explicit", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    view |> element("#dispatch-mode-interactive") |> render_click()

    assert has_element?(view, "#dispatch-mode-interactive")
    assert render(view) =~ "Interactive mode"
    assert Runs.list_runs(session_id: session.id) == []
  end

  test "persists a configured deep-research mission and renders its manifest", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    view |> element("#toggle-run-setup") |> render_click()
    assert has_element?(view, "#run-setup-panel")

    view
    |> form("#run-setup-panel", %{
      "run_setup" => %{
        "mode" => "research",
        "priority" => "high",
        "max_attempts" => "4",
        "token_budget" => "25000",
        "cost_budget_cents" => "500",
        "time_budget_minutes" => "45",
        "research_depth" => "deep",
        "research_max_sources" => "18",
        "providers" => %{"duckduckgo" => "true"}
      }
    })
    |> render_change()

    view
    |> form("#prompt-form", %{"prompt" => "/research compare durable agent control planes"})
    |> render_submit()

    [run] = Runs.list_runs(session_id: session.id)
    assert run.kind == "deep_research"
    assert run.mode == "research"
    assert run.priority == "high"
    assert run.max_attempts == 4
    assert run.token_budget == 25_000
    assert run.cost_budget_cents == 500
    assert run.time_budget_ms == 2_700_000

    assert run.metadata["research"]["mode"] == "research"
    assert run.metadata["research"]["depth"] == "deep"
    assert run.metadata["research"]["max_sources"] == 18
    assert "duckduckgo" in run.metadata["research"]["providers"]

    assert Enum.map(Runs.list_steps(run), & &1.key) == [
             "prepare",
             "execute",
             "research.plan",
             "research.search",
             "research.fetch",
             "research.synthesize"
           ]

    assert has_element?(view, "#async-run-research-manifest")
    assert has_element?(view, "#async-run-token-budget[data-budget-limit='25000']")
    assert has_element?(view, "#async-run-cost-budget", "Cost · reported only")
  end

  test "requires an explicit provider for a deep-research mission", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    view |> element("#toggle-run-setup") |> render_click()

    view
    |> form("#run-setup-panel", %{
      "run_setup" => %{
        "mode" => "research",
        "providers" =>
          Map.new(~w(tavily brave exa serper google bing searxng duckduckgo), &{&1, "false"})
      }
    })
    |> render_change()

    refute has_element?(view, "#run-setup-provider-duckduckgo[checked]")

    view
    |> form("#prompt-form", %{"prompt" => "/research durable agent control planes"})
    |> render_submit()

    assert has_element?(view, "#run-setup-panel")
    assert Runs.list_runs(session_id: session.id) == []
  end

  test "rejects selecting a durable run from another session", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)
    other_session = create_session_fixture(project)

    {:ok, foreign_run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: other_session.id,
        objective: "Foreign run",
        kind: "analysis",
        mode: "single"
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    html = render_click(view, "select_async_run", %{"id" => foreign_run.id})

    assert html =~ "Run not found in this session"
    refute has_element?(view, "#async-run-#{foreign_run.id}")
  end

  test "counts pending approvals across the session while keeping detail selection scoped", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, run_with_approval} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Older run awaiting review",
        kind: "analysis",
        mode: "single"
      })

    {:ok, approval} =
      Runs.request_approval(run_with_approval, %{
        key: "approve-older-run",
        action: "workspace_write",
        resource: "lib/example.ex",
        reason: "Review the generated change"
      })

    {:ok, newest_run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Newest run without approvals",
        kind: "analysis",
        mode: "single"
      })

    assert Runs.count_pending_approvals(session.id) == 1

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    view |> element("#tab-btn-swarm") |> render_click()

    view |> element("#async-run-#{newest_run.id}") |> render_click()

    assert has_element?(view, "#async-run-#{newest_run.id}")
    assert has_element?(view, "#async-run-metrics[data-pending-approvals='1']")
    refute has_element?(view, "#async-run-approval-#{approval.id}")

    assert {:ok, _decided} =
             Runs.decide_approval(approval, "denied", %{
               decided_by: "test-user",
               decision_note: "Not approved"
             })

    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#async-run-metrics[data-pending-approvals='0']")

    view |> element("#async-run-#{run_with_approval.id}") |> render_click()

    assert has_element?(view, "#async-run-approval-#{approval.id}")
    assert has_element?(view, "#async-run-metrics[data-pending-approvals='0']")
  end

  test "renders honest dispatcher state and accessible asynchronous progress", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Accessible progress run",
        kind: "analysis",
        mode: "single",
        progress: 37
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    view |> element("#tab-btn-swarm") |> render_click()

    assert has_element?(view, "#async-dispatcher-status[role='status']")
    assert has_element?(view, "#async-run-metrics[aria-live='polite']")
    assert has_element?(view, "#async-run-events[role='log'][aria-live='polite']")

    assert has_element?(
             view,
             "#async-run-#{run.id} [role='progressbar'][aria-valuenow='37'][aria-valuemin='0'][aria-valuemax='100']"
           )

    offline_html =
      render_component(&IexCodeWeb.RunComponents.run_control_plane/1,
        runs: [],
        run_count: 0,
        run_counts: %{active: 0, queued: 0, attention: 0, approvals: 0},
        selected_run: nil,
        steps: [],
        events: [],
        approvals: [],
        artifacts: [],
        stats: %{online: false, capacity: 0}
      )

    offline_document = LazyHTML.from_fragment(offline_html)

    assert LazyHTML.query(offline_document, "#async-dispatcher-status") |> LazyHTML.text() =~
             "Dispatcher offline"
  end

  test "renders durable workspace lock ownership and wait state in Mission Control", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{root_path: path})
    session = create_session_fixture(project)

    {:ok, held_run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Hold the project mutation boundary",
        kind: "coding_swarm",
        mode: "swarm",
        status: "running"
      })

    {:ok, waiting_run} =
      Runs.create_run(%{
        project_id: project.id,
        session_id: session.id,
        objective: "Wait for the project mutation boundary",
        kind: "coding_swarm",
        mode: "swarm"
      })

    {:ok, held} =
      Runs.acquire_workspace_lock(%{
        project_id: project.id,
        session_id: session.id,
        run_id: held_run.id,
        owner_id: "mission-control-holder",
        resource_type: "project",
        resource_key: ".",
        mode: "exclusive"
      })

    {:ok, waiting} =
      Runs.acquire_workspace_lock(%{
        project_id: project.id,
        session_id: session.id,
        run_id: waiting_run.id,
        owner_id: "mission-control-waiter",
        resource_type: "project",
        resource_key: ".",
        mode: "exclusive"
      })

    held_lock = hd(held.locks)
    waiting_lock = hd(waiting.locks)
    assert held_lock.status == "held"
    assert waiting_lock.status == "waiting"

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    view |> element("#tab-btn-swarm") |> render_click()
    view |> element("#async-run-#{waiting_run.id}") |> render_click()

    assert has_element?(view, "#workspace-lock-overview[data-lock-state='waiting']")
    assert has_element?(view, "#workspace-lock-details")
    assert has_element?(view, "#workspace-lock-#{held_lock.id}[data-lock-status='held']")
    assert has_element?(view, "#workspace-lock-#{waiting_lock.id}[data-lock-status='waiting']")

    assert has_element?(
             view,
             "#async-run-#{held_run.id}[data-workspace-lock-state='held']"
           )

    assert has_element?(
             view,
             "#async-run-#{waiting_run.id}[data-workspace-lock-state='waiting']"
           )
  end
end
