defmodule IexCode.TimeTravel.RollbackTest do
  @moduledoc """
  Requirement R3: Atomic Workspace Time-Travel Checkpoints & 1-Click Rollback.
  Tests for IexCode.TimeTravel rollback engine:
  - Single-step rollback (rollback_latest)
  - Reverse-chronological multi-step rollback (rollback_to)
  - Non-destructive file restoration and clean deletion of created files (zero orphans)
  - Status updates and PubSub broadcasts
  """
  use IexCode.DataCase, async: false

  alias IexCode.TimeTravel
  alias IexCode.Tools
  alias IexCode.Projects
  alias IexCode.Sessions
  alias Phoenix.PubSub

  setup do
    unique_id = System.unique_integer([:positive])
    temp_dir = Path.join(System.tmp_dir!(), "iex_rollback_test_#{unique_id}")
    File.mkdir_p!(temp_dir)

    {:ok, project} =
      Projects.create_project(%{
        name: "Rollback Test Project #{unique_id}",
        root_path: temp_dir
      })

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Rollback Session #{unique_id}"
      })

    if Process.whereis(IexCode.PubSub) do
      PubSub.subscribe(IexCode.PubSub, "session:#{session.id}")
    end

    on_exit(fn ->
      File.rm_rf(temp_dir)
    end)

    {:ok, project: project, session: session, temp_dir: temp_dir}
  end

  describe "Tier 1: Single-Step Rollback (rollback_latest)" do
    test "T1_R3_ROL_01: rollback_latest restores modified file to exact original content", %{
      session: session,
      temp_dir: temp_dir
    } do
      file_path = Path.join(temp_dir, "lib/counter.ex")
      File.mkdir_p!(Path.dirname(file_path))
      original_code = "defmodule Counter, do: def value, do: 0\n"
      File.write!(file_path, original_code)

      # Apply mutation
      Tools.execute(
        "patch_file",
        %{
          "path" => "lib/counter.ex",
          "target_content" => "def value, do: 0",
          "replacement_content" => "def value, do: 1",
          "session_id" => session.id
        },
        temp_dir
      )

      assert File.read!(file_path) =~ "do: 1"

      # Rollback latest
      {:ok, summary} = TimeTravel.rollback_latest(session.id)

      assert summary.reverted_checkpoints >= 1
      assert File.read!(file_path) == original_code
    end

    test "T1_R3_ROL_02: rollback_latest cleanly removes newly created file with zero orphans", %{
      session: session,
      temp_dir: temp_dir
    } do
      rel_path = "lib/orphan_candidate.ex"
      full_path = Path.join(temp_dir, rel_path)

      Tools.execute(
        "write_file",
        %{
          "path" => rel_path,
          "content" => "defmodule Orphan, do: :temporary\n",
          "session_id" => session.id
        },
        temp_dir
      )

      assert File.exists?(full_path)

      {:ok, _} = TimeTravel.rollback_latest(session.id)

      refute File.exists?(full_path), "Created file must be cleanly deleted upon rollback"
    end
  end

  describe "Tier 1 & 2: Reverse-Chronological Multi-Step Rollback (rollback_to)" do
    test "T1_R3_ROL_03: rollback_to reverses sequence of mutations back to chosen checkpoint", %{
      session: session,
      temp_dir: temp_dir
    } do
      base_file = Path.join(temp_dir, "lib/evolution.ex")
      File.mkdir_p!(Path.dirname(base_file))
      File.write!(base_file, "defmodule Evolution, do: @v 1\n")

      # Mutation 1: update to @v 2
      Tools.execute(
        "patch_file",
        %{
          "path" => "lib/evolution.ex",
          "target_content" => "@v 1",
          "replacement_content" => "@v 2",
          "session_id" => session.id
        },
        temp_dir
      )

      [c1 | _] = TimeTravel.list_checkpoints(session.id)

      # Mutation 2: create helper file
      Tools.execute(
        "write_file",
        %{
          "path" => "lib/helper.ex",
          "content" => "defmodule Helper, do: :ok\n",
          "session_id" => session.id
        },
        temp_dir
      )

      # Mutation 3: update to @v 3
      Tools.execute(
        "patch_file",
        %{
          "path" => "lib/evolution.ex",
          "target_content" => "@v 2",
          "replacement_content" => "@v 3",
          "session_id" => session.id
        },
        temp_dir
      )

      assert File.read!(base_file) =~ "@v 3"
      assert File.exists?(Path.join(temp_dir, "lib/helper.ex"))

      tx_id = c1.transaction_id || c1.id
      {:ok, rollback_summary} = TimeTravel.rollback_to(tx_id, session_id: session.id)

      assert rollback_summary.reverted_checkpoints == 2
      assert File.read!(base_file) =~ "@v 2"
      refute File.exists?(Path.join(temp_dir, "lib/helper.ex"))
    end

    test "T2_R3_ROL_01: rolling back to non-existent checkpoint returns error tuple", %{
      session: session
    } do
      assert {:error, :checkpoint_not_found} =
               TimeTravel.rollback_to("invalid_tx_id", session_id: session.id)
    end

    test "T2_R3_ROL_02: rolling back when already at target checkpoint is a clean no-op", %{
      session: session,
      temp_dir: temp_dir
    } do
      Tools.execute(
        "write_file",
        %{"path" => "single.txt", "content" => "initial", "session_id" => session.id},
        temp_dir
      )

      [c1] = TimeTravel.list_checkpoints(session.id)
      tx_id = c1.transaction_id || c1.id

      result = TimeTravel.rollback_to(tx_id, session_id: session.id)
      assert match?({:ok, _}, result)
    end
  end

  describe "Tier 3: PubSub Broadcasts & Status Tracking" do
    test "T3_R3_ROL_01: rollback broadcasts {:checkpoint_rolled_back, tx_id, details} to session topic",
         %{
           session: session,
           temp_dir: temp_dir
         } do
      Tools.execute(
        "write_file",
        %{"path" => "revert_me.txt", "content" => "will be reverted", "session_id" => session.id},
        temp_dir
      )

      {:ok, _} = TimeTravel.rollback_latest(session.id)

      assert_receive {:checkpoint_rolled_back, _tx_id, _details}, 1000
    end
  end
end
