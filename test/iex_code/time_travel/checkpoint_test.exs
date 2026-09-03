defmodule IexCode.TimeTravel.CheckpointTest do
  @moduledoc """
  Requirement R3: Atomic Workspace Time-Travel Checkpoints & 1-Click Rollback.
  Tests for IexCode.TimeTravel pre-mutation checkpointing:
  - Universal pre-mutation capture across write_file, patch_file, and multi_patch
  - Monotonic sequencing, human-readable labels, and diff summaries
  - Real-time PubSub event broadcasting
  """
  use IexCode.DataCase, async: false

  alias IexCode.TimeTravel
  alias IexCode.Tools
  alias IexCode.Projects
  alias IexCode.Sessions
  alias Phoenix.PubSub

  setup do
    unique_id = System.unique_integer([:positive])
    temp_dir = Path.join(System.tmp_dir!(), "iex_checkpoint_test_#{unique_id}")
    File.mkdir_p!(temp_dir)

    {:ok, project} =
      Projects.create_project(%{
        name: "Checkpoint Test Project #{unique_id}",
        root_path: temp_dir
      })

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Checkpoint Session #{unique_id}"
      })

    if Process.whereis(IexCode.PubSub) do
      PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")
    end

    on_exit(fn ->
      File.rm_rf(temp_dir)
    end)

    {:ok, project: project, session: session, temp_dir: temp_dir}
  end

  describe "Tier 1: Universal Pre-Mutation Snapshotting" do
    test "T1_R3_CKP_01: write_file tool generates pre-mutation snapshot checkpoint", %{
      session: session,
      temp_dir: temp_dir
    } do
      rel_path = "lib/new_service.ex"
      content = "defmodule NewService, do: :ok\n"

      {:ok, _} =
        Tools.execute(
          "write_file",
          %{"path" => rel_path, "content" => content, "session_id" => session.id},
          temp_dir
        )

      checkpoints = TimeTravel.list_checkpoints(session.id)
      assert length(checkpoints) >= 1

      latest = hd(checkpoints)
      assert latest.session_id == session.id
      assert latest.status in ["active", :active]
      assert latest.label =~ "write_file" or latest.label =~ rel_path

      patch = hd(latest.patches)
      assert patch["path"] == rel_path or patch[:path] == rel_path
      assert patch["file_existed"] == false or patch[:file_existed] == false
    end

    test "T1_R3_CKP_02: patch_file captures original file content before mutation", %{
      session: session,
      temp_dir: temp_dir
    } do
      rel_path = "lib/service.ex"
      full_path = Path.join(temp_dir, rel_path)
      original_content = "defmodule Service do\n  def run, do: :v1\nend\n"
      File.mkdir_p!(Path.dirname(full_path))
      File.write!(full_path, original_content)

      {:ok, _} =
        Tools.execute(
          "patch_file",
          %{
            "path" => rel_path,
            "target_content" => "def run, do: :v1",
            "replacement_content" => "def run, do: :v2",
            "session_id" => session.id
          },
          temp_dir
        )

      checkpoints = TimeTravel.list_checkpoints(session.id)
      latest = hd(checkpoints)

      patch = hd(latest.patches)
      assert patch["file_existed"] == true or patch[:file_existed] == true
      assert patch["original_content"] =~ ":v1" or patch[:original_content] =~ ":v1"
      assert patch["new_content"] =~ ":v2" or patch[:new_content] =~ ":v2"
    end

    test "T1_R3_CKP_03: multi_patch creates atomic snapshot encompassing all touched files", %{
      session: session,
      temp_dir: temp_dir
    } do
      file1 = "lib/alpha.ex"
      file2 = "lib/beta.ex"
      File.mkdir_p!(Path.dirname(Path.join(temp_dir, file1)))
      File.write!(Path.join(temp_dir, file1), "defmodule Alpha, do: 1\n")
      File.write!(Path.join(temp_dir, file2), "defmodule Beta, do: 2\n")

      multi_args = %{
        "session_id" => session.id,
        "patches" => [
          %{
            "path" => file1,
            "target_content" => "do: 1",
            "replacement_content" => "do: 10"
          },
          %{
            "path" => file2,
            "target_content" => "do: 2",
            "replacement_content" => "do: 20"
          }
        ]
      }

      {:ok, _} = Tools.execute("multi_patch", multi_args, temp_dir)

      checkpoints = TimeTravel.list_checkpoints(session.id)
      latest = hd(checkpoints)

      assert length(latest.patches) == 2
      assert latest.label =~ "multi_patch" or latest.label =~ "2 files"
    end
  end

  describe "Tier 2: Checkpoint Sequencing & Boundary Conditions" do
    test "T2_R3_CKP_01: consecutive mutations generate monotonically increasing sequence numbers",
         %{
           session: session,
           temp_dir: temp_dir
         } do
      for i <- 1..4 do
        Tools.execute(
          "write_file",
          %{"path" => "file_#{i}.txt", "content" => "iteration #{i}", "session_id" => session.id},
          temp_dir
        )
      end

      checkpoints = TimeTravel.list_checkpoints(session.id)
      assert length(checkpoints) == 4

      seqs = Enum.map(checkpoints, & &1.seq)
      assert seqs == Enum.sort(seqs, :desc) or seqs == Enum.sort(seqs, :asc)
    end

    test "T2_R3_CKP_02: snapshotting an overwrite of an existing file preserves full original content",
         %{
           session: session,
           temp_dir: temp_dir
         } do
      target_file = "lib/heavy.ex"
      full_target = Path.join(temp_dir, target_file)
      File.mkdir_p!(Path.dirname(full_target))
      orig_body = String.duplicate("Line of code\n", 100)
      File.write!(full_target, orig_body)

      new_body = "defmodule HeavyReplacement, do: :replaced\n"

      {:ok, _} =
        Tools.execute(
          "write_file",
          %{"path" => target_file, "content" => new_body, "session_id" => session.id},
          temp_dir
        )

      [latest | _] = TimeTravel.list_checkpoints(session.id)
      patch = hd(latest.patches)

      assert (patch["original_content"] || patch[:original_content]) == orig_body
      assert (patch["new_content"] || patch[:new_content]) == new_body
    end
  end

  describe "Tier 3: PubSub Broadcasts" do
    test "T3_R3_CKP_01: creating a checkpoint broadcasts {:checkpoint_created, checkpoint} to session",
         %{
           session: session,
           temp_dir: temp_dir
         } do
      Tools.execute(
        "write_file",
        %{"path" => "broadcast_test.txt", "content" => "pubsub test", "session_id" => session.id},
        temp_dir
      )

      assert_receive {:checkpoint_created, checkpoint}, 1000
      assert checkpoint.session_id == session.id
    end
  end
end
