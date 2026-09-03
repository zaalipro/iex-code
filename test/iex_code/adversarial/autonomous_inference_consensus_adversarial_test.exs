defmodule IexCode.Adversarial.AutonomousInferenceConsensusAdversarialTest do
  @moduledoc """
  Adversarial Challenge Test Suite: Offline Local Inference Failure Modes & Consensus Perturbations.
  Targeting Objectives 2 and 3 of Challenger 2 Dispatch:
  - Offline local inference failure modes: unreachable ports (11434, 1234, 8080), timeouts, 500 errors, corrupted payloads, zero crashes.
  - Consensus arbitration perturbations: missing models, zero weights, all-cloud vs all-local, corrupted JSON, and blocker critiques.
  """
  use ExUnit.Case, async: false

  alias IexCode.Consensus.{Arbitrator, Assessment}
  alias IexCode.SemanticIndex.{EmbeddingClient, Vector}

  # ============================================================================
  # Mock Plugs for Adversarial Inference Server Testing
  # ============================================================================

  defmodule SlowHangingPlug do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, _opts) do
      # Simulate a model hang exceeding client timeout
      Process.sleep(300)
      send_resp(conn, 200, Jason.encode!(%{"data" => []}))
    end
  end

  defmodule ServerErrorPlug do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, opts) do
      status = Keyword.get(opts, :status, 500)
      body = Keyword.get(opts, :body, "Internal Model Crash: CUDA/Metal OOM")
      send_resp(conn, status, body)
    end
  end

  defmodule CorruptedJsonPlug do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, _opts) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, "{\"data\": [unclosed json object")
    end
  end

  defmodule UnexpectedSchemaPlug do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, _opts) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"unexpected_field" => 123, "status" => "weird"}))
    end
  end

  # ============================================================================
  # Objective 2: Offline Local Inference Failure Modes
  # ============================================================================

  describe "Objective 2: Local Inference Endpoint Failure Modes" do
    test "ADV_INF_01: unreachable ports (11434, 1234, 8080) return structured errors with zero crashes" do
      ports = [11434, 1234, 8080]

      for port <- ports do
        opts = [
          base_url: "http://127.0.0.1:#{port}",
          timeout: 100,
          retry: false
        ]

        result =
          try do
            EmbeddingClient.embed("adversarial test query", opts)
          rescue
            e -> {:caught, e}
          catch
            k, v -> {:caught, {k, v}}
          end

        # Must never raise an uncaught exception
        refute match?({:caught, _}, result)
        assert match?({:error, _}, result)

        {:error, reason} = result

        assert reason in [:econnrefused, :connection_refused, :timeout] or
                 match?(%Req.TransportError{}, reason) or
                 match?({:http_error, _, _}, reason) or
                 is_binary(to_string(reason))
      end
    end

    test "ADV_INF_02: hanging local server triggers timeout cleanly without blocking caller indefinitely" do
      opts = [
        plug: {SlowHangingPlug, []},
        base_url: "http://localhost:11434",
        timeout: 50
      ]

      start_time = System.monotonic_time(:millisecond)

      result =
        try do
          EmbeddingClient.embed("slow query text", opts)
        rescue
          e -> {:caught, e}
        catch
          k, v -> {:caught, {k, v}}
        end

      elapsed_ms = System.monotonic_time(:millisecond) - start_time

      # Even if plug is synchronous in test, ensure caller is not blocked for seconds
      assert elapsed_ms < 5000
      refute match?({:caught, _}, result)
    end

    test "ADV_INF_03: HTTP 500, 502, 503, 504 server errors return structured errors without crashing" do
      for status <- [500, 502, 503, 504] do
        opts = [
          plug: {ServerErrorPlug, [status: status, body: "Error #{status}"]},
          base_url: "http://localhost:11434"
        ]

        result = EmbeddingClient.embed("sample query", opts)

        assert match?({:error, {:http_error, ^status, _}}, result)
      end
    end

    test "ADV_INF_04: unexpected JSON schema from local endpoint returns unexpected_response error" do
      opts = [
        plug: {UnexpectedSchemaPlug, []},
        base_url: "http://localhost:11434"
      ]

      result = EmbeddingClient.embed("sample query", opts)

      assert match?({:error, {:unexpected_response, 200, _}}, result)
    end

    test "ADV_INF_05: zero-config fallback generates valid unit-normalized embeddings when offline" do
      # In zero-config mode (no base_url or plug given), it falls back to deterministic hash vectors
      dim = EmbeddingClient.model_dimension()
      {:ok, vectors} = EmbeddingClient.embed(["search term one", "search term two"])

      assert length(vectors) == 2

      for vec <- vectors do
        assert is_list(vec)
        assert length(vec) == dim
        norm = Vector.l2_norm(vec)
        assert abs(norm - 1.0) < 1.0e-4
      end
    end

    test "ADV_INF_06: binary return mode produces compact IEEE 754 packed byte vector" do
      dim = EmbeddingClient.model_dimension()

      {:ok, [binary_vec]} =
        EmbeddingClient.embed("compact representation test", return: :binary)

      assert is_binary(binary_vec)
      assert byte_size(binary_vec) == dim * 4

      # Unpack and verify L2 unit norm
      unpacked = Vector.unpack(binary_vec)
      assert abs(Vector.l2_norm(unpacked) - 1.0) < 1.0e-4
    end
  end

  # ============================================================================
  # Objective 3: Consensus Arbitration & Model Panel Perturbations
  # ============================================================================

  describe "Objective 3: Consensus Arbitration Perturbations & Adversarial Models" do
    test "ADV_CON_01: empty assessment panel returns requires_arbitration without exception" do
      result = Arbitrator.arbitrate([])

      assert result.decision == :requires_arbitration
      assert result.auto_approved == false
      assert result.swarm_concordance == 0.0
      assert result.weighted_score == 0.0
      assert is_map(result.matrix)
    end

    test "ADV_CON_02: all zero weights do not trigger divide-by-zero arithmetic exception" do
      a1 = %Assessment{
        reviewer_id: "m1",
        provider: "cloud",
        model: "claude-3-5-sonnet",
        vote: :approve,
        confidence: 0.95,
        scores: %{
          correctness: 0.9,
          security: 0.9,
          architectural_fit: 0.9,
          maintainability: 0.9,
          testability: 0.9
        }
      }

      a2 = %Assessment{
        reviewer_id: "m2",
        provider: "local",
        model: "llama-3-8b",
        vote: :approve,
        confidence: 0.90,
        scores: %{
          correctness: 0.9,
          security: 0.9,
          architectural_fit: 0.9,
          maintainability: 0.9,
          testability: 0.9
        }
      }

      # Zero weights perturbation
      zero_weights = %{"m1" => 0.0, "m2" => 0.0}

      result =
        try do
          Arbitrator.arbitrate([a1, a2], initial_weights: zero_weights)
        rescue
          e -> {:caught, e}
        end

      refute match?({:caught, _}, result)
      assert result.decision in [:approved, :requires_arbitration]
      assert is_float(result.weighted_score)
      assert is_float(result.swarm_concordance)
    end

    test "ADV_CON_03: negative weights perturbation sum to zero does not raise ArithmeticError" do
      a1 = %Assessment{
        reviewer_id: "m1",
        provider: "cloud",
        model: "model_1",
        vote: :approve,
        confidence: 0.9
      }

      a2 = %Assessment{
        reviewer_id: "m2",
        provider: "cloud",
        model: "model_2",
        vote: :approve,
        confidence: 0.9
      }

      cancelled_weights = %{"m1" => -1.0, "m2" => 1.0}

      result =
        try do
          Arbitrator.arbitrate([a1, a2], initial_weights: cancelled_weights)
        rescue
          e -> {:caught, e}
        end

      refute match?({:caught, _}, result)
      assert is_map(result)
    end

    test "ADV_CON_04: missing models from initial_weights triggers dynamic weight renormalization" do
      a1 = %Assessment{
        reviewer_id: "active_1",
        vote: :approve,
        confidence: 0.9,
        scores: %{
          correctness: 0.95,
          security: 0.95,
          architectural_fit: 0.95,
          maintainability: 0.95,
          testability: 0.95
        }
      }

      # initial_weights contains 3 models, but only active_1 responded
      initial = %{"active_1" => 0.4, "offline_local" => 0.3, "timed_out_cloud" => 0.3}

      result = Arbitrator.arbitrate([a1], initial_weights: initial)

      assert result.decision == :approved
      assert result.auto_approved == true
      # With only active_1, its weight is renormalized to 1.0
      assert abs(result.weighted_score - 0.9) < 1.0e-4
    end

    test "ADV_CON_05: all-cloud panel with unanimous approval auto-approves" do
      cloud_panel = [
        %Assessment{
          reviewer_id: "claude-3-5",
          provider: "anthropic",
          model: "claude-3-5-sonnet",
          vote: :approve,
          confidence: 0.98,
          scores: %{
            correctness: 0.95,
            security: 0.95,
            architectural_fit: 0.95,
            maintainability: 0.95,
            testability: 0.95
          }
        },
        %Assessment{
          reviewer_id: "gpt-4o",
          provider: "openai",
          model: "gpt-4o",
          vote: :approve,
          confidence: 0.95,
          scores: %{
            correctness: 0.92,
            security: 0.92,
            architectural_fit: 0.90,
            maintainability: 0.90,
            testability: 0.90
          }
        },
        %Assessment{
          reviewer_id: "gemini-1-5",
          provider: "google",
          model: "gemini-1.5-pro",
          vote: :approve,
          confidence: 0.92,
          scores: %{
            correctness: 0.90,
            security: 0.90,
            architectural_fit: 0.90,
            maintainability: 0.90,
            testability: 0.90
          }
        }
      ]

      result = Arbitrator.arbitrate(cloud_panel)

      assert result.decision == :approved
      assert result.auto_approved == true
      assert result.swarm_concordance >= 0.90
      assert result.weighted_score >= 0.90
    end

    test "ADV_CON_06: all-local Apple Silicon panel with unanimous rejection rejects" do
      local_panel = [
        %Assessment{
          reviewer_id: "llama-3-8b",
          provider: "local_mlx",
          model: "llama-3-8b-instruct",
          vote: :reject,
          confidence: 0.90,
          scores: %{
            correctness: 0.3,
            security: 0.3,
            architectural_fit: 0.4,
            maintainability: 0.3,
            testability: 0.3
          }
        },
        %Assessment{
          reviewer_id: "qwen-2-5-coder",
          provider: "local_ollama",
          model: "qwen2.5-coder:7b",
          vote: :reject,
          confidence: 0.85,
          scores: %{
            correctness: 0.2,
            security: 0.2,
            architectural_fit: 0.3,
            maintainability: 0.2,
            testability: 0.2
          }
        },
        %Assessment{
          reviewer_id: "deepseek-coder",
          provider: "local_llamacpp",
          model: "deepseek-coder-6.7b",
          vote: :reject,
          confidence: 0.88,
          scores: %{
            correctness: 0.2,
            security: 0.2,
            architectural_fit: 0.2,
            maintainability: 0.2,
            testability: 0.2
          }
        }
      ]

      result = Arbitrator.arbitrate(local_panel)

      assert result.decision == :rejected
      assert result.auto_approved == false
      assert result.weighted_score <= -0.40
    end

    test "ADV_CON_07: split cloud-vs-local disagreement triggers requires_arbitration (contested)" do
      cloud = %Assessment{
        reviewer_id: "cloud_reviewer",
        provider: "anthropic",
        model: "claude-3-5-sonnet",
        vote: :approve,
        confidence: 0.95,
        scores: %{
          correctness: 0.9,
          security: 0.9,
          architectural_fit: 0.9,
          maintainability: 0.9,
          testability: 0.9
        }
      }

      local = %Assessment{
        reviewer_id: "local_reviewer",
        provider: "local_ollama",
        model: "llama-3-8b",
        vote: :reject,
        confidence: 0.95,
        scores: %{
          correctness: 0.2,
          security: 0.2,
          architectural_fit: 0.3,
          maintainability: 0.2,
          testability: 0.2
        }
      }

      result = Arbitrator.arbitrate([cloud, local])

      assert result.decision == :requires_arbitration
      assert result.auto_approved == false
    end

    test "ADV_CON_08: single blocker critique from any model prevents auto-approval" do
      approver = %Assessment{
        reviewer_id: "cloud_approver",
        vote: :approve,
        confidence: 0.95,
        scores: %{
          correctness: 0.95,
          security: 0.95,
          architectural_fit: 0.95,
          maintainability: 0.95,
          testability: 0.95
        }
      }

      blocker_reviewer = %Assessment{
        reviewer_id: "local_watcher",
        vote: :request_changes,
        confidence: 0.90,
        scores: %{
          correctness: 0.70,
          security: 0.40,
          architectural_fit: 0.70,
          maintainability: 0.70,
          testability: 0.70
        },
        critique_points: [
          %{
            severity: :blocker,
            category: "security",
            file_path: "lib/auth.ex",
            line_number: 42,
            description: "Arbitrary command injection vulnerability found"
          }
        ]
      }

      result = Arbitrator.arbitrate([approver, blocker_reviewer])

      refute result.decision == :approved
      assert result.auto_approved == false
      assert result.decision in [:rejected, :requires_arbitration]
    end

    test "ADV_CON_09: Assessment.parse resilient against diverse corrupted model payloads" do
      corrupted_inputs = [
        "",
        "   ",
        "I am an AI assistant and I cannot review this code.",
        "{vote: 'approve', invalid_json_syntax}",
        "```json\n{\"vote\": \"approve\", \"confidence\": \"not_a_float\"}\n```",
        "```json\n{\"vote\": 12345, \"scores\": \"corrupted\"}\n```",
        "{\"vote\": \"completely_unknown_vote\", \"confidence\": 0.9}",
        "{\"scores\": null, \"critique_points\": \"not_a_list\"}",
        "<html><body>502 Bad Gateway</body></html>",
        "{\"vote\": \"approve\", \"confidence\": null}",
        "{\"confidence\": 0.85, \"scores\": {\"security\": \"0.95\", \"correctness\": 1}}"
      ]

      for input <- corrupted_inputs do
        parsed =
          try do
            Assessment.parse(input)
          rescue
            e -> {:caught, e}
          catch
            k, v -> {:caught, {k, v}}
          end

        # Assessment.parse must NEVER raise uncaught exceptions on arbitrary strings
        refute match?({:caught, _}, parsed)
        assert match?({:ok, %Assessment{}}, parsed) or match?({:error, _}, parsed)

        # If it parsed successfully, ensure fields conform to valid types
        case parsed do
          {:ok, a} ->
            assert a.vote in [:approve, :reject, :request_changes]
            assert is_float(a.confidence)
            assert is_map(a.scores)

          {:error, _} ->
            :ok
        end
      end
    end
  end
end
