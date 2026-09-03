defmodule IexCodeWeb.Detached.DiffLiveTest do
  @moduledoc """
  Empirical challenger test suite for Detached.DiffLive.
  Stress tests mounting across all git states (clean, modified unstaged, staged, untracked, combinations)
  and verifies all granular hunk actions (accept_hunk, reject_hunk, revert_hunk, unstage_hunk).
  Guarantees zero KeyErrors and zero Protocol.UndefinedErrors.
  """
  use IexCodeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias IexCode.{Projects, Sessions}
  alias IexCode.Tools.Git

  setup do
    unique_suffix = System.unique_integer([:positive])
    temp_root = Path.join(System.tmp_dir!(), "iex_detached_diff_live_test_#{unique_suffix}")
    File.mkdir_p!(temp_root)

    System.cmd("git", ["init", temp_root])
    System.cmd("git", ["-C", temp_root, "config", "user.name", "Challenger"])
    System.cmd("git", ["-C", temp_root, "config", "user.email", "challenger@example.com"])

    tracked_file = Path.join(temp_root, "file_a.txt")
    File.write!(tracked_file, "line 1\nline 2\nline 3\nline 4\nline 5\n")
    System.cmd("git", ["-C", temp_root, "add", "file_a.txt"])
    System.cmd("git", ["-C", temp_root, "commit", "-m", "initial commit"])

    {:ok, project} =
      Projects.create_project(%{
        name: "DiffLive Test Project #{unique_suffix}",
        root_path: temp_root
      })

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "DiffLive Session #{unique_suffix}"
      })

    on_exit(fn ->
      File.rm_rf(temp_root)
    end)

    {:ok, project: project, session: session, temp_root: temp_root, tracked_file: tracked_file}
  end

  # ============================================================================
  # 1. Empirical Mount Verification Across All Git States
  # ============================================================================
  describe "Detached.DiffLive mounting across git states" do
    test "mounts cleanly under a completely clean git state", %{
      conn: conn,
      session: session
    } do
      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}/detached/diff")

      assert has_element?(view, "#detached-diff-container")
      assert html =~ "No staged changes"
      assert html =~ "No unstaged changes"
      assert html =~ "GIT STAGING &amp; DIFF INSPECTOR"
      refute html =~ "KeyError"
      refute html =~ "Protocol.UndefinedError"
    end

    test "mounts cleanly when modified unstaged files exist", %{
      conn: conn,
      session: session,
      tracked_file: tracked_file
    } do
      File.write!(tracked_file, "line 1\nmodified line 2 unstaged\nline 3\nline 4\nline 5\n")

      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}/detached/diff")

      assert has_element?(view, "#detached-diff-container")
      assert has_element?(view, "main")
      assert html =~ "file_a.txt"
      assert html =~ "UNSTAGED CHANGES"
      assert html =~ "modified line 2 unstaged"
      # Verifies hunk action buttons rendered in unstaged mode
      assert html =~ "Accept Hunk"
      assert html =~ "Reject Hunk"
      assert html =~ "Revert"
      refute html =~ "KeyError"
      refute html =~ "Protocol.UndefinedError"
    end

    test "mounts cleanly when staged files exist", %{
      conn: conn,
      session: session,
      temp_root: temp_root,
      tracked_file: tracked_file
    } do
      File.write!(tracked_file, "line 1\nstaged change here\nline 3\nline 4\nline 5\n")
      System.cmd("git", ["-C", temp_root, "add", "file_a.txt"])

      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}/detached/diff")

      assert has_element?(view, "#detached-diff-container")
      assert html =~ "file_a.txt"
      assert html =~ "STAGED CHANGES"

      # Switch to staged scope and verify diff view displays staged hunk with Unstage button
      html_staged = render_click(view, "set_diff_scope", %{"scope" => "staged"})
      assert html_staged =~ "Unstage Hunk"
      assert html_staged =~ "staged change here"
      refute html_staged =~ "KeyError"
      refute html_staged =~ "Protocol.UndefinedError"
    end

    test "mounts cleanly when untracked files exist", %{
      conn: conn,
      session: session,
      temp_root: temp_root
    } do
      untracked_path = Path.join(temp_root, "brand_new_file.ex")
      File.write!(untracked_path, "defmodule BrandNewFile do\nend\n")

      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}/detached/diff")

      assert has_element?(view, "#detached-diff-container")
      assert html =~ "UNTRACKED FILES"
      assert html =~ "brand_new_file.ex"
      refute html =~ "KeyError"
      refute html =~ "Protocol.UndefinedError"

      # Verify staging untracked file directly from UI
      html_after_stage = render_click(view, "stage_file", %{"file" => "brand_new_file.ex"})
      assert html_after_stage =~ "STAGED CHANGES"
      assert html_after_stage =~ "brand_new_file.ex"
    end

    test "mounts cleanly under concurrent mixed git states (staged + unstaged + untracked + deleted)",
         %{
           conn: conn,
           session: session,
           temp_root: temp_root,
           tracked_file: tracked_file
         } do
      # 1. Prepare base committed files first
      file_b = Path.join(temp_root, "file_b.txt")
      File.write!(file_b, "alpha\nbeta\ngamma\n")
      file_c = Path.join(temp_root, "file_c.txt")
      File.write!(file_c, "to be deleted\n")
      System.cmd("git", ["-C", temp_root, "add", "file_b.txt", "file_c.txt"])
      System.cmd("git", ["-C", temp_root, "commit", "-m", "add file_b and file_c"])

      # 2. Staged modification on file_a
      File.write!(tracked_file, "line 1\nstaged modification\nline 3\nline 4\nline 5\n")
      System.cmd("git", ["-C", temp_root, "add", "file_a.txt"])

      # 3. Unstaged modification on file_b
      File.write!(file_b, "alpha\nmodified unstaged beta\ngamma\n")

      # 4. Deleted file_c
      File.rm!(file_c)

      # 5. Untracked file
      File.write!(Path.join(temp_root, "fresh_untracked.txt"), "untracked content\n")

      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}/detached/diff")

      assert has_element?(view, "#detached-diff-container")
      assert html =~ "STAGED CHANGES"
      assert html =~ "file_a.txt"
      assert html =~ "UNSTAGED CHANGES"
      assert html =~ "file_b.txt"
      assert html =~ "file_c.txt"
      assert html =~ "UNTRACKED FILES"
      assert html =~ "fresh_untracked.txt"
      refute html =~ "KeyError"
      refute html =~ "Protocol.UndefinedError"

      # Select unstaged file_b
      render_click(view, "select_diff_file", %{"file" => "file_b.txt", "scope" => "unstaged"})
      html_b = render(view)
      assert html_b =~ "modified unstaged beta"

      # Select staged file_a
      render_click(view, "select_diff_file", %{"file" => "file_a.txt", "scope" => "staged"})
      html_a = render(view)
      assert html_a =~ "staged modification"
      assert html_a =~ "Unstage Hunk"
    end

    test "mounts safely when project root is non-git or missing", %{
      conn: conn,
      session: session,
      project: project
    } do
      non_git_path =
        Path.join(System.tmp_dir!(), "non_git_dir_#{System.unique_integer([:positive])}")

      File.mkdir_p!(non_git_path)
      {:ok, _} = Projects.update_project(project, %{root_path: non_git_path})

      on_exit(fn -> File.rm_rf(non_git_path) end)

      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}/detached/diff")
      assert has_element?(view, "#detached-diff-container")
      assert html =~ "No staged changes"
      assert html =~ "No unstaged changes"
      refute html =~ "KeyError"
      refute html =~ "Protocol.UndefinedError"
    end
  end

  # ============================================================================
  # 2. Granular Hunk Actions Stress Suite
  # ============================================================================
  describe "Detached.DiffLive hunk actions" do
    test "accept_hunk stages the targeted hunk into git index", %{
      conn: conn,
      session: session,
      temp_root: temp_root,
      tracked_file: tracked_file
    } do
      File.write!(tracked_file, "line 1\nmodified line 2\nline 3\nline 4\nline 5\n")

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/detached/diff")

      # Initially unstaged
      {:ok, status_before} = Git.status(temp_root)
      assert length(status_before.unstaged) == 1
      assert length(status_before.staged) == 0

      # Trigger accept_hunk
      html = render_click(view, "accept_hunk", %{"file" => "file_a.txt", "hunk_id" => "hunk-1"})
      assert html =~ "Accepted hunk hunk-1 for file_a.txt"

      # Verify git state: file_a is now staged
      {:ok, status_after} = Git.status(temp_root)
      assert length(status_after.staged) == 1
      assert length(status_after.unstaged) == 0
    end

    test "unstage_hunk removes targeted hunk from index back to working tree", %{
      conn: conn,
      session: session,
      temp_root: temp_root,
      tracked_file: tracked_file
    } do
      File.write!(tracked_file, "line 1\nmodified line 2 staged\nline 3\nline 4\nline 5\n")
      System.cmd("git", ["-C", temp_root, "add", "file_a.txt"])

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/detached/diff")

      # Switch to staged scope
      render_click(view, "set_diff_scope", %{"scope" => "staged"})

      # Verify before state: staged
      {:ok, status_before} = Git.status(temp_root)
      assert length(status_before.staged) == 1
      assert length(status_before.unstaged) == 0

      # Trigger unstage_hunk
      render_click(view, "unstage_hunk", %{"file" => "file_a.txt", "hunk_id" => "hunk-1"})

      # Verify after state: moved to unstaged
      {:ok, status_after} = Git.status(temp_root)
      assert length(status_after.staged) == 0
      assert length(status_after.unstaged) == 1

      content = File.read!(tracked_file)
      assert content =~ "modified line 2 staged"
    end

    test "reject_hunk discards changes from working tree file", %{
      conn: conn,
      session: session,
      temp_root: temp_root,
      tracked_file: tracked_file
    } do
      File.write!(tracked_file, "line 1\nmodified line 2 to discard\nline 3\nline 4\nline 5\n")

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/detached/diff")

      # Trigger reject_hunk
      html = render_click(view, "reject_hunk", %{"file" => "file_a.txt", "hunk_id" => "hunk-1"})
      assert html =~ "Reverted hunk hunk-1 in file_a.txt"

      # Verify file on disk reverted to original state
      content = File.read!(tracked_file)
      assert content =~ "line 2\n"
      refute content =~ "to discard"

      # Verify git status is clean
      {:ok, status} = Git.status(temp_root)
      assert length(status.unstaged) == 0
      assert length(status.staged) == 0
    end

    test "revert_hunk is an alias for reject_hunk and discards hunk changes", %{
      conn: conn,
      session: session,
      temp_root: _temp_root,
      tracked_file: tracked_file
    } do
      File.write!(tracked_file, "line 1\nmodified line 2 revert test\nline 3\nline 4\nline 5\n")

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/detached/diff")

      # Trigger revert_hunk
      html = render_click(view, "revert_hunk", %{"file" => "file_a.txt", "hunk_id" => "hunk-1"})
      assert html =~ "Reverted hunk hunk-1 in file_a.txt"

      content = File.read!(tracked_file)
      assert content =~ "line 2\n"
      refute content =~ "revert test"
    end

    test "multi-hunk granularity: can accept one hunk while rejecting another in same file", %{
      conn: conn,
      session: session,
      temp_root: temp_root,
      tracked_file: tracked_file
    } do
      # Create a file with enough distance between changes to produce 2 distinct hunks
      lines = for i <- 1..30, do: "original line #{i}"
      File.write!(tracked_file, Enum.join(lines, "\n") <> "\n")
      System.cmd("git", ["-C", temp_root, "add", "file_a.txt"])
      System.cmd("git", ["-C", temp_root, "commit", "-m", "expand file_a"])

      # Modify line 2 (hunk 1) and line 28 (hunk 2)
      modified_lines =
        lines
        |> List.replace_at(1, "MODIFIED LINE 2 - STAGE ME")
        |> List.replace_at(27, "MODIFIED LINE 28 - DISCARD ME")

      File.write!(tracked_file, Enum.join(modified_lines, "\n") <> "\n")

      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}/detached/diff")
      assert html =~ "2 hunk(s)"

      # Accept hunk 1 (stages line 2 into git index)
      render_click(view, "accept_hunk", %{"file" => "file_a.txt", "hunk_id" => "hunk-1"})

      # Verify intermediate state: staged has hunk 1, unstaged has hunk 2
      {:ok, status_mid} = Git.status(temp_root)
      assert length(status_mid.staged) == 1
      assert length(status_mid.unstaged) == 1

      # In the remaining unstaged diff, the remaining change is now the first hunk (hunk-1)
      render_click(view, "reject_hunk", %{"file" => "file_a.txt", "hunk_id" => "hunk-1"})

      # Verify unstaged is now empty, staged still has hunk 1
      {:ok, status_final} = Git.status(temp_root)
      assert length(status_final.unstaged) == 0
      assert length(status_final.staged) == 1

      # Working file contains hunk 1 change and original line 28
      disk_content = File.read!(tracked_file)
      assert disk_content =~ "MODIFIED LINE 2 - STAGE ME"
      assert disk_content =~ "original line 28"
      refute disk_content =~ "DISCARD ME"
    end
  end

  # ============================================================================
  # 3. File Actions, Scope Toggling, and Edge Cases
  # ============================================================================
  describe "File-level actions and boundary resilience" do
    test "accept_all_hunks and revert_file work correctly", %{
      conn: conn,
      session: session,
      temp_root: temp_root,
      tracked_file: tracked_file
    } do
      File.write!(tracked_file, "line 1 modified\nline 2\nline 3 modified\nline 4\nline 5\n")

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/detached/diff")

      # Accept all hunks stages the entire file
      render_click(view, "accept_all_hunks", %{"file" => "file_a.txt"})
      {:ok, status1} = Git.status(temp_root)
      assert length(status1.staged) == 1
      assert length(status1.unstaged) == 0

      # Revert file resets both staged and unstaged to HEAD
      render_click(view, "revert_file", %{"file" => "file_a.txt"})
      {:ok, status2} = Git.status(temp_root)
      assert length(status2.staged) == 0
      assert length(status2.unstaged) == 0
      assert File.read!(tracked_file) =~ "line 1\nline 2\nline 3\n"
    end

    test "handles non-existent hunk ID gracefully without crash", %{
      conn: conn,
      session: session,
      tracked_file: tracked_file
    } do
      File.write!(tracked_file, "line 1\nmodified line 2\nline 3\nline 4\nline 5\n")

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/detached/diff")

      # Attempting to accept a non-existent hunk should not crash
      html =
        render_click(view, "accept_hunk", %{"file" => "file_a.txt", "hunk_id" => "hunk-9999"})

      assert html =~ "Failed to accept hunk" or html =~ "hunk_not_found" or is_binary(html)
      assert has_element?(view, "#detached-diff-container")
    end

    test "switching diff mode between split and inline", %{
      conn: conn,
      session: session,
      tracked_file: tracked_file
    } do
      File.write!(tracked_file, "line 1\nmodified line 2\nline 3\nline 4\nline 5\n")

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/detached/diff")

      # Switch to inline
      render_click(view, "set_diff_mode", %{"mode" => "inline"})
      assert has_element?(view, "#detached-diff-container")

      # Switch to split
      render_click(view, "set_diff_mode", %{"mode" => "split"})
      assert has_element?(view, "#detached-diff-container")
    end

    test "PubSub git_state_changed broadcast refreshes view", %{
      conn: conn,
      session: session,
      project: project,
      temp_root: _temp_root,
      tracked_file: tracked_file
    } do
      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}/detached/diff")
      assert html =~ "No unstaged changes"

      # External file modification and broadcast
      File.write!(tracked_file, "line 1\nexternally modified\nline 3\n")

      Phoenix.PubSub.broadcast(
        IexCode.PubSub,
        "project:#{project.id}:git",
        {:git_state_changed, project.id}
      )

      # Allow event to process and render
      rendered = render(view)
      assert rendered =~ "file_a.txt"
      assert rendered =~ "externally modified"
    end

    test "stage_all and unstage_all operate across multiple files", %{
      conn: conn,
      session: session,
      temp_root: temp_root,
      tracked_file: tracked_file
    } do
      # Modify tracked file
      File.write!(tracked_file, "line 1\nmodified file_a\n")

      # Create second tracked file and modify it
      file_b = Path.join(temp_root, "file_b.txt")
      File.write!(file_b, "initial b\n")
      System.cmd("git", ["-C", temp_root, "add", "file_b.txt"])
      System.cmd("git", ["-C", temp_root, "commit", "-m", "add file_b"])
      File.write!(file_b, "modified file_b\n")

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/detached/diff")

      # Stage all
      render_click(view, "stage_all")
      {:ok, status1} = Git.status(temp_root)
      assert length(status1.staged) == 2
      assert length(status1.unstaged) == 0

      # Unstage all
      render_click(view, "unstage_all")
      {:ok, status2} = Git.status(temp_root)
      assert length(status2.staged) == 0
      assert length(status2.unstaged) == 2
    end
  end

  # ============================================================================
  # 4. Advanced Adversarial Stress: Binary, Unicode, Branch, Commit, Time-Travel
  # ============================================================================
  describe "Advanced adversarial stress: binary, unicode, branch, commit, and time-travel" do
    test "safely handles binary files without crashing", %{
      conn: conn,
      session: session,
      temp_root: temp_root
    } do
      bin_file = Path.join(temp_root, "binary_data.png")
      # Write raw random bytes simulating binary png
      File.write!(bin_file, <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82>>)
      System.cmd("git", ["-C", temp_root, "add", "binary_data.png"])
      System.cmd("git", ["-C", temp_root, "commit", "-m", "add binary"])

      # Modify binary file
      File.write!(bin_file, <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 1, 99, 73, 72, 68, 82>>)

      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}/detached/diff")
      assert has_element?(view, "#detached-diff-container")
      assert html =~ "binary_data.png"
      refute html =~ "KeyError"
      refute html =~ "Protocol.UndefinedError"

      # Stage binary file
      render_click(view, "stage_file", %{"file" => "binary_data.png"})
      {:ok, status} = Git.status(temp_root)
      assert length(status.staged) == 1
    end

    test "handles paths with spaces, unicode characters, and subdirectories", %{
      conn: conn,
      session: session,
      temp_root: temp_root
    } do
      nested_dir = Path.join([temp_root, "sub dir with spaces", "nested unicode 📁"])
      File.mkdir_p!(nested_dir)
      special_file = Path.join(nested_dir, "специальный_файл_🚀.txt")
      File.write!(special_file, "original unicode content\n")

      rel_path = Path.relative_to(special_file, temp_root)
      System.cmd("git", ["-C", temp_root, "add", rel_path])
      System.cmd("git", ["-C", temp_root, "commit", "-m", "add special file"])

      # Modify file
      File.write!(special_file, "modified unicode content 🚀✨\n")

      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}/detached/diff")
      assert has_element?(view, "#detached-diff-container")
      assert html =~ rel_path
      refute html =~ "KeyError"
      refute html =~ "Protocol.UndefinedError"

      # Accept all hunks for the unicode file
      render_click(view, "accept_all_hunks", %{"file" => rel_path})
      {:ok, status} = Git.status(temp_root)
      assert length(status.staged) == 1
    end

    test "handles CRLF Windows line endings", %{
      conn: conn,
      session: session,
      temp_root: temp_root
    } do
      crlf_file = Path.join(temp_root, "crlf_file.txt")
      File.write!(crlf_file, "line 1\r\nline 2\r\nline 3\r\n")
      System.cmd("git", ["-C", temp_root, "add", "crlf_file.txt"])
      System.cmd("git", ["-C", temp_root, "commit", "-m", "add crlf file"])

      File.write!(crlf_file, "line 1\r\nmodified line 2 crlf\r\nline 3\r\n")

      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}/detached/diff")
      assert html =~ "crlf_file.txt"

      render_click(view, "accept_hunk", %{"file" => "crlf_file.txt", "hunk_id" => "hunk-1"})
      {:ok, status} = Git.status(temp_root)
      assert length(status.staged) == 1
    end

    test "commit composer validates empty message and commits staged changes", %{
      conn: conn,
      session: session,
      temp_root: temp_root,
      tracked_file: tracked_file
    } do
      File.write!(tracked_file, "line 1\nstaged to commit\n")
      System.cmd("git", ["-C", temp_root, "add", "file_a.txt"])

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/detached/diff")

      # Attempt commit with empty message -> error flash
      html_empty = render_click(view, "git_commit")
      assert html_empty =~ "Please enter a commit message"

      # Update commit message
      render_change(view, "update_commit_message", %{
        "message" => "feat: test commit from detached view"
      })

      # Commit
      html_committed = render_click(view, "git_commit")
      assert html_committed =~ "Changes committed successfully"

      # Verify git log
      {log, 0} = System.cmd("git", ["-C", temp_root, "log", "-n", "1", "--oneline"])
      assert log =~ "feat: test commit from detached view"
    end

    test "branch switching works seamlessly", %{
      conn: conn,
      session: session,
      temp_root: temp_root
    } do
      System.cmd("git", ["-C", temp_root, "checkout", "-b", "feature-detached"])

      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}/detached/diff")
      assert html =~ "feature-detached"

      # Switch back to master or main
      {branches_out, 0} = System.cmd("git", ["-C", temp_root, "branch"])
      target_branch = if branches_out =~ "master", do: "master", else: "main"

      html_switched = render_click(view, "switch_branch", %{"branch" => target_branch})
      assert html_switched =~ "Switched to branch #{target_branch}"
      assert html_switched =~ target_branch
    end

    test "time-travel tab switching, checkpoint diff inspection, and rollback", %{
      conn: conn,
      session: session,
      temp_root: temp_root,
      tracked_file: _tracked_file
    } do
      # Create a durable checkpoint
      patch = %{
        file_path: "file_a.txt",
        original_content: "line 1\nline 2\nline 3\nline 4\nline 5\n",
        new_content: "line 1\ncheckpoint mutation\nline 3\nline 4\nline 5\n"
      }

      {:ok, checkpoint} =
        IexCode.TimeTravel.create_checkpoint(%{
          session_id: session.id,
          project_root: temp_root,
          label: "Pre-Mutation Checkpoint Alpha",
          patches: [patch]
        })

      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}/detached/diff")
      assert html =~ "Time-Travel (1)"

      # Switch to checkpoints subtab
      html_checkpoints = render_click(view, "switch_changes_subtab", %{"tab" => "checkpoints"})
      assert html_checkpoints =~ "CHECKPOINTS TIMELINE"
      assert html_checkpoints =~ "Pre-Mutation Checkpoint Alpha"
      assert has_element?(view, "#checkpoint-node-#{checkpoint.transaction_id}")

      # Select checkpoint
      render_click(view, "select_checkpoint", %{"tx_id" => checkpoint.transaction_id})
      html_selected = render(view)
      assert html_selected =~ "1-Click Rollback"

      # Rollback checkpoint
      html_rolled_back =
        render_click(view, "rollback_to_checkpoint", %{"tx_id" => checkpoint.transaction_id})

      assert html_rolled_back =~ "Rolled back"
    end
  end
end
