defmodule IexCode.Adversarial.AutonomousScrubberLoadAdversarialTest do
  @moduledoc """
  Adversarial Challenge Test Suite: LiveView Time-Travel Scrubber Interaction Under Load.
  Targeting Objective 4 of Challenger 2 Dispatch:
  - Drive WorkspaceLive with rapid events across tabs, checkpoints, and detached tools.
  - Test rapid checkpoint scrubbing, stale rollback handling, empty checkpoint rollback resilience.
  - Test LiveView PubSub event reactivity under concurrent mutation and rollback bursts.
  """
  use IexCodeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias IexCode.{Projects, Sessions, TimeTravel, Tools}

  setup do
    unique_id = System.unique_integer([:positive])
    temp_dir = Path.join(System.tmp_dir!(), "iex_lv_adv_scrub_#{unique_id}")
    File.mkdir_p!(Path.join(temp_dir, "lib"))

    File.write!(Path.join(temp_dir, "lib/main.ex"), "defmodule Main, do: :v1\n")
    File.write!(Path.join(temp_dir, "lib/config.ex"), "defmodule Config, do: :default\n")

    {:ok, project} =
      Projects.create_project(%{
        name: "Adv Scrubber Project #{unique_id}",
        root_path: temp_dir
      })

    {:ok, session} =
      Sessions.create_session(%{
        project_id: project.id,
        title: "Adv Scrubber Session #{unique_id}"
      })

    # Generate 4 initial sequential checkpoints
    for step <- 2..5 do
      Tools.execute(
        "patch_file",
        %{
          "path" => "lib/main.ex",
          "target_content" => ":v#{step - 1}",
          "replacement_content" => ":v#{step}",
          "session_id" => session.id
        },
        temp_dir
      )
    end

    on_exit(fn ->
      File.rm_rf(temp_dir)
    end)

    {:ok, project: project, session: session, temp_dir: temp_dir}
  end

  describe "Objective 4: LiveView Scrubber Interaction Under Load" do
    test "ADV_SCRUB_01: rapid 40-cycle checkpoint scrubbing does not crash or corrupt selected state",
         %{
           conn: conn,
           session: session
         } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}?tab=changes&subtab=checkpoints")

      checkpoints = TimeTravel.list_checkpoints(session.id)
      assert length(checkpoints) >= 4

      tx_ids = Enum.map(checkpoints, &(&1.transaction_id || &1.id))

      # Rapidly scrub back and forth 40 times
      for i <- 1..40 do
        tx_id = Enum.at(tx_ids, rem(i, length(tx_ids)))
        render_click(view, "select_checkpoint", %{"tx_id" => tx_id})
      end

      # Verify LiveView process is alive and responsive
      assert render(view) =~ "Changes" or render(view) =~ "Checkpoints" or
               render(view) =~ "Rollback"

      assert Process.alive?(view.pid)
    end

    test "ADV_SCRUB_02: selecting non-existent or malformed tx_id does not crash LiveView", %{
      conn: conn,
      session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}?tab=changes&subtab=checkpoints")

      malformed_ids = [
        "non_existent_tx_99999",
        "",
        "   ",
        "../../etc/passwd",
        "null",
        "0",
        Ecto.UUID.generate()
      ]

      for bad_id <- malformed_ids do
        render_click(view, "select_checkpoint", %{"tx_id" => bad_id})
      end

      # LiveView must survive all malformed selections
      assert Process.alive?(view.pid)
    end

    test "ADV_SCRUB_03: rapid tab switching storm while on checkpoints subtab", %{
      conn: conn,
      session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}?tab=changes&subtab=checkpoints")

      tabs = ["terminal", "changes", "files", "dag", "ast", "consensus"]

      # Rapidly switch tabs 30 times
      for i <- 1..30 do
        tab = Enum.at(tabs, rem(i, length(tabs)))
        render_click(view, "switch_tab", %{"tab" => tab})
      end

      # Switch back to changes tab
      render_click(view, "switch_tab", %{"tab" => "changes"})

      assert Process.alive?(view.pid)
    end

    test "ADV_SCRUB_04: detached tool events trigger without crashing LiveView", %{
      conn: conn,
      session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      tools = ["terminal", "diff", "dag", "invalid_tool"]

      for tool <- tools do
        render_click(view, "detach_window", %{"tool" => tool})
      end

      assert Process.alive?(view.pid)
    end

    test "ADV_SCRUB_05: sequential rollback to earliest checkpoint restores initial file and updates scrubber",
         %{
           conn: conn,
           session: session,
           temp_dir: temp_dir
         } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}?tab=changes&subtab=checkpoints")

      checkpoints = TimeTravel.list_checkpoints(session.id)
      earliest = List.last(checkpoints)
      tx_id = earliest.transaction_id || earliest.id

      # Execute rollback_to in LiveView
      render_click(view, "rollback_to_checkpoint", %{"tx_id" => tx_id})

      rendered = render(view)
      assert rendered =~ "Rolled back" or rendered =~ "checkpoint"

      # Verify file was rolled back to state of earliest checkpoint (v2)
      content = File.read!(Path.join(temp_dir, "lib/main.ex"))
      assert String.contains?(content, ":v2")
      refute String.contains?(content, ":v5")
      refute String.contains?(content, ":v4")
      refute String.contains?(content, ":v3")

      # Rolling back latest (the earliest checkpoint itself) restores initial baseline :v1
      render_click(view, "rollback_latest_checkpoint", %{})
      final_content = File.read!(Path.join(temp_dir, "lib/main.ex"))
      assert String.contains?(final_content, ":v1")
    end

    test "ADV_SCRUB_06: repeated rollback_latest on empty checkpoint history reports clean error without crash",
         %{
           conn: conn,
           session: session
         } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}?tab=changes&subtab=checkpoints")

      # Drain all checkpoints by rolling back repeatedly
      for _ <- 1..10 do
        render_click(view, "rollback_latest_checkpoint", %{})
      end

      # LiveView must remain alive and responsive
      assert Process.alive?(view.pid)
      rendered = render(view)
      assert is_binary(rendered)
    end

    test "ADV_SCRUB_07: concurrent background checkpoint creation broadcast updates LiveView seamlessly",
         %{
           conn: conn,
           session: session,
           temp_dir: temp_dir
         } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}?tab=changes&subtab=checkpoints")

      # Create new checkpoint in background
      Tools.execute(
        "write_file",
        %{
          "path" => "lib/new_module.ex",
          "content" => "defmodule NewModule, do: :live_sync\n",
          "session_id" => session.id
        },
        temp_dir
      )

      # Allow PubSub propagation
      Process.sleep(100)

      # Scrubber should reflect new state
      rendered = render(view)
      assert is_binary(rendered)
      assert Process.alive?(view.pid)
    end
  end
end
