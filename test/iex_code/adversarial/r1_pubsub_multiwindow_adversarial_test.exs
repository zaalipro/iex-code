defmodule IexCode.Adversarial.R1PubSubMultiWindowAdversarialTest do
  @moduledoc """
  Adversarial stress testing for Requirement R1:
  - High-concurrency message broadcasting across detached window topics
  - Deadlock immunity and delivery consistency across multiple subscribers
  - Concurrent WindowManager operations (open, hide, list, query)
  - Config boundaries and error handling for detached window lifecycles
  """

  use IexCode.DataCase, async: false

  alias IexCode.Desktop.WindowManager
  alias Phoenix.PubSub

  setup do
    session_id = "sess_adv_win_#{System.unique_integer([:positive])}"
    project_id = "proj_adv_win_#{System.unique_integer([:positive])}"
    {:ok, session_id: session_id, project_id: project_id}
  end

  describe "ADV_R1_01: Massive Concurrent PubSub Stress Across Detached Window Topics" do
    test "delivers 1,000 messages across 4 detached topics to 8 subscribers with zero loss and zero deadlocks",
         %{session_id: session_id, project_id: project_id} do
      topic_terminal = "session:#{session_id}:terminal"
      topic_git = "project:#{project_id}:git"
      topic_runs = "runs:session:#{session_id}"
      topic_session = "session:#{session_id}"

      pubsub = IexCode.PubSub

      # Spawn 8 subscriber processes
      # 2 subscribed to terminal
      # 2 subscribed to git
      # 2 subscribed to runs
      # 2 subscribed to all 4 topics
      subscriber_specs = [
        {:sub_term_1, [topic_terminal]},
        {:sub_term_2, [topic_terminal]},
        {:sub_git_1, [topic_git]},
        {:sub_git_2, [topic_git]},
        {:sub_runs_1, [topic_runs]},
        {:sub_runs_2, [topic_runs]},
        {:sub_omni_1, [topic_terminal, topic_git, topic_runs, topic_session]},
        {:sub_omni_2, [topic_terminal, topic_git, topic_runs, topic_session]}
      ]

      parent = self()

      subscriber_pids =
        Enum.map(subscriber_specs, fn {name, topics} ->
          pid =
            spawn_link(fn ->
              Enum.each(topics, &PubSub.subscribe(pubsub, &1))
              send(parent, {:ready, name, self()})
              message_collector_loop([], topics)
            end)

          assert_receive {:ready, ^name, ^pid}, 1000
          {name, pid, topics}
        end)

      # Concurrently broadcast 1,000 messages (250 per topic) via 20 worker tasks
      messages_per_topic = 250
      topics = [topic_terminal, topic_git, topic_runs, topic_session]

      work_items =
        for topic <- topics,
            seq <- 1..messages_per_topic do
          {topic, seq}
        end

      # Execute broadcasts concurrently with Task.async_stream
      work_items
      |> Task.async_stream(
        fn {topic, seq} ->
          PubSub.broadcast!(pubsub, topic, {:adversarial_event, topic, seq})
        end,
        max_concurrency: 20,
        timeout: 10_000
      )
      |> Stream.run()

      # Give short synchronization window
      _ = :sys.get_state(pubsub)

      # Request tally from all subscribers
      for {name, pid, topics} <- subscriber_pids do
        send(pid, {:get_count, self()})

        assert_receive {:count_report, ^pid, count}, 5000

        expected_count =
          Enum.reduce(topics, 0, fn t, acc ->
            case t do
              ^topic_terminal -> acc + messages_per_topic
              ^topic_git -> acc + messages_per_topic
              ^topic_runs -> acc + messages_per_topic
              ^topic_session -> acc + messages_per_topic
              _ -> acc
            end
          end)

        assert count == expected_count,
               "Subscriber #{name} lost messages: expected #{expected_count}, got #{count}"
      end

      # Terminate subscribers cleanly
      for {_name, pid, _topics} <- subscriber_pids do
        send(pid, :stop)
      end
    end
  end

  describe "ADV_R1_02: Concurrent WindowManager Lifecycle & Race Conditions" do
    test "handles 30 concurrent open, hide, list, and query operations without crash",
         %{session_id: session_id} do
      tools = [:terminal, :diff, :dag]

      operations =
        for _ <- 1..30 do
          tool = Enum.random(tools)
          action = Enum.random([:open, :hide, :list, :alive])
          {action, tool}
        end

      results =
        operations
        |> Task.async_stream(
          fn
            {:open, tool} -> WindowManager.open_window(tool, session_id)
            {:hide, tool} -> WindowManager.hide_window(tool)
            {:list, _} -> WindowManager.list_windows()
            {:alive, tool} -> WindowManager.window_alive?(tool)
          end,
          max_concurrency: 15,
          timeout: 5_000
        )
        |> Enum.to_list()

      assert length(results) == 30

      for {:ok, res} <- results do
        case res do
          {:ok, :web, path} -> assert is_binary(path)
          {:ok, :native, _id} -> :ok
          :ok -> :ok
          status_map when is_map(status_map) -> assert map_size(status_map) == 3
          bool when is_boolean(bool) -> :ok
          other -> flunk("Unexpected WindowManager result: #{inspect(other)}")
        end
      end
    end
  end

  describe "ADV_R1_03: WindowManager Configuration & Boundary Contracts" do
    test "correctly rejects unknown tools and returns proper error tuples", %{
      session_id: session_id
    } do
      assert {:error, :unknown_tool} = WindowManager.open_window(:non_existent_tool, session_id)
      assert {:error, :unknown_tool} = WindowManager.hide_window(:non_existent_tool)
      assert false == WindowManager.window_alive?(:non_existent_tool)
      assert nil == WindowManager.window_id(:non_existent_tool)
    end

    test "maintains valid configuration contracts for all 3 detached tools" do
      configs = WindowManager.window_configs()

      assert Map.has_key?(configs, :terminal)
      assert Map.has_key?(configs, :diff)
      assert Map.has_key?(configs, :dag)

      for tool <- [:terminal, :diff, :dag] do
        cfg = Map.fetch!(configs, tool)
        assert is_atom(cfg.id)
        assert is_binary(cfg.title)
        assert {w, h} = cfg.size
        assert is_integer(w) and is_integer(h)
        assert {min_w, min_h} = cfg.min_size
        assert min_w <= w and min_h <= h
        assert is_binary(cfg.slug)
      end
    end

    test "generates clean window URLs and relative paths with session ID", %{
      session_id: session_id
    } do
      assert WindowManager.window_path(:terminal, session_id) ==
               "/sessions/#{session_id}/detached/terminal"

      assert WindowManager.window_path(:diff, session_id) ==
               "/sessions/#{session_id}/detached/diff"

      assert WindowManager.window_path(:dag, session_id) ==
               "/sessions/#{session_id}/detached/dag"

      full_url = WindowManager.window_url(:terminal, session_id)
      assert String.ends_with?(full_url, "/sessions/#{session_id}/detached/terminal")
    end
  end

  # Helper collector process loop
  defp message_collector_loop(collected, topics) do
    receive do
      {:adversarial_event, _topic, _seq} = msg ->
        message_collector_loop([msg | collected], topics)

      {:get_count, caller} ->
        send(caller, {:count_report, self(), length(collected)})
        message_collector_loop(collected, topics)

      :stop ->
        :ok
    after
      15_000 -> :ok
    end
  end
end
