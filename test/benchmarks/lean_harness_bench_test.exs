defmodule IexCode.LeanHarnessBenchTest do
  use IexCode.DataCase, async: false

  alias IexCode.Test.LeanHarnessCollector
  alias IexCode.Test.{LeanHarnessLLM, LeanHarnessProvider}
  alias IexCode.{Projects, Repo, Runs, Sessions, Tools}
  alias IexCode.Engine.AgentLoop

  setup do
    handlers = collector_handlers()

    on_exit(fn ->
      assert collector_handlers() -- handlers == []
    end)

    on_exit(fn ->
      Enum.each(collector_handlers() -- handlers, &:telemetry.detach/1)
    end)

    suffix =
      System.unique_integer([:positive]) |> Integer.to_string() |> String.pad_leading(20, "0")

    root = Path.join(System.tmp_dir!(), "lean-bench-#{suffix}")
    File.mkdir_p!(root)
    {:ok, root} = IexCode.WorkspacePath.resolve(root, "")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, project} = Projects.create_project(%{name: "Synthetic benchmark", root_path: root})

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Synthetic benchmark",
        model_provider: "openai",
        model_name: "fixture-model"
      })

    %{root: root, project: project, session: session}
  end

  test "collector counts actual SQLite selections and detaches after measurement" do
    collector = LeanHarnessCollector.start()

    assert {:ok, %{rows: [[1]]}} =
             Ecto.Adapters.SQL.query(IexCode.Repo, "SELECT 1", [])

    metrics = LeanHarnessCollector.finish(collector)
    assert metrics.query_count == 1
    assert metrics.selected_rows == 1
    assert metrics.wall_us >= 0
    assert metrics.process_memory_before_bytes > 0
    assert metrics.vm_memory_after_bytes > 0

    assert [] ==
             Enum.filter(:telemetry.list_handlers([:iex_code, :repo, :query]), fn handler ->
               handler.id == collector.handler
             end)
  end

  for {scenario, history, chunks} <- [
        {"short_single", 0, 4},
        {"short_single_many_chunks", 0, 64},
        {"long_history_small", 40, 64},
        {"long_history_large", 2_000, 64}
      ] do
    @tag timeout: 30_000
    test "#{scenario}: real durable single with local Req/SSE", context do
      history = unquote(history)
      chunks = unquote(chunks)
      seed_history(context.session.id, history)
      run = running_run(context)
      fixture = provider(chunks: chunks)
      Process.put(:lean_fixture, Map.put(fixture, :receiver, self()))

      {result, metrics} = LeanHarnessCollector.measure(fn -> execute(run, context.root) end)
      assert {:ok, %{content: content, turns: 1}} = result
      assert content == String.duplicate("fixture ", chunks)
      assert_receive {:lean_request, request}
      assert_receive {:lean_callbacks, callbacks}
      assert callbacks.text_callback_count == chunks
      assert callbacks.request_message_rows <= 20
      assert metrics.loaded_message_rows > 0
      assert metrics.loaded_message_rows <= 20

      LeanHarnessCollector.emit(
        unquote(scenario),
        %{
          history_rows: history,
          sse_text_events: chunks,
          tool_allowlist: ["read_file"],
          output_reserve: 128
        },
        metrics
        |> Map.merge(request)
        |> Map.merge(callbacks)
        |> Map.merge(%{
          final_output_bytes: byte_size(content),
          first_visible_text_us: nil,
          first_visible_text_availability:
            "unavailable: no UI subscription in fixture; original durable callback discards text",
          provider_reported_tokens: nil,
          provider_usage_availability: "unavailable: synthetic SSE contains no usage",
          retained_ui_rows: nil
        })
      )

      {replay, replay_metrics} =
        LeanHarnessCollector.measure(fn -> execute(run, context.root) end)

      assert {:ok, %{replayed?: true, message_id: message_id}} = replay
      assert message_id == elem(result, 1).message_id
      assert replay_metrics.loaded_message_rows == 2
      refute_receive {:lean_request, _request}

      LeanHarnessCollector.emit(
        unquote(scenario) <> "_final_replay",
        %{history_rows: history, provider_calls: 0},
        replay_metrics
      )
    end
  end

  for lines <- [16_000, 128_000] do
    test "tool-heavy files: #{lines} lines and 600 eligible candidates", context do
      lines = unquote(lines)
      content = String.duplicate("needle synthetic fixture content\n", lines)
      File.write!(Path.join(context.root, "large.txt"), content)
      File.mkdir_p!(Path.join(context.root, "search"))

      for n <- 1..600 do
        name = n |> Integer.to_string() |> String.pad_leading(4, "0")

        File.write!(
          Path.join(context.root, "search/#{name}.txt"),
          String.duplicate("needle synthetic match\n", 20)
        )
      end

      for directory <- ["deps", "_build", "node_modules", ".git"] do
        File.mkdir_p!(Path.join(context.root, "search/#{directory}/nested"))
        File.write!(Path.join(context.root, "search/#{directory}/nested/ignored.txt"), content)
      end

      {{:ok, read}, read_metrics} =
        LeanHarnessCollector.measure(fn ->
          Tools.execute("read_file", %{"path" => "large.txt"}, context.root)
        end)

      assert read =~ "1: needle synthetic fixture content"
      assert length(String.split(read, "\n")) <= 802

      {{:ok, grep}, grep_metrics} =
        LeanHarnessCollector.measure(fn ->
          Tools.execute("grep_search", %{"query" => "needle", "path" => "search"}, context.root)
        end)

      assert length(Regex.scan(~r/^search\/\d+\.txt:\d+:/m, grep)) == 100
      assert grep =~ "incomplete"
      refute grep =~ "ignored.txt"
      assert read_metrics.scanned_bytes == 32_768
      assert grep_metrics.eligible_files == 10
      assert grep_metrics.scanned_bytes == 4_600

      parameters = %{
        large_file_lines: lines,
        large_file_bytes: byte_size(content),
        eligible_files: 600,
        matches_per_file: 20,
        excluded_nested_files: 4
      }

      LeanHarnessCollector.emit(
        "file_read",
        parameters,
        Map.merge(read_metrics, %{
          output_bytes: byte_size(read),
          output_lines: length(String.split(read, "\n")),
          scanned_bytes: read_metrics.scanned_bytes,
          scan_availability: "aggregate native scan telemetry; includes fixed chunk read-ahead"
        })
      )

      LeanHarnessCollector.emit(
        "file_grep",
        parameters,
        Map.merge(grep_metrics, %{
          output_bytes: byte_size(grep),
          output_matches: length(Regex.scan(~r/^search\/\d+\.txt:\d+:/m, grep)),
          scanned_bytes: grep_metrics.scanned_bytes,
          visited_files: grep_metrics.eligible_files,
          scan_availability: "aggregate native scan telemetry; no paths or content"
        })
      )
    end
  end

  test "cancelled provider cannot persist a successful final answer", context do
    run = running_run(context)
    fixture = provider(chunks: 64)

    Process.put(
      :lean_fixture,
      Map.merge(fixture, %{receiver: self(), cancel_after: 1, run_id: run.id})
    )

    {result, metrics} = LeanHarnessCollector.measure(fn -> execute(run, context.root) end)
    assert {:error, :cancelled} = result
    assert_receive {:lean_request, request}
    assert_receive {:lean_callbacks, callbacks}
    assert Runs.get_run!(run.id).cancellation_requested_at
    refute Enum.any?(Sessions.list_messages(context.session.id), &(&1.role == "assistant"))

    LeanHarnessCollector.emit(
      "cancelled_provider",
      %{sse_text_events: 64, cancel_after_callback: 1},
      metrics
      |> Map.merge(request)
      |> Map.merge(callbacks)
      |> Map.put(:first_visible_text_us, nil)
    )
  end

  test "silent provider cancellation is observed when controlled silence is released", context do
    run = running_run(context)
    fixture = provider(chunks: 1, silent: true)
    receiver = self()
    supervisor = start_supervised!({Task.Supervisor, []})

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Process.put(:lean_fixture, Map.put(fixture, :receiver, receiver))
        LeanHarnessCollector.measure(fn -> execute(run, context.root) end)
      end)

    assert_receive {:lean_silent_ready, server}, 5_000
    assert {:ok, _} = Runs.request_cancellation(run)
    send(server, :release)
    assert {{:error, :cancelled}, metrics} = Task.await(task, 5_000)
    assert_receive {:lean_request, request}
    assert_receive {:lean_callbacks, callbacks}
    assert callbacks.text_callback_count == 0
    assert callbacks.first_text_callback_us == nil
    refute Enum.any?(Sessions.list_messages(context.session.id), &(&1.role == "assistant"))

    LeanHarnessCollector.emit(
      "silent_provider",
      %{sse_text_events: 1, release: "after durable cancellation"},
      metrics
      |> Map.merge(request)
      |> Map.merge(callbacks)
      |> Map.merge(%{
        first_visible_text_us: nil,
        silence_cleanup_availability:
          "not measured: original cancellation is polled only when data arrives; silence explicitly released"
      })
    )
  end

  test "collector detaches even if a measured operation raises" do
    before_handlers = :telemetry.list_handlers([:iex_code, :repo, :query])

    assert_raise RuntimeError, "synthetic collector failure", fn ->
      LeanHarnessCollector.measure(fn -> raise "synthetic collector failure" end)
    end

    assert :telemetry.list_handlers([:iex_code, :repo, :query]) == before_handlers
  end

  test "benchmark teardown detaches a collector whose owner is killed" do
    supervisor = start_supervised!({Task.Supervisor, []})
    receiver = self()

    {:ok, owner} =
      Task.Supervisor.start_child(supervisor, fn ->
        LeanHarnessCollector.measure(fn ->
          send(receiver, {:collector_started, self()})

          receive do
            :release -> :ok
          end
        end)
      end)

    monitor = Process.monitor(owner)
    assert_receive {:collector_started, ^owner}
    assert length(collector_handlers()) == 2
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}
  end

  defp collector_handlers do
    for %{id: id} <-
          :telemetry.list_handlers([:iex_code, :repo, :query]) ++
            :telemetry.list_handlers([:iex_code, :tools, :native_scan]),
        is_tuple(id) and elem(id, 0) == LeanHarnessCollector,
        do: id
  end

  defp provider(opts) do
    sync = start_supervised!({Agent, fn -> nil end})

    server =
      start_supervised!(
        {Bandit,
         plug:
           {LeanHarnessProvider,
            opts |> Keyword.put(:receiver, self()) |> Keyword.put(:sync, sync)},
         port: 0,
         ip: :loopback,
         startup_log: false}
      )

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)
    %{url: "http://127.0.0.1:#{port}", sync: sync}
  end

  defp seed_history(_session_id, 0), do: :ok

  defp seed_history(session_id, count) do
    now = ~U[2026-01-01 00:00:00Z]

    rows =
      for n <- 1..count do
        %{
          id: Ecto.UUID.generate(),
          session_id: session_id,
          role: if(rem(n, 2) == 0, do: "assistant", else: "user"),
          content:
            "Synthetic history #{String.pad_leading(Integer.to_string(n), 4, "0")}: " <>
              String.duplicate("context ", 32),
          inserted_at: DateTime.add(now, n - count - 1, :second),
          updated_at: now
        }
      end

    Repo.insert_all(Sessions.Message, rows)
  end

  defp running_run(context) do
    {:ok, _} =
      Runs.create_run(%{
        project_id: context.project.id,
        session_id: context.session.id,
        objective: "Report the synthetic fixture.",
        kind: "coding_agent",
        mode: "single",
        metadata: %{
          "execution_policy" => %{
            "agent_max_turns" => 2,
            "allowed_tools" => ["read_file"],
            "max_tokens" => 128
          }
        }
      })

    {:ok, run} = Runs.claim_next_run("lean-bench", lease_ms: 300_000)
    run
  end

  defp execute(run, root) do
    AgentLoop.execute(run, root, fn _, _ -> :ok end,
      llm: LeanHarnessLLM,
      run_lease_owner: run.lease_owner,
      run_attempt: run.attempt,
      run_lease_generation: run.lease_generation,
      run_terminal_lease_ms: 30_000
    )
  end
end
