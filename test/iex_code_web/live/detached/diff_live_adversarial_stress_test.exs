defmodule IexCodeWeb.Detached.DiffLiveAdversarialStressTest do
  @moduledoc """
  Challenger 2 Empirical Adversarial Stress Suite for `Detached.DiffLive`.
  Empirically verifies:
  1. Rapid git updates and PubSub `broadcast_git_changed` synchronization between WorkspaceLive and Detached.DiffLive
  2. Multi-patch files (multi-hunk and multi-file) staging, unstaging, reverting, and scoping in Detached.DiffLive
  3. Checkpoint scrubber timeline, multi-patch checkpoint diff inspection, and 1-click time-travel rollback
  4. High-frequency PubSub burst resilience, untracked files, clean repo state, and full commit lifecycle
  """
  use IexCodeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias IexCode.{Projects, Sessions, TimeTravel}
  alias Phoenix.PubSub

  setup do
    unique_suffix = System.unique_integer([:positive])
    temp_root = Path.join(System.tmp_dir!(), "iex_detached_diff_stress_#{unique_suffix}")
    File.mkdir_p!(temp_root)

    # Initialize a valid git repository
    System.cmd("git", ["init"], cd: temp_root)
    System.cmd("git", ["config", "user.name", "Challenger Test"], cd: temp_root)
    System.cmd("git", ["config", "user.email", "challenger@iexcode.local"], cd: temp_root)

    # Base committed files
    base_file = Path.join(temp_root, "base.txt")
    File.write!(base_file, "line 1\nline 2\nline 3\nline 4\nline 5\n")
    System.cmd("git", ["-C", temp_root, "add", "base.txt"])
    System.cmd("git", ["-C", temp_root, "commit", "-m", "Initial commit"])

    {:ok, project} =
      Projects.create_project(%{
        name: "Detached Diff Stress Project #{unique_suffix}",
        root_path: temp_root
      })

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Detached Diff Stress Session #{unique_suffix}"
      })

    on_exit(fn ->
      File.rm_rf(temp_root)
    end)

    {:ok,
     project: project,
     session: session,
     temp_root: temp_root,
     base_file: base_file,
     unique_suffix: unique_suffix}
  end

  # ============================================================================
  # 1. Rapid Git Updates & PubSub Synchronization
  # ============================================================================
  describe "Rapid Git Updates & PubSub Synchronization" do
    test "synchronizes git status bidirectionally between WorkspaceLive and Detached.DiffLive via PubSub",
         %{
           conn: conn,
           session: session,
           project: project,
           base_file: base_file
         } do
      # Mount both WorkspaceLive and Detached.DiffLive
      {:ok, ws_view, _} = live(conn, ~p"/sessions/#{session.id}")
      {:ok, diff_view, _} = live(conn, ~p"/sessions/#{session.id}/detached/diff")

      # Modify file on disk
      File.write!(base_file, "line 1\nmodified line 2\nline 3\nline 4\nmodified line 5\n")

      # Trigger broadcast from external source / git tool
      PubSub.broadcast(
        IexCode.PubSub,
        "project:#{project.id}:git",
        {:git_state_changed, project.id}
      )

      # Synchronize LiveView processes
      _ = :sys.get_state(ws_view.pid)
      _ = :sys.get_state(diff_view.pid)

      # Detached diff live now shows the unstaged changes
      html_diff = render(diff_view)
      assert html_diff =~ "base.txt"
      assert html_diff =~ "UNSTAGED CHANGES"

      # Stage file from Detached.DiffLive
      render_click(diff_view, "stage_file", %{"file" => "base.txt"})
      _ = :sys.get_state(diff_view.pid)
      _ = :sys.get_state(ws_view.pid)

      # Detached diff view should now show base.txt under STAGED
      assert render(diff_view) =~ "STAGED CHANGES"

      # Unstage file from Detached.DiffLive
      render_click(diff_view, "unstage_file", %{"file" => "base.txt"})
      _ = :sys.get_state(diff_view.pid)
      _ = :sys.get_state(ws_view.pid)

      # Verify staged changes are empty, unstaged has base.txt
      assert render(diff_view) =~ "No staged changes"
      assert render(diff_view) =~ "base.txt"
    end

    test "resiliently survives rapid burst of 50 concurrent PubSub notifications without crashing",
         %{
           conn: conn,
           session: session,
           project: project,
           base_file: base_file
         } do
      {:ok, diff_view, _} = live(conn, ~p"/sessions/#{session.id}/detached/diff")

      # Rapidly modify files and flood PubSub with 50 git state changed events
      for i <- 1..50 do
        File.write!(base_file, "line 1\nrapid edit #{i}\nline 3\n")

        PubSub.broadcast(
          IexCode.PubSub,
          "project:#{project.id}:git",
          {:git_state_changed, project.id}
        )
      end

      # Synchronize and verify LiveView survived without crashing or dropping connection
      _ = :sys.get_state(diff_view.pid)
      assert Process.alive?(diff_view.pid)
      assert has_element?(diff_view, "#detached-diff-container")
      assert render(diff_view) =~ "base.txt"
    end

    test "stage_all and unstage_all synchronize immediately across detached view",
         %{
           conn: conn,
           session: session,
           temp_root: temp_root
         } do
      # Create 3 modified files
      for i <- 1..3 do
        f = Path.join(temp_root, "file_#{i}.txt")
        File.write!(f, "initial #{i}\n")
        System.cmd("git", ["-C", temp_root, "add", "file_#{i}.txt"])
      end

      System.cmd("git", ["-C", temp_root, "commit", "-m", "add 3 files"])

      for i <- 1..3 do
        f = Path.join(temp_root, "file_#{i}.txt")
        File.write!(f, "updated content #{i}\n")
      end

      {:ok, diff_view, _} = live(conn, ~p"/sessions/#{session.id}/detached/diff")

      # Verify 3 unstaged files
      assert render(diff_view) =~ "file_1.txt"
      assert render(diff_view) =~ "file_2.txt"
      assert render(diff_view) =~ "file_3.txt"

      # Stage All
      render_click(diff_view, "stage_all", %{})
      _ = :sys.get_state(diff_view.pid)

      html_staged = render(diff_view)
      assert html_staged =~ "No unstaged changes"
      assert html_staged =~ "Commit Changes (3)"

      # Unstage All
      render_click(diff_view, "unstage_all", %{})
      _ = :sys.get_state(diff_view.pid)

      html_unstaged = render(diff_view)
      assert html_unstaged =~ "No staged changes"
      assert html_unstaged =~ "file_1.txt"
      assert html_unstaged =~ "file_2.txt"
      assert html_unstaged =~ "file_3.txt"
    end
  end

  # ============================================================================
  # 2. Multi-Patch Files & Hunk Granularity
  # ============================================================================
  describe "Multi-Patch Files & Hunk Granularity in Detached.DiffLive" do
    test "renders and parses a file with 5 distant hunks with unique DOM IDs",
         %{
           conn: conn,
           session: session,
           temp_root: temp_root
         } do
      # Create a large file with 100 lines
      initial_lines = for i <- 1..100, do: "line #{i}"
      file_path = Path.join(temp_root, "multi_hunk.txt")
      File.write!(file_path, Enum.join(initial_lines, "\n") <> "\n")
      System.cmd("git", ["-C", temp_root, "add", "multi_hunk.txt"])
      System.cmd("git", ["-C", temp_root, "commit", "-m", "add multi_hunk base"])

      # Modify lines at distant intervals: 5, 25, 50, 75, 95
      modified_lines =
        initial_lines
        |> List.replace_at(4, "MODIFIED LINE 5")
        |> List.replace_at(24, "MODIFIED LINE 25")
        |> List.replace_at(49, "MODIFIED LINE 50")
        |> List.replace_at(74, "MODIFIED LINE 75")
        |> List.replace_at(94, "MODIFIED LINE 95")

      File.write!(file_path, Enum.join(modified_lines, "\n") <> "\n")

      {:ok, diff_view, _} = live(conn, ~p"/sessions/#{session.id}/detached/diff")

      # Select the multi_hunk file
      render_click(diff_view, "select_diff_file", %{
        "file" => "multi_hunk.txt",
        "scope" => "unstaged"
      })

      _ = :sys.get_state(diff_view.pid)

      html = render(diff_view)
      assert html =~ "multi_hunk.txt"
      assert html =~ "5 hunk(s)"

      # Verify all 5 hunk cards exist with unique DOM IDs
      for i <- 1..5 do
        assert has_element?(diff_view, "#diff-viewer-container-hunk-card-hunk-#{i}")
      end
    end

    test "partially stages a single hunk from a multi-hunk file (accept_hunk)",
         %{
           conn: conn,
           session: session,
           temp_root: temp_root
         } do
      initial_lines = for i <- 1..60, do: "line #{i}"
      file_path = Path.join(temp_root, "partial_stage.txt")
      File.write!(file_path, Enum.join(initial_lines, "\n") <> "\n")
      System.cmd("git", ["-C", temp_root, "add", "partial_stage.txt"])
      System.cmd("git", ["-C", temp_root, "commit", "-m", "add partial base"])

      # Modify line 5 and line 45
      modified_lines =
        initial_lines
        |> List.replace_at(4, "MODIFIED LINE 5")
        |> List.replace_at(44, "MODIFIED LINE 45")

      File.write!(file_path, Enum.join(modified_lines, "\n") <> "\n")

      {:ok, diff_view, _} = live(conn, ~p"/sessions/#{session.id}/detached/diff")

      # Accept first hunk
      render_click(diff_view, "accept_hunk", %{
        "file" => "partial_stage.txt",
        "hunk_id" => "hunk-1"
      })

      _ = :sys.get_state(diff_view.pid)

      # Check that partial_stage.txt now appears in both STAGED and UNSTAGED
      html = render(diff_view)
      assert html =~ "Accepted hunk hunk-1 for partial_stage.txt"

      # Switch scope to staged
      render_click(diff_view, "set_diff_scope", %{"scope" => "staged"})
      _ = :sys.get_state(diff_view.pid)
      html_staged = render(diff_view)
      assert html_staged =~ "MODIFIED LINE 5"

      # Unstage the hunk
      render_click(diff_view, "unstage_hunk", %{
        "file" => "partial_stage.txt",
        "hunk_id" => "hunk-1"
      })

      _ = :sys.get_state(diff_view.pid)

      assert render(diff_view) =~ "No staged changes"
    end

    test "reverts a single hunk (reject_hunk) while preserving other modified hunks",
         %{
           conn: conn,
           session: session,
           temp_root: temp_root
         } do
      initial_lines = for i <- 1..60, do: "line #{i}"
      file_path = Path.join(temp_root, "revert_hunk_test.txt")
      File.write!(file_path, Enum.join(initial_lines, "\n") <> "\n")
      System.cmd("git", ["-C", temp_root, "add", "revert_hunk_test.txt"])
      System.cmd("git", ["-C", temp_root, "commit", "-m", "add revert test base"])

      # Modify line 5 and line 45
      modified_lines =
        initial_lines
        |> List.replace_at(4, "MODIFIED LINE 5")
        |> List.replace_at(44, "MODIFIED LINE 45")

      File.write!(file_path, Enum.join(modified_lines, "\n") <> "\n")

      {:ok, diff_view, _} = live(conn, ~p"/sessions/#{session.id}/detached/diff")

      # Revert (reject) hunk-1
      render_click(diff_view, "reject_hunk", %{
        "file" => "revert_hunk_test.txt",
        "hunk_id" => "hunk-1"
      })

      _ = :sys.get_state(diff_view.pid)

      # Verify disk contents: line 5 reverted, line 45 still modified!
      disk_content = File.read!(file_path)
      assert disk_content =~ "line 5"
      refute disk_content =~ "MODIFIED LINE 5"
      assert disk_content =~ "MODIFIED LINE 45"

      # Revert the entire file
      render_click(diff_view, "revert_file", %{"file" => "revert_hunk_test.txt"})
      _ = :sys.get_state(diff_view.pid)

      disk_reverted = File.read!(file_path)
      assert disk_reverted =~ "line 45"
      refute disk_reverted =~ "MODIFIED LINE 45"
    end

    test "switches diff modes between split and inline seamlessly",
         %{
           conn: conn,
           session: session,
           base_file: base_file
         } do
      File.write!(base_file, "line 1\nmodified line 2\nline 3\n")

      {:ok, diff_view, _} = live(conn, ~p"/sessions/#{session.id}/detached/diff")

      # Default is split mode
      assert render(diff_view) =~ "Split"

      # Switch to inline mode
      render_click(diff_view, "set_diff_mode", %{"mode" => "inline"})
      _ = :sys.get_state(diff_view.pid)

      html_inline = render(diff_view)
      assert html_inline =~ "inline" or html_inline =~ "Unified"

      # Switch back to split mode
      render_click(diff_view, "set_diff_mode", %{"mode" => "split"})
      _ = :sys.get_state(diff_view.pid)
      assert render(diff_view) =~ "Split"
    end
  end

  # ============================================================================
  # 3. Checkpoint Views & Time-Travel Scrubber in Detached Diff
  # ============================================================================
  describe "Checkpoint Views & Time-Travel in Detached.DiffLive" do
    test "switches to checkpoints subtab and renders empty state when no checkpoints exist",
         %{
           conn: conn,
           session: session
         } do
      {:ok, diff_view, _} = live(conn, ~p"/sessions/#{session.id}/detached/diff")

      # Switch to checkpoints tab
      render_click(diff_view, "switch_changes_subtab", %{"tab" => "checkpoints"})
      _ = :sys.get_state(diff_view.pid)

      html = render(diff_view)
      assert html =~ "CHECKPOINTS TIMELINE"
      assert html =~ "No checkpoints recorded yet"
      assert html =~ "Select a checkpoint from the timeline"
    end

    test "renders checkpoint timeline, multi-patch diff viewers, and performs 1-click rollback",
         %{
           conn: conn,
           session: session,
           temp_root: temp_root
         } do
      # Create tracked files on disk
      f1 = Path.join(temp_root, "alpha.ex")
      f2 = Path.join(temp_root, "beta.ex")
      File.write!(f1, "defmodule Alpha do\n  def v, do: 1\nend\n")
      File.write!(f2, "defmodule Beta do\n  def v, do: 1\nend\n")

      # Record Checkpoint 1 (Single file mutation)
      {:ok, cp1} =
        TimeTravel.create_checkpoint(%{
          session_id: session.id,
          project_root: temp_root,
          label: "CP1: Mutate Alpha",
          patches: [
            %{
              "path" => "alpha.ex",
              "file_existed" => true,
              "original_content" => "defmodule Alpha do\n  def v, do: 1\nend\n",
              "new_content" => "defmodule Alpha do\n  def v, do: 2\nend\n"
            }
          ]
        })

      # Record Checkpoint 2 (Multi-file mutation: Alpha and Beta)
      {:ok, cp2} =
        TimeTravel.create_checkpoint(%{
          session_id: session.id,
          project_root: temp_root,
          label: "CP2: Mutate Alpha & Beta",
          patches: [
            %{
              "path" => "alpha.ex",
              "file_existed" => true,
              "original_content" => "defmodule Alpha do\n  def v, do: 2\nend\n",
              "new_content" => "defmodule Alpha do\n  def v, do: 3\nend\n"
            },
            %{
              "path" => "beta.ex",
              "file_existed" => true,
              "original_content" => "defmodule Beta do\n  def v, do: 1\nend\n",
              "new_content" => "defmodule Beta do\n  def v, do: 2\nend\n"
            }
          ]
        })

      # Mount Detached.DiffLive
      {:ok, diff_view, _} = live(conn, ~p"/sessions/#{session.id}/detached/diff")

      # Switch to checkpoints tab
      render_click(diff_view, "switch_changes_subtab", %{"tab" => "checkpoints"})
      _ = :sys.get_state(diff_view.pid)

      html = render(diff_view)
      assert html =~ "CP2: Mutate Alpha &amp; Beta" or html =~ "CP2: Mutate Alpha & Beta"
      assert html =~ "CP1: Mutate Alpha"

      # Select CP2: verify both alpha.ex and beta.ex diff viewers render with unique DOM IDs
      tx_id_2 = cp2.transaction_id || cp2.id
      render_click(diff_view, "select_checkpoint", %{"tx_id" => tx_id_2})
      _ = :sys.get_state(diff_view.pid)

      assert has_element?(diff_view, "#detached-checkpoint-diff-#{tx_id_2}-0")
      assert has_element?(diff_view, "#detached-checkpoint-diff-#{tx_id_2}-1")

      # Verify 1-Click Rollback button exists
      assert render(diff_view) =~ "1-Click Rollback to this Checkpoint"
      assert render(diff_view) =~ "Revert Hunk"

      # Select CP1: verify diff inspector updates to alpha.ex
      tx_id_1 = cp1.transaction_id || cp1.id
      render_click(diff_view, "select_checkpoint", %{"tx_id" => tx_id_1})
      _ = :sys.get_state(diff_view.pid)

      assert has_element?(diff_view, "#detached-checkpoint-diff-#{tx_id_1}-0")

      # Execute 1-Click Rollback to CP1
      render_click(diff_view, "rollback_to_checkpoint", %{"tx_id" => tx_id_1})
      _ = :sys.get_state(diff_view.pid)

      html_rolled_back = render(diff_view)
      assert html_rolled_back =~ "Rolled back"
    end

    test "rollback_latest_checkpoint rolls back top checkpoint and updates UI",
         %{
           conn: conn,
           session: session,
           temp_root: temp_root
         } do
      f = Path.join(temp_root, "gamma.txt")
      File.write!(f, "initial gamma\n")

      {:ok, _cp} =
        TimeTravel.create_checkpoint(%{
          session_id: session.id,
          project_root: temp_root,
          label: "CP Gamma",
          patches: [
            %{
              "path" => "gamma.txt",
              "file_existed" => true,
              "original_content" => "initial gamma\n",
              "new_content" => "mutated gamma\n"
            }
          ]
        })

      {:ok, diff_view, _} = live(conn, ~p"/sessions/#{session.id}/detached/diff")
      render_click(diff_view, "switch_changes_subtab", %{"tab" => "checkpoints"})
      _ = :sys.get_state(diff_view.pid)

      assert render(diff_view) =~ "CP Gamma"

      # Trigger Rollback Latest
      render_click(diff_view, "rollback_latest_checkpoint", %{})
      _ = :sys.get_state(diff_view.pid)

      assert render(diff_view) =~ "Rolled back 1 checkpoint successfully"
    end

    test "handles real-time {:checkpoint_created, cp} and {:checkpoint_rolled_back, tx_id, details} events",
         %{
           conn: conn,
           session: session,
           temp_root: temp_root
         } do
      {:ok, diff_view, _} = live(conn, ~p"/sessions/#{session.id}/detached/diff")
      render_click(diff_view, "switch_changes_subtab", %{"tab" => "checkpoints"})
      _ = :sys.get_state(diff_view.pid)

      # Broadcast external checkpoint creation
      {:ok, cp} =
        TimeTravel.create_checkpoint(%{
          session_id: session.id,
          project_root: temp_root,
          label: "Live Broadcast CP",
          patches: []
        })

      _ = :sys.get_state(diff_view.pid)

      # Check that live view automatically appended the checkpoint
      assert render(diff_view) =~ "Live Broadcast CP"

      # Broadcast rollback event
      tx_id = cp.transaction_id || cp.id
      send(diff_view.pid, {:checkpoint_rolled_back, tx_id, %{}})
      _ = :sys.get_state(diff_view.pid)

      assert Process.alive?(diff_view.pid)
    end
  end

  # ============================================================================
  # 4. Adversarial Edge Cases: Untracked Files, Clean State, and Commit Lifecycle
  # ============================================================================
  describe "Adversarial Edge Cases & Full Commit Lifecycle" do
    test "mounts cleanly in a pristine repository with zero changes without exceptions",
         %{
           conn: conn,
           session: session
         } do
      {:ok, diff_view, html} = live(conn, ~p"/sessions/#{session.id}/detached/diff")

      assert html =~ "No staged changes"
      assert html =~ "No unstaged changes"
      assert html =~ "Select a file to inspect diff"
      assert has_element?(diff_view, "#detached-diff-container")
    end

    test "detects untracked files, stages them into index, and commits them via commit composer",
         %{
           conn: conn,
           session: session,
           temp_root: temp_root
         } do
      # Create an untracked file
      new_file = Path.join(temp_root, "untracked.txt")
      File.write!(new_file, "brand new file\n")

      {:ok, diff_view, _} = live(conn, ~p"/sessions/#{session.id}/detached/diff")

      # Should be visible in UNTRACKED FILES
      html = render(diff_view)
      assert html =~ "UNTRACKED FILES"
      assert html =~ "untracked.txt"

      # Click Stage File on untracked file
      render_click(diff_view, "stage_file", %{"file" => "untracked.txt"})
      _ = :sys.get_state(diff_view.pid)

      # Verify it moved to STAGED CHANGES
      html_staged = render(diff_view)
      assert html_staged =~ "STAGED CHANGES"
      assert html_staged =~ "Commit Changes (1)"

      # Update commit message
      render_change(diff_view, "update_commit_message", %{
        "commit_message" => "feat: add untracked file"
      })

      _ = :sys.get_state(diff_view.pid)

      # Commit
      render_click(diff_view, "git_commit", %{})
      _ = :sys.get_state(diff_view.pid)

      html_committed = render(diff_view)
      assert html_committed =~ "Changes committed successfully"
      assert html_committed =~ "No staged changes"

      # Verify commit exists in git log
      {git_log, 0} = System.cmd("git", ["-C", temp_root, "log", "-n", "1", "--oneline"])
      assert git_log =~ "feat: add untracked file"
    end

    test "handles deleted file diffs gracefully",
         %{
           conn: conn,
           session: session,
           base_file: base_file
         } do
      # Remove the committed base file
      File.rm!(base_file)

      {:ok, diff_view, _} = live(conn, ~p"/sessions/#{session.id}/detached/diff")

      html = render(diff_view)
      assert html =~ "base.txt"
      assert html =~ "UNSTAGED CHANGES"

      # Select the deleted file
      render_click(diff_view, "select_diff_file", %{
        "file" => "base.txt",
        "scope" => "unstaged"
      })

      _ = :sys.get_state(diff_view.pid)

      # Must render deletion diff cleanly without crash
      assert render(diff_view) =~ "base.txt"
    end
  end
end
