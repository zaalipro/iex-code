defmodule IexCodeWeb.WorkspaceRound4SurfacesTest do
  @moduledoc """
  Round 4 LiveView & Component verification suite covering:
  1. Hybrid / Vector / Lexical semantic retrieval mode pills in WorkspaceLive
  2. Symbol References & Safe Multi-File Rename explorer (SafetyPolicy + WorkspaceLocks gated)
  3. TimeTravel checkpoint drift inspection & warning banner (#checkpoint-drift-banner)
  4. CommandPalette Round 4 actions & ExecutionPreviews optional telemetry pills
  """

  use IexCode.E2E.Case, async: false

  import Phoenix.LiveViewTest

  alias IexCode.SemanticIndex.Indexer
  alias IexCode.{Projects, Sessions, Settings, TimeTravel, Tools, WorkspaceLocks}
  alias IexCodeWeb.{CommandPalette, ExecutionPreviews}

  @moduletag mock_llm: true
  @moduletag timeout: 120_000

  describe "Hybrid / Vector / Lexical Semantic Search Modes" do
    test "defaults to hybrid mode, renders mode pills, and switches retrieval modes without atom leaks",
         %{conn: conn, workspace_path: root_path} do
      workspace_write_file(root_path, "lib/retrieval/fusion_engine.ex", """
      defmodule SampleApp.Retrieval.FusionEngine do
        @doc "Computes reciprocal rank fusion scores across dense and BM25 lexical lists."
        def calculate_rrf_fusion(dense_candidates, lexical_candidates) do
          {:ok, dense_candidates ++ lexical_candidates}
        end
      end
      """)

      workspace_write_file(root_path, "lib/retrieval/token_counter.ex", """
      defmodule SampleApp.Retrieval.TokenCounter do
        def count_identifier_tokens(source_text) do
          source_text |> String.split() |> length()
        end
      end
      """)

      project = create_project_fixture(%{root_path: root_path})
      session = create_session_fixture(project)

      on_exit(fn ->
        if :ets.whereis(Indexer.table_name()) != :undefined do
          :ets.match_delete(
            Indexer.table_name(),
            {:_, project.id, :_, :_, :_, :_, :_, :_, :_}
          )
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      state = :sys.get_state(view.pid)
      assert state.socket.assigns.semantic_search_mode == "hybrid"

      render_click(view, "switch_tab", %{"tab" => "ast"})
      assert has_element?(view, "#symbol-explorer-mode-toolbar")

      view |> element("#symbol-explorer-semantic-mode") |> render_click()

      assert has_element?(view, "#semantic-search-panel")
      assert has_element?(view, "#semantic-mode-hybrid[aria-pressed='true']")
      assert has_element?(view, "#semantic-mode-vector[aria-pressed='false']")
      assert has_element?(view, "#semantic-mode-lexical[aria-pressed='false']")

      # Adjust threshold for synthetic offline hash vectors in test env while exercising UI re-index
      view |> element("#semantic-reindex-btn") |> render_click()

      stats = Indexer.stats(project.id)
      assert stats.ets_chunks >= 2

      # Search in default hybrid mode (BM25 + RRF yields strong score on exact identifier tokens)
      html =
        view
        |> element("#semantic-search-form")
        |> render_submit(%{"query" => "calculate_rrf_fusion reciprocal rank"})

      assert html =~ "lib/retrieval/fusion_engine.ex"

      # Switch to lexical mode pill -> re-runs search with mode: :lexical
      lexical_html = view |> element("#semantic-mode-lexical") |> render_click()
      assert has_element?(view, "#semantic-mode-lexical[aria-pressed='true']")
      assert has_element?(view, "#semantic-mode-hybrid[aria-pressed='false']")
      assert lexical_html =~ "lib/retrieval/fusion_engine.ex"

      # Switch to vector mode pill -> re-runs search with mode: :vector
      _vector_html = view |> element("#semantic-mode-vector") |> render_click()
      assert has_element?(view, "#semantic-mode-vector[aria-pressed='true']")
      assert :sys.get_state(view.pid).socket.assigns.semantic_search_mode == "vector"

      # Switch back to hybrid mode pill
      hybrid_html = view |> element("#semantic-mode-hybrid") |> render_click()
      assert has_element?(view, "#semantic-mode-hybrid[aria-pressed='true']")
      assert hybrid_html =~ "lib/retrieval/fusion_engine.ex"

      # Untrusted mode input must fall back via closed map without creating dynamic atoms
      unique_untrusted_mode = "untrusted_semantic_mode_#{System.unique_integer([:positive])}"
      render_click(view, "set_semantic_mode", %{"mode" => unique_untrusted_mode})

      assert :sys.get_state(view.pid).socket.assigns.semantic_search_mode == "hybrid"

      assert_raise ArgumentError, fn ->
        String.to_existing_atom(unique_untrusted_mode)
      end
    end
  end

  describe "Symbol References & Safe Multi-File Rename Explorer" do
    test "finds lexical-scope-aware AST references and previews dry-run multi-file rename without touching disk",
         %{conn: conn, workspace_path: root_path} do
      billing_source = """
      defmodule SampleApp.Billing do
        def compute_invoice(subtotal, tax_rate) do
          total = subtotal + trunc(subtotal * tax_rate)
          {:ok, %{amount: total}}
        end
      end
      """

      checkout_source = """
      defmodule SampleApp.Checkout do
        alias SampleApp.Billing, as: InvoiceEngine

        # compute_invoice inside a comment must never count as a reference
        def finalize(order_subtotal) do
          InvoiceEngine.compute_invoice(order_subtotal, 0.1)
        end
      end
      """

      workspace_write_file(root_path, "lib/sample_app/billing.ex", billing_source)
      workspace_write_file(root_path, "lib/sample_app/checkout.ex", checkout_source)

      project = create_project_fixture(%{root_path: root_path})
      session = create_session_fixture(project)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "switch_tab", %{"tab" => "ast"})
      assert has_element?(view, "#symbol-explorer-references-mode")

      view |> element("#symbol-explorer-references-mode") |> render_click()

      assert has_element?(view, "#symbol-refactor-panel")
      assert has_element?(view, "#symbol-references-form")
      assert has_element?(view, "#symbol-rename-preview-form")

      # Blank symbol query surfaces helpful validation message
      view
      |> element("#symbol-references-form")
      |> render_submit(%{"symbol" => "   "})

      assert has_element?(view, "#symbol-references-error")

      # Valid qualified function reference search across aliased call + definition
      refs_html =
        view
        |> element("#symbol-references-form")
        |> render_submit(%{"symbol" => "SampleApp.Billing.compute_invoice/2"})

      refute has_element?(view, "#symbol-references-error")
      assert has_element?(view, "#symbol-reference-item-0")
      assert has_element?(view, "#symbol-reference-item-1")
      refute has_element?(view, "#symbol-reference-item-2")
      assert refs_html =~ "lib/sample_app/billing.ex:2:"
      assert refs_html =~ "lib/sample_app/checkout.ex:6:"
      assert refs_html =~ "definition"
      assert refs_html =~ "call"

      # Dry-run rename preview renders counts, unified diff, and Apply button while leaving disk untouched
      preview_html =
        view
        |> element("#symbol-rename-preview-form")
        |> render_submit(%{
          "from" => "SampleApp.Billing.compute_invoice/2",
          "to" => "build_invoice"
        })

      assert has_element?(view, "#symbol-rename-preview-card")
      assert has_element?(view, "#symbol-rename-files-count")
      assert has_element?(view, "#symbol-rename-occurrences-count")
      assert has_element?(view, "#symbol-rename-diff-preview")
      assert has_element?(view, "#apply-symbol-rename-btn")
      assert preview_html =~ "2 file(s) changed"
      assert preview_html =~ "2 occurrence(s)"
      assert preview_html =~ "-  def compute_invoice(subtotal, tax_rate) do"
      assert preview_html =~ "+  def build_invoice(subtotal, tax_rate) do"
      assert preview_html =~ "+    InvoiceEngine.build_invoice(order_subtotal, 0.1)"

      assert File.read!(Path.join(root_path, "lib/sample_app/billing.ex")) == billing_source
      assert File.read!(Path.join(root_path, "lib/sample_app/checkout.ex")) == checkout_source
    end

    test "gates apply_symbol_rename via SafetyPolicy and WorkspaceLocks before committing atomic disk edits",
         %{conn: conn, workspace_path: root_path} do
      billing_path = Path.join(root_path, "lib/sample_app/billing.ex")
      checkout_path = Path.join(root_path, "lib/sample_app/checkout.ex")

      billing_source = """
      defmodule SampleApp.Billing do
        def compute_invoice(subtotal, tax_rate), do: {subtotal, tax_rate}
      end
      """

      checkout_source = """
      defmodule SampleApp.Checkout do
        alias SampleApp.Billing
        def run(x), do: Billing.compute_invoice(x, 1)
      end
      """

      workspace_write_file(root_path, "lib/sample_app/billing.ex", billing_source)
      workspace_write_file(root_path, "lib/sample_app/checkout.ex", checkout_source)

      project = create_project_fixture(%{root_path: root_path})
      session = create_session_fixture(project)
      competing_session = create_session_fixture(project)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "open_symbol_refactor_explorer", %{})
      assert has_element?(view, "#symbol-refactor-panel")

      view
      |> element("#symbol-rename-preview-form")
      |> render_submit(%{
        "from" => "SampleApp.Billing.compute_invoice/2",
        "to" => "build_invoice"
      })

      assert has_element?(view, "#apply-symbol-rename-btn")

      # 1. Fail-closed under read_only SafetyPolicy
      {:ok, _} = Settings.update_settings(%{tool_approval_mode: "read_only"})

      denied_html = view |> element("#apply-symbol-rename-btn") |> render_click()
      assert has_element?(view, "#symbol-rename-error")
      assert denied_html =~ "denied by safety policy"
      assert File.read!(billing_path) == billing_source
      assert File.read!(checkout_path) == checkout_source

      # Restore default safety mode
      {:ok, _} = Settings.update_settings(%{tool_approval_mode: "prompt_dangerous"})

      # 2. Blocked cleanly when another session/task holds a conflicting WorkspaceLocks lease
      {:ok, lock_handle} =
        WorkspaceLocks.acquire(project, [:project],
          owner_id: "session:#{competing_session.id}",
          session_id: competing_session.id,
          lease_seconds: 15,
          heartbeat_interval_ms: 3_000
        )

      try do
        locked_html = view |> element("#apply-symbol-rename-btn") |> render_click()
        assert has_element?(view, "#symbol-rename-error")
        assert locked_html =~ "Workspace change blocked"
        assert has_element?(view, "#symbol-rename-preview-card")
        assert File.read!(billing_path) == billing_source
        assert File.read!(checkout_path) == checkout_source
      after
        _ = WorkspaceLocks.release(lock_handle)
      end

      # 3. Succeeds atomically once lock is free and policy permits human-confirmed preview
      applied_html = view |> element("#apply-symbol-rename-btn") |> render_click()
      refute has_element?(view, "#symbol-rename-error")
      assert applied_html =~ "Applied"
      assert File.read!(billing_path) =~ "def build_invoice(subtotal, tax_rate)"
      assert File.read!(checkout_path) =~ "Billing.build_invoice(x, 1)"
    end
  end

  describe "TimeTravel Checkpoint Drift Check Banner" do
    test "checks checkpoint drift cleanly, renders #checkpoint-drift-banner on external edits, and isolates foreign sessions",
         %{conn: conn, workspace_path: root_path} do
      app_file = Path.join(root_path, "lib/drifty.ex")
      workspace_write_file(root_path, "lib/drifty.ex", "defmodule Drifty, do: :v1\n")

      project = create_project_fixture(%{root_path: root_path})
      session = create_session_fixture(project)

      # Create a checkpoint via patch_file tool
      assert {:ok, _} =
               Tools.execute(
                 "patch_file",
                 %{
                   "path" => "lib/drifty.ex",
                   "target_content" => ":v1",
                   "replacement_content" => ":v2",
                   "session_id" => session.id
                 },
                 root_path
               )

      [checkpoint | _] = TimeTravel.list_checkpoints(session.id)
      tx_id = checkpoint.transaction_id || checkpoint.id

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}?tab=changes&subtab=checkpoints")

      assert has_element?(view, "#check-checkpoint-drift-btn")
      refute has_element?(view, "#checkpoint-drift-banner")

      # 1. Clean state -> clicking Check Drift renders clean badge, not drift warning banner
      view |> element("#check-checkpoint-drift-btn") |> render_click()
      assert has_element?(view, "#checkpoint-drift-clean-badge")
      refute has_element?(view, "#checkpoint-drift-banner")

      # 2. External modification on disk -> Check Drift renders #checkpoint-drift-banner with file path & reason
      File.write!(app_file, "defmodule Drifty, do: :externally_mutated\n")

      drift_html =
        render_click(view, "check_checkpoint_drift", %{"id" => tx_id})

      assert has_element?(view, "#checkpoint-drift-banner")
      refute has_element?(view, "#checkpoint-drift-clean-badge")
      assert drift_html =~ "lib/drifty.ex"
      assert drift_html =~ "modified since snapshot"

      # 3. External deletion on disk -> Check Drift updates #checkpoint-drift-banner with missing file warning
      File.rm!(app_file)

      missing_html = view |> element("#check-checkpoint-drift-btn") |> render_click()
      assert has_element?(view, "#checkpoint-drift-banner")
      assert missing_html =~ "lib/drifty.ex"
      assert missing_html =~ "deleted since snapshot"

      # 4. Cross-session isolation: foreign checkpoint tx_id must not leak foreign paths
      foreign_dir =
        Path.join(System.tmp_dir!(), "iex_r4_foreign_#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(foreign_dir, "lib"))
      File.write!(Path.join(foreign_dir, "lib/secret.ex"), "defmodule Secret, do: :v1\n")

      on_exit(fn -> File.rm_rf(foreign_dir) end)

      {:ok, foreign_project} =
        Projects.create_project(%{name: "Foreign R4", root_path: foreign_dir})

      {:ok, foreign_session} =
        Sessions.create_session(%{project_id: foreign_project.id, title: "Foreign Session"})

      assert {:ok, _} =
               Tools.execute(
                 "patch_file",
                 %{
                   "path" => "lib/secret.ex",
                   "target_content" => ":v1",
                   "replacement_content" => ":v2",
                   "session_id" => foreign_session.id
                 },
                 foreign_dir
               )

      File.write!(Path.join(foreign_dir, "lib/secret.ex"), "defmodule Secret, do: :drifted\n")
      [foreign_cp | _] = TimeTravel.list_checkpoints(foreign_session.id)

      foreign_html =
        render_click(view, "check_checkpoint_drift", %{"id" => foreign_cp.transaction_id})

      assert has_element?(view, "#checkpoint-drift-error")
      refute has_element?(view, "#checkpoint-drift-banner")
      refute foreign_html =~ "lib/secret.ex"
    end
  end

  describe "CommandPalette Actions & ExecutionPreviews Optional Telemetry Pills" do
    test "CommandPalette ranks and executes hybrid_semantic_search and symbol_refactor_explorer within sub-10ms budget",
         %{conn: conn, workspace_path: root_path} do
      project = create_project_fixture(%{root_path: root_path})
      session = create_session_fixture(project)

      files = for i <- 1..250, do: "lib/module_#{i}.ex"

      {us_hybrid, hybrid_results} =
        :timer.tc(fn ->
          CommandPalette.search("hybrid semantic", files, [session], "actions")
        end)

      assert us_hybrid < 10_000
      assert Enum.any?(hybrid_results, &(&1.id == "hybrid_semantic_search"))

      {us_refactor, refactor_results} =
        :timer.tc(fn ->
          CommandPalette.search("symbol rename", files, [session], "actions")
        end)

      assert us_refactor < 10_000
      assert Enum.any?(refactor_results, &(&1.id == "symbol_refactor_explorer"))

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Execute hybrid_semantic_search via Command Palette
      render_click(view, "toggle_command_palette", %{})
      render_change(view, "command_palette_search", %{"query" => "Hybrid Semantic Code Search"})
      render_click(view, "command_palette_execute_selected", %{})

      assert has_element?(view, "#semantic-search-panel")
      assert has_element?(view, "#semantic-mode-hybrid[aria-pressed='true']")

      # Execute symbol_refactor_explorer via Command Palette
      render_click(view, "toggle_command_palette", %{})

      render_change(view, "command_palette_search", %{
        "query" => "Symbol References & Rename Explorer"
      })

      render_click(view, "command_palette_execute_selected", %{})

      assert has_element?(view, "#symbol-refactor-panel")
      assert has_element?(view, "#symbol-explorer-references-mode[aria-pressed='true']")
    end

    test "ExecutionPreviews renders optional tool_name, iteration, and repair_mode pills while preserving legacy preview compatibility" do
      legacy_preview = %{
        identity: %{role: "assistant", turn: 1},
        text: "Streaming baseline response...",
        status: "streaming",
        closed?: false,
        partial?: false,
        truncated?: false
      }

      enriched_preview = %{
        identity: %{role: "coder", turn: 2},
        text: "Applying AST-verified symbol patch...",
        status: "streaming",
        closed?: false,
        partial?: true,
        truncated?: false,
        tool_name: "rename_symbol",
        iteration: 3,
        repair_mode: "compile_fix"
      }

      boolean_repair_preview = %{
        identity: %{role: "verifier", turn: 3},
        text: "Re-running targeted ExUnit check...",
        status: "settled",
        closed?: false,
        partial?: false,
        truncated?: false,
        tool_name: "run_tests",
        iteration: 4,
        repair_mode: true
      }

      html =
        render_component(&ExecutionPreviews.execution_previews/1, %{
          id: "execution",
          previews: [legacy_preview, enriched_preview, boolean_repair_preview]
        })

      doc = LazyHTML.from_fragment(html)

      # Index 0 (legacy map): zero optional pills rendered
      assert Enum.count(LazyHTML.query(doc, "#execution-preview-0")) == 1
      assert Enum.count(LazyHTML.query(doc, "#execution-preview-tool-0")) == 0
      assert Enum.count(LazyHTML.query(doc, "#execution-preview-iteration-0")) == 0
      assert Enum.count(LazyHTML.query(doc, "#execution-preview-repair-0")) == 0

      # Index 1 (enriched map): renders tool_name, iteration, and descriptive repair_mode pills
      assert LazyHTML.query(doc, "#execution-preview-tool-1") |> LazyHTML.text() =~
               "Tool · rename_symbol"

      assert LazyHTML.query(doc, "#execution-preview-iteration-1") |> LazyHTML.text() =~
               "Iter 3"

      assert LazyHTML.query(doc, "#execution-preview-repair-1") |> LazyHTML.text() =~
               "Repair · compile_fix"

      # Index 2 (boolean repair_mode): renders generic Repair mode pill
      assert LazyHTML.query(doc, "#execution-preview-tool-2") |> LazyHTML.text() =~
               "Tool · run_tests"

      assert LazyHTML.query(doc, "#execution-preview-iteration-2") |> LazyHTML.text() =~
               "Iter 4"

      assert LazyHTML.query(doc, "#execution-preview-repair-2") |> LazyHTML.text() =~
               "Repair mode"
    end
  end
end
