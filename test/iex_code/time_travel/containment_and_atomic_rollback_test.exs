defmodule IexCode.TimeTravel.ContainmentAndAtomicRollbackTest do
  use IexCode.DataCase, async: false

  alias IexCode.Projects.Project
  alias IexCode.Repo
  alias IexCode.{TimeTravel, WorkspaceLocks}

  defp make_workspace(prefix) do
    parent =
      Path.join(
        System.tmp_dir!(),
        "iex_code_#{prefix}_#{System.unique_integer([:positive, :monotonic])}"
      )

    workspace = Path.join(parent, "workspace")
    outside = Path.join(parent, "outside")
    File.mkdir_p!(workspace)
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf(parent) end)
    {workspace, outside}
  end

  defp unique_session(prefix) do
    "#{prefix}_#{System.unique_integer([:positive, :monotonic])}"
  end

  describe "path containment fail-closed checks" do
    test "rollback_latest fails closed on ../ traversal before mutating any valid patch" do
      {workspace, outside} = make_workspace("traversal")
      session_id = unique_session("traversal")

      safe_path = Path.join(workspace, "safe.txt")
      outside_target = Path.join(outside, "escape.txt")
      outside_victim = Path.join(outside, "victim.txt")

      File.write!(safe_path, "modified_content")
      File.write!(outside_victim, "do_not_delete")

      {:ok, cp} =
        TimeTravel.create_checkpoint(%{
          session_id: session_id,
          project_root: workspace,
          patches: [
            %{
              path: "safe.txt",
              file_existed: true,
              original_content: "original_content",
              new_content: "modified_content"
            },
            %{
              path: "../outside/escape.txt",
              file_existed: true,
              original_content: "pwned",
              new_content: "anything"
            }
          ]
        })

      assert {:error, :outside_workspace} = TimeTravel.rollback_latest(session_id)
      refute File.exists?(outside_target)
      assert File.read!(safe_path) == "modified_content"
      assert TimeTravel.get_checkpoint(cp.transaction_id).status == "active"

      # Also verify file_existed: false with traversal does not delete outside files
      session_del = unique_session("traversal_del")

      {:ok, cp_del} =
        TimeTravel.create_checkpoint(%{
          session_id: session_del,
          project_root: workspace,
          patches: [
            %{
              path: "safe.txt",
              file_existed: true,
              original_content: "orig",
              new_content: "modified_content"
            },
            %{
              path: "../outside/victim.txt",
              file_existed: false,
              original_content: nil,
              new_content: "x"
            }
          ]
        })

      assert {:error, :outside_workspace} = TimeTravel.rollback_latest(session_del)
      assert File.read!(outside_victim) == "do_not_delete"
      assert File.read!(safe_path) == "modified_content"
      assert TimeTravel.get_checkpoint(cp_del.transaction_id).status == "active"
    end

    test "rollback_to fails closed across checkpoint chain if any checkpoint contains path traversal" do
      {workspace, outside} = make_workspace("chain_traversal")
      session_id = unique_session("chain_trav")

      a_path = Path.join(workspace, "a.txt")
      outside_file = Path.join(outside, "pwn.txt")
      File.write!(a_path, "v1")

      {:ok, cp0} =
        TimeTravel.create_checkpoint(%{
          session_id: session_id,
          project_root: workspace,
          patches: []
        })

      File.write!(a_path, "v2")

      {:ok, cp1} =
        TimeTravel.create_checkpoint(%{
          session_id: session_id,
          project_root: workspace,
          patches: [
            %{path: "a.txt", file_existed: true, original_content: "v1", new_content: "v2"}
          ]
        })

      {:ok, cp2} =
        TimeTravel.create_checkpoint(%{
          session_id: session_id,
          project_root: workspace,
          patches: [
            %{
              path: "../outside/pwn.txt",
              file_existed: true,
              original_content: "hacked",
              new_content: "x"
            }
          ]
        })

      assert {:error, :outside_workspace} = TimeTravel.rollback_to(cp0.transaction_id)
      refute File.exists?(outside_file)
      assert File.read!(a_path) == "v2"
      assert TimeTravel.get_checkpoint(cp1.transaction_id).status == "active"
      assert TimeTravel.get_checkpoint(cp2.transaction_id).status == "active"
    end

    test "symlink directory escape, leaf escape, and dangling outside symlink all fail closed" do
      {workspace, outside} = make_workspace("symlinks")
      safe_file = Path.join(workspace, "valid.txt")
      File.write!(safe_file, "new_val")

      # 1. Directory symlink pointing outside workspace
      File.ln_s!(outside, Path.join(workspace, "dir_escape"))
      outside_target = Path.join(outside, "written_through_dir.txt")
      session1 = unique_session("sym_dir")

      {:ok, _} =
        TimeTravel.create_checkpoint(%{
          session_id: session1,
          project_root: workspace,
          patches: [
            %{
              path: "valid.txt",
              file_existed: true,
              original_content: "old_val",
              new_content: "new_val"
            },
            %{
              path: "dir_escape/written_through_dir.txt",
              file_existed: true,
              original_content: "pwned",
              new_content: "x"
            }
          ]
        })

      assert {:error, :outside_workspace} = TimeTravel.rollback_latest(session1)
      refute File.exists?(outside_target)
      assert File.read!(safe_file) == "new_val"

      # 2. Existing leaf symlink pointing to an outside file
      outside_leaf = Path.join(outside, "leaf_victim.txt")
      File.write!(outside_leaf, "victim_original")
      File.ln_s!(outside_leaf, Path.join(workspace, "leaf_escape.txt"))
      session2 = unique_session("sym_leaf")

      {:ok, _} =
        TimeTravel.create_checkpoint(%{
          session_id: session2,
          project_root: workspace,
          patches: [
            %{
              path: "valid.txt",
              file_existed: true,
              original_content: "old_val",
              new_content: "new_val"
            },
            %{
              path: "leaf_escape.txt",
              file_existed: true,
              original_content: "overwritten",
              new_content: "x"
            }
          ]
        })

      assert {:error, :outside_workspace} = TimeTravel.rollback_latest(session2)
      assert File.read!(outside_leaf) == "victim_original"
      assert File.read!(safe_file) == "new_val"

      # 3. Dangling symlink pointing outside workspace
      outside_dangling_target = Path.join(outside, "dangling_nonexistent.txt")
      File.ln_s!(outside_dangling_target, Path.join(workspace, "dangling_escape.txt"))
      session3 = unique_session("sym_dangling")

      {:ok, _} =
        TimeTravel.create_checkpoint(%{
          session_id: session3,
          project_root: workspace,
          patches: [
            %{
              path: "valid.txt",
              file_existed: true,
              original_content: "old_val",
              new_content: "new_val"
            },
            %{
              path: "dangling_escape.txt",
              file_existed: true,
              original_content: "should_fail",
              new_content: "x"
            }
          ]
        })

      assert {:error, :outside_workspace} = TimeTravel.rollback_latest(session3)
      refute File.exists?(outside_dangling_target)
      assert File.read!(safe_file) == "new_val"
    end

    test "rejects empty path, root path '.', and NUL bytes cleanly" do
      {workspace, _outside} = make_workspace("invalid_paths")
      session_base = unique_session("bad_path")

      for {idx, bad_path} <- Enum.with_index(["", ".", "bad\0path.txt"]) do
        sid = "#{session_base}_#{idx}"

        {:ok, _} =
          TimeTravel.create_checkpoint(%{
            session_id: sid,
            project_root: workspace,
            patches: [%{path: bad_path, file_existed: true, original_content: "x"}]
          })

        assert {:error, reason} = TimeTravel.rollback_latest(sid)
        assert reason in [:invalid_path, :outside_workspace]
      end
    end
  end

  describe "atomic temp write + WorkspaceLocks rollback" do
    test "atomic restore preserves mode, leaves zero .timetravel temp files, and deletes created files" do
      {workspace, _outside} = make_workspace("atomic")
      session_id = unique_session("atomic")

      script = Path.join(workspace, "bin/tool.sh")
      created = Path.join(workspace, "lib/generated.ex")
      File.mkdir_p!(Path.dirname(script))
      File.mkdir_p!(Path.dirname(created))
      File.write!(script, "#!/bin/sh\necho new\n")
      File.chmod!(script, 0o755)
      File.write!(created, "defmodule Generated, do: nil\n")

      {:ok, _cp} =
        TimeTravel.create_checkpoint(%{
          session_id: session_id,
          project_root: workspace,
          patches: [
            %{
              path: "bin/tool.sh",
              file_existed: true,
              original_content: "#!/bin/sh\necho old\n",
              new_content: "#!/bin/sh\necho new\n"
            },
            %{
              path: "lib/generated.ex",
              file_existed: false,
              original_content: nil,
              new_content: "defmodule Generated, do: nil\n"
            }
          ]
        })

      assert {:ok, %{reverted_checkpoints: 1}} = TimeTravel.rollback_latest(session_id)
      assert File.read!(script) == "#!/bin/sh\necho old\n"
      {:ok, %File.Stat{mode: mode}} = File.stat(script)
      assert Bitwise.band(mode, 0o111) != 0
      refute File.exists?(created)
      assert [] == Path.wildcard(Path.join(workspace, "**/.*.timetravel-*"))
    end

    test "rollback_latest and rollback_to respect WorkspaceLocks contention without partial disk or DB updates" do
      {workspace, _outside} = make_workspace("locks")
      session_id = unique_session("locks")
      Repo.insert!(%Project{name: "tt-locks-proj", root_path: workspace})

      a_path = Path.join(workspace, "a.txt")
      b_path = Path.join(workspace, "b.txt")
      File.write!(a_path, "a_v0")
      File.write!(b_path, "b_v0")

      {:ok, cp0} =
        TimeTravel.create_checkpoint(%{
          session_id: session_id,
          project_root: workspace,
          patches: []
        })

      File.write!(a_path, "a_v1")
      File.write!(b_path, "b_v1")

      {:ok, cp1} =
        TimeTravel.create_checkpoint(%{
          session_id: session_id,
          project_root: workspace,
          patches: [
            %{path: "a.txt", file_existed: true, original_content: "a_v0", new_content: "a_v1"},
            %{path: "b.txt", file_existed: true, original_content: "b_v0", new_content: "b_v1"}
          ]
        })

      parent = self()

      {holder_pid, holder_ref} =
        spawn_monitor(fn ->
          receive do
            :acquire ->
              WorkspaceLocks.with_locks(
                workspace,
                [{{:file, "b.txt"}, :write}],
                [owner_id: "blocker-#{System.unique_integer([:positive])}"],
                fn ->
                  send(parent, :locked)

                  receive do
                    :unlock -> :ok
                  end
                end
              )
          end
        end)

      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), holder_pid)
      send(holder_pid, :acquire)
      assert_receive :locked, 2_000

      assert {:error, {:workspace_lock_waiting, _conflicts}} =
               TimeTravel.rollback_latest(session_id)

      assert File.read!(a_path) == "a_v1"
      assert File.read!(b_path) == "b_v1"
      assert TimeTravel.get_checkpoint(cp1.transaction_id).status == "active"

      assert {:error, {:workspace_lock_waiting, _conflicts}} =
               TimeTravel.rollback_to(cp0.transaction_id)

      assert File.read!(a_path) == "a_v1"
      assert File.read!(b_path) == "b_v1"
      assert TimeTravel.get_checkpoint(cp1.transaction_id).status == "active"

      send(holder_pid, :unlock)
      assert_receive {:DOWN, ^holder_ref, :process, ^holder_pid, :normal}, 2_000

      assert {:ok, %{reverted_checkpoints: 1}} = TimeTravel.rollback_to(cp0.transaction_id)
      assert File.read!(a_path) == "a_v0"
      assert File.read!(b_path) == "b_v0"
      assert TimeTravel.get_checkpoint(cp1.transaction_id).status == "rolled_back"
    end
  end

  describe "drift detection (check_drift/1 and allow_drift: false)" do
    test "check_drift/1 verifies clean match, content mismatch, missing file, and unexpected recreated file" do
      {workspace, _outside} = make_workspace("drift")
      session_id = unique_session("drift")

      a_path = Path.join(workspace, "a.txt")
      gone_path = Path.join(workspace, "gone.txt")
      File.write!(a_path, "a_after")

      {:ok, cp} =
        TimeTravel.create_checkpoint(%{
          session_id: session_id,
          project_root: workspace,
          patches: [
            %{
              path: "a.txt",
              file_existed: true,
              original_content: "a_before",
              new_content: "a_after"
            },
            %{
              path: "gone.txt",
              file_existed: true,
              original_content: "was_here",
              new_content: nil
            }
          ]
        })

      assert :ok = TimeTravel.check_drift(cp.transaction_id)
      assert :ok = TimeTravel.check_drift(cp)
      assert {:error, :checkpoint_not_found} = TimeTravel.check_drift("nonexistent_tx")

      # Modify a.txt and recreate gone.txt externally
      File.write!(a_path, "manual_edit")
      File.write!(gone_path, "recreated_externally")

      assert {:error, {:drift_detected, drifts}} = TimeTravel.check_drift(cp.transaction_id)
      reasons_by_path = Map.new(drifts, fn d -> {d.path, d.reason} end)
      assert reasons_by_path["a.txt"] == :content_mismatch
      assert reasons_by_path["gone.txt"] == :unexpected_file_exists

      # Delete a.txt -> :file_missing
      File.rm!(a_path)
      File.rm!(gone_path)

      assert {:error, {:drift_detected, missing_drifts}} =
               TimeTravel.check_drift(cp.transaction_id)

      assert [%{path: "a.txt", reason: :file_missing}] = missing_drifts
    end

    test "rollback_latest/2 honors allow_drift: false while defaulting allow_drift: true" do
      {workspace, _outside} = make_workspace("latest_drift")
      session_id = unique_session("latest_drift")
      file_path = Path.join(workspace, "file.txt")
      File.write!(file_path, "ai_edit")

      {:ok, cp} =
        TimeTravel.create_checkpoint(%{
          session_id: session_id,
          project_root: workspace,
          patches: [
            %{
              path: "file.txt",
              file_existed: true,
              original_content: "original",
              new_content: "ai_edit"
            }
          ]
        })

      File.write!(file_path, "human_edit")

      assert {:error, {:drift_detected, [%{path: "file.txt", reason: :content_mismatch}]}} =
               TimeTravel.rollback_latest(session_id, allow_drift: false)

      assert File.read!(file_path) == "human_edit"
      assert TimeTravel.get_checkpoint(cp.transaction_id).status == "active"

      # Default allow_drift: true restores original content
      assert {:ok, %{reverted_checkpoints: 1}} = TimeTravel.rollback_latest(session_id)
      assert File.read!(file_path) == "original"
      assert TimeTravel.get_checkpoint(cp.transaction_id).status == "rolled_back"
    end

    test "rollback_to/2 with allow_drift: false simulates multi-step chain cleanly and aborts on real drift" do
      {workspace, _outside} = make_workspace("multi_drift")
      session_id = unique_session("multi_drift")

      a_path = Path.join(workspace, "a.txt")
      b_path = Path.join(workspace, "b.txt")
      File.write!(a_path, "v0")

      {:ok, cp0} =
        TimeTravel.create_checkpoint(%{
          session_id: session_id,
          project_root: workspace,
          patches: []
        })

      File.write!(a_path, "v1")

      {:ok, cp1} =
        TimeTravel.create_checkpoint(%{
          session_id: session_id,
          project_root: workspace,
          patches: [
            %{path: "a.txt", file_existed: true, original_content: "v0", new_content: "v1"}
          ]
        })

      File.write!(a_path, "v2")

      {:ok, cp2} =
        TimeTravel.create_checkpoint(%{
          session_id: session_id,
          project_root: workspace,
          patches: [
            %{path: "a.txt", file_existed: true, original_content: "v1", new_content: "v2"}
          ]
        })

      File.write!(b_path, "created")

      {:ok, cp3} =
        TimeTravel.create_checkpoint(%{
          session_id: session_id,
          project_root: workspace,
          patches: [
            %{path: "b.txt", file_existed: false, original_content: nil, new_content: "created"}
          ]
        })

      # Inject external drift on b.txt first: rollback_to must abort atomically without touching a.txt or DB
      File.write!(b_path, "manual_b")

      assert {:error, {:drift_detected, [%{path: "b.txt", reason: :content_mismatch}]}} =
               TimeTravel.rollback_to(cp0.transaction_id, allow_drift: false)

      assert File.read!(a_path) == "v2"
      assert File.read!(b_path) == "manual_b"
      assert TimeTravel.get_checkpoint(cp1.transaction_id).status == "active"
      assert TimeTravel.get_checkpoint(cp2.transaction_id).status == "active"
      assert TimeTravel.get_checkpoint(cp3.transaction_id).status == "active"

      # Restore expected state of b.txt and confirm full multi-step chain succeeds with allow_drift: false
      File.write!(b_path, "created")

      assert {:ok, %{reverted_checkpoints: 3}} =
               TimeTravel.rollback_to(cp0.transaction_id, allow_drift: false)

      assert File.read!(a_path) == "v0"
      refute File.exists?(b_path)
      assert TimeTravel.get_checkpoint(cp1.transaction_id).status == "rolled_back"
      assert TimeTravel.get_checkpoint(cp2.transaction_id).status == "rolled_back"
      assert TimeTravel.get_checkpoint(cp3.transaction_id).status == "rolled_back"
    end
  end
end
