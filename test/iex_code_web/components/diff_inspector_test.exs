defmodule IexCodeWeb.Components.DiffInspectorTest do
  use IexCodeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias IexCode.{Projects, Sessions, TimeTravel}
  alias IexCode.Tools.Git.DiffParser
  alias IexCodeWeb.WorkspaceComponents

  describe "WorkspaceComponents.hunk_split_lines/1" do
    test "renders aligned columns with spacer elements for asymmetric changes" do
      diff = """
      diff --git a/calc.ex b/calc.ex
      --- a/calc.ex
      +++ b/calc.ex
      @@ -1,4 +1,5 @@
       def calc do
      -  a + b
      +  # comment
      +  a + b
       end
      """

      {:ok, [file_diff]} = DiffParser.parse(diff)
      [hunk] = file_diff.hunks

      rendered =
        render_component(&WorkspaceComponents.hunk_split_lines/1, %{
          lines: hunk.lines
        })

      document = LazyHTML.from_fragment(rendered)
      assert LazyHTML.text(document) =~ "Original"
      assert LazyHTML.text(document) =~ "Modified"

      rows = LazyHTML.query(document, "div.group")
      assert Enum.count(rows) == 4

      for row <- rows do
        assert row |> LazyHTML.child_nodes() |> LazyHTML.filter("div") |> Enum.count() == 2
      end

      assert document
             |> LazyHTML.query("div[class~='border-danger'] > div")
             |> Enum.map(&(LazyHTML.text(&1) |> String.replace(~r/\s+/, ""))) == ["a+b"]

      assert document
             |> LazyHTML.query("div[class~='border-success'] > div")
             |> Enum.map(&(LazyHTML.text(&1) |> String.replace(~r/\s+/, ""))) ==
               ["#comment", "a+b"]

      spacer = LazyHTML.query(document, "div.group > div:first-child > div.border-transparent")
      assert Enum.count(spacer) == 1
      spacer_row = spacer |> LazyHTML.parent_node() |> LazyHTML.parent_node()

      assert spacer_row
             |> LazyHTML.query("div[class~='border-success'] > div")
             |> LazyHTML.text()
             |> String.replace(~r/\s+/, "") == "a+b"

      assert document
             |> LazyHTML.query("div.group:last-child > div > div > div")
             |> Enum.map(&(LazyHTML.text(&1) |> String.trim())) == ["end", "end"]
    end

    test "renders intra-line word diff chips on changed rows" do
      diff = """
      diff --git a/calc.ex b/calc.ex
      --- a/calc.ex
      +++ b/calc.ex
      @@ -1,3 +1,3 @@
       def calc do
      -  user.first_name
      +  user.full_name
       end
      """

      {:ok, [file_diff]} = DiffParser.parse(diff)
      [hunk] = file_diff.hunks

      rendered =
        render_component(&WorkspaceComponents.hunk_split_lines/1, %{
          lines: hunk.lines
        })

      assert_changed_name_highlights(LazyHTML.from_fragment(rendered))
    end
  end

  describe "WorkspaceComponents.hunk_inline_lines/1" do
    test "renders inline diff with intra-line word diff highlights" do
      diff = """
      diff --git a/calc.ex b/calc.ex
      --- a/calc.ex
      +++ b/calc.ex
      @@ -1,3 +1,3 @@
       def calc do
      -  user.first_name
      +  user.full_name
       end
      """

      {:ok, [file_diff]} = DiffParser.parse(diff)
      [hunk] = file_diff.hunks

      rendered =
        render_component(&WorkspaceComponents.hunk_inline_lines/1, %{
          lines: hunk.lines
        })

      assert_changed_name_highlights(LazyHTML.from_fragment(rendered))
    end
  end

  defp assert_changed_name_highlights(document) do
    for {tone, changed_name} <- [{"danger", "first_name"}, {"success", "full_name"}] do
      line = LazyHTML.query(document, "div[class~='border-#{tone}'] > div")
      assert Enum.count(line) == 1

      assert line |> LazyHTML.text() |> String.replace(~r/\s+/, "") == "user.#{changed_name}"

      highlighted_words = LazyHTML.query(line, "span.whitespace-pre-wrap > span.font-semibold")
      assert Enum.map(highlighted_words, &LazyHTML.text/1) == [changed_name]
    end
  end

  describe "WorkspaceComponents.hunk_card/1" do
    test "scopes hunk card element ID with parent_id" do
      diff = """
      --- a/test.ex
      +++ b/test.ex
      @@ -1,1 +1,1 @@
      -old
      +new
      """

      {:ok, [file_diff]} = DiffParser.parse(diff)
      [hunk] = file_diff.hunks

      # Default parent_id
      rendered_default =
        render_component(&WorkspaceComponents.hunk_card/1, %{
          hunk: hunk
        })

      assert rendered_default =~ "id=\"diff-viewer-container-hunk-card-hunk-1\""

      # Explicit parent_id
      rendered_scoped =
        render_component(&WorkspaceComponents.hunk_card/1, %{
          parent_id: "scoped-viewer-xyz",
          hunk: hunk
        })

      assert rendered_scoped =~ "id=\"scoped-viewer-xyz-hunk-card-hunk-1\""
    end
  end

  describe "WorkspaceComponents.interactive_diff_viewer/1" do
    test "renders parameterized diff viewer with split and inline modes" do
      diff = """
      --- a/lib/test.ex
      +++ b/lib/test.ex
      @@ -1,2 +1,3 @@
       defmodule Test do
      +  def hello, do: :world
       end
      """

      rendered_inline =
        render_component(&WorkspaceComponents.interactive_diff_viewer/1, %{
          id: "custom-diff-viewer-1",
          diff_text: diff,
          file_path: "lib/test.ex",
          diff_mode: "inline"
        })

      assert rendered_inline =~ "id=\"custom-diff-viewer-1\""
      assert rendered_inline =~ "id=\"custom-diff-viewer-1-copy-btn\""
      assert rendered_inline =~ "id=\"custom-diff-viewer-1-hunk-card-hunk-1\""
      assert rendered_inline =~ "lib/test.ex"
      assert rendered_inline =~ "def hello, do: :world"

      rendered_split =
        render_component(&WorkspaceComponents.interactive_diff_viewer/1, %{
          id: "custom-diff-viewer-2",
          diff_text: diff,
          file_path: "lib/test.ex",
          diff_mode: "split"
        })

      assert rendered_split =~ "id=\"custom-diff-viewer-2\""
      assert rendered_split =~ "id=\"custom-diff-viewer-2-hunk-card-hunk-1\""
      assert rendered_split =~ "Original"
      assert rendered_split =~ "Modified"
    end

    test "renders checkpoint mode with 1-click rollback controls" do
      diff = """
      --- a/lib/checkpoint.ex
      +++ b/lib/checkpoint.ex
      @@ -1,2 +1,2 @@
      -old_code()
      +new_code()
      """

      rendered =
        render_component(&WorkspaceComponents.interactive_diff_viewer/1, %{
          id: "checkpoint-diff-viewer",
          diff_text: diff,
          file_path: "lib/checkpoint.ex",
          is_checkpoint: true,
          rollback_tx_id: "tx_test_12345"
        })

      # Checkpoint header rollback button
      assert rendered =~ "phx-click=\"rollback_to_checkpoint\""
      assert rendered =~ "phx-value-tx_id=\"tx_test_12345\""
      assert rendered =~ "1-Click Rollback"

      # Hunk card rollback button
      assert rendered =~ "Revert Hunk"

      # Git staging buttons are NOT rendered in checkpoint mode
      refute rendered =~ "Accept All"
      refute rendered =~ "Accept Hunk"
    end

    test "renders unstage_hunk when staged={true} and accept_hunk when staged={false}" do
      diff = """
      --- a/lib/test.ex
      +++ b/lib/test.ex
      @@ -1,2 +1,3 @@
       defmodule Test do
      +  def hello, do: :world
       end
      """

      rendered_staged =
        render_component(&WorkspaceComponents.interactive_diff_viewer/1, %{
          id: "staged-diff-viewer",
          diff_text: diff,
          file_path: "lib/test.ex",
          staged: true
        })

      assert rendered_staged =~ "phx-click=\"unstage_hunk\""
      assert rendered_staged =~ "Unstage Hunk"
      refute rendered_staged =~ "phx-click=\"accept_hunk\""
      refute rendered_staged =~ "Accept Hunk"

      rendered_unstaged =
        render_component(&WorkspaceComponents.interactive_diff_viewer/1, %{
          id: "unstaged-diff-viewer",
          diff_text: diff,
          file_path: "lib/test.ex",
          staged: false
        })

      assert rendered_unstaged =~ "phx-click=\"accept_hunk\""
      assert rendered_unstaged =~ "Accept Hunk"
      refute rendered_unstaged =~ "phx-click=\"unstage_hunk\""
      refute rendered_unstaged =~ "Unstage Hunk"

      # Also verify default staged=false when omitted
      rendered_default =
        render_component(&WorkspaceComponents.interactive_diff_viewer/1, %{
          id: "default-diff-viewer",
          diff_text: diff,
          file_path: "lib/test.ex"
        })

      assert rendered_default =~ "phx-click=\"accept_hunk\""
      refute rendered_default =~ "phx-click=\"unstage_hunk\""
    end
  end

  describe "TimeTravel patch conversion and checkpoint diffs" do
    test "patch_to_unified_diff/1 handles created files with /dev/null header" do
      patch = %{
        "path" => "lib/new_file.ex",
        "file_existed" => false,
        "original_content" => nil,
        "new_content" => "defmodule NewFile do\n  def run, do: :ok\nend\n"
      }

      diff_text = TimeTravel.patch_to_unified_diff(patch)
      assert diff_text =~ "--- /dev/null"
      assert diff_text =~ "+++ b/lib/new_file.ex"
      assert diff_text =~ "+defmodule NewFile do"

      {:ok, [fd]} = DiffParser.parse(diff_text)
      assert fd.status == :added
      assert length(fd.hunks) == 1
    end

    test "patch_to_unified_diff/1 handles deleted files with /dev/null header" do
      patch = %{
        "path" => "lib/old_file.ex",
        "file_existed" => true,
        "original_content" => "defmodule OldFile do\nend\n",
        "new_content" => nil
      }

      diff_text = TimeTravel.patch_to_unified_diff(patch)
      assert diff_text =~ "--- a/lib/old_file.ex"
      assert diff_text =~ "+++ /dev/null"
      assert diff_text =~ "-defmodule OldFile do"

      {:ok, [fd]} = DiffParser.parse(diff_text)
      assert fd.status == :deleted
      assert length(fd.hunks) == 1
    end

    test "checkpoint_diffs/1 converts mutation snapshot into structured diff maps" do
      snapshot = %{
        patches: [
          %{
            "path" => "lib/calc.ex",
            "file_existed" => true,
            "original_content" => "def a, do: 1\n",
            "new_content" => "def a, do: 2\n"
          },
          %{
            "path" => "lib/created.ex",
            "file_existed" => false,
            "original_content" => nil,
            "new_content" => "def b, do: 3\n"
          }
        ]
      }

      diffs = TimeTravel.checkpoint_diffs(snapshot)
      assert length(diffs) == 2

      [d1, d2] = diffs
      assert d1.path == "lib/calc.ex"
      assert d1.status == :modified
      assert length(d1.hunks) == 1

      assert d2.path == "lib/created.ex"
      assert d2.status == :added
      assert length(d2.hunks) == 1
    end
  end

  describe "Detached.DiffLive Checkpoint Subtab and Scrubber Integration" do
    setup do
      unique_suffix = System.unique_integer([:positive])
      temp_root = Path.join(System.tmp_dir!(), "iex_detached_diff_test_#{unique_suffix}")
      File.mkdir_p!(temp_root)

      {:ok, project} =
        Projects.create_project(%{
          name: "Detached Diff Test Project #{unique_suffix}",
          root_path: temp_root
        })

      {:ok, session} =
        Sessions.create_session(%{
          project_id: project.id,
          title: "Detached Diff Session #{unique_suffix}"
        })

      on_exit(fn ->
        File.rm_rf(temp_root)
      end)

      {:ok, project: project, session: session, temp_root: temp_root}
    end

    test "mounts with changes subtab and switches to checkpoints subtab", %{
      conn: conn,
      session: session,
      temp_root: temp_root
    } do
      test_file = Path.join(temp_root, "hello.ex")
      File.write!(test_file, "defmodule Hello do\n  def world, do: 1\nend\n")

      {:ok, cp} =
        TimeTravel.create_checkpoint(%{
          session_id: session.id,
          project_root: temp_root,
          label: "Test Checkpoint",
          patches: [
            %{
              "path" => test_file,
              "file_existed" => false,
              "original_content" => nil,
              "new_content" => "defmodule Hello do\n  def world, do: 1\nend\n"
            }
          ]
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/detached/diff")

      # Initially on changes subtab
      assert has_element?(view, "#diff-viewer-container")

      # Switch to checkpoints subtab
      view
      |> element("button[phx-click='switch_changes_subtab'][phx-value-tab='checkpoints']")
      |> render_click()

      assert has_element?(view, "#checkpoints-timeline")
      assert has_element?(view, "#checkpoint-node-#{cp.transaction_id}")
      assert has_element?(view, "#checkpoint-diff-inspector")

      # Select checkpoint and assert interactive diff viewer renders
      view |> element("#checkpoint-node-#{cp.transaction_id}") |> render_click()
      assert has_element?(view, "#checkpoint-diff-inspector")
      assert has_element?(view, "button[phx-click='rollback_to_checkpoint']")

      # 1-Click Rollback Latest works cleanly
      view |> element("button[phx-click='rollback_latest_checkpoint']") |> render_click()
      assert render(view) =~ "Rolled back"
    end
  end
end
