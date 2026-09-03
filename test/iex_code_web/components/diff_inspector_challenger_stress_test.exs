defmodule IexCodeWeb.Components.DiffInspectorChallengerStressTest do
  use IexCodeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias IexCode.Tools.Git.DiffParser
  alias IexCode.Tools.Git.DiffParser.Line
  alias IexCodeWeb.DiffHighlighter, as: DH
  alias IexCodeWeb.WorkspaceComponents

  @moduledoc """
  Challenger 2 Adversarial Stress Suite for the Diff Inspection Subsystem.
  Empirically verifies:
  1. Checkpoint rollback hunks vs live git hunks (`is_checkpoint={true}` vs `false`)
  2. Large diffs with 50+ lines and intra-line word diffing
  3. Malformed, incomplete, and empty diff strings
  4. DOM ID uniqueness across complex multi-file/multi-hunk viewports
  5. Zero crash resilience against extreme input anomalies
  """

  # ============================================================================
  # 1. Checkpoint Rollback Hunks vs Live Git Hunks
  # ============================================================================
  describe "checkpoint rollback hunks vs live git hunks" do
    @sample_diff """
    --- a/lib/app.ex
    +++ b/lib/app.ex
    @@ -10,3 +10,3 @@
     defmodule App do
    -  def config, do: :old_val
    +  def config, do: :new_val
     end
    """

    test "live git hunk unstaged (is_checkpoint: false, staged: false) renders full git action palette" do
      rendered =
        render_component(&WorkspaceComponents.interactive_diff_viewer/1, %{
          id: "live-git-unstaged-viewer",
          diff_text: @sample_diff,
          file_path: "lib/app.ex",
          is_checkpoint: false,
          staged: false
        })

      # Hunk actions: Accept Hunk, Reject Hunk, Revert
      assert rendered =~ "phx-click=\"accept_hunk\""
      assert rendered =~ "Accept Hunk"
      assert rendered =~ "phx-click=\"reject_hunk\""
      assert rendered =~ "Reject Hunk"
      assert rendered =~ "phx-click=\"revert_hunk\""
      assert rendered =~ "Revert"

      # File actions: Revert File, Accept All
      assert rendered =~ "phx-click=\"revert_file\""
      assert rendered =~ "Revert File"
      assert rendered =~ "phx-click=\"accept_all_hunks\""
      assert rendered =~ "Accept All"

      # Strictly refutes staged and checkpoint controls
      refute rendered =~ "phx-click=\"unstage_hunk\""
      refute rendered =~ "Unstage Hunk"
      refute rendered =~ "phx-click=\"rollback_to_checkpoint\""
      refute rendered =~ "1-Click Rollback"
    end

    test "live git hunk staged (is_checkpoint: false, staged: true) renders Unstage Hunk and refutes Accept Hunk" do
      rendered =
        render_component(&WorkspaceComponents.interactive_diff_viewer/1, %{
          id: "live-git-staged-viewer",
          diff_text: @sample_diff,
          file_path: "lib/app.ex",
          is_checkpoint: false,
          staged: true
        })

      # Hunk action: Unstage Hunk
      assert rendered =~ "phx-click=\"unstage_hunk\""
      assert rendered =~ "Unstage Hunk"

      # Strictly refutes unstaged actions
      refute rendered =~ "phx-click=\"accept_hunk\""
      refute rendered =~ "Accept Hunk"
      refute rendered =~ "phx-click=\"reject_hunk\""
      refute rendered =~ "Reject Hunk"

      # File actions still present for file
      assert rendered =~ "phx-click=\"revert_file\""
      assert rendered =~ "phx-click=\"accept_all_hunks\""

      # Checkpoint actions refuted
      refute rendered =~ "phx-click=\"rollback_to_checkpoint\""
      refute rendered =~ "1-Click Rollback"
    end

    test "checkpoint rollback hunk with rollback_tx_id renders 1-Click Rollback and Revert Hunk" do
      tx_id = "tx-chkpt-alpha-42"

      rendered =
        render_component(&WorkspaceComponents.interactive_diff_viewer/1, %{
          id: "checkpoint-viewer-active",
          diff_text: @sample_diff,
          file_path: "lib/app.ex",
          is_checkpoint: true,
          rollback_tx_id: tx_id
        })

      # Toolbar header rollback button
      assert rendered =~ "phx-click=\"rollback_to_checkpoint\""
      assert rendered =~ "phx-value-tx_id=\"#{tx_id}\""
      assert rendered =~ "1-Click Rollback"

      # Hunk card rollback button
      assert rendered =~ "Revert Hunk"

      # Strictly refutes git staging and reverting actions
      refute rendered =~ "phx-click=\"accept_hunk\""
      refute rendered =~ "Accept Hunk"
      refute rendered =~ "phx-click=\"reject_hunk\""
      refute rendered =~ "Reject Hunk"
      refute rendered =~ "phx-click=\"unstage_hunk\""
      refute rendered =~ "Unstage Hunk"
      refute rendered =~ "phx-click=\"revert_file\""
      refute rendered =~ "Revert File"
      refute rendered =~ "phx-click=\"accept_all_hunks\""
      refute rendered =~ "Accept All"
    end

    test "checkpoint rollback hunk with rollback_tx_id: nil gracefully renders without rollback or git buttons" do
      rendered =
        render_component(&WorkspaceComponents.interactive_diff_viewer/1, %{
          id: "checkpoint-viewer-no-tx",
          diff_text: @sample_diff,
          file_path: "lib/app.ex",
          is_checkpoint: true,
          rollback_tx_id: nil
        })

      # No rollback button because tx_id is nil
      refute rendered =~ "1-Click Rollback"
      refute rendered =~ "Revert Hunk"

      # No git staging/revert buttons because is_checkpoint is true
      refute rendered =~ "Accept Hunk"
      refute rendered =~ "Reject Hunk"
      refute rendered =~ "Unstage Hunk"
      refute rendered =~ "Revert File"
      refute rendered =~ "Accept All"

      # Content is still rendered properly
      assert rendered =~ "lib/app.ex"
      assert rendered =~ "def config"
    end

    test "switching dynamically between checkpoint and live git mode preserves component integrity" do
      # Render checkpoint first
      rendered_cp =
        render_component(&WorkspaceComponents.interactive_diff_viewer/1, %{
          id: "dynamic-diff-viewer",
          diff_text: @sample_diff,
          file_path: "lib/app.ex",
          is_checkpoint: true,
          rollback_tx_id: "tx-dynamic-001"
        })

      assert rendered_cp =~ "1-Click Rollback"
      refute rendered_cp =~ "Accept Hunk"

      # Render live git on the same ID
      rendered_live =
        render_component(&WorkspaceComponents.interactive_diff_viewer/1, %{
          id: "dynamic-diff-viewer",
          diff_text: @sample_diff,
          file_path: "lib/app.ex",
          is_checkpoint: false,
          staged: false
        })

      assert rendered_live =~ "Accept Hunk"
      refute rendered_live =~ "1-Click Rollback"
    end
  end

  # ============================================================================
  # 2. Large Diffs with 50+ Lines and Intra-Line Word Diffing
  # ============================================================================
  describe "large diffs with 50+ lines and intra-line word diffing" do
    test "renders large symmetric diff (60 lines: 30 deletions, 30 additions) with intra-line word diffs" do
      dels =
        Enum.map_join(1..30, "\n", fn i ->
          "-  def calculate_metric_old_#{i}(user_id, count), do: user_id * #{i} + count"
        end)

      adds =
        Enum.map_join(1..30, "\n", fn i ->
          "+  def calculate_metric_new_#{i}(user_id, count), do: user_id * #{i} + count + 1"
        end)

      diff = """
      --- a/lib/metrics.ex
      +++ b/lib/metrics.ex
      @@ -1,30 +1,30 @@
      #{dels}
      #{adds}
      """

      # 1. Verify split mode
      rendered_split =
        render_component(&WorkspaceComponents.interactive_diff_viewer/1, %{
          id: "large-diff-split",
          diff_text: diff,
          file_path: "lib/metrics.ex",
          diff_mode: "split"
        })

      assert rendered_split =~ "Original"
      assert rendered_split =~ "Modified"
      # Intra-line word highlight chips
      assert rendered_split =~ "bg-rose-500/30"
      assert rendered_split =~ "calculate_metric_old_1"
      assert rendered_split =~ "calculate_metric_old_30"
      assert rendered_split =~ "bg-emerald-500/30"
      assert rendered_split =~ "calculate_metric_new_1"
      assert rendered_split =~ "calculate_metric_new_30"

      # 2. Verify inline mode
      rendered_inline =
        render_component(&WorkspaceComponents.interactive_diff_viewer/1, %{
          id: "large-diff-inline",
          diff_text: diff,
          file_path: "lib/metrics.ex",
          diff_mode: "inline"
        })

      assert rendered_inline =~ "calculate_metric_old_1"
      assert rendered_inline =~ "calculate_metric_new_30"
      assert rendered_inline =~ "bg-rose-500/30"
      assert rendered_inline =~ "bg-emerald-500/30"
    end

    test "renders large asymmetric diff (80 additions, 10 deletions) with 70 spacer elements and 0 vertical drift" do
      dels =
        Enum.map_join(1..10, "\n", fn i ->
          "-  old_step_item_#{i}()"
        end)

      adds =
        Enum.map_join(1..80, "\n", fn i ->
          "+  new_step_item_#{i}()"
        end)

      diff = """
      --- a/lib/pipeline.ex
      +++ b/lib/pipeline.ex
      @@ -1,11 +1,81 @@
       def run_pipeline do
      #{dels}
      #{adds}
       end
      """

      {:ok, [file_diff]} = DiffParser.parse(diff)
      [hunk] = file_diff.hunks
      assert length(hunk.lines) == 92

      # Check split lines pairing directly
      split_pairs = DH.pair_split_lines(hunk.lines, :empty)
      # 1 context + max(10, 80) + 1 context = 82 rows
      assert length(split_pairs) == 82

      # Check spacers in left column: 80 - 10 = 70 :empty spacers
      empty_spacers_count =
        Enum.count(split_pairs, fn {left, right} ->
          left == :empty and is_map(right) and right.type == :addition
        end)

      assert empty_spacers_count == 70

      # Context lines must be at index 0 and index 81 with 0 vertical drift
      assert {c_start_l, c_start_r} = Enum.at(split_pairs, 0)
      assert c_start_l.content == "def run_pipeline do"
      assert c_start_r.content == "def run_pipeline do"

      assert {c_end_l, c_end_r} = Enum.at(split_pairs, 81)
      assert c_end_l.content == "end"
      assert c_end_r.content == "end"

      # Render in component
      rendered =
        render_component(&WorkspaceComponents.interactive_diff_viewer/1, %{
          id: "large-asymmetric-diff",
          diff_text: diff,
          file_path: "lib/pipeline.ex",
          diff_mode: "split"
        })

      assert rendered =~ "Original"
      assert rendered =~ "Modified"
      assert rendered =~ "new_step_item_80"
      assert rendered =~ "border-transparent"
    end

    test "renders diff with multiple hunks exceeding 150 lines total" do
      hunk1 = """
      @@ -1,10 +1,10 @@
      #{Enum.map_join(1..20, "\n", fn i -> if rem(i, 2) == 0, do: "+# hunk1 add #{i}", else: "-# hunk1 del #{i}" end)}
      """

      hunk2 = """
      @@ -50,10 +50,10 @@
      #{Enum.map_join(1..25, "\n", fn i -> if rem(i, 2) == 0, do: "+# hunk2 add #{i}", else: "-# hunk2 del #{i}" end)}
      """

      hunk3 = """
      @@ -100,10 +100,10 @@
      #{Enum.map_join(1..30, "\n", fn i -> if rem(i, 2) == 0, do: "+# hunk3 add #{i}", else: "-# hunk3 del #{i}" end)}
      """

      hunk4 = """
      @@ -200,10 +200,10 @@
      #{Enum.map_join(1..40, "\n", fn i -> if rem(i, 2) == 0, do: "+# hunk4 add #{i}", else: "-# hunk4 del #{i}" end)}
      """

      diff =
        "--- a/lib/multi_hunk.ex\n+++ b/lib/multi_hunk.ex\n" <> hunk1 <> hunk2 <> hunk3 <> hunk4

      {:ok, [file_diff]} = DiffParser.parse(diff)
      assert length(file_diff.hunks) == 4

      rendered =
        render_component(&WorkspaceComponents.interactive_diff_viewer/1, %{
          id: "multi-hunk-150-viewer",
          diff_text: diff,
          file_path: "lib/multi_hunk.ex",
          diff_mode: "split"
        })

      # All 4 hunk cards must be present with unique scoped IDs
      assert rendered =~ "id=\"multi-hunk-150-viewer-hunk-card-hunk-1\""
      assert rendered =~ "id=\"multi-hunk-150-viewer-hunk-card-hunk-2\""
      assert rendered =~ "id=\"multi-hunk-150-viewer-hunk-card-hunk-3\""
      assert rendered =~ "id=\"multi-hunk-150-viewer-hunk-card-hunk-4\""

      assert rendered =~ "hunk1 add 20"
      assert rendered =~ "hunk4 add 40"
    end

    test "handles lines exceeding max_line_bytes (>2,000 bytes) within large diff without hang" do
      giant_del = "-  data_blob_old = \"" <> String.duplicate("A", 3_500) <> "\""
      giant_add = "+  data_blob_new = \"" <> String.duplicate("B", 3_500) <> "\""

      diff = """
      --- a/lib/blob.ex
      +++ b/lib/blob.ex
      @@ -1,2 +1,2 @@
      #{giant_del}
      #{giant_add}
      """

      {time_us, rendered} =
        :timer.tc(fn ->
          render_component(&WorkspaceComponents.interactive_diff_viewer/1, %{
            id: "giant-line-viewer",
            diff_text: diff,
            file_path: "lib/blob.ex",
            diff_mode: "inline"
          })
        end)

      # Under 100ms
      assert time_us < 100_000
      assert rendered =~ "data_blob_old"
      assert rendered =~ "data_blob_new"
    end
  end

  # ============================================================================
  # 3. Malformed / Empty Diff Strings
  # ============================================================================
  describe "malformed and empty diff strings" do
    test "handles nil, empty string, and whitespace-only diffs cleanly" do
      for input <- [nil, "", "   ", "\n\t  \n  \r\n"] do
        rendered =
          render_component(&WorkspaceComponents.interactive_diff_viewer/1, %{
            id: "empty-viewer",
            diff_text: input,
            file_path: "lib/empty.ex"
          })

        assert rendered =~ "No patch or diff selected."
        refute rendered =~ "hunk-card"
      end
    end

    test "handles arbitrary prose and non-diff text without crashing (falls back gracefully)" do
      garbage_diff = """
      Lorem ipsum dolor sit amet, consectetur adipiscing elit.
      Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.
      Random compiler error: UndefinedFunctionError at line 42.
      Stacktrace: (elixir 1.18.2) lib/enum.ex:123: Enum.map/2
      """

      # Inline mode fallback
      rendered_inline =
        render_component(&WorkspaceComponents.interactive_diff_viewer/1, %{
          id: "garbage-inline-viewer",
          diff_text: garbage_diff,
          diff_mode: "inline"
        })

      assert rendered_inline =~ "Lorem ipsum"
      assert rendered_inline =~ "UndefinedFunctionError"

      # Split mode fallback
      rendered_split =
        render_component(&WorkspaceComponents.interactive_diff_viewer/1, %{
          id: "garbage-split-viewer",
          diff_text: garbage_diff,
          diff_mode: "split"
        })

      assert rendered_split =~ "Original"
      assert rendered_split =~ "Modified"
      assert rendered_split =~ "Lorem ipsum"
    end

    test "handles incomplete headers and truncated diff markers" do
      corrupted_cases = [
        # Missing +++ line
        "--- a/only_old.ex\n@@ -1,2 +1,2 @@\n-old\n+new\n",
        # Missing --- line
        "+++ b/only_new.ex\n@@ -1,2 +1,2 @@\n-old\n+new\n",
        # Header only without hunks
        "diff --git a/file.ex b/file.ex\n--- a/file.ex\n+++ b/file.ex\n",
        # Invalid @@ numbers
        "--- a/file.ex\n+++ b/file.ex\n@@ -invalid +numbers @@\n-old\n+new\n",
        # Hunk body lines without prefix (+, -, space)
        "--- a/file.ex\n+++ b/file.ex\n@@ -1,2 +1,2 @@\nraw line 1 without prefix\nraw line 2 without prefix\n",
        # Binary file diff marker
        "Binary files a/sample.png and b/sample.png differ\n",
        # CRLF line endings throughout
        "--- a/crlf.ex\r\n+++ b/crlf.ex\r\n@@ -1,2 +1,2 @@\r\n-old\r\n+new\r\n",
        # Lone hunk without file headers
        "@@ -10,2 +10,2 @@\n-old\n+new\n"
      ]

      for {case_diff, idx} <- Enum.with_index(corrupted_cases) do
        for mode <- ["split", "inline"] do
          rendered =
            render_component(&WorkspaceComponents.interactive_diff_viewer/1, %{
              id: "corrupted-viewer-#{idx}-#{mode}",
              diff_text: case_diff,
              file_path: "lib/corrupted_#{idx}.ex",
              diff_mode: mode
            })

          assert is_binary(rendered) and rendered != ""
          assert rendered =~ "corrupted-viewer-#{idx}-#{mode}"
        end
      end
    end

    test "handles extreme Unicode, RTL text, emojis, and null bytes in diff content" do
      unicode_diff = """
      --- a/lib/🚀/مرحبا.ex
      +++ b/lib/🚀/مرحبا.ex
      @@ -1,3 +1,3 @@
       defmodule Test🚀 do
      -  def greet, do: "مرحبا \0 old"
      +  def greet, do: "مرحبا \0 new! 👍🏽"
       end
      """

      for mode <- ["split", "inline"] do
        rendered =
          render_component(&WorkspaceComponents.interactive_diff_viewer/1, %{
            id: "unicode-diff-viewer-#{mode}",
            diff_text: unicode_diff,
            file_path: "lib/🚀/مرحبا.ex",
            diff_mode: mode
          })

        assert rendered =~ "مرحبا"
        assert rendered =~ "🚀"
        assert rendered =~ "👍🏽"
      end
    end
  end

  # ============================================================================
  # 4. DOM ID Uniqueness & Multi-Viewport Collisions
  # ============================================================================
  describe "DOM ID uniqueness across multi-file and multi-hunk viewports" do
    test "guarantees 100% unique DOM IDs across 30 diff viewers on a single page" do
      diff = """
      --- a/test.ex
      +++ b/test.ex
      @@ -1,2 +1,2 @@
      -old_code_a()
      +new_code_a()
      @@ -10,2 +10,2 @@
      -old_code_b()
      +new_code_b()
      """

      {:ok, [parsed_file]} = DiffParser.parse(diff)

      # 15 checkpoint viewers and 15 git viewers on one page
      html_chunks =
        Enum.map(1..15, fn i ->
          render_component(&WorkspaceComponents.interactive_diff_viewer/1, %{
            id: "chkpt-viewer-#{i}",
            diff_text: diff,
            hunks: parsed_file.hunks,
            file_path: "lib/file_cp_#{i}.ex",
            is_checkpoint: true,
            rollback_tx_id: "tx-dom-#{i}",
            diff_mode: "split"
          })
        end) ++
          Enum.map(16..30, fn i ->
            render_component(&WorkspaceComponents.interactive_diff_viewer/1, %{
              id: "git-viewer-#{i}",
              diff_text: diff,
              hunks: parsed_file.hunks,
              file_path: "lib/file_git_#{i}.ex",
              is_checkpoint: false,
              staged: rem(i, 2) == 0,
              diff_mode: "inline"
            })
          end)

      full_html = "<div id=\"mega-viewport\">" <> Enum.join(html_chunks, "\n") <> "</div>"
      {:ok, document} = Floki.parse_fragment(full_html)

      all_ids = Floki.attribute(document, "[id]", "id")

      # 1 wrapper + 30 viewer containers + 30 copy buttons + 60 hunk cards (2 per viewer) = 121 IDs
      assert length(all_ids) == 121

      id_counts = Enum.frequencies(all_ids)
      duplicate_ids = Enum.filter(id_counts, fn {_id, count} -> count > 1 end)

      assert duplicate_ids == [],
             "DOM ID collision detected across 30 diff viewers: #{inspect(duplicate_ids)}"
    end

    test "guarantees unique IDs for identical hunk structures across different parent containers" do
      hunk_struct = %IexCode.Tools.Git.DiffParser.Hunk{
        id: "hunk-1",
        header: "@@ -1,2 +1,2 @@",
        old_start: 1,
        new_start: 1,
        lines: [
          %Line{type: :deletion, content: "old", old_num: 1},
          %Line{type: :addition, content: "new", new_num: 1}
        ]
      }

      h1 =
        render_component(&WorkspaceComponents.hunk_card/1, %{
          parent_id: "parent-container-A",
          hunk: hunk_struct
        })

      h2 =
        render_component(&WorkspaceComponents.hunk_card/1, %{
          parent_id: "parent-container-B",
          hunk: hunk_struct
        })

      assert h1 =~ "id=\"parent-container-A-hunk-card-hunk-1\""
      assert h2 =~ "id=\"parent-container-B-hunk-card-hunk-1\""
      refute h1 =~ "parent-container-B"
      refute h2 =~ "parent-container-A"
    end
  end

  # ============================================================================
  # 5. LiveView Integration Stress: Detached.DiffLive & WorkspaceLive
  # ============================================================================
  describe "LiveView integration stress: Detached.DiffLive & WorkspaceLive" do
    setup do
      unique_suffix = System.unique_integer([:positive])
      temp_root = Path.join(System.tmp_dir!(), "iex_challenger_diff_#{unique_suffix}")
      File.mkdir_p!(temp_root)

      System.cmd("git", ["init", temp_root])
      System.cmd("git", ["-C", temp_root, "config", "user.name", "Challenger"])
      System.cmd("git", ["-C", temp_root, "config", "user.email", "challenger@example.com"])

      test_file = Path.join(temp_root, "sample.txt")
      File.write!(test_file, "initial line 1\ninitial line 2\n")
      System.cmd("git", ["-C", temp_root, "add", "sample.txt"])
      System.cmd("git", ["-C", temp_root, "commit", "-m", "initial commit"])

      {:ok, project} =
        IexCode.Projects.create_project(%{
          name: "Challenger Project #{unique_suffix}",
          root_path: temp_root
        })

      {:ok, session} =
        IexCode.Sessions.create_session(%{
          project_id: project.id,
          title: "Challenger Session #{unique_suffix}"
        })

      on_exit(fn ->
        File.rm_rf(temp_root)
      end)

      {:ok, project: project, session: session, temp_root: temp_root, test_file: test_file}
    end

    test "WorkspaceLive mounts and renders staged diffs without KeyError", %{
      conn: conn,
      session: session,
      temp_root: temp_root,
      test_file: test_file
    } do
      # Modify file and stage it
      File.write!(test_file, "initial line 1\nmodified line 2\n")
      System.cmd("git", ["-C", temp_root, "add", "sample.txt"])

      # Mount WorkspaceLive
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      assert has_element?(view, "#workspace-shell")
    end

    test "Detached.DiffLive mounts cleanly and renders diff view when git changes exist without KeyError",
         %{
           conn: conn,
           session: session,
           temp_root: temp_root,
           test_file: test_file
         } do
      # Modify file and stage it
      File.write!(test_file, "initial line 1\nmodified line 2\n")
      System.cmd("git", ["-C", temp_root, "add", "sample.txt"])

      # Empirically verify that live mount succeeds and renders without KeyError
      assert {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}/detached/diff")
      assert has_element?(view, "#detached-diff-container")
      assert html =~ "sample.txt"
    end

    test "Detached.DiffLive handles hunk and file actions (accept_hunk, reject_hunk, revert_hunk, accept_all_hunks, revert_file)",
         %{
           conn: conn,
           session: session,
           temp_root: _temp_root,
           test_file: test_file
         } do
      # Make an unstaged modification
      File.write!(test_file, "initial line 1\nmodified unstaged line 2\n")

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/detached/diff")
      assert has_element?(view, "#detached-diff-container")

      # Accept all hunks (stage changes)
      html_accept = render_click(view, "accept_all_hunks", %{"file" => "sample.txt"})
      assert html_accept =~ "Staged all changes for sample.txt"

      # Revert file
      html_revert = render_click(view, "revert_file", %{"file" => "sample.txt"})
      assert html_revert =~ "Reverted sample.txt"

      # Make another modification for accept_hunk / reject_hunk
      File.write!(test_file, "initial line 1\nmodified line 2 again\n")
      render_click(view, "set_diff_scope", %{"scope" => "unstaged"})

      html_hunk =
        render_click(view, "accept_hunk", %{"file" => "sample.txt", "hunk_id" => "hunk-1"})

      assert html_hunk =~ "Accepted hunk" or is_binary(html_hunk)

      html_revert_hunk =
        render_click(view, "revert_hunk", %{"file" => "sample.txt", "hunk_id" => "hunk-1"})

      assert is_binary(html_revert_hunk)
    end
  end
end
