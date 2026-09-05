defmodule IexCode.Desktop.DesktopE2ETest do
  use IexCode.DataCase, async: false

  alias IexCode.Desktop.Lifecycle
  alias IexCode.Repo
  alias IexCode.Tools.TerminalSupervisor
  alias IexCodeWeb.MenuBar
  alias IexCodeWeb.TrayMenu
  alias Mix.Tasks.Desktop.Package
  alias Phoenix.PubSub

  describe "1. Desktop Window Child Spec & Menu Integration" do
    test "desktop_child/0 returns complete Desktop.Window child specification when enabled" do
      original_env = Application.get_env(:iex_code, :start_desktop_window)

      try do
        Application.put_env(:iex_code, :start_desktop_window, true)

        child_spec = IexCode.Application.desktop_child()
        assert {Desktop.Window, opts} = child_spec

        assert opts[:app] == :iex_code
        assert opts[:id] == IexCodeWindow
        assert opts[:title] == "IexCode - Desktop AI Coding Harness"
        assert opts[:size] == {1440, 920}
        assert opts[:min_size] == {1024, 700}
        assert opts[:icon] == "desktop/AppIcon.png"
        assert opts[:taskbar_icon] == "desktop/AppIcon.png"
        assert opts[:menubar] == IexCodeWeb.MenuBar

        expected_icon_menu =
          if match?({:unix, :darwin}, :os.type()), do: nil, else: IexCodeWeb.TrayMenu

        assert opts[:icon_menu] == expected_icon_menu
        assert opts[:on_close] == :quit

        assert is_function(opts[:url], 0)
        resolved_url = opts[:url].()
        assert is_binary(resolved_url)
        assert resolved_url =~ ~r/^https?:\/\//

        expected_native_lifecycle =
          if match?({:unix, :darwin}, :os.type()), do: IexCode.Desktop.NativeLifecycle

        assert IexCode.Application.desktop_native_lifecycle_child() == expected_native_lifecycle
      after
        Application.put_env(:iex_code, :start_desktop_window, original_env)
      end
    end

    test "desktop_child/0 returns nil when start_desktop_window is false" do
      original_env = Application.get_env(:iex_code, :start_desktop_window)

      try do
        Application.put_env(:iex_code, :start_desktop_window, false)
        assert IexCode.Application.desktop_child() == nil
      after
        Application.put_env(:iex_code, :start_desktop_window, original_env)
      end
    end

    test "MenuBar renders valid XML with full menu hierarchy, accelerators, and parses cleanly" do
      assigns = %{active_tab: "kanban"}
      rendered = MenuBar.render(assigns)
      rendered_str = Phoenix.HTML.Safe.to_iodata(rendered) |> IO.iodata_to_binary()

      # Top-level menubar container
      assert rendered_str =~ "<menubar"

      # Menus
      assert rendered_str =~ ~s(label="File")
      assert rendered_str =~ ~s(label="Edit")
      assert rendered_str =~ ~s(label="View")
      assert rendered_str =~ ~s(label="Workspace")
      assert rendered_str =~ ~s(label="Help")

      # Accelerators
      assert rendered_str =~ "Ctrl+N"
      assert rendered_str =~ "Ctrl+,"
      assert rendered_str =~ "Ctrl+W"
      assert rendered_str =~ "Ctrl+Q"
      assert rendered_str =~ "Ctrl+Z"
      assert rendered_str =~ "Ctrl+Shift+Z"
      assert rendered_str =~ "Ctrl+X"
      assert rendered_str =~ "Ctrl+C"
      assert rendered_str =~ "Ctrl+V"
      assert rendered_str =~ "Ctrl+R"
      assert rendered_str =~ "Ctrl+J"
      assert rendered_str =~ "Ctrl+K"
      assert rendered_str =~ "Ctrl+1"
      assert rendered_str =~ "Ctrl+2"
      assert rendered_str =~ "Ctrl+3"
      assert rendered_str =~ "Ctrl+4"
      assert rendered_str =~ "Ctrl+5"

      # Verify parser compliance
      assert {:menubar, _, menus} = Desktop.Menu.Parser.parse(rendered)
      assert length(menus) in [5, 6]
    end

    test "TrayMenu renders valid XML with essential dock items and parses cleanly" do
      assigns = %{}
      rendered = TrayMenu.render(assigns)
      rendered_str = Phoenix.HTML.Safe.to_iodata(rendered) |> IO.iodata_to_binary()

      assert rendered_str =~ "<menu"
      assert rendered_str =~ "Open IexCode"
      assert rendered_str =~ "New Workspace Session"
      assert rendered_str =~ "Quit IexCode"

      assert {:menu, _, items} = Desktop.Menu.Parser.parse(rendered)
      assert length(items) >= 3
    end

    test "MenuBar and TrayMenu broadcast actions over PubSub 'desktop:events'" do
      PubSub.subscribe(IexCode.PubSub, "desktop:events")

      menu_bar = %Desktop.Menu{assigns: %{active_tab: "kanban"}}
      tray_menu = %Desktop.Menu{assigns: %{}}

      # MenuBar broadcasts
      assert {:noreply, _} = MenuBar.handle_event("new_session", menu_bar)
      assert_receive {:desktop_action, :new_session}

      assert {:noreply, _} = MenuBar.handle_event("open_settings", menu_bar)
      assert_receive {:desktop_action, :open_settings}

      assert {:noreply, _} = MenuBar.handle_event("toggle_sidebar", menu_bar)
      assert_receive {:desktop_action, :toggle_sidebar}

      assert {:noreply, _} = MenuBar.handle_event("focus_command_palette", menu_bar)
      assert_receive {:desktop_action, :command_palette}

      assert {:noreply, _} = MenuBar.handle_event("tab_research", menu_bar)
      assert_receive {:desktop_switch_tab, "research"}

      # TrayMenu broadcasts
      assert {:noreply, _} = TrayMenu.handle_event("new_session", tray_menu)
      assert_receive {:desktop_action, :new_session}
    end
  end

  describe "2. Release Packaging via Mix.Tasks.Desktop.Package.run/1" do
    @tag :tmp_dir
    test "packages standalone macOS .app bundle with --no-dmg", %{tmp_dir: tmp_dir} do
      out_dir = Path.join(tmp_dir, "desktop_no_dmg")

      # Create fake release directory to simulate OTP release
      fake_rel_dir = Path.join(tmp_dir, "fake_rel")
      fake_bin_dir = Path.join(fake_rel_dir, "bin")
      File.mkdir_p!(fake_bin_dir)
      fake_bin = Path.join(fake_bin_dir, "iex_code")
      File.write!(fake_bin, "#!/bin/sh\necho 'iex_code release stub'")
      File.chmod!(fake_bin, 0o755)

      # Run Package task with --no-dmg
      args = [
        "--no-dmg",
        "--skip-assets",
        "--skip-release",
        "--output-dir",
        out_dir,
        "--app-name",
        "IexCodeE2E",
        "--bundle-id",
        "com.iexcode.e2e.test"
      ]

      assert {:ok, app_dir, nil} = Package.run(args)
      assert File.dir?(app_dir)
      assert Path.basename(app_dir) == "IexCodeE2E.app"

      # Contents structure
      contents_dir = Path.join(app_dir, "Contents")
      assert File.dir?(contents_dir)
      assert File.exists?(Path.join(contents_dir, "Info.plist"))
      assert File.exists?(Path.join(contents_dir, "PkgInfo"))
      assert File.exists?(Path.join([contents_dir, "MacOS", "IexCodeE2E"]))
      assert File.dir?(Path.join([contents_dir, "Resources", "rel"]))
    end

    @tag :tmp_dir
    test "packages standalone macOS .app bundle with DMG generation when hdiutil is available", %{
      tmp_dir: tmp_dir
    } do
      out_dir = Path.join(tmp_dir, "desktop_with_dmg")

      args = [
        "--skip-assets",
        "--skip-release",
        "--output-dir",
        out_dir,
        "--app-name",
        "IexCodeDMG",
        "--bundle-id",
        "com.iexcode.dmg.test",
        "--dmg-name",
        "IexCodeDMG-E2E.dmg"
      ]

      case Package.run(args) do
        {:ok, app_dir, dmg_path} ->
          assert File.dir?(app_dir)

          if dmg_path do
            assert File.exists?(dmg_path)
            assert File.stat!(dmg_path).size > 0
            assert Path.extname(dmg_path) == ".dmg"

            # If hdiutil is present, verify disk image info
            if System.find_executable("hdiutil") && match?({:unix, :darwin}, :os.type()) do
              {info_output, exit_code} = System.cmd("hdiutil", ["imageinfo", dmg_path])
              assert exit_code == 0
              assert info_output =~ "Format:" or info_output =~ "UDZO"
            end
          end

        {:error, reason} ->
          flunk("Package.run failed with error: #{inspect(reason)}")
      end
    end
  end

  describe "3. Plist XML Structure & Apple plutil -lint Compliance" do
    @tag :tmp_dir
    test "generates valid XML plist matching macOS specs and passes plutil -lint", %{
      tmp_dir: tmp_dir
    } do
      plist_xml =
        Package.info_plist(
          app_name: "IexCodeE2E",
          bundle_id: "com.iexcode.app.e2e",
          version: "0.1.0",
          year: 2026
        )

      # 1. XML Header and DOCTYPE assertions
      assert plist_xml =~ "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
      assert plist_xml =~ "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\""
      assert plist_xml =~ "<plist version=\"1.0\">"

      # 2. Key-value pairs
      assert plist_xml =~
               "<key>CFBundleIdentifier</key>\n    <string>com.iexcode.app.e2e</string>"

      assert plist_xml =~ "<key>CFBundleExecutable</key>\n    <string>IexCodeE2E</string>"
      assert plist_xml =~ "<key>CFBundleName</key>\n    <string>IexCodeE2E</string>"
      assert plist_xml =~ "<key>CFBundleDisplayName</key>\n    <string>IexCodeE2E</string>"
      assert plist_xml =~ "<key>CFBundlePackageType</key>\n    <string>APPL</string>"
      assert plist_xml =~ "<key>CFBundleShortVersionString</key>\n    <string>0.1.0</string>"
      assert plist_xml =~ "<key>CFBundleVersion</key>\n    <string>0.1.0</string>"
      assert plist_xml =~ "<key>NSHighResolutionCapable</key>\n    <true/>"
      assert plist_xml =~ "<key>NSSupportsAutomaticGraphicsSwitching</key>\n    <true/>"
      assert plist_xml =~ "<key>LSMinimumSystemVersion</key>\n    <string>12.0</string>"
      assert plist_xml =~ "<key>CFBundleDevelopmentRegion</key>\n    <string>en</string>"
      assert plist_xml =~ "<key>CFBundleIconFile</key>\n    <string>AppIcon</string>"
      assert plist_xml =~ "<key>NSHumanReadableCopyright</key>"
      assert plist_xml =~ "Copyright (c) 2026 IexCodeE2E. All rights reserved."

      # 3. Floki DOM tree validation
      assert {:ok, document} = Floki.parse_document(plist_xml)
      assert Floki.find(document, "dict") != []
      assert Floki.find(document, "key") != []

      # 4. Apple plutil -lint validation on macOS
      if System.find_executable("plutil") && match?({:unix, :darwin}, :os.type()) do
        plist_path = Path.join(tmp_dir, "Info.plist")
        File.write!(plist_path, plist_xml)

        {lint_output, exit_code} = System.cmd("plutil", ["-lint", plist_path])
        assert exit_code == 0, "Apple plutil -lint failed: #{lint_output}"
        assert lint_output =~ "OK" or lint_output =~ plist_path
      end
    end
  end

  describe "4. Launcher Script Execution Semantics & File Permissions" do
    @tag :tmp_dir
    test "assembles bundle with 0o755 executable permissions and correct launcher envs", %{
      tmp_dir: tmp_dir
    } do
      out_dir = Path.join(tmp_dir, "launcher_perms_test")
      fake_rel_dir = Path.join(tmp_dir, "fake_release")
      fake_bin = Path.join([fake_rel_dir, "bin", "iex_code"])
      File.mkdir_p!(Path.dirname(fake_bin))
      File.write!(fake_bin, "#!/bin/sh\necho running")
      File.chmod!(fake_bin, 0o755)

      app_dir =
        Package.assemble_bundle(
          output_dir: out_dir,
          app_name: "IexCodePerms",
          bundle_id: "com.iexcode.perms",
          version: "0.1.0",
          release_src_dir: fake_rel_dir
        )

      launcher_path = Path.join([app_dir, "Contents", "MacOS", "IexCodePerms"])
      assert File.exists?(launcher_path)

      # Verify launcher file permissions have user executable bit set
      stat = File.stat!(launcher_path)
      assert Bitwise.band(stat.mode, 0o100) != 0, "Launcher must be user executable"
      assert Bitwise.band(stat.mode, 0o111) != 0, "Launcher must have executable bits"

      # Verify launcher script content
      script_content = File.read!(launcher_path)
      assert script_content =~ "#!/bin/bash"
      assert script_content =~ "set -e"
      assert script_content =~ ~s(export DESKTOP_WINDOW="${DESKTOP_WINDOW:-true}")
      assert script_content =~ ~s(export PHX_SERVER="${PHX_SERVER:-true}")
      assert script_content =~ ~s(export PORT="${PORT:-4000}")
      assert script_content =~ ~s(export IEX_CODE_BIND="${IEX_CODE_BIND:-127.0.0.1}")
      assert script_content =~ ~s(APP_SUPPORT_DIR="$HOME/Library/Application Support/IexCode")

      assert script_content =~
               ~s(export DATABASE_PATH="${DATABASE_PATH:-$APP_SUPPORT_DIR/iex_code.db}")

      assert script_content =~ ~s(SECRET_FILE="$APP_SUPPORT_DIR/secret_key_base")
      assert script_content =~ ~s(exec "$REL_DIR/bin/iex_code" start)

      # Verify release executable inside Resources/rel/bin/ has 0o755 permissions
      rel_bin = Path.join([app_dir, "Contents", "Resources", "rel", "bin", "iex_code"])
      assert File.exists?(rel_bin)
      rel_stat = File.stat!(rel_bin)
      assert Bitwise.band(rel_stat.mode, 0o100) != 0
    end
  end

  describe "5. Runtime Desktop Fallbacks" do
    @tag :tmp_dir
    test "DATABASE_PATH fallback defaults to Application Support and creates directory", %{
      tmp_dir: tmp_dir
    } do
      app_support_dir = Path.join(tmp_dir, "AppSupportDir")
      db_path = Package.fallback_database_path(nil, app_support_dir)

      assert db_path == Path.join(app_support_dir, "iex_code.db")
      assert File.dir?(app_support_dir)
    end

    @tag :tmp_dir
    test "DATABASE_PATH preserves explicit path from environment", %{tmp_dir: tmp_dir} do
      explicit_path = Path.join([tmp_dir, "custom_db_dir", "production.db"])
      db_path = Package.fallback_database_path(explicit_path, tmp_dir)

      assert db_path == explicit_path
      assert File.dir?(Path.dirname(explicit_path))
    end

    @tag :tmp_dir
    test "SECRET_KEY_BASE fallback generates 64-byte key with 0o600 perms and persists it", %{
      tmp_dir: tmp_dir
    } do
      app_support_dir = Path.join(tmp_dir, "AppSupportDir")

      # First call: creates and writes secret_key_base file
      secret1 = Package.fallback_secret_key_base(nil, app_support_dir)
      assert is_binary(secret1)
      assert byte_size(secret1) >= 64

      secret_file = Path.join(app_support_dir, "secret_key_base")
      assert File.exists?(secret_file)
      assert File.read!(secret_file) == secret1

      stat = File.stat!(secret_file)
      # Check 0o600 permissions (group/other cannot read/write)
      assert Bitwise.band(stat.mode, 0o077) == 0

      # Second call: returns existing saved key
      secret2 = Package.fallback_secret_key_base(nil, app_support_dir)
      assert secret2 == secret1
    end

    @tag :tmp_dir
    test "SECRET_KEY_BASE fallback reads legacy .secret_key_base and respects explicit env key",
         %{
           tmp_dir: tmp_dir
         } do
      app_support_dir = Path.join(tmp_dir, "AppSupportDir")
      File.mkdir_p!(app_support_dir)

      legacy_file = Path.join(app_support_dir, ".secret_key_base")
      legacy_val = "legacy_secret_key_base_value_64_bytes_long_012345678901234567890123456789"
      File.write!(legacy_file, legacy_val)

      assert Package.fallback_secret_key_base(nil, app_support_dir) == legacy_val

      # Explicit key
      explicit_key = "explicit_secret_key_from_env_at_least_64_bytes_long_1234567890123456789"
      assert Package.fallback_secret_key_base(explicit_key, app_support_dir) == explicit_key
    end

    test "Endpoint URL fallback defaults to http localhost:4000 and https:443 for remote" do
      local_url = Package.fallback_endpoint_url(nil, nil)
      assert local_url[:host] == "localhost"
      assert local_url[:port] == 4000
      assert local_url[:scheme] == "http"

      remote_url = Package.fallback_endpoint_url("app.iexcode.dev", "8080")
      assert remote_url[:host] == "app.iexcode.dev"
      assert remote_url[:port] == 443
      assert remote_url[:scheme] == "https"
    end
  end

  describe "6. Clean Lifecycle Teardown Pipeline & SQLite WAL Checkpoint" do
    test "IexCode.Repo.checkpoint_wal/0 executes PRAGMA wal_checkpoint(TRUNCATE)" do
      assert {:ok, result} = Repo.checkpoint_wal()
      assert is_map(result)
      assert is_list(result.rows)
      assert length(result.rows) == 1

      [row] = result.rows
      assert length(row) == 3
      assert [busy, log, checkpointed] = row
      assert is_integer(busy) and busy >= 0
      assert is_integer(log) and log >= 0
      assert is_integer(checkpointed) and checkpointed >= 0
    end

    test "Lifecycle.teardown/1 coordinates full pipeline with terminals, locks, and WAL flush" do
      session_id = "e2e_lifecycle_terminal_#{System.unique_integer([:positive])}"

      if Process.whereis(TerminalSupervisor) do
        {:ok, pid} = TerminalSupervisor.start_session(session_id)
        assert Process.alive?(pid)

        assert {:ok, results} = Lifecycle.teardown(halt: false)

        assert is_map(results)
        assert match?({:ok, _}, results.terminals)
        assert match?({:ok, _}, results.workspace_locks)
        assert match?({:ok, _}, results.wal) or match?({:error, _}, results.wal)

        refute Process.alive?(pid)
      else
        assert {:ok, results} = Lifecycle.teardown(halt: false)
        assert is_map(results)
      end
    end

    test "Lifecycle teardown supports selective stage execution and custom halt callback" do
      assert {:ok, skipped} =
               Lifecycle.teardown(
                 kill_terminals: false,
                 release_locks: false,
                 flush_wal: false,
                 halt: false
               )

      assert skipped.terminals == :skipped
      assert skipped.workspace_locks == :skipped
      assert skipped.wal == :skipped

      test_pid = self()

      assert {:ok, _} =
               Lifecycle.teardown(
                 halt: true,
                 halt_fn: fn -> send(test_pid, :desktop_teardown_halt_invoked) end
               )

      assert_received :desktop_teardown_halt_invoked
    end

    test "Lifecycle exit hooks and orphan cleanup execute safely" do
      assert Lifecycle.register_shutdown_hook() == :ok
      assert Lifecycle.at_exit() == :ok
      assert {:ok, count} = Lifecycle.cleanup_orphans()
      assert is_integer(count)
    end
  end
end
