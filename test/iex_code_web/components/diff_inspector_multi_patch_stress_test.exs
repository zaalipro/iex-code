defmodule IexCodeWeb.Components.DiffInspectorMultiPatchStressTest do
  use IexCodeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias IexCode.{Projects, Sessions, TimeTravel}
  alias IexCode.Tools.Git.DiffParser
  alias IexCodeWeb.WorkspaceComponents

  describe "TimeTravel.patch_to_unified_diff/1 and checkpoint_diffs/1 edge cases" do
    test "handles newly created files (file_existed: false, nil orig)" do
      patch = %{
        "path" => "lib/new_module.ex",
        "file_existed" => false,
        "original_content" => nil,
        "new_content" => "defmodule NewMod do\n  def hello, do: :world\nend\n"
      }

      diff = TimeTravel.patch_to_unified_diff(patch)
      assert diff =~ "--- /dev/null"
      assert diff =~ "+++ b/lib/new_module.ex"
      assert diff =~ "+defmodule NewMod do"

      assert {:ok, [fd]} = DiffParser.parse(diff)
      assert fd.status == :added
      assert length(fd.hunks) == 1

      diffs = TimeTravel.checkpoint_diffs(%{patches: [patch]})
      assert length(diffs) == 1
      assert hd(diffs).status == :added
      assert hd(diffs).path == "lib/new_module.ex"
    end

    test "handles newly created empty file (new_content: empty string or nil)" do
      patch_empty = %{
        "path" => "lib/empty.ex",
        "file_existed" => false,
        "original_content" => nil,
        "new_content" => ""
      }

      diff_empty = TimeTravel.patch_to_unified_diff(patch_empty)
      assert diff_empty =~ "--- /dev/null"
      assert diff_empty =~ "+++ b/lib/empty.ex"

      assert {:ok, [fd]} = DiffParser.parse(diff_empty)
      assert fd.status == :added

      patch_nil = %{
        "path" => "lib/nil_content.ex",
        "file_existed" => false,
        "original_content" => nil,
        "new_content" => nil
      }

      diff_nil = TimeTravel.patch_to_unified_diff(patch_nil)
      assert diff_nil =~ "--- /dev/null"
      assert diff_nil =~ "+++ b/lib/nil_content.ex"
      assert {:ok, [fd_nil]} = DiffParser.parse(diff_nil)
      assert fd_nil.status == :added
    end

    test "handles deleted files (new_content: nil)" do
      patch = %{
        "path" => "lib/obsolete.ex",
        "file_existed" => true,
        "original_content" => "defmodule Obsolete do\n  def bye, do: :done\nend\n",
        "new_content" => nil
      }

      diff = TimeTravel.patch_to_unified_diff(patch)
      assert diff =~ "--- a/lib/obsolete.ex"
      assert diff =~ "+++ /dev/null"
      assert diff =~ "-defmodule Obsolete do"

      assert {:ok, [fd]} = DiffParser.parse(diff)
      assert fd.status == :deleted
      assert length(fd.hunks) == 1

      diffs = TimeTravel.checkpoint_diffs(%{patches: [patch]})
      assert hd(diffs).status == :deleted
    end

    test "handles deleted empty file" do
      patch = %{
        "path" => "lib/empty_deleted.ex",
        "file_existed" => true,
        "original_content" => "",
        "new_content" => nil
      }

      diff = TimeTravel.patch_to_unified_diff(patch)
      assert diff =~ "--- a/lib/empty_deleted.ex"
      assert diff =~ "+++ /dev/null"
      assert {:ok, [fd]} = DiffParser.parse(diff)
      assert fd.status == :deleted
    end

    test "handles unchanged file (original_content == new_content)" do
      patch = %{
        "path" => "lib/same.ex",
        "file_existed" => true,
        "original_content" => "same content\n",
        "new_content" => "same content\n"
      }

      diff = TimeTravel.patch_to_unified_diff(patch)
      assert diff == ""

      diffs = TimeTravel.checkpoint_diffs(%{patches: [patch]})
      assert hd(diffs).hunks == []
    end

    test "handles whitespace, spaces, unicode, and symbols in paths" do
      paths = [
        "lib/path with spaces/and spaces.ex",
        "lib/unicode_🚀_файл_тест.ex",
        "lib/üñîçødé/accentués.ex",
        "lib/dots.v1.2.3/file.test.ex",
        "lib/[brackets]/special(parens).ex"
      ]

      for path <- paths do
        patch = %{
          "path" => path,
          "file_existed" => true,
          "original_content" => "line1\nline2\n",
          "new_content" => "line1\nline2_modified\n"
        }

        diff = TimeTravel.patch_to_unified_diff(patch)
        assert diff =~ path
        assert {:ok, [fd]} = DiffParser.parse(diff)
        assert fd.path == path
        assert length(fd.hunks) >= 1

        diffs = TimeTravel.checkpoint_diffs(%{patches: [patch]})
        assert hd(diffs).path == path
        assert hd(diffs).status == :modified
        assert length(hd(diffs).hunks) >= 1
      end
    end
  end

  describe "Multi-patch checkpoints with 20+ files: DOM ID collisions and rendering" do
    test "renders 25 files in interactive_diff_viewer and checks DOM ID uniqueness" do
      patches =
        for i <- 1..25 do
          %{
            "path" => "lib/multi_mod_#{i}.ex",
            "file_existed" => false,
            "original_content" => nil,
            "new_content" => "defmodule MultiMod#{i} do\n  def test_#{i}, do: #{i}\nend\n"
          }
        end

      checkpoint = %{
        id: "cp-multi-25",
        transaction_id: "tx-multi-25",
        patches: patches
      }

      diffs = TimeTravel.checkpoint_diffs(checkpoint)
      assert length(diffs) == 25

      html_chunks =
        Enum.map(Enum.with_index(diffs), fn {p_diff, idx} ->
          render_component(&WorkspaceComponents.interactive_diff_viewer/1, %{
            id: "checkpoint-diff-#{checkpoint.transaction_id}-#{idx}",
            diff_text: p_diff.diff_text,
            hunks: p_diff.hunks,
            file_path: p_diff.path,
            status: p_diff.status,
            diff_mode: "split",
            is_checkpoint: true,
            rollback_tx_id: checkpoint.transaction_id
          })
        end)

      full_html = "<div id=\"container\">" <> Enum.join(html_chunks, "\n") <> "</div>"
      {:ok, document} = Floki.parse_fragment(full_html)

      all_ids = Floki.attribute(document, "[id]", "id")
      id_counts = Enum.frequencies(all_ids)
      duplicate_ids = Enum.filter(id_counts, fn {_id, count} -> count > 1 end)

      # Log duplicate IDs if any exist
      if duplicate_ids != [] do
        IO.inspect(duplicate_ids, label: "FOUND DUPLICATE DOM IDS IN MULTI-PATCH CHECKPOINT")
      end

      # We assert whether there are any duplicate DOM IDs
      assert duplicate_ids == [],
             "DOM ID collision detected in multi-patch checkpoint: #{inspect(duplicate_ids)}"
    end

    test "renders 55 files with multi-hunk modifications in interactive_diff_viewer with 0 duplicate DOM IDs" do
      # 55 files with diverse patch types:
      # - 20 added files
      # - 10 deleted files
      # - 25 modified files with multiple hunks per file
      # 20 added
      # 10 deleted
      # 25 modified files with multiple hunks (3 hunks each)
      patches =
        Enum.map(1..20, fn i ->
          %{
            "path" => "lib/added_mod_#{i}.ex",
            "file_existed" => false,
            "original_content" => nil,
            "new_content" => "defmodule AddedMod#{i} do\n  def val, do: #{i}\nend\n"
          }
        end) ++
          Enum.map(1..10, fn i ->
            %{
              "path" => "lib/deleted_mod_#{i}.ex",
              "file_existed" => true,
              "original_content" => "defmodule DelMod#{i} do\n  def bye, do: :done\nend\n",
              "new_content" => nil
            }
          end) ++
          Enum.map(1..25, fn i ->
            orig = """
            defmodule Mod#{i} do
              def part_one do
                :old_one
              end

              # context line 1
              # context line 2
              # context line 3
              # context line 4
              # context line 5
              # context line 6
              # context line 7
              # context line 8
              # context line 9
              # context line 10

              def part_two do
                :old_two
              end

              # context line 11
              # context line 12
              # context line 13
              # context line 14
              # context line 15
              # context line 16
              # context line 17
              # context line 18
              # context line 19
              # context line 20

              def part_three do
                :old_three
              end
            end
            """

            new_c = """
            defmodule Mod#{i} do
              def part_one do
                :new_one_modified
              end

              # context line 1
              # context line 2
              # context line 3
              # context line 4
              # context line 5
              # context line 6
              # context line 7
              # context line 8
              # context line 9
              # context line 10

              def part_two do
                :new_two_modified
              end

              # context line 11
              # context line 12
              # context line 13
              # context line 14
              # context line 15
              # context line 16
              # context line 17
              # context line 18
              # context line 19
              # context line 20

              def part_three do
                :new_three_modified
              end
            end
            """

            %{
              "path" => "lib/modified_mod_#{i}.ex",
              "file_existed" => true,
              "original_content" => orig,
              "new_content" => new_c
            }
          end)

      checkpoint = %{
        id: "cp-stress-55",
        transaction_id: "tx-stress-55",
        patches: patches
      }

      diffs = TimeTravel.checkpoint_diffs(checkpoint)
      assert length(diffs) == 55

      # Test both "split" and "inline" diff modes across all 55 checkpoint files
      for mode <- ["split", "inline"] do
        html_chunks =
          Enum.map(Enum.with_index(diffs), fn {p_diff, idx} ->
            render_component(&WorkspaceComponents.interactive_diff_viewer/1, %{
              id: "checkpoint-diff-#{checkpoint.transaction_id}-#{idx}",
              diff_text: p_diff.diff_text,
              hunks: p_diff.hunks,
              file_path: p_diff.path,
              status: p_diff.status,
              diff_mode: mode,
              is_checkpoint: true,
              rollback_tx_id: checkpoint.transaction_id
            })
          end)

        full_html =
          "<div id=\"stress-container-#{mode}\">" <> Enum.join(html_chunks, "\n") <> "</div>"

        {:ok, document} = Floki.parse_fragment(full_html)

        all_ids = Floki.attribute(document, "[id]", "id")

        # Ensure we actually extracted a significant number of DOM IDs (55 containers + 55 copy btns + 55 hunk cards)
        assert length(all_ids) >= 110

        id_counts = Enum.frequencies(all_ids)
        duplicate_ids = Enum.filter(id_counts, fn {_id, count} -> count > 1 end)

        assert duplicate_ids == [],
               "DOM ID collision detected in mode #{mode} with 55 files: #{inspect(duplicate_ids)}"
      end
    end

    test "renders 50 files each containing 3 distinct hunks with 0 duplicate DOM IDs (150+ hunks)" do
      multi_hunk_diff = """
      --- a/test_module.ex
      +++ b/test_module.ex
      @@ -1,5 +1,5 @@
      -defmodule TestModOld do
      +defmodule TestModNew do
       # line 1
       # line 2
       # line 3
      @@ -20,5 +20,5 @@
       # line 19
      -def old_func_a, do: :a
      +def new_func_a, do: :alpha
       # line 21
       # line 22
      @@ -40,5 +40,5 @@
       # line 39
      -def old_func_b, do: :b
      +def new_func_b, do: :beta
       # line 41
       # line 42
      """

      {:ok, [parsed_file]} = DiffParser.parse(multi_hunk_diff)
      assert length(parsed_file.hunks) == 3

      tx_id = "tx-multi-hunks-50"

      for mode <- ["split", "inline"] do
        html_chunks =
          Enum.map(1..50, fn idx ->
            render_component(&WorkspaceComponents.interactive_diff_viewer/1, %{
              id: "checkpoint-diff-#{tx_id}-#{idx}",
              diff_text: multi_hunk_diff,
              hunks: parsed_file.hunks,
              file_path: "lib/mod_#{idx}.ex",
              status: :modified,
              diff_mode: mode,
              is_checkpoint: true,
              rollback_tx_id: tx_id
            })
          end)

        full_html =
          "<div id=\"multi-hunk-container-#{mode}\">" <> Enum.join(html_chunks, "\n") <> "</div>"

        {:ok, document} = Floki.parse_fragment(full_html)

        all_ids = Floki.attribute(document, "[id]", "id")
        # 1 wrapper + 50 containers + 50 copy btns + 150 hunk cards = 251 DOM IDs
        assert length(all_ids) == 251

        # Verify all hunk cards are present and unique
        hunk_card_ids = Enum.filter(all_ids, &String.contains?(&1, "-hunk-card-"))
        assert length(hunk_card_ids) == 150

        id_counts = Enum.frequencies(all_ids)
        duplicate_ids = Enum.filter(id_counts, fn {_id, count} -> count > 1 end)

        assert duplicate_ids == [],
               "Duplicate DOM IDs detected across 150 hunks: #{inspect(duplicate_ids)}"
      end
    end

    test "renders files with identical basenames across directories with 0 duplicate DOM IDs" do
      patches = [
        %{
          "path" => "lib/foo/user.ex",
          "file_existed" => false,
          "original_content" => nil,
          "new_content" => "defmodule Foo.User do\nend\n"
        },
        %{
          "path" => "lib/bar/user.ex",
          "file_existed" => false,
          "original_content" => nil,
          "new_content" => "defmodule Bar.User do\nend\n"
        },
        %{
          "path" => "lib/baz/user.ex",
          "file_existed" => false,
          "original_content" => nil,
          "new_content" => "defmodule Baz.User do\nend\n"
        }
      ]

      checkpoint = %{id: "cp-dup-paths", transaction_id: "tx-dup-paths", patches: patches}
      diffs = TimeTravel.checkpoint_diffs(checkpoint)

      html_chunks =
        Enum.map(Enum.with_index(diffs), fn {p_diff, idx} ->
          render_component(&WorkspaceComponents.interactive_diff_viewer/1, %{
            id: "detached-checkpoint-diff-#{checkpoint.transaction_id}-#{idx}",
            diff_text: p_diff.diff_text,
            hunks: p_diff.hunks,
            file_path: p_diff.path,
            status: p_diff.status,
            diff_mode: "split",
            is_checkpoint: true,
            rollback_tx_id: checkpoint.transaction_id
          })
        end)

      full_html = "<div id=\"dup-container\">" <> Enum.join(html_chunks, "\n") <> "</div>"
      {:ok, document} = Floki.parse_fragment(full_html)
      all_ids = Floki.attribute(document, "[id]", "id")
      id_counts = Enum.frequencies(all_ids)
      duplicate_ids = Enum.filter(id_counts, fn {_id, count} -> count > 1 end)
      assert duplicate_ids == []
    end
  end

  describe "Detached.DiffLive Rollback and PubSub synchronization" do
    setup do
      unique_suffix = System.unique_integer([:positive])
      temp_root = Path.join(System.tmp_dir!(), "iex_detached_diff_stress_#{unique_suffix}")
      File.mkdir_p!(temp_root)

      {:ok, project} =
        Projects.create_project(%{
          name: "Detached Stress #{unique_suffix}",
          root_path: temp_root
        })

      {:ok, session} =
        Sessions.create_session(%{
          project_id: project.id,
          title: "Detached Stress Session #{unique_suffix}"
        })

      # Create 2 checkpoints
      f1 = Path.join(temp_root, "file_a.ex")
      File.write!(f1, "version 1\n")

      {:ok, cp1} =
        TimeTravel.create_checkpoint(%{
          session_id: session.id,
          project_root: temp_root,
          label: "Checkpoint 1",
          patches: [
            %{
              "path" => "file_a.ex",
              "file_existed" => false,
              "original_content" => nil,
              "new_content" => "version 1\n"
            }
          ]
        })

      File.write!(f1, "version 2\n")

      {:ok, cp2} =
        TimeTravel.create_checkpoint(%{
          session_id: session.id,
          project_root: temp_root,
          label: "Checkpoint 2",
          patches: [
            %{
              "path" => "file_a.ex",
              "file_existed" => true,
              "original_content" => "version 1\n",
              "new_content" => "version 2\n"
            }
          ]
        })

      on_exit(fn ->
        File.rm_rf(temp_root)
      end)

      {:ok, project: project, session: session, temp_root: temp_root, cp1: cp1, cp2: cp2}
    end

    test "detached DiffLive handles rollback_latest_checkpoint cleanly", %{
      conn: conn,
      session: session,
      cp1: cp1,
      cp2: cp2
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/detached/diff")

      # Switch to checkpoints subtab
      view
      |> element("button[phx-click='switch_changes_subtab'][phx-value-tab='checkpoints']")
      |> render_click()

      # Both checkpoints appear
      assert has_element?(view, "#checkpoint-node-#{cp1.transaction_id}")
      assert has_element?(view, "#checkpoint-node-#{cp2.transaction_id}")

      # Trigger rollback_latest_checkpoint
      view
      |> element("button[phx-click='rollback_latest_checkpoint']")
      |> render_click()

      assert render(view) =~ "Rolled back 1 checkpoint successfully"

      # Checkpoints list is refreshed
      all_cps = TimeTravel.list_checkpoints(session.id)
      active_cps = Enum.filter(all_cps, &(&1.status == "active"))
      # CP2 is rolled back, CP1 is active
      assert length(active_cps) == 1
      assert hd(active_cps).transaction_id == cp1.transaction_id

      # CP2 is rolled_back
      rolled_back_cp = Enum.find(all_cps, &(&1.transaction_id == cp2.transaction_id))
      assert rolled_back_cp.status == "rolled_back"
    end

    test "detached DiffLive handles rollback_to_checkpoint cleanly", %{
      conn: conn,
      session: session,
      cp1: cp1
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/detached/diff")

      view
      |> element("button[phx-click='switch_changes_subtab'][phx-value-tab='checkpoints']")
      |> render_click()

      # Rollback to cp1
      view
      |> element(
        "button[phx-click='rollback_to_checkpoint'][phx-value-tx_id='#{cp1.transaction_id}']"
      )
      |> render_click()

      assert render(view) =~ "Rolled back"
    end

    test "detached DiffLive handles error on rollback when no checkpoints active", %{
      conn: conn,
      session: session
    } do
      # Roll back all checkpoints first
      TimeTravel.rollback_latest(session.id)
      TimeTravel.rollback_latest(session.id)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/detached/diff")

      view
      |> element("button[phx-click='switch_changes_subtab'][phx-value-tab='checkpoints']")
      |> render_click()

      view
      |> element("button[phx-click='rollback_latest_checkpoint']")
      |> render_click()

      assert render(view) =~ "Rollback failed"
    end

    test "dual-window PubSub synchronization: main workspace and detached DiffLive", %{
      conn: conn,
      session: session,
      cp1: cp1,
      cp2: _cp2
    } do
      # Mount main workspace LiveView
      {:ok, main_view, _} = live(conn, ~p"/sessions/#{session.id}")

      # Mount detached DiffLive
      {:ok, detached_view, _} = live(conn, ~p"/sessions/#{session.id}/detached/diff")

      # Switch detached view to checkpoints
      detached_view
      |> element("button[phx-click='switch_changes_subtab'][phx-value-tab='checkpoints']")
      |> render_click()

      # Both views start with active checkpoints
      # Now trigger rollback from detached view
      detached_view
      |> element("button[phx-click='rollback_latest_checkpoint']")
      |> render_click()

      # Detached view shows success flash
      assert render(detached_view) =~ "Rolled back"

      # Synchronize main_view: it should have received PubSub {:checkpoint_rolled_back, ...}
      # Send a noop event or re-render main_view to check state
      main_html = render(main_view)
      # Check that main workspace did not crash and is responsive
      refute main_html == ""

      # Checkpoints in DB should now only have 1 active
      all_cps = TimeTravel.list_checkpoints(session.id)
      active = Enum.filter(all_cps, &(&1.status == "active"))
      assert length(active) == 1
      assert hd(active).transaction_id == cp1.transaction_id
    end

    test "detached DiffLive with 30-file checkpoint renders with 0 duplicate DOM IDs across entire LiveView page",
         %{
           conn: conn,
           session: session,
           temp_root: temp_root
         } do
      patches =
        Enum.map(1..30, fn i ->
          fpath = Path.join(temp_root, "multi_live_#{i}.ex")
          File.write!(fpath, "defmodule MultiLive#{i} do\n  def val, do: #{i}\nend\n")

          %{
            "path" => "multi_live_#{i}.ex",
            "file_existed" => false,
            "original_content" => nil,
            "new_content" => "defmodule MultiLive#{i} do\n  def val, do: #{i}\nend\n"
          }
        end)

      {:ok, cp} =
        TimeTravel.create_checkpoint(%{
          session_id: session.id,
          project_root: temp_root,
          label: "Multi 30 Checkpoint",
          patches: patches
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}/detached/diff")

      # Switch to checkpoints subtab
      view
      |> element("button[phx-click='switch_changes_subtab'][phx-value-tab='checkpoints']")
      |> render_click()

      # Select our 30-file checkpoint
      view
      |> element("#checkpoint-node-#{cp.transaction_id}")
      |> render_click()

      page_html = render(view)
      {:ok, document} = Floki.parse_fragment(page_html)

      all_ids = Floki.attribute(document, "[id]", "id")
      # Check that at least 30 file viewer diff containers are present
      viewer_ids =
        Enum.filter(
          all_ids,
          &String.starts_with?(&1, "detached-checkpoint-diff-#{cp.transaction_id}")
        )

      assert length(viewer_ids) >= 30

      id_counts = Enum.frequencies(all_ids)
      duplicate_ids = Enum.filter(id_counts, fn {_id, count} -> count > 1 end)

      assert duplicate_ids == [],
             "DOM ID collision detected in full LiveView rendering: #{inspect(duplicate_ids)}"
    end
  end
end
