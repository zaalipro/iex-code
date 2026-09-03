defmodule IexCode.Desktop.E2EDesktopCapabilitiesTest do
  use IexCode.E2E.Case, async: false
  @moduletag mock_llm: true
  @moduletag timeout: 120_000

  import ExUnit.CaptureLog

  alias IexCode.Desktop.{ActivityTracker, Dock, Notifier, Sound, SwarmHooks}
  alias IexCode.Execution.ModelRoute
  alias IexCode.LLM.Discovery
  alias IexCode.Observability.{MemoryPoller, MemorySnapshot}
  alias IexCode.Sessions
  alias Phoenix.PubSub

  # Mock HTTP plug simulating Ollama (:11434), LM Studio (:1234), and llama.cpp (:8080)
  defmodule MockLocalInferencePlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      case {conn.method, conn.request_path, conn.port} do
        # Ollama (:11434)
        {"GET", "/api/tags", 11434} ->
          body = %{
            "models" => [
              %{
                "name" => "llama3.2:latest",
                "model" => "llama3.2:latest",
                "size" => 2_019_393_189,
                "details" => %{
                  "parameter_size" => "3.2B",
                  "quantization_level" => "Q4_K_M",
                  "family" => "llama",
                  "format" => "gguf"
                }
              },
              %{
                "name" => "qwen2.5-coder:7b",
                "model" => "qwen2.5-coder:7b",
                "size" => 4_683_074_368,
                "details" => %{
                  "parameter_size" => "7.6B",
                  "quantization_level" => "Q4_K_M",
                  "family" => "qwen2",
                  "format" => "gguf"
                }
              }
            ]
          }

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(body))

        {"GET", "/api/version", 11434} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(%{"version" => "0.5.1"}))

        # LM Studio (:1234)
        {"GET", "/v1/models", 1234} ->
          body = %{
            "object" => "list",
            "data" => [
              %{
                "id" => "qwen2.5-coder-7b-instruct",
                "arch" => "qwen2",
                "quantization" => "Q4_K_M",
                "compatibility_type" => "gguf"
              }
            ]
          }

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(body))

        # llama.cpp (:8080)
        {"GET", "/v1/models", 8080} ->
          body = %{
            "object" => "list",
            "data" => [
              %{
                "id" => "llama-3.2-3b-instruct"
              }
            ]
          }

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(body))

        {"GET", "/health", 8080} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(%{"status" => "ok"}))

        _ ->
          send_resp(conn, 404, "not found")
      end
    end
  end

  setup do
    original_window_id = Application.get_env(:iex_code, :desktop_window_id)
    original_notifications = Application.get_env(:iex_code, :desktop_notifications_enabled)
    original_sound = Application.get_env(:iex_code, :desktop_sound_enabled)

    # Ensure ActivityTracker and Dock start from a clean baseline
    ActivityTracker.clear()
    Dock.clear()

    on_exit(fn ->
      Application.put_env(:iex_code, :desktop_window_id, original_window_id)
      Application.put_env(:iex_code, :desktop_notifications_enabled, original_notifications)
      Application.put_env(:iex_code, :desktop_sound_enabled, original_sound)
      ActivityTracker.clear()
      Dock.clear()
    end)

    :ok
  end

  # ============================================================================
  # Capability 1: Native macOS Desktop Notifications & Sound Cues
  # ============================================================================

  describe "Capability 1: Native macOS Desktop Notifications & Auditory Sound Cues" do
    test "gracefully falls back when desktop window is unstarted or dead without crashing" do
      # Point to an unstarted/non-existent process
      dead_window_id = :"dead_window_#{System.unique_integer([:positive])}"
      Application.put_env(:iex_code, :desktop_window_id, dead_window_id)
      Application.put_env(:iex_code, :desktop_notifications_enabled, true)

      log =
        capture_info_log(fn ->
          assert {:ok, :fallback} =
                   Notifier.notify("Autonomous swarm refactor completed successfully",
                     title: "Swarm Goal Completed",
                     type: :info,
                     sound: :hero
                   )
        end)

      assert log =~ "[Desktop Notification Fallback] [info] Swarm Goal Completed"
      assert log =~ "Autonomous swarm refactor completed successfully"
    end

    test "dispatches genuine Desktop.Window notifications for all 4 lifecycle events with active mock window" do
      test_pid = self()
      {_mock_window, _mock_name} = create_mock_window(test_pid)

      # 1. Swarm completed
      assert {:ok, :swarm_completed} =
               SwarmHooks.dispatch_event(:swarm_completed, %{
                 title: "Implement Auth Flow",
                 id: "run-complete-e2e"
               })

      assert_receive {:"$gen_cast",
                      {:show_notification, "Swarm goal completed: Implement Auth Flow", :default,
                       :info, "Swarm Goal Completed", nil, -1}},
                     1000

      # 2. Verification rejected
      assert {:ok, :verification_rejected} =
               SwarmHooks.dispatch_event(:verification_rejected, %{
                 reason: "Mix test failure in auth_test.exs"
               })

      assert_receive {:"$gen_cast",
                      {:show_notification,
                       "Verification rejected: Mix test failure in auth_test.exs", :default,
                       :warning, "Verification Rejected", nil, -1}},
                     1000

      # 3. Step failed
      assert {:ok, :step_failed} =
               SwarmHooks.dispatch_event(:step_failed, %{
                 title: "Elixir Compilation",
                 error_message: "Syntax error on line 42"
               })

      assert_receive {:"$gen_cast",
                      {:show_notification, "Step failed: Syntax error on line 42", :default,
                       :error, "Swarm Step Failed", nil, -1}},
                     1000

      # 4. Approval requested
      assert {:ok, :approval_requested} =
               SwarmHooks.dispatch_event(:approval_requested, %{
                 action: "git push origin main",
                 reason: "Deploy to production"
               })

      assert_receive {:"$gen_cast",
                      {:show_notification,
                       "Approval needed for git push origin main: Deploy to production", :default,
                       :warning, "Approval Required", nil, -1}},
                     1000

      # Verify SwarmHooks state tracking
      counts = SwarmHooks.get_event_counts()
      assert counts.swarm_completed >= 1
      assert counts.verification_rejected >= 1
      assert counts.step_failed >= 1
      assert counts.approval_requested >= 1
    end

    test "resolves macOS sound cues, verifies files exist on host, and guarantees test silence" do
      # 1. Verify sound resolution for all 4 lifecycle events
      assert Sound.sound_path_for_event(:swarm_completed) =~ "Hero.aiff"
      assert Sound.sound_path_for_event(:verification_rejected) =~ "Sosumi.aiff"
      assert Sound.sound_path_for_event(:step_failed) =~ "Basso.aiff"
      assert Sound.sound_path_for_event(:approval_requested) =~ "Ping.aiff"

      # 2. On macOS host Darwin, verify sound assets actually exist on disk
      if match?({:unix, :darwin}, :os.type()) do
        assert File.exists?(Sound.sound_path_for_event(:swarm_completed))
        assert File.exists?(Sound.sound_path_for_event(:verification_rejected))
        assert File.exists?(Sound.sound_path_for_event(:step_failed))
        assert File.exists?(Sound.sound_path_for_event(:approval_requested))
      end

      # 3. Verify unmuted sound playback is strictly inhibited in test environment
      refute Sound.should_play?(:swarm_completed)
      refute Sound.should_play?(:verification_rejected)
      refute Sound.should_play?(:step_failed)
      refute Sound.should_play?(:approval_requested)

      # 4. Executing Sound.play returns :ok cleanly without unmuted audio output
      assert :ok = Sound.play(:swarm_completed)
      assert :ok = Sound.play(:verification_rejected)
      assert :ok = Sound.play(:step_failed)
      assert :ok = Sound.play(:approval_requested)
    end

    test "reacts to swarm PubSub lifecycle broadcasts and updates internal hook metrics" do
      # Broadcast real-world PubSub lifecycle events
      PubSub.broadcast(
        IexCode.PubSub,
        "swarm:lifecycle",
        {:swarm_completed, %{title: "Autonomous Benchmark Pass"}}
      )

      _ = :sys.get_state(Process.whereis(SwarmHooks))

      assert {:swarm_completed, %{title: "Autonomous Benchmark Pass"}, %DateTime{}} =
               SwarmHooks.get_last_event()

      PubSub.broadcast(
        IexCode.PubSub,
        "desktop:events",
        {:error, {:verification_failed, %{reason: "Assertion mismatch"}}}
      )

      _ = :sys.get_state(Process.whereis(SwarmHooks))

      assert {:verification_rejected, %{reason: "Assertion mismatch"}, %DateTime{}} =
               SwarmHooks.get_last_event()
    end
  end

  # ============================================================================
  # Capability 2: Real-Time Memory & Erlang VM Telemetry
  # ============================================================================

  describe "Capability 2: Real-Time Physical Memory & Erlang VM Telemetry Poller" do
    test "MemoryPoller samples genuine OS RSS, BEAM memory allocators, and process counts" do
      snapshot = MemoryPoller.current_metrics()

      assert is_struct(snapshot, MemorySnapshot)
      assert is_integer(snapshot.rss_bytes) and snapshot.rss_bytes >= 0
      assert is_integer(snapshot.beam_total_bytes) and snapshot.beam_total_bytes > 0
      assert is_integer(snapshot.beam_processes_bytes) and snapshot.beam_processes_bytes > 0
      assert is_integer(snapshot.beam_system_bytes) and snapshot.beam_system_bytes > 0
      assert is_integer(snapshot.process_count) and snapshot.process_count > 0
      assert is_integer(snapshot.gc_runs) and snapshot.gc_runs >= 0
      assert is_integer(snapshot.gc_words_reclaimed) and snapshot.gc_words_reclaimed >= 0
      assert is_struct(snapshot.timestamp, DateTime)

      # Byte formatting helper produces clean human-readable representations
      assert MemorySnapshot.format_bytes(512) == "512 B"
      assert MemorySnapshot.format_bytes(1024 * 1024 * 64) == "64.0 MB"
      assert MemorySnapshot.format_bytes(1024 * 1024 * 1024 * 2) == "2.0 GB"
    end

    test "LiveView renders memory telemetry footer status pill and updates via PubSub in real time",
         %{
           conn: conn,
           workspace_path: path
         } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # 1. Verify presence of footer status container and memory pill
      assert has_element?(view, "#workspace-status-footer")
      assert has_element?(view, "#memory-telemetry-pill")
      assert has_element?(view, "#memory-rss-stat")
      assert has_element?(view, "#memory-beam-stat")
      assert has_element?(view, "#memory-procs-stat")

      # 2. Broadcast simulated memory snapshot over PubSub
      simulated_snapshot = %MemorySnapshot{
        rss_bytes: 85_000_000,
        beam_total_bytes: 45_000_000,
        beam_processes_bytes: 22_000_000,
        beam_system_bytes: 23_000_000,
        beam_atom_bytes: 1_200_000,
        beam_binary_bytes: 4_500_000,
        beam_ets_bytes: 3_100_000,
        process_count: 92,
        gc_runs: 150,
        gc_words_reclaimed: 60_000,
        delta_gc_runs: 7,
        delta_reclaimed_bytes: 98_304,
        timestamp: DateTime.utc_now()
      }

      PubSub.broadcast(
        IexCode.PubSub,
        "telemetry:memory",
        {:memory_telemetry, simulated_snapshot}
      )

      _ = :sys.get_state(view.pid)

      # 3. Assert stats update in the rendered LiveView HTML
      rss_text = element(view, "#memory-rss-stat") |> render()
      beam_text = element(view, "#memory-beam-stat") |> render()
      procs_text = element(view, "#memory-procs-stat") |> render()

      assert rss_text =~ "81.1 MB"
      assert beam_text =~ "42.9 MB"
      assert procs_text =~ "92"
      assert has_element?(view, "#memory-gc-delta-stat")
      assert element(view, "#memory-gc-delta-stat") |> render() =~ "+7 GC"

      # 4. Verify memory popover card with micro-GC breakdown
      assert has_element?(view, "#memory-popover-card")
      assert has_element?(view, "#memory-breakdown-processes")
      assert has_element?(view, "#memory-breakdown-system")
      assert has_element?(view, "#memory-gc-runs")

      # 5. Interactive Force GC button triggers garbage collection
      render_click(view, "force_gc")
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#memory-telemetry-pill")
    end
  end

  # ============================================================================
  # Capability 3: Dynamic macOS Dock Icon Badging & Window Title
  # ============================================================================

  describe "Capability 3: Dynamic macOS Dock Icon Badging & Window Title Updates" do
    test "pure calculation helpers format window title and dock badges accurately" do
      # Window title formatting
      assert Dock.compute_title(0, 0) == "IexCode - Desktop AI Coding Harness"
      assert Dock.compute_title(3, 1) == "IexCode - 3 running, 1 waiting"
      assert Dock.compute_title(1, 0) == "IexCode - 1 running, 0 waiting"
      assert Dock.compute_title(0, 2) == "IexCode - 0 running, 2 waiting"
      assert Dock.compute_title(-1, -2) == "IexCode - Desktop AI Coding Harness"

      # Dock badge formatting
      assert Dock.compute_badge(0, 0) == ""
      assert Dock.compute_badge(3, 1) == "3R/1W"
      assert Dock.compute_badge(4, 0) == "4"
      assert Dock.compute_badge(0, 2) == "2"
      assert Dock.compute_badge(-5, -5) == ""
    end

    test "ActivityTracker updates running workers and waiting approvals with set idempotency" do
      # 1. Track workers
      assert :ok = ActivityTracker.track_worker_start("worker-agent-1")
      assert :ok = ActivityTracker.track_worker_start("worker-agent-2")
      assert :ok = ActivityTracker.track_worker_start("worker-agent-3")

      # Idempotent start: duplicate start of worker-agent-1 does not inflate count
      assert :ok = ActivityTracker.track_worker_start("worker-agent-1")

      assert %{running: 3, waiting: 0} = ActivityTracker.get_counts()

      # 2. Track approval request
      assert :ok = ActivityTracker.track_approval_request("gate-approval-alpha")
      assert %{running: 3, waiting: 1} = ActivityTracker.get_counts()

      # 3. Dock reflects ActivityTracker state
      dock_state = Dock.get_activity()
      assert dock_state.running == 3
      assert dock_state.waiting == 1
      assert dock_state.badge == "3R/1W"
      assert dock_state.title == "IexCode - 3 running, 1 waiting"

      # 4. Resolve approval
      assert :ok = ActivityTracker.track_approval_resolve("gate-approval-alpha")
      assert %{running: 3, waiting: 0} = ActivityTracker.get_counts()

      # 5. Finish worker
      assert :ok = ActivityTracker.track_worker_finish("worker-agent-1")
      assert %{running: 2, waiting: 0} = ActivityTracker.get_counts()

      dock_state2 = Dock.get_activity()
      assert dock_state2.running == 2
      assert dock_state2.waiting == 0
      assert dock_state2.badge == "2"
      assert dock_state2.title == "IexCode - 2 running, 0 waiting"
    end

    test "Dock sets native window title via cast and updates LiveView page title synchronously",
         %{
           conn: conn,
           workspace_path: path
         } do
      test_pid = self()
      {_mock_window, _mock_name} = create_mock_window(test_pid)

      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Update Dock activity
      Dock.set_activity(3, 1)

      # 1. Verify native window title was cast to mock window
      assert_receive {:"$gen_cast", {:set_title, "IexCode - 3 running, 1 waiting"}}, 1000

      # 2. Verify LiveView page title synchronized via PubSub
      _ = :sys.get_state(view.pid)
      assert page_title(view) == "IexCode - 3 running, 1 waiting"

      # Clear Dock
      Dock.clear()
      assert_receive {:"$gen_cast", {:set_title, "IexCode - Desktop AI Coding Harness"}}, 1000
      _ = :sys.get_state(view.pid)
      assert page_title(view) == "IexCode - Desktop AI Coding Harness"
    end
  end

  # ============================================================================
  # Capability 4: Zero-Config Local LLM Auto-Discovery & Zero-Key Routing
  # ============================================================================

  describe "Capability 4: Zero-Config Local LLM Auto-Discovery & Zero-Key Routing" do
    test "Discovery.scan/1 discovers Ollama, LM Studio, and llama.cpp models concurrently" do
      scan_results = Discovery.scan(plug: MockLocalInferencePlug)

      # 1. Ollama on :11434
      assert %{online?: true, models: ollama_models, port: 11434, version: "0.5.1"} =
               scan_results.ollama

      assert length(ollama_models) == 2
      llama = Enum.find(ollama_models, &(&1.id == "llama3.2:latest"))
      assert llama.provider == "ollama"
      assert llama.parameter_size == "3.2B"
      assert llama.quantization == "Q4_K_M"

      # 2. LM Studio on :1234
      assert %{online?: true, models: lm_models, port: 1234} = scan_results.lm_studio
      assert length(lm_models) == 1
      qwen = hd(lm_models)
      assert qwen.id == "qwen2.5-coder-7b-instruct"
      assert qwen.provider == "lm_studio"

      # 3. llama.cpp on :8080
      assert %{online?: true, models: cpp_models, port: 8080} = scan_results.llama_cpp
      assert length(cpp_models) == 1
      cpp = hd(cpp_models)
      assert cpp.id == "llama-3.2-3b-instruct"
      assert cpp.provider == "llama_cpp"
    end

    test "closed local port fails fast without blocking or crashing" do
      # Target a closed port on loopback with a tight timeout
      target = %{
        id: "offline_engine",
        name: "Offline Engine",
        port: 59998,
        base_url: "http://localhost:59998/v1",
        probe_url: "http://localhost:59998/v1/models",
        version_url: nil
      }

      {elapsed_us, result} =
        :timer.tc(fn ->
          Discovery.probe_target(target, connect_timeout: 100, receive_timeout: 100)
        end)

      # Fast non-blocking fail (< 500ms)
      assert elapsed_us < 500_000
      assert result.online == false
      assert result.models == []
      assert result.error != nil
    end

    test "discovered local models appear in LiveView model picker and update session on selection",
         %{
           conn: conn,
           workspace_path: path
         } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Open model picker dropdown
      render_click(view, "toggle_dropdown", %{"name" => "model"})
      assert has_element?(view, "#model-picker-listbox")

      # Broadcast discovered local models over PubSub topic "llm:discovery"
      local_models = [
        %{
          id: "llama3.2:latest",
          name: "llama3.2:latest",
          provider: "ollama",
          server_name: "Ollama",
          port: 11434,
          base_url: "http://localhost:11434/v1",
          parameter_size: "3.2B",
          quantization: "Q4_K_M",
          size_bytes: 2_019_393_189,
          format: "gguf"
        },
        %{
          id: "qwen2.5-coder-7b",
          name: "qwen2.5-coder-7b",
          provider: "lm_studio",
          server_name: "LM Studio",
          port: 1234,
          base_url: "http://localhost:1234/v1",
          parameter_size: "7.6B",
          quantization: "Q4_K_M",
          size_bytes: nil,
          format: "gguf"
        }
      ]

      PubSub.broadcast(
        IexCode.PubSub,
        "llm:discovery",
        {:local_models_discovered, local_models}
      )

      _ = :sys.get_state(view.pid)

      # Local models rendered in dropdown
      html = render(view)
      assert html =~ "Local Offline Models"
      assert html =~ "llama3.2:latest"
      assert html =~ "qwen2.5-coder-7b"

      # 1-click select local Ollama model
      render_click(view, "change_model", %{
        "provider" => "ollama",
        "model" => "llama3.2:latest"
      })

      # Verify session updated in database
      updated_session = Sessions.get_session!(session.id)
      assert updated_session.model_provider == "ollama"
      assert updated_session.model_name == "llama3.2:latest"
    end

    test "zero-config ModelRoute resolves local providers with 'local' key without requiring API key" do
      # 1. Ollama zero-config resolution
      ollama_policy = %{"model_provider" => "ollama", "model_name" => "llama3.2:latest"}
      assert {:ok, ollama_route} = ModelRoute.resolve(ollama_policy, %{})
      assert ollama_route["provider"] == "ollama"
      assert ollama_route["model"] == "llama3.2:latest"
      assert ollama_route["api_key"] == "local"
      assert ollama_route["base_url"] == "http://localhost:11434/v1"

      # 2. LM Studio zero-config resolution
      lms_policy = %{"model_provider" => "lm_studio", "model_name" => "qwen2.5-coder-7b"}
      assert {:ok, lms_route} = ModelRoute.resolve(lms_policy, %{})
      assert lms_route["provider"] == "lm_studio"
      assert lms_route["model"] == "qwen2.5-coder-7b"
      assert lms_route["api_key"] == "local"
      assert lms_route["base_url"] == "http://localhost:1234/v1"

      # 3. llama.cpp zero-config resolution
      cpp_policy = %{"model_provider" => "llama_cpp", "model_name" => "default"}
      assert {:ok, cpp_route} = ModelRoute.resolve(cpp_policy, %{})
      assert cpp_route["provider"] == "llama_cpp"
      assert cpp_route["model"] == "default"
      assert cpp_route["api_key"] == "local"
      assert cpp_route["base_url"] == "http://localhost:8080/v1"

      # 4. Local loopback endpoint detection
      assert Discovery.is_local_endpoint?("http://localhost:11434/v1")
      assert Discovery.is_local_endpoint?("http://127.0.0.1:1234/v1")
      assert Discovery.is_local_endpoint?("http://0.0.0.0:8080/v1")
      refute Discovery.is_local_endpoint?("https://api.openai.com/v1")
    end
  end

  # ============================================================================
  # End-to-End Unified Swarm Lifecycle with Desktop Capabilities
  # ============================================================================

  describe "Unified End-to-End Swarm Lifecycle with All Desktop Capabilities" do
    test "exercises complete desktop-integrated swarm lifecycle seamlessly", %{
      conn: conn,
      workspace_path: path
    } do
      test_pid = self()
      {_mock_window, _mock_name} = create_mock_window(test_pid)

      # 1. Mount LiveView workspace
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # 2. Verify initial memory telemetry footer pill is live
      assert has_element?(view, "#workspace-status-footer")
      assert has_element?(view, "#memory-telemetry-pill")

      # 3. Local LLM Discovery surfaces local models and user selects Ollama llama3.2:latest
      PubSub.broadcast(
        IexCode.PubSub,
        "llm:discovery",
        {:local_models_discovered,
         [
           %{
             id: "llama3.2:latest",
             name: "llama3.2:latest",
             provider: "ollama",
             server_name: "Ollama",
             port: 11434,
             base_url: "http://localhost:11434/v1",
             parameter_size: "3.2B",
             quantization: "Q4_K_M",
             size_bytes: 2_019_393_189,
             format: "gguf"
           }
         ]}
      )

      _ = :sys.get_state(view.pid)

      render_click(view, "change_model", %{
        "provider" => "ollama",
        "model" => "llama3.2:latest"
      })

      updated_session = Sessions.get_session!(session.id)
      assert updated_session.model_provider == "ollama"
      assert updated_session.model_name == "llama3.2:latest"

      # 4. Swarm execution begins: 2 workers start running
      ActivityTracker.track_worker_start("swarm-worker-1")
      ActivityTracker.track_worker_start("swarm-worker-2")

      assert_receive {:"$gen_cast", {:set_title, "IexCode - 2 running, 0 waiting"}}, 1000
      _ = :sys.get_state(view.pid)
      assert page_title(view) == "IexCode - 2 running, 0 waiting"
      assert Dock.get_activity().badge == "2"

      # 5. Worker requests human approval for security-sensitive action
      ActivityTracker.track_approval_request("gate-approval-deploy")

      assert_receive {:"$gen_cast", {:set_title, "IexCode - 2 running, 1 waiting"}}, 1000
      _ = :sys.get_state(view.pid)
      assert page_title(view) == "IexCode - 2 running, 1 waiting"
      assert Dock.get_activity().badge == "2R/1W"

      # SwarmHooks dispatches approval notification
      SwarmHooks.dispatch_event(:approval_requested, %{
        action: "mix ecto.migrate",
        reason: "Apply schema migrations to production database"
      })

      assert_receive {:"$gen_cast",
                      {:show_notification,
                       "Approval needed for mix ecto.migrate: Apply schema migrations to production database",
                       :default, :warning, "Approval Required", nil, -1}},
                     1000

      # 6. User grants approval, approval gate resolves
      ActivityTracker.track_approval_resolve("gate-approval-deploy")

      assert_receive {:"$gen_cast", {:set_title, "IexCode - 2 running, 0 waiting"}}, 1000
      _ = :sys.get_state(view.pid)
      assert page_title(view) == "IexCode - 2 running, 0 waiting"

      # 7. Swarm completes successfully, SwarmHooks dispatches completion notification
      SwarmHooks.dispatch_event(:swarm_completed, %{
        title: "Full Codebase Refactor and Verification"
      })

      assert_receive {:"$gen_cast",
                      {:show_notification,
                       "Swarm goal completed: Full Codebase Refactor and Verification", :default,
                       :info, "Swarm Goal Completed", nil, -1}},
                     1000

      # 8. All workers finish and Dock clears to idle
      ActivityTracker.track_worker_finish("swarm-worker-1")
      ActivityTracker.track_worker_finish("swarm-worker-2")

      assert_receive {:"$gen_cast", {:set_title, "IexCode - Desktop AI Coding Harness"}}, 1000
      _ = :sys.get_state(view.pid)
      assert page_title(view) == "IexCode - Desktop AI Coding Harness"
      assert Dock.get_activity().badge == ""

      # 9. Trigger Force GC on LiveView memory telemetry pill
      render_click(view, "force_gc")
      _ = :sys.get_state(view.pid)
      assert has_element?(view, "#memory-telemetry-pill")
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp create_mock_window(test_pid) do
    mock_window =
      spawn_link(fn ->
        mock_receiver(test_pid)
      end)

    mock_name = :"mock_desktop_window_#{System.unique_integer([:positive])}"
    Process.register(mock_window, mock_name)
    Application.put_env(:iex_code, :desktop_window_id, mock_name)
    Application.put_env(:iex_code, :desktop_notifications_enabled, true)

    {mock_window, mock_name}
  end

  defp mock_receiver(forward_to) do
    receive do
      msg ->
        send(forward_to, msg)
        mock_receiver(forward_to)
    end
  end

  defp capture_info_log(fun) do
    prev = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log(fun)
    after
      Logger.configure(level: prev)
    end
  end
end
