defmodule IexCode.Engine.SessionServerBoundedHistoryTest do
  use IexCode.DataCase, async: false

  alias IexCode.{Projects, Repo, Sessions, Settings}
  alias IexCode.E2E.MockLLMServer
  alias IexCode.Engine.SessionServer
  alias IexCode.Test.LeanHarnessCollector

  for history_size <- [60, 600] do
    test "interactive history selects at most 50 rows before compaction with #{history_size} rows" do
      provider = start_supervised!({MockLLMServer, scenario: :sse_chunks})
      server = GenServer.call(provider, :get_info)
      root = Path.join(System.tmp_dir!(), "interactive-history-#{Ecto.UUID.generate()}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)

      assert {:ok, _} =
               Settings.update_settings(%{
                 openai_api_key: "fixture-key",
                 openai_base_url: "#{server.url}/v1",
                 anthropic_api_key: nil
               })

      {:ok, project} = Projects.create_project(%{name: "Interactive history", root_path: root})

      {:ok, session} =
        Sessions.create_session(%{
          project_id: project.id,
          title: "Interactive",
          swarm_mode: false,
          model_provider: "openai",
          model_name: "fixture-model"
        })

      timestamp = ~U[2026-01-01 00:00:00Z]

      Repo.insert_all(
        Sessions.Message,
        for n <- 1..unquote(history_size) do
          %{
            id: Ecto.UUID.generate(),
            session_id: session.id,
            role: if(rem(n, 2) == 0, do: "assistant", else: "user"),
            content: "history #{n}",
            inserted_at: DateTime.add(timestamp, n, :second),
            updated_at: timestamp
          }
        end
      )

      Phoenix.PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")
      session_server = start_supervised!({SessionServer, session.id})
      collector = LeanHarnessCollector.start()

      try do
        assert :ok = SessionServer.send_prompt(session.id, "Newest objective", allowed_tools: [])
        state = :sys.get_state(session_server)
        task_monitor = if state.current_task, do: Process.monitor(state.current_task)
        assert_receive {:session_status_changed, "idle"}, 10_000
        if task_monitor, do: assert_receive({:DOWN, ^task_monitor, :process, _, _}, 5_000)
        # Both the task and its owner settle status. Await the owner's DOWN
        # handler so teardown cannot interrupt its final database write.
        assert_receive {:session_status_changed, "idle"}, 5_000
        assert :sys.get_state(session_server).current_task == nil
        metrics = LeanHarnessCollector.finish(collector)
        assert metrics.loaded_message_rows == 50

        assert [%{body: body}] = MockLLMServer.get_requests(provider)
        assert [%{"role" => "system"} | history] = body["messages"]
        assert length(history) == 50

        assert Enum.map(history, & &1["content"]) ==
                 Enum.map((unquote(history_size) - 48)..unquote(history_size), &"history #{&1}") ++
                   ["Newest objective"]
      after
        :telemetry.detach(collector.handler)
      end
    end
  end
end
