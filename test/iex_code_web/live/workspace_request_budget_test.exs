defmodule IexCodeWeb.WorkspaceRequestBudgetTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true

  alias IexCode.{Sessions, Settings}
  alias IexCode.Engine.SessionServer
  alias IexCode.E2E.MockLLMServer

  test "interactive rejected request shows narrowing guidance and no successful answer", ctx do
    provider = start_supervised!({MockLLMServer, scenario: :standard_completion})
    url = GenServer.call(provider, :get_info).url

    {:ok, _} =
      Settings.update_settings(%{
        openai_api_key: "fixture",
        openai_base_url: url <> "/v1",
        max_tokens: 100,
        context_window_tokens: 2_000
      })

    project = create_project_fixture(%{root_path: ctx.workspace_path})

    session =
      create_session_fixture(project, %{
        swarm_mode: false,
        model_provider: "openai",
        model_name: "unknown-budget-fixture"
      })

    server = start_supervised!({SessionServer, session.id})
    {:ok, view, _} = live(ctx.conn, ~p"/sessions/#{session.id}?tab=chat")
    Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")

    assert :ok =
             SessionServer.send_prompt(session.id, String.duplicate("required objective ", 3_000),
               allowed_tools: []
             )

    task = :sys.get_state(server).current_task
    ref = Process.monitor(task)
    assert_receive {:message_created, %{role: "assistant"} = error}, 10_000
    assert_receive {:DOWN, ^ref, :process, ^task, _}, 5_000
    assert_receive {:run_failed, %{reason: reason}}, 5_000
    assert reason =~ "No model request was sent"
    _ = :sys.get_state(server)
    assert has_element?(view, "[data-chat-msg-id='#{error.id}']", "Reduce")
    assert has_element?(view, "[data-chat-msg-id='#{error.id}']", "context budget")
    assert MockLLMServer.get_requests(provider) == []
    assert Sessions.get_session(session.id).status == "failed"
    assert [^error] = Enum.filter(Sessions.list_messages(session.id), &(&1.role == "assistant"))
  end
end
