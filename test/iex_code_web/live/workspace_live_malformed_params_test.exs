defmodule IexCodeWeb.WorkspaceLiveMalformedParamsTest do
  use IexCode.E2E.Case, async: false

  @moduletag mock_llm: true

  test "malformed numeric params never crash workspace event handlers", %{
    conn: conn,
    workspace_path: path
  } do
    project = create_project_fixture(%{name: "Malformed params", root_path: path})
    session = create_session_fixture(project, %{title: "Malformed params"})

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    # Date picker: a valid selection sticks, garbage and out-of-range are ignored.
    render_click(view, "picker_select_day", %{"year" => "2026", "month" => "5", "day" => "6"})
    assert :sys.get_state(view.pid).socket.assigns.selected_calendar_date == "2026-05-06"

    render_click(view, "picker_select_day", %{"year" => "nope", "month" => "xx", "day" => "yy"})
    render_click(view, "picker_select_day", %{"year" => "2026", "month" => "99", "day" => "99"})
    assert :sys.get_state(view.pid).socket.assigns.selected_calendar_date == "2026-05-06"

    # Command palette: garbage index closes the palette instead of crashing.
    render_click(view, "command_palette_select_item", %{"index" => "not-an-index"})
    assert :sys.get_state(view.pid).socket.assigns.show_command_palette == false

    # Autofix: garbage index reports not-found instead of crashing.
    assert render_click(view, "autofix_failure", %{"index" => "bogus"}) =~
             "not found in current test results"

    # Symbol jump: garbage line flashes instead of crashing.
    assert render_click(view, "jump_to_symbol", %{"path" => "mix.exs", "line" => "NaN"}) =~
             "Invalid line number"

    # Quick settings: garbage budget flashes instead of crashing.
    assert render_click(
             view,
             "quick_update_settings",
             %{"key" => "default_thinking_budget", "value" => "unlimited"}
           ) =~ "Invalid thinking budget value"

    # Test runner file mode: garbage line is treated as absent, view survives.
    render_click(
      view,
      "run_tests",
      %{"mode" => "file", "file" => "test/missing_test.exs", "line" => "abc"}
    )

    # Workspace workflow launch: unknown ids flash instead of crashing.
    assert render_click(view, "launch_workflow_from_workspace", %{"id" => "not-a-uuid"}) =~
             "Workflow not found"

    assert render_click(view, "launch_workflow_from_workspace", %{"id" => Ecto.UUID.generate()}) =~
             "Workflow not found"

    assert is_binary(render(view))
  end
end
