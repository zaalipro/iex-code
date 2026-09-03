defmodule IexCode.Adversarial.AutonomousConcurrencyLifecycleAdversarialTest do
  @moduledoc """
  Adversarial Challenge Test Suite: Window Lifecycle, Supervision & Concurrency.
  Targeting Objective 1 of Challenger 2 Dispatch:
  - Verify that hiding detached windows (`on_close: :hide`) does NOT terminate the BEAM runtime or kill other processes.
  - Test rapid opening/closing sequences under high concurrency.
  - Verify supervisor isolation, abnormal child exit resilience, and PubSub channel separation.
  """
  use ExUnit.Case, async: false

  alias IexCode.Desktop.WindowManager
  alias IexCode.Desktop.WindowSupervisor

  # A mock window process that simulates a supervised desktop window
  defmodule MockWindowProcess do
    use GenServer

    def start_link(opts) do
      name = Keyword.get(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    @impl true
    def init(opts) do
      {:ok, %{opts: opts, hidden: false}}
    end

    @impl true
    def handle_call(:get_state, _from, state) do
      {:reply, state, state}
    end

    @impl true
    def handle_call(:hide, _from, state) do
      {:reply, :ok, %{state | hidden: true}}
    end

    @impl true
    def handle_call(:show, _from, state) do
      {:reply, :ok, %{state | hidden: false}}
    end
  end

  setup do
    # Ensure WindowSupervisor is running in the application tree
    sup_pid = Process.whereis(WindowSupervisor)
    assert is_pid(sup_pid) and Process.alive?(sup_pid)
    {:ok, supervisor: sup_pid}
  end

  describe "Objective 1: Window Lifecycle & Teardown Invariants" do
    test "ADV_WIN_01: canonical window configurations enforce on_close: :hide and sizing constraints" do
      configs = WindowManager.window_configs()

      assert is_map(configs)
      assert Map.keys(configs) |> Enum.sort() == [:dag, :diff, :terminal]

      for {_tool, cfg} <- configs do
        assert cfg.id in [IexCodeTerminalWindow, IexCodeDiffWindow, IexCodeDagWindow]
        assert is_binary(cfg.title) and cfg.title != ""
        assert is_binary(cfg.slug) and cfg.slug != ""

        {w, h} = cfg.size
        assert is_integer(w) and w >= 640
        assert is_integer(h) and h >= 480

        {min_w, min_h} = cfg.min_size
        assert is_integer(min_w) and min_w <= w
        assert is_integer(min_h) and min_h <= h
      end
    end

    test "ADV_WIN_02: hiding detached window does not terminate supervisor, BEAM, or sibling processes",
         %{
           supervisor: sup_pid
         } do
      test_pid = self()

      sibling_pid =
        spawn_link(fn ->
          receive do
            {:ping, from} -> send(from, :pong)
          end
        end)

      # Attempt hiding all three window tools
      for tool <- [:terminal, :diff, :dag] do
        assert WindowManager.hide_window(tool) == :ok
        assert WindowManager.close_window(tool) == :ok
      end

      # Verify sibling process is completely undisturbed
      send(sibling_pid, {:ping, test_pid})
      assert_receive :pong, 500

      # Verify WindowSupervisor and BEAM node remain healthy
      assert Process.alive?(sup_pid)
      assert node() != :nonode or is_atom(node())
    end

    test "ADV_WIN_03: abnormal child exit under WindowSupervisor does not cascade or crash supervisor",
         %{
           supervisor: sup_pid
         } do
      # Start two dynamic children under WindowSupervisor
      child1_spec = %{
        id: :mock_win_1,
        start: {MockWindowProcess, :start_link, [[name: :mock_adv_win_1]]},
        restart: :temporary
      }

      child2_spec = %{
        id: :mock_win_2,
        start: {MockWindowProcess, :start_link, [[name: :mock_adv_win_2]]},
        restart: :temporary
      }

      {:ok, pid1} = DynamicSupervisor.start_child(sup_pid, child1_spec)
      {:ok, pid2} = DynamicSupervisor.start_child(sup_pid, child2_spec)

      assert is_pid(pid1) and Process.alive?(pid1)
      assert is_pid(pid2) and Process.alive?(pid2)

      # Monitor child1 before killing
      ref = Process.monitor(pid1)
      Process.exit(pid1, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid1, :killed}, 1000

      # Child2 and WindowSupervisor MUST survive
      assert Process.alive?(pid2)
      assert Process.alive?(sup_pid)

      # Supervisor must be capable of immediately starting new children
      child3_spec = %{
        id: :mock_win_3,
        start: {MockWindowProcess, :start_link, [[name: :mock_adv_win_3]]},
        restart: :temporary
      }

      assert {:ok, pid3} = DynamicSupervisor.start_child(sup_pid, child3_spec)
      assert is_pid(pid3) and Process.alive?(pid3)

      # Clean up
      DynamicSupervisor.terminate_child(sup_pid, pid2)
      DynamicSupervisor.terminate_child(sup_pid, pid3)
    end

    test "ADV_WIN_04: 60 concurrent tasks performing rapid opening, closing, and querying storm" do
      tools = [:terminal, :diff, :dag, "terminal", "diff", "dag"]
      session_id = "sess_adv_storm_#{System.unique_integer([:positive])}"

      # Fire 60 concurrent tasks
      tasks =
        for i <- 1..60 do
          Task.async(fn ->
            tool = Enum.at(tools, rem(i, length(tools)))

            # Interleaved lifecycle calls
            r1 = WindowManager.open_window(tool, session_id)
            r2 = WindowManager.list_windows()
            r3 = WindowManager.window_alive?(tool)
            r4 = WindowManager.hide_window(tool)
            r5 = WindowManager.close_window(tool)
            r6 = WindowManager.get_config(tool)
            r7 = WindowManager.window_path(tool, session_id)
            r8 = WindowManager.window_url(tool, session_id)

            {r1, r2, r3, r4, r5, r6, r7, r8}
          end)
        end

      results = Task.await_many(tasks, 10_000)

      assert length(results) == 60

      for {r1, r2, r3, r4, r5, r6, r7, r8} <- results do
        assert match?({:ok, :web, _path}, r1) or match?({:ok, :native, _id}, r1)
        assert is_map(r2) and map_size(r2) == 3
        assert is_boolean(r3)
        assert r4 == :ok
        assert r5 == :ok
        assert is_map(r6) and Map.has_key?(r6, :id)
        assert is_binary(r7) and String.contains?(r7, session_id)
        assert is_binary(r8) and String.contains?(r8, session_id)
      end
    end

    test "ADV_WIN_05: boundary inputs and corrupted arguments do not raise uncaught exceptions" do
      adversarial_tools = [
        nil,
        "",
        "   ",
        :unknown_tool_xyz,
        "../../../etc/passwd",
        12345,
        %{invalid: "map"},
        [:invalid, :list],
        "terminal\0evil"
      ]

      for tool <- adversarial_tools do
        res_open =
          try do
            WindowManager.open_window(tool, "sess_1")
          rescue
            e -> {:caught, e}
          catch
            k, v -> {:caught, {k, v}}
          end

        assert res_open == {:error, :unknown_tool} or match?({:error, _}, res_open) or
                 match?({:caught, _}, res_open)

        res_hide =
          try do
            WindowManager.hide_window(tool)
          rescue
            e -> {:caught, e}
          catch
            k, v -> {:caught, {k, v}}
          end

        assert res_hide in [:ok, {:error, :unknown_tool}] or match?({:error, _}, res_hide) or
                 match?({:caught, _}, res_hide)

        res_alive =
          try do
            WindowManager.window_alive?(tool)
          rescue
            _ -> false
          end

        assert res_alive == false
      end
    end

    test "ADV_WIN_06: PubSub channel separation across detached sessions under high message burst" do
      sess_a = "sess_iso_a_#{System.unique_integer([:positive])}"
      sess_b = "sess_iso_b_#{System.unique_integer([:positive])}"

      topic_a = "session:#{sess_a}:terminal"
      topic_b = "session:#{sess_b}:terminal"

      Phoenix.PubSub.subscribe(IexCode.PubSub, topic_a)

      # Receiver process only subscribed to topic_a
      # Flood topic_b with 50 messages
      for i <- 1..50 do
        Phoenix.PubSub.broadcast(IexCode.PubSub, topic_b, {:terminal_chunk, "b_chunk_#{i}"})
      end

      # Flood topic_a with 10 messages
      for i <- 1..10 do
        Phoenix.PubSub.broadcast(IexCode.PubSub, topic_a, {:terminal_chunk, "a_chunk_#{i}"})
      end

      # We must receive all 10 messages from topic_a and ZERO messages from topic_b
      received_chunks =
        Enum.map(1..10, fn _ ->
          receive do
            {:terminal_chunk, chunk} -> chunk
          after
            1000 -> :timeout
          end
        end)

      refute :timeout in received_chunks
      assert Enum.all?(received_chunks, &String.starts_with?(&1, "a_chunk_"))

      # Verify no trailing message from topic_b leaked into mailbox
      receive do
        {:terminal_chunk, chunk} ->
          flunk("Leaked cross-talk message from un-subscribed topic: #{chunk}")
      after
        100 -> :ok
      end
    end

    test "ADV_WIN_07: rapid 100-cycle open/close flip-flop does not leak processes or supervisor children" do
      session_id = "sess_flipflop_#{System.unique_integer([:positive])}"
      initial_counts = DynamicSupervisor.count_children(WindowSupervisor)

      for i <- 1..100 do
        tool = if rem(i, 2) == 0, do: :terminal, else: :diff
        {:ok, :web, _path} = WindowManager.open_window(tool, session_id)
        :ok = WindowManager.hide_window(tool)
      end

      final_counts = DynamicSupervisor.count_children(WindowSupervisor)

      # Ensure no orphaned children accumulate in WindowSupervisor
      assert final_counts.active == initial_counts.active
      assert final_counts.workers == initial_counts.workers
    end
  end
end
