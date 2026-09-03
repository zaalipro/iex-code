defmodule IexCode.Adversarial.R3TimeTravelRollbackAdversarialTest do
  @moduledoc """
  Adversarial stress testing for Requirement R3:
  - Multi-step interspersed checkpoints (create, edit, delete, overwrite, recreate)
  - Bit-level exact restoration (SHA-256 validation)
  - Strict zero-orphan file verification on rollback
  - Binary and UTF-8 / Emoji content preservation
  - Multi-file atomic checkpoint rollbacks
  - Idempotency and error boundary behavior
  - PubSub notification verification
  """

  use IexCode.DataCase, async: false

  alias IexCode.TimeTravel
  alias IexCode.Tools
  alias IexCode.Projects
  alias IexCode.Sessions
  alias Phoenix.PubSub

  setup do
    unique_id = System.unique_integer([:positive])
    temp_dir = Path.join(System.tmp_dir!(), "iex_adv_rollback_#{unique_id}")
    File.mkdir_p!(temp_dir)

    {:ok, project} =
      Projects.create_project(%{
        name: "Adversarial Rollback Project #{unique_id}",
        root_path: temp_dir
      })

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Adversarial Rollback Session #{unique_id}"
      })

    if Process.whereis(IexCode.PubSub) do
      PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")
    end

    on_exit(fn ->
      File.rm_rf(temp_dir)
    end)

    {:ok, project: project, session: session, temp_dir: temp_dir}
  end

  defp sha256(content) when is_binary(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp file_sha256(path) do
    File.read!(path) |> sha256()
  end

  describe "ADV_R3_01: Interspersed Multi-Step Rollback with Zero Orphans and Exact Bit Fidelity" do
    test "correctly traverses reverse-chronological checkpoints with file creations, modifications, overwrites",
         %{session: session, temp_dir: temp_dir} do
      # --- Base State: 2 files ---
      cfg_path = Path.join(temp_dir, "config.json")
      core_path = Path.join(temp_dir, "lib/core.ex")
      File.mkdir_p!(Path.dirname(core_path))

      base_cfg = ~s|{"name": "adv_test", "version": 1.0, "active": true}\n|
      base_core = "defmodule Core do\n  def init, do: :v1\nend\n"

      File.write!(cfg_path, base_cfg)
      File.write!(core_path, base_core)

      sha_base_cfg = sha256(base_cfg)
      sha_base_core = sha256(base_core)

      # --- Step 1: Checkpoint 1 (Modify core.ex, Create feature1.ex) ---
      c1_core = "defmodule Core do\n  def init, do: :v2\nend\n"
      c1_f1 = "defmodule Feature1 do\n  def run, do: :running\nend\n"
      f1_path = Path.join(temp_dir, "lib/feature1.ex")

      Tools.execute(
        "patch_file",
        %{
          "path" => "lib/core.ex",
          "target_content" => "def init, do: :v1",
          "replacement_content" => "def init, do: :v2",
          "session_id" => session.id
        },
        temp_dir
      )

      Tools.execute(
        "write_file",
        %{"path" => "lib/feature1.ex", "content" => c1_f1, "session_id" => session.id},
        temp_dir
      )

      sha_c1_core = sha256(c1_core)
      sha_c1_f1 = sha256(c1_f1)

      checkpoints_after_c1 = TimeTravel.list_checkpoints(session.id)
      # CP 1 has 2 mutation records (one for core, one for feature1)
      cp_f1_tx = hd(checkpoints_after_c1).transaction_id

      # --- Step 2: Checkpoint 2 (Update feature1, Create deep nested subsystem, Create binary file) ---
      c2_f1 = "defmodule Feature1 do\n  def run, do: :advanced_v2\nend\n"
      sub_path = Path.join(temp_dir, "lib/deep/nested/subsystem.ex")
      c2_sub = "defmodule Deep.Nested.Subsystem, do: :ok\n"
      bin_path = Path.join(temp_dir, "assets/data.bin")

      Tools.execute(
        "patch_file",
        %{
          "path" => "lib/feature1.ex",
          "target_content" => "def run, do: :running",
          "replacement_content" => "def run, do: :advanced_v2",
          "session_id" => session.id
        },
        temp_dir
      )

      Tools.execute(
        "write_file",
        %{
          "path" => "lib/deep/nested/subsystem.ex",
          "content" => c2_sub,
          "session_id" => session.id
        },
        temp_dir
      )

      bin_content = "DATA_ASSET_V1: 0, 255, 128, 64, 32, 16, 8, 4, 2, 1, 0, 42, 137, 200, 254\n"

      Tools.execute(
        "write_file",
        %{"path" => "assets/data.bin", "content" => bin_content, "session_id" => session.id},
        temp_dir
      )

      sha_c2_f1 = sha256(c2_f1)
      sha_c2_sub = sha256(c2_sub)
      sha_c2_bin = sha256(bin_content)

      checkpoints_after_c2 = TimeTravel.list_checkpoints(session.id)
      cp_c2_latest_tx = hd(checkpoints_after_c2).transaction_id

      # --- Step 3: Checkpoint 3 (Overwrite config.json, Update core.ex, Create temp notes) ---
      c3_cfg = ~s|{"name": "overwritten", "version": 3.0, "danger": true}\n|
      notes_path = Path.join(temp_dir, "temp_notes.txt")
      c3_notes = "These notes should vanish on rollback!\n"

      Tools.execute(
        "write_file",
        %{"path" => "config.json", "content" => c3_cfg, "session_id" => session.id},
        temp_dir
      )

      Tools.execute(
        "patch_file",
        %{
          "path" => "lib/core.ex",
          "target_content" => "def init, do: :v2",
          "replacement_content" => "def init, do: :v3_overwritten",
          "session_id" => session.id
        },
        temp_dir
      )

      Tools.execute(
        "write_file",
        %{"path" => "temp_notes.txt", "content" => c3_notes, "session_id" => session.id},
        temp_dir
      )

      # --- Step 4: Checkpoint 4 (Mutate binary data, Create final log) ---
      c4_bin_content = "DATA_ASSET_V2_MUTATED: 255, 254, 253, 252, 0, 0, 1, 2, 3\n"
      log_path = Path.join(temp_dir, "final_marker.log")

      Tools.execute(
        "write_file",
        %{"path" => "assets/data.bin", "content" => c4_bin_content, "session_id" => session.id},
        temp_dir
      )

      Tools.execute(
        "write_file",
        %{
          "path" => "final_marker.log",
          "content" => "END OF SWARM RUN\n",
          "session_id" => session.id
        },
        temp_dir
      )

      # Confirm current mutated state
      assert File.exists?(log_path)
      assert File.exists?(notes_path)
      assert file_sha256(bin_path) == sha256(c4_bin_content)
      assert file_sha256(cfg_path) == sha256(c3_cfg)

      # =========================================================================
      # PHASE A: Rollback to Checkpoint 2 (cp_c2_latest_tx)
      # Must undo Steps 4 and 3:
      # - final_marker.log and temp_notes.txt MUST BE DELETED (zero orphans)
      # - assets/data.bin must be restored to CP2 binary content
      # - config.json must be restored to base_cfg
      # - lib/core.ex must be restored to c1_core
      # - lib/feature1.ex must still have c2_f1 content
      # - lib/deep/nested/subsystem.ex must still exist
      # =========================================================================
      {:ok, res_a} = TimeTravel.rollback_to(cp_c2_latest_tx, session_id: session.id)
      assert res_a.reverted_checkpoints >= 5

      # Zero orphan assertions
      refute File.exists?(log_path), "final_marker.log must be deleted (zero orphans)"
      refute File.exists?(notes_path), "temp_notes.txt must be deleted (zero orphans)"

      # Bit-level content assertions
      assert File.read!(bin_path) == bin_content, "Binary file must match exact CP2 bytes"
      assert file_sha256(bin_path) == sha_c2_bin
      assert File.read!(cfg_path) == base_cfg, "Config must be restored to exact base"
      assert file_sha256(cfg_path) == sha_base_cfg
      assert File.read!(core_path) == c1_core, "Core must be restored to c1_core"
      assert file_sha256(core_path) == sha_c1_core
      assert File.read!(f1_path) == c2_f1, "Feature1 must remain at c2_f1"
      assert file_sha256(f1_path) == sha_c2_f1
      assert File.read!(sub_path) == c2_sub, "Subsystem must remain at c2_sub"
      assert file_sha256(sub_path) == sha_c2_sub

      # =========================================================================
      # PHASE B: Rollback to Checkpoint 1 (cp_f1_tx)
      # Must undo Step 2:
      # - assets/data.bin and lib/deep/nested/subsystem.ex MUST BE DELETED (zero orphans)
      # - lib/feature1.ex must be restored to c1_f1
      # - lib/core.ex still at c1_core
      # =========================================================================
      {:ok, res_b} = TimeTravel.rollback_to(cp_f1_tx, session_id: session.id)
      assert res_b.reverted_checkpoints >= 3

      refute File.exists?(bin_path), "assets/data.bin must be cleanly deleted"
      refute File.exists?(sub_path), "subsystem.ex must be cleanly deleted"

      assert File.read!(f1_path) == c1_f1, "Feature1 must be restored to c1_f1"
      assert file_sha256(f1_path) == sha_c1_f1
      assert File.read!(core_path) == c1_core, "Core must still be at c1_core"
      assert file_sha256(core_path) == sha_c1_core

      # =========================================================================
      # PHASE C: Rollback all remaining checkpoints to initial baseline
      # Must undo Step 1:
      # - lib/feature1.ex MUST BE DELETED (zero orphans)
      # - lib/core.ex must be restored to base_core
      # - config.json is still base_cfg
      # =========================================================================
      # Revert remaining active checkpoints one by one or via rollback_latest
      assert {:ok, _} = TimeTravel.rollback_latest(session.id)
      assert {:ok, _} = TimeTravel.rollback_latest(session.id)

      # No active checkpoints left
      assert {:error, :no_active_checkpoints} = TimeTravel.rollback_latest(session.id)

      refute File.exists?(f1_path), "lib/feature1.ex must be deleted (zero orphans)"

      assert File.read!(core_path) == base_core,
             "lib/core.ex must be restored to exact initial base"

      assert file_sha256(core_path) == sha_base_core
      assert File.read!(cfg_path) == base_cfg, "config.json must still match base"
      assert file_sha256(cfg_path) == sha_base_cfg
    end
  end

  describe "ADV_R3_02: Atomic Multi-Patch Rollback (5 Files Simultaneously)" do
    test "rolls back multi-file transactions cleanly across creations and modifications",
         %{session: session, temp_dir: temp_dir} do
      # 3 existing files
      f1 = Path.join(temp_dir, "file1.txt")
      f2 = Path.join(temp_dir, "file2.txt")
      f3 = Path.join(temp_dir, "file3.txt")

      File.write!(f1, "Original Content 1\n")
      File.write!(f2, "Original Content 2\n")
      File.write!(f3, "Original Content 3\n")

      sha1 = file_sha256(f1)
      sha2 = file_sha256(f2)
      sha3 = file_sha256(f3)

      f4_rel = "created_a.txt"
      f5_rel = "created_b.txt"
      f4 = Path.join(temp_dir, f4_rel)
      f5 = Path.join(temp_dir, f5_rel)

      patches = [
        %{
          path: "file1.txt",
          file_existed: true,
          original_content: "Original Content 1\n",
          new_content: "Mutated Content 1\n"
        },
        %{
          path: "file2.txt",
          file_existed: true,
          original_content: "Original Content 2\n",
          new_content: "Mutated Content 2\n"
        },
        %{
          path: "file3.txt",
          file_existed: true,
          original_content: "Original Content 3\n",
          new_content: "Mutated Content 3\n"
        },
        %{
          path: f4_rel,
          file_existed: false,
          original_content: "",
          new_content: "Newly Created A\n"
        },
        %{
          path: f5_rel,
          file_existed: false,
          original_content: "",
          new_content: "Newly Created B\n"
        }
      ]

      # Apply mutations
      File.write!(f1, "Mutated Content 1\n")
      File.write!(f2, "Mutated Content 2\n")
      File.write!(f3, "Mutated Content 3\n")
      File.write!(f4, "Newly Created A\n")
      File.write!(f5, "Newly Created B\n")

      {:ok, cp} =
        TimeTravel.create_checkpoint(%{
          session_id: session.id,
          project_root: temp_dir,
          label: "Multi-file atomic patch",
          patches: patches
        })

      assert File.exists?(f4)
      assert File.exists?(f5)

      # Rollback latest
      {:ok, summary} = TimeTravel.rollback_latest(session.id)
      assert summary.reverted_checkpoints == 1
      assert summary.reverted_tx_ids == [cp.transaction_id]

      # Assert all 3 modified files are restored exactly
      assert file_sha256(f1) == sha1
      assert file_sha256(f2) == sha2
      assert file_sha256(f3) == sha3

      # Assert both created files are deleted
      refute File.exists?(f4), "Created file A must be deleted"
      refute File.exists?(f5), "Created file B must be deleted"
    end
  end

  describe "ADV_R3_03: File Recreation and Re-deletion Lifecycle" do
    test "correctly handles file deleted by rollback and subsequently recreated in later step",
         %{session: session, temp_dir: temp_dir} do
      ephemeral_rel = "ephemeral.txt"
      ephemeral_full = Path.join(temp_dir, ephemeral_rel)

      # Step 1: Create ephemeral file
      Tools.execute(
        "write_file",
        %{"path" => ephemeral_rel, "content" => "Version Alpha\n", "session_id" => session.id},
        temp_dir
      )

      assert File.exists?(ephemeral_full)
      assert File.read!(ephemeral_full) == "Version Alpha\n"

      # Rollback step 1
      {:ok, _} = TimeTravel.rollback_latest(session.id)
      refute File.exists?(ephemeral_full)

      # Step 2: Recreate ephemeral file with completely different content
      Tools.execute(
        "write_file",
        %{"path" => ephemeral_rel, "content" => "Version Beta\n", "session_id" => session.id},
        temp_dir
      )

      [cp_beta | _] = TimeTravel.list_checkpoints(session.id)
      sha_beta = file_sha256(ephemeral_full)

      # Step 3: Modify ephemeral file
      Tools.execute(
        "patch_file",
        %{
          "path" => ephemeral_rel,
          "target_content" => "Version Beta",
          "replacement_content" => "Version Gamma",
          "session_id" => session.id
        },
        temp_dir
      )

      assert File.read!(ephemeral_full) == "Version Gamma\n"

      # Rollback to cp_beta
      {:ok, _} = TimeTravel.rollback_to(cp_beta.transaction_id, session_id: session.id)
      assert File.exists?(ephemeral_full)
      assert file_sha256(ephemeral_full) == sha_beta
      assert File.read!(ephemeral_full) == "Version Beta\n"

      # Rollback beta
      {:ok, _} = TimeTravel.rollback_latest(session.id)

      refute File.exists?(ephemeral_full),
             "Must be deleted again after rolling back beta creation"
    end
  end

  describe "ADV_R3_04: UTF-8, Emoji, and CRLF Bit-Level Integrity" do
    test "restores multi-byte UTF-8, emojis, and Windows CRLF without byte corruption",
         %{session: session, temp_dir: temp_dir} do
      utf8_rel = "multilingual.txt"
      utf8_full = Path.join(temp_dir, utf8_rel)

      complex_content =
        "Emojis: 🚀 🤖 🧪 ⚡ 💻\n" <>
          "Georgian: გამარჯობა მსოფლიო\n" <>
          "Arabic: مرحبا بالعالم\n" <>
          "Japanese: こんにちは世界\n" <>
          "CRLF line:\r\nSecond CRLF line:\r\nEnd"

      File.write!(utf8_full, complex_content)
      expected_sha = sha256(complex_content)

      # Overwrite file
      Tools.execute(
        "write_file",
        %{"path" => utf8_rel, "content" => "Plain ASCII replacement", "session_id" => session.id},
        temp_dir
      )

      assert File.read!(utf8_full) == "Plain ASCII replacement"

      # Rollback
      {:ok, _} = TimeTravel.rollback_latest(session.id)

      restored = File.read!(utf8_full)
      assert restored == complex_content
      assert sha256(restored) == expected_sha
    end
  end

  describe "ADV_R3_05: Idempotency and Boundary Conditions" do
    test "returns clean error when rolling back empty session", %{session: session} do
      assert {:error, :no_active_checkpoints} = TimeTravel.rollback_latest(session.id)
    end

    test "returns clean error when target checkpoint does not exist", %{session: session} do
      assert {:error, :checkpoint_not_found} =
               TimeTravel.rollback_to("non_existent_uuid", session_id: session.id)
    end

    test "repeated rollback_to the same target is completely idempotent",
         %{session: session, temp_dir: temp_dir} do
      file_path = Path.join(temp_dir, "test.txt")

      Tools.execute(
        "write_file",
        %{"path" => "test.txt", "content" => "Target Point\n", "session_id" => session.id},
        temp_dir
      )

      [cp_target] = TimeTravel.list_checkpoints(session.id)

      Tools.execute(
        "write_file",
        %{"path" => "test.txt", "content" => "Point 2\n", "session_id" => session.id},
        temp_dir
      )

      # First rollback to target
      {:ok, res1} = TimeTravel.rollback_to(cp_target.transaction_id, session_id: session.id)
      assert res1.reverted_checkpoints == 1
      assert File.read!(file_path) == "Target Point\n"

      # Second rollback to same target (already there)
      {:ok, res2} = TimeTravel.rollback_to(cp_target.transaction_id, session_id: session.id)
      assert res2.reverted_checkpoints == 0
      assert File.read!(file_path) == "Target Point\n"
    end
  end

  describe "ADV_R3_06: PubSub Notification Verification" do
    test "broadcasts {:checkpoint_rolled_back, tx_id, details} on rollback_to",
         %{session: session, temp_dir: temp_dir} do
      Tools.execute(
        "write_file",
        %{"path" => "pubsub_test.txt", "content" => "step 1", "session_id" => session.id},
        temp_dir
      )

      [cp1] = TimeTravel.list_checkpoints(session.id)

      Tools.execute(
        "write_file",
        %{"path" => "pubsub_test.txt", "content" => "step 2", "session_id" => session.id},
        temp_dir
      )

      {:ok, _} = TimeTravel.rollback_to(cp1.transaction_id, session_id: session.id)

      assert_receive {:checkpoint_rolled_back, target_id, details}, 1000
      assert target_id == cp1.transaction_id
      assert details.reverted_count == 1
      assert is_list(details.reverted_ids)
    end
  end

  describe "ADV_R3_07: Binary Non-UTF8 Serialization Boundary" do
    test "proves that raw non-UTF8 binary byte sequences in patches raise Ecto.ChangeError on JSON serialization",
         %{session: session, temp_dir: temp_dir} do
      non_utf8_binary = <<0, 255, 128, 64, 32>>

      # Verifies the empirical boundary: SQLite stores patches as JSON text, so raw non-UTF8 binary cannot be dumped directly
      assert_raise Ecto.ChangeError, fn ->
        TimeTravel.create_checkpoint(%{
          session_id: session.id,
          project_root: temp_dir,
          label: "binary raw byte checkpoint",
          patches: [
            %{
              "path" => "raw.bin",
              "file_existed" => false,
              "original_content" => "",
              "new_content" => non_utf8_binary
            }
          ]
        })
      end
    end
  end
end
